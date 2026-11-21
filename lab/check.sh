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
# shellcheck source=lib.sh
source "$LAB/lib.sh"

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

check_image_8_3_apt() {
  local info
  docker image inspect php-lab:8.3-apt >/dev/null 2>&1 || { echo "image php-lab:8.3-apt is missing (run lab/build.sh 8.3-apt)"; return 1; }
  info="$(bash "$LAB/run.sh" 8.3-apt php-info 2>&1)" || { echo "php-info failed: $info"; return 1; }
  grep -q '^php: 8\.3\.' <<<"$info" || { echo "php-info does not report PHP 8.3: $info"; return 1; }
  grep -qx 'swoole: 6.2.6' <<<"$info" || { echo "php-info does not report Swoole 6.2.6: $info"; return 1; }
}

# check_source_image <variant>: the source image reports the pinned PHP version, OPcache with JIT, the same SQLite as
# the apt image, and Swoole 6.2.6 (or "not built" when lab/lib.sh says this variant is built without it).
check_source_image() {
  local v="$1" php_version sha with_swoole info want_swoole apt_sqlite
  read -r php_version sha with_swoole <<<"$(lab_source_release "$v")"
  docker image inspect "php-lab:$v" >/dev/null 2>&1 || { echo "image php-lab:$v is missing (run lab/build.sh $v)"; return 1; }
  info="$(bash "$LAB/run.sh" "$v" php-info 2>&1)" || { echo "php-info failed: $info"; return 1; }
  grep -qx "php: $php_version" <<<"$info" || { echo "php-info does not report PHP $php_version: ${info//$'\n'/ | }"; return 1; }
  want_swoole=6.2.6
  [ "$with_swoole" = 1 ] || want_swoole="not built"
  grep -qx "swoole: $want_swoole" <<<"$info" || { echo "php-info does not report 'swoole: $want_swoole': ${info//$'\n'/ | }"; return 1; }
  grep -qx 'opcache: loaded' <<<"$info" || { echo "OPcache is not loaded: ${info//$'\n'/ | }"; return 1; }
  grep -qx 'jit: available' <<<"$info" || { echo "JIT is not available: ${info//$'\n'/ | }"; return 1; }
  apt_sqlite="$(bash "$LAB/run.sh" 8.3-apt php-info 2>&1 | grep '^sqlite: ')"
  grep -qxF "$apt_sqlite" <<<"$info" || { echo "SQLite differs from 8.3-apt ($apt_sqlite): ${info//$'\n'/ | }"; return 1; }
}

check_image_8_3() { check_source_image 8.3; }
check_image_8_4() { check_source_image 8.4; }
check_image_8_5() { check_source_image 8.5; }
check_image_8_6() { check_source_image 8.6; }

# Every source image was configured with the same flags (the build keeps the full list in the image).
check_source_flags_match() {
  local v flags first="" first_v=""
  for v in "${LAB_SOURCE_VARIANTS[@]}"; do
    flags="$(bash "$LAB/run.sh" "$v" cat /usr/local/etc/php/configure-flags 2>&1)" || { echo "no configure-flags file in $v: $flags"; return 1; }
    if [ -z "$first" ]; then
      first="$flags"; first_v="$v"
    elif [ "$flags" != "$first" ]; then
      echo "$v was configured differently from $first_v: $flags <> $first"
      return 1
    fi
  done
}

check_run_limits() {
  local out expected
  out="$(bash "$LAB/run.sh" 8.3-apt sh -c 'cat /sys/fs/cgroup/cpu.max /sys/fs/cgroup/memory.max /sys/fs/cgroup/memory.swap.max; ulimit -n' 2>&1)" || { echo "lab/run.sh failed: $out"; return 1; }
  expected=$'100000 100000\n2147483648\n0\n65535'
  [ "$out" = "$expected" ] || { echo "limits differ from 1 CPU, 2 GiB, no swap, 65535 fds: ${out//$'\n'/ | }"; return 1; }
}

CHECKS=(
  check_seed_files_exist
  check_seed_has_posts
  check_image_8_3_apt
  check_image_8_3
  check_image_8_4
  check_image_8_5
  check_image_8_6
  check_source_flags_match
  check_run_limits
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
