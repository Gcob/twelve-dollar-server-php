#!/usr/bin/env bash
# Runs once, as root, on a clean Ubuntu 24.04: builds SQLite 3.54.1, PHP 8.5.13 and the three extensions start.sh loads (pcntl,
# sockets and PECL event) from their source tarballs. PHP and its extensions go into /opt/php-gcob, SQLite into /opt/sqlite-tuned.
# PHP is built with its FFI extension (--with-ffi, against Ubuntu's libffi): the io_uring loop of ring.php calls the kernel through it, and
# FFI is enabled for the CLI by PHP's own default (ffi.enable=preload allows it in a CLI script), so no setting is written or passed.
# Nothing else on the machine is touched: Ubuntu's own libsqlite3 stays as it is, no php.ini is written and nothing is enabled
# globally, start.sh loads the extensions with `-d extension=`.
#
# Why from source: Ubuntu 24.04 ships PHP 8.3, and this server is measured on PHP 8.5 with the JIT. Every download is
# pinned by sha256 and checked before it is unpacked; the apt packages are not pinned (the archive moves on, the pins
# below are what the build depends on).
#
# Why our own SQLite: SQLite does most of a request's work, and Ubuntu's build (3.45.1) is a general one. Built from sqlite.org's
# amalgamation with the options sqlite.org recommends for a single-threaded program, `-O2 -march=native` and profile-guided
# optimisation, it runs the server's own statements in fewer CPU cycles. The order is: the library built with -fprofile-generate,
# PHP built once against it, the training (sqlite-train.php, next to this file: a database it generates from the challenge's
# schema, then the statements of app.php), and the library built again with -fprofile-use over the first. The second build has
# the same soname and exports, so PHP is not rebuilt: it finds the optimised library at the same path (its RUNPATH).
# -march=native means the library is tuned for the machine that runs this script, which is the machine that runs the server.
#
# Every PHP tool is called by its full path: the machine may have another PHP first on its PATH (the challenge's CI
# runner has Ubuntu's 8.3), and `sudo` resets the PATH. A bare `phpize` would build the extensions for the wrong PHP.
#
# On one CPU the install takes about 5 minutes (see the README for the times measured on one arm64 core; the droplet was not measured): the
# SQLite is compiled twice and trained in between. The last line it prints says what was installed.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Why: the training and app.php are read from this folder, whatever the directory the script is started from.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PREFIX=/opt/php-gcob
SQLITE_PREFIX=/opt/sqlite-tuned
# Why fixed folders: gcc names a profile after the absolute path of the object it belongs to, so the second build must run in the
# folder of the first. Both are removed at the end.
SQLITE_SRC=/opt/sqlite-tuned-build
SQLITE_PGO=/opt/sqlite-tuned-pgo
PHP_VERSION=8.5.13
PHP_SHA256=607602acaf0c3061818e9916ec44a058e8b3d43959a83862b9cd3ec7bf5b785f   # https://www.php.net/releases/?json&version=8.5
EVENT_VERSION=3.2.0
EVENT_SHA256=fb3d4e3c9fdc79125274f2b46461492923edec6b489ed7077973f7e65f41dc1c   # https://pecl.php.net/get/event-3.2.0.tgz
# 3.54.1 was the newest release on https://sqlite.org/download.html on 2026-11-26. The sha256 is the one `sha256sum` prints for the
# file (the page lists its SHA3-256, b6ced585c750916b1052667239a12c25a7ff34e7f06e1e6e01ecb0427657d9c4, which it has too).
SQLITE_VERSION=3.54.1
SQLITE_SHA256=926ef8d3eab93fbf6e06011901273eec076b25594a4e1cdadd50c987f4f6d64e   # https://sqlite.org/2026/sqlite-autoconf-3540100.tar.gz

# build-essential, autoconf, pkg-config: the compiler and what `configure` and `phpize` need.
# libxml2-dev, libonig-dev, libsodium-dev, libffi-dev: what PHP's own configure flags below link against. There is no libsqlite3-dev:
# PHP links the SQLite built below (a machine that has one anyway finds the tuned one first, through PKG_CONFIG_PATH, and the check at the
# end of this script fails the install if the php binary does not load /opt/sqlite-tuned).
# libevent-dev: what PECL event builds against.
apt-get -o DPkg::Lock::Timeout=120 update
apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends \
  ca-certificates curl xz-utils build-essential autoconf pkg-config \
  libxml2-dev libonig-dev libsodium-dev libffi-dev libevent-dev

tmp="$(mktemp -d)"
trap 'cd /; rm -rf "$tmp" "$SQLITE_SRC" "$SQLITE_PGO"' EXIT
cd "$tmp"

fetch() { # fetch <url> <sha256> <file>
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c -
}

# The SQLite options, each one checked against what PDO and the app call:
#   THREADSAFE=0                 no mutexes (configure's --disable-threadsafe): one thread, and the two processes share nothing but the file
#   DEFAULT_MEMSTATUS=0          no memory statistics
#   DQS=0                        a "double-quoted" string is an identifier only (the app's SQL quotes with single quotes)
#   LIKE_DOESNT_MATCH_BLOBS      LIKE on a BLOB is false
#   MAX_EXPR_DEPTH=0             no expression depth limit to track
#   OMIT_DEPRECATED, OMIT_PROGRESS_CALLBACK, OMIT_SHARED_CACHE   code the app never reaches
#   USE_ALLOCA                   temporary arrays on the stack
#   _HAVE_SQLITE_CONFIG_H        makes sqlite3.c read the sqlite_cfg.h that `configure` writes (fdatasync, pread, usleep...), which the
#                                Makefile of the amalgamation leaves out: without it the library calls fsync and lseek+read
# RETURNING, WAL and ON CONFLICT are core: no option turns them off.
SQLITE_OPTIONS=(
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

# build_sqlite <profile flags>...: compiles sqlite3.c and links libsqlite3.so.0 from scratch in $SQLITE_SRC, then installs the library, its
# headers and its sqlite3.pc under $SQLITE_PREFIX. The soname is set by hand: the Makefile leaves it empty, and PHP would record the
# library as `libsqlite3.so` instead of `libsqlite3.so.0`. gcc only warns when the profile it is asked to read is missing, and the
# library would silently be an ordinary -O2 build, so a warning stops the install.
build_sqlite() {
  local log
  log="$(mktemp)"
  (
    cd "$SQLITE_SRC"
    rm -f sqlite3.o libsqlite3.so
    make libsqlite3.so CFLAGS="-O2 -march=native ${SQLITE_OPTIONS[*]} $*" LDFLAGS="-Wl,-soname,libsqlite3.so.0 $*"
    make install-dll install-headers install-pc
  ) 2>&1 | tee "$log"
  if [ "${PIPESTATUS[0]}" -ne 0 ] || grep -q -E 'profile count data file not found|-Wmissing-profile|profile data may be' "$log"; then
    echo "install: the SQLite build failed, or gcc did not find the profile it was asked to use (see the log above)" >&2
    exit 1
  fi
  rm -f "$log"
}

# The library with -fprofile-generate. One thread, so the cheapest counters.
fetch "https://sqlite.org/2026/sqlite-autoconf-3540100.tar.gz" "$SQLITE_SHA256" sqlite.tar.gz
rm -rf "$SQLITE_SRC" "$SQLITE_PGO"
mkdir -p "$SQLITE_SRC" "$SQLITE_PGO"
tar -xzf sqlite.tar.gz -C "$SQLITE_SRC" --strip-components=1
# --disable-static: one object, one library; --disable-readline: only the library is built, not the shell.
(cd "$SQLITE_SRC" && ./configure --prefix="$SQLITE_PREFIX" --disable-static --disable-readline --disable-threadsafe)
build_sqlite -fprofile-generate="$SQLITE_PGO" -fprofile-update=single

# Why each flag:
#   CFLAGS=-O2                   -O2 like Ubuntu's build, without its other flags
#   --prefix, --with-config-file-path, --with-config-file-scan-dir
#                                everything under /opt/php-gcob, and no php.ini there: start.sh passes its settings with -d
#   --disable-cgi, --disable-fpm CLI only: the server is started with `php server.php`
#   --enable-opcache             OPcache with its JIT (built in from PHP 8.5; configure ignores this flag there: it is kept because the
#                                flags match the lab's measured build)
#   --with-pdo-sqlite            pdo_sqlite against the SQLite built above: PKG_CONFIG_PATH puts its sqlite3.pc first, and the RUNPATH in
#                                LDFLAGS lets php find the library at run time without LD_LIBRARY_PATH
#   --enable-mbstring            mbstring (needs libonig)
#   --with-sodium, --with-ffi    sodium and ffi (libsodium, libffi)
#   --enable-ctype, --with-iconv ctype and iconv (iconv uses glibc)
# posix, hash and json are built in by default.
fetch "https://www.php.net/distributions/php-$PHP_VERSION.tar.xz" "$PHP_SHA256" php.tar.xz
tar -xJf php.tar.xz
(
  cd "php-$PHP_VERSION"
  PKG_CONFIG_PATH="$SQLITE_PREFIX/lib/pkgconfig" ./configure CFLAGS=-O2 "LDFLAGS=-Wl,-rpath,$SQLITE_PREFIX/lib" \
    --prefix="$PREFIX" \
    --with-config-file-path="$PREFIX/etc" \
    --with-config-file-scan-dir="$PREFIX/etc/conf.d" \
    --disable-cgi --disable-fpm \
    --enable-opcache \
    --with-pdo-sqlite \
    --enable-mbstring \
    --with-sodium \
    --with-ffi \
    --enable-ctype \
    --with-iconv
  make -j"$(nproc)"
  make install
)
mkdir -p "$PREFIX/etc/conf.d"

# pcntl and sockets: shared extensions built with phpize from the tarball PHP itself was built from.
for ext in pcntl sockets; do
  (
    cd "php-$PHP_VERSION/ext/$ext"
    "$PREFIX/bin/phpize"
    ./configure --with-php-config="$PREFIX/bin/php-config" CFLAGS=-O2
    make -j"$(nproc)"
    make install
  )
done
# Why: event's configure looks for sockets' header under PHP's include dir, and `make install` of a shared extension does
# not put it there.
mkdir -p "$("$PREFIX/bin/php-config" --include-dir)/ext/sockets"
cp "php-$PHP_VERSION/ext/sockets/php_sockets.h" "$("$PREFIX/bin/php-config" --include-dir)/ext/sockets/"

# ext-event: the core and the sockets support only, no OpenSSL and no threads.
fetch "https://pecl.php.net/get/event-$EVENT_VERSION.tgz" "$EVENT_SHA256" event.tgz
tar -xzf event.tgz
(
  cd "event-$EVENT_VERSION"
  "$PREFIX/bin/phpize"
  ./configure --with-php-config="$PREFIX/bin/php-config" CFLAGS=-O2 \
    --with-event-core --with-event-extra --enable-event-sockets \
    --without-event-openssl --without-event-pthreads
  make -j"$(nproc)"
  make install
)

# The training with the PHP just built (it loads the instrumented library). The database is generated by a process of its own and its
# profile is deleted: the 2.5 million bulk inserts are not the app's work. A training that ran no statement, or left no profile, stops
# the install: the second build would be an ordinary -O2 one.
"$PREFIX/bin/php" "$HERE/sqlite-train.php" generate "$tmp/train.db"
find "$SQLITE_PGO" -name '*.gcda' -delete
out="$("$PREFIX/bin/php" "$HERE/sqlite-train.php" run "$HERE/app.php" "$tmp/train.db")" || { echo "$out"; echo "install: the SQLite training failed" >&2; exit 1; }
echo "$out"
count="$(sed -n 's/^training: \([0-9][0-9]*\) statements.*/\1/p' <<<"$out")"
[ "${count:-0}" -gt 0 ] || { echo "install: the SQLite training ran no statement" >&2; exit 1; }
[ "$(find "$SQLITE_PGO" -name '*.gcda' | wc -l)" -gt 0 ] || { echo "install: the training wrote no profile under $SQLITE_PGO" >&2; exit 1; }
find "$tmp" -maxdepth 1 -name 'train.db*' -delete
# -fprofile-correction: counters of a run that was cut short can disagree; gcc then smooths them instead of stopping.
build_sqlite -fprofile-use="$SQLITE_PGO" -fprofile-correction
rm -rf "$SQLITE_SRC" "$SQLITE_PGO"

# Load order: sockets before event (event declares sockets as a dependency). The JIT only starts with OPcache enabled in the
# CLI, so the probe turns it on like start.sh does. Everything the server needs at runtime must be there, or the build fails: FFI too, which
# is proved by calling libc through it, with no -d setting (the way start.sh runs the server).
# php must load the SQLite built above and nothing else, and that library must be the build with its options.
# (ldd's output is read whole: `grep -q` closing the pipe early would make ldd fail under pipefail.)
loaded="$(ldd "$PREFIX/bin/php")"
grep -q "libsqlite3.so.0 => $SQLITE_PREFIX/lib/" <<<"$loaded" \
  || { echo "install: the installed binary does not load $SQLITE_PREFIX/lib/libsqlite3.so.0" >&2; exit 1; }
PHP_FLAGS=(-d extension=pcntl -d extension=sockets -d extension=event -d opcache.enable_cli=1 -d opcache.jit=tracing -d opcache.jit_buffer_size=32M)
libevent="$("$PREFIX/bin/php" "${PHP_FLAGS[@]}" --ri event | sed -n 's/^libevent2 headers version => //p')"
"$PREFIX/bin/php" "${PHP_FLAGS[@]}" -r '
$missing = array_filter(["pcntl", "posix", "sockets", "event", "pdo_sqlite", "mbstring", "ctype", "hash", "json", "Zend OPcache", "FFI"],
    fn ($name) => !extension_loaded($name));
$ffi = in_array("FFI", $missing, true) ? false : FFI::cdef("int getpid(void);", "libc.so.6")->getpid() === getmypid();
$jit = function_exists("opcache_get_status") ? (opcache_get_status(false)["jit"]["on"] ?? false) : false;
$db = new PDO("sqlite::memory:");
$sqlite = $db->query("select sqlite_version()")->fetchColumn();
$options = $db->query("pragma compile_options")->fetchAll(PDO::FETCH_COLUMN);
$single = in_array("THREADSAFE=0", $options, true);
if ($missing || !$jit || !$ffi || $sqlite !== $argv[2] || !$single) {
    fwrite(STDERR, "install: missing " . implode(", ", $missing) . ($jit ? "" : " (JIT is off)") . ($ffi ? "" : " (FFI cannot call libc)") . ($sqlite === $argv[2] ? "" : " (SQLite is $sqlite, not $argv[2])")
        . ($single ? "" : " (SQLite is not built with THREADSAFE=0)") . "\n");
    exit(1);
}
echo "sqlite compile options: ", implode(" ", $options), "\n";
echo "installed: PHP ", PHP_VERSION, ", SQLite ", $sqlite, " (THREADSAFE=0), libevent ", $argv[1], ", ext-event ", phpversion("event"),
    ", OPcache with JIT, FFI (calls libc), pcntl posix sockets event pdo_sqlite mbstring ctype hash json\n";
' -- "$libevent" "$SQLITE_VERSION"
