#!/usr/bin/env bash
# Tells, without timing anything, whether the submission's single-post query costs a re-prepare on every request, so the lever
# "the single-post query's plan" closes or gets a micro bench later.
#
#   bash lab/post-plan.sh [--image 8.5] [--seed lab/data/feed.db] [--force-reprepare]
#
# Runs lab/post-plan/post-plan.php in the lab's image, on a fresh copy of the seed made inside the container (the app's own copy:
# lab_start_app in lab/lib.sh), through the system's libsqlite3. It prints the SQLite version, whether ENABLE_STAT4 is among its compile
# options, and for the submission's `p.id = ?` (read from submissions/php-Gcob/app.php, not retyped) and for the same SQL with `p.id = +?`:
# SQLITE_STMTSTATUS_REPREPARE and SQLITE_STMTSTATUS_RUN after 10,000 executions over random existing post ids, and the EXPLAIN QUERY PLAN.
# The last line is `post-plan: closed` (no re-prepare, same plans) or `post-plan: timing needed (<why>)`.
#
# --force-reprepare is the check's fixture: a schema change halfway, which must make the counter move. --seed is for the same check
# (a seed that is missing). Exit 0 when it reports, whatever it says (it reports, it does not judge); 1 on an error (a missing image or
# seed, a PHP without FFI, a failed run).
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$LAB")"
# shellcheck source=lib.sh
source "$LAB/lib.sh"

usage() { echo "usage: lab/post-plan.sh [--image <variant>] [--seed <feed.db under lab/>] [--force-reprepare]" >&2; exit 1; }
fail() { echo "post-plan: $*" >&2; exit 1; }

image=8.5 seed="$LAB/data/feed.db" force=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --image) [ "$#" -ge 2 ] || usage; image="$2"; shift 2 ;;
    --seed) [ "$#" -ge 2 ] || usage; seed="$2"; shift 2 ;;
    --force-reprepare) force=--force-reprepare; shift ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done

# Everything is checked before the container starts.
lab_require_variant "$image" || exit 1
docker image inspect "$LAB_IMAGE:$image" >/dev/null 2>&1 || fail "image $LAB_IMAGE:$image is missing (run lab/build.sh $image)"
[ -f "$seed" ] || fail "the seed $seed is missing (run lab/seed.sh)"
seed_in="$(lab_in_container_path "$seed")" || exit 1
app_file="$REPO/submissions/php-Gcob/app.php"
[ -f "$app_file" ] || fail "$app_file is missing: the single-post SQL is read from it"

# Why: the copy is made by `cp` inside the container, like lab_start_app does: the seed is mounted read-only and in WAL mode, so
# opening it in place would leave -wal and -shm files in lab/data/.
LAB_RUN_SUBMISSIONS=1 bash "$LAB/run.sh" "$image" sh -c '
  src="$1"; app="$2"; shift 2
  cp "$src" /tmp/post-plan.db || exit 1
  exec php -d ffi.enable=1 -d memory_limit=-1 /lab/post-plan/post-plan.php /tmp/post-plan.db "$app" "$@"' post-plan \
  "$seed_in" /submissions/php-Gcob/app.php ${force:+"$force"}
