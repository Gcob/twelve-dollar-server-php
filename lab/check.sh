#!/usr/bin/env bash
# The lab's smoke suite: one line per check, `ok` or `FAIL: <reason>`, exit non-zero if any check fails.
#
#   bash lab/check.sh
#
# To add a check: write a function `check_<name>` that returns 0 or prints a reason on stdout and returns 1,
# then add its name to CHECKS.
set -uo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
DATA="$LAB/data"

check_seed_files_exist() {
  local f
  for f in feed.db tokens.json; do
    [ -f "$DATA/$f" ] || { echo "lab/data/$f is missing (run lab/seed.sh)"; return 1; }
  done
}

check_seed_has_posts() {
  local n
  # Why: immutable=1 opens the WAL-mode file without creating -wal/-shm files next to it.
  n="$(sqlite3 "file:${DATA// /%20}/feed.db?immutable=1" "SELECT count(*) FROM posts;" 2>&1)" || { echo "sqlite3 cannot read feed.db: $n"; return 1; }
  [ "$n" -gt 0 ] 2>/dev/null || { echo "posts has no rows (got: $n)"; return 1; }
}

CHECKS=(
  check_seed_files_exist
  check_seed_has_posts
)

failed=0
for check in "${CHECKS[@]}"; do
  if reason="$("$check")"; then
    echo "ok    $check"
  else
    echo "FAIL  $check: $reason"
    failed=1
  fi
done
exit "$failed"
