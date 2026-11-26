#!/usr/bin/env bash
# Runs as root, in two steps with PHP's build between them, on a clean Ubuntu 24.04: builds a SQLite of our own from sqlite.org's
# amalgamation (sha256 checked) under /opt/sqlite-tuned, with the options sqlite.org recommends for a single-threaded app, `-O2 -march=native`
# and profile-guided optimisation trained on the app's own statements. Ubuntu's libsqlite3 is never touched.
#
#   bash install-sqlite-tuned.sh generate   # 1. the library with -fprofile-generate, installed under /opt/sqlite-tuned
#   (PHP is built against it: install-php-src.sh with SQLITE_PREFIX=/opt/sqlite-tuned, then install-extras.sh)
#   bash install-sqlite-tuned.sh use        # 3. the training with that PHP, 4. the library again with -fprofile-use, installed over the first
#
# The order is the point: the training needs a PHP, and PHP is built once, against the instrumented library. Step 4 gives the same soname
# (libsqlite3.so.0) and the same exports, so PHP is not rebuilt: it finds the optimised library at the same path (RUNPATH).
# The profile (.gcda files) goes to /opt/sqlite-tuned-pgo, and the second build reads it from the same source folder, because gcc names a
# profile after the absolute path of the object it belongs to.
#
# `use` reads the training's count (lab/images/sqlite-train.php prints `training: <n> statements`) and stops the build when it is 0 or missing.
# The training is read from /tmp/sqlite-train.php, the challenge's schema from /tmp/schema.sql and the submission's SQL from /tmp/app.php
# (lab/build.sh puts them in the build context). SQLITE_TRAIN_LOOPS, when set, replaces the training's number of loops (0 makes the build fail).
#
# -march=native: the build runs on the machine that runs it. An image built on the Mac (arm64) is only for the Mac; the x86 session rebuilds
# it on its own box (lab/build.sh 8.5-sqlite there).
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Pinned like every download of the lab: the build stops on a mismatch. Read from https://sqlite.org/download.html on 2026-11-26 (3.54.1 is
# the newest release; the page lists the SHA3-256 of the file, b6ced585c750916b1052667239a12c25a7ff34e7f06e1e6e01ecb0427657d9c4, which this file
# has too; the sha256 below is the one `sha256sum` prints). To move to a new release, change the three lines and read the hash again.
SQLITE_VERSION=3.54.1
SQLITE_TARBALL=sqlite-autoconf-3540100.tar.gz
SQLITE_URL=https://sqlite.org/2026/sqlite-autoconf-3540100.tar.gz
SQLITE_SHA256=926ef8d3eab93fbf6e06011901273eec076b25594a4e1cdadd50c987f4f6d64e

PREFIX=/opt/sqlite-tuned
SRC=/opt/sqlite-tuned-build
PGO=/opt/sqlite-tuned-pgo

# sqlite.org's recommended options for a single-threaded app (https://sqlite.org/compile.html#recommended_compile_time_options), each
# one checked against what PDO and the app call:
#   THREADSAFE=0                 no mutexes: one thread, and the app's processes share nothing but the database file
#   DEFAULT_MEMSTATUS=0          no memory statistics
#   DQS=0                        a "double-quoted" string is an identifier only (the app's SQL quotes with single quotes)
#   LIKE_DOESNT_MATCH_BLOBS      LIKE on a BLOB is false
#   MAX_EXPR_DEPTH=0             no expression depth limit to track
#   OMIT_DEPRECATED, OMIT_PROGRESS_CALLBACK, OMIT_SHARED_CACHE   code the app never reaches (php's configure checks below)
#   USE_ALLOCA                   temporary arrays on the stack
# `RETURNING`, WAL and `ON CONFLICT` are core: no option turns them off. _HAVE_SQLITE_CONFIG_H makes sqlite3.c read the sqlite_cfg.h that
# `configure` writes (HAVE_FDATASYNC, HAVE_PREAD, HAVE_USLEEP...), which the Makefile of the amalgamation leaves out: without it the library
# would call fsync and lseek+read where Ubuntu's calls fdatasync and pread.
OPTIONS=(
  -DSQLITE_DEFAULT_MEMSTATUS=0
  -DSQLITE_DQS=0
  -DSQLITE_LIKE_DOESNT_MATCH_BLOBS
  -DSQLITE_MAX_EXPR_DEPTH=0
  -DSQLITE_OMIT_DEPRECATED
  -DSQLITE_OMIT_PROGRESS_CALLBACK
  -DSQLITE_OMIT_SHARED_CACHE
  -DSQLITE_USE_ALLOCA
  -D_HAVE_SQLITE_CONFIG_H
)
# THREADSAFE=0 comes from configure's --disable-threadsafe, which also writes it into the library's feature flags.

fail() { echo "BUILD FAILED: $*" >&2; exit 1; }

# fetch_source: downloads the tarball, checks it and unpacks it to $SRC, then runs `configure` there.
fetch_source() {
  apt-get update
  apt-get install -y --no-install-recommends ca-certificates curl build-essential
  rm -rf "$SRC"
  mkdir -p "$SRC"
  curl -fsSL -o "/tmp/$SQLITE_TARBALL" "$SQLITE_URL"
  echo "$SQLITE_SHA256  /tmp/$SQLITE_TARBALL" | sha256sum -c -
  tar -xzf "/tmp/$SQLITE_TARBALL" -C "$SRC" --strip-components=1
  rm "/tmp/$SQLITE_TARBALL"
  cd "$SRC"
  # --disable-static: one object, one library, no libtool; --disable-readline: only the library is built, not the shell.
  ./configure --prefix="$PREFIX" --disable-static --disable-readline --disable-threadsafe
}

# build_library <profile flags>: compiles sqlite3.c and links libsqlite3.so.0 from scratch, then installs the library, its headers and its
# sqlite3.pc under $PREFIX. The soname is set by hand: the Makefile leaves it out, and a library without one is recorded in PHP as
# `libsqlite3.so` instead of the `libsqlite3.so.0` the system's has.
build_library() {
  local profile=("$@") log
  cd "$SRC"
  rm -f sqlite3.o libsqlite3.so
  log="$(mktemp)"
  make libsqlite3.so CFLAGS="-O2 -march=native ${OPTIONS[*]} ${profile[*]}" LDFLAGS="-Wl,-soname,libsqlite3.so.0 ${profile[*]}" 2>&1 | tee "$log"
  # Why: gcc only warns when the profile of an object is missing, and the library would silently be an ordinary -O2 build.
  if grep -q -E 'profile count data file not found|-Wmissing-profile|profile data may be' "$log"; then
    fail "gcc did not find the profile it was asked to use (see the log above)"
  fi
  rm -f "$log"
  make install-dll install-headers install-pc
}

show_library() {
  echo "SQLite $SQLITE_VERSION installed under $PREFIX:"
  ls -l "$PREFIX/lib"
  cat "$PREFIX/lib/pkgconfig/sqlite3.pc"
}

step_generate() {
  fetch_source
  rm -rf "$PGO"
  mkdir -p "$PGO"
  # -fprofile-update=single: one thread, the cheapest counters.
  build_library -fprofile-generate="$PGO" -fprofile-update=single
  show_library
}

step_use() {
  [ -d "$SRC" ] || fail "$SRC is missing: run the generate step first"
  [ -x "$(command -v php)" ] || fail "php is not installed: build PHP against $PREFIX between the two steps"
  local db=/tmp/sqlite-train.db out count loops=() profiles
  [ -z "${SQLITE_TRAIN_LOOPS:-}" ] || loops=(--loops "$SQLITE_TRAIN_LOOPS")

  # The database is generated by a process of its own, and its profile is deleted: the bulk inserts are not the app's work.
  php /tmp/sqlite-train.php generate /tmp/schema.sql "$db"
  rm -f "$PGO"/*.gcda
  out="$(php /tmp/sqlite-train.php run /tmp/app.php "$db" "${loops[@]+"${loops[@]}"}")" || { echo "$out"; fail "the training failed"; }
  echo "$out"
  count="$(sed -n 's/^training: \([0-9][0-9]*\) statements.*/\1/p' <<<"$out")"
  [ "${count:-0}" -gt 0 ] || fail "the training ran no statement"
  profiles="$(find "$PGO" -name '*.gcda' | wc -l)"
  [ "$profiles" -gt 0 ] || fail "the training wrote no profile under $PGO: the instrumented library was not the one PHP loaded"
  echo "profile: $profiles file(s) under $PGO, $(du -sh "$PGO" | cut -f1)"
  rm -f "$db" "$db-wal" "$db-shm"

  # -fprofile-correction: counters of a run that was cut short can disagree; gcc then smooths them instead of stopping.
  build_library -fprofile-use="$PGO" -fprofile-correction
  show_library
  rm -rf "$SRC" "$PGO" /tmp/sqlite-train.php /tmp/schema.sql /tmp/app.php
  echo "ldd of php:"
  ldd "$(command -v php)" | grep sqlite
  php -r '
    $db = new PDO("sqlite::memory:");
    echo "version: ", $db->query("select sqlite_version()")->fetchColumn(), "\n";
    echo "options: ", implode(" ", $db->query("pragma compile_options")->fetchAll(PDO::FETCH_COLUMN)), "\n";'
}

case "${1:-}" in
  generate) step_generate ;;
  use) step_use ;;
  *) echo "usage: install-sqlite-tuned.sh generate|use" >&2; exit 2 ;;
esac
