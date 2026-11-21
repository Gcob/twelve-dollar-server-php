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

# The micro harness, in quick mode (short timing, so these numbers mean nothing): the sample bench passes on one image
# with JIT on and off, and prints a median and a spread for each of its 3 cases plus the empty loop.
check_micro_sample() {
  local out rows
  out="$(bash "$LAB/micro.sh" "$LAB/micro/benches/sample.php" --images 8.4 --jit both --quick --out "$(mktemp -d)/micro.json" 2>&1)" || { echo "lab/micro.sh failed: ${out//$'\n'/ | }"; return 1; }
  rows="$(grep -c -E '^8\.4 +8\.4\.[0-9]+ +(on|off) +.* [0-9.]+ +[0-9.]+ \.\. [0-9.]+ +[0-9]+( +UNSTABLE.*)?$' <<<"$out")"
  [ "$rows" = 8 ] || { echo "expected 8 rows with a median and a spread, got $rows: ${out//$'\n'/ | }"; return 1; }
}

# A case whose check fails is reported and skipped, the other case is still timed, the run does not fail.
check_micro_skips_failed_case() {
  local out
  out="$(bash "$LAB/micro.sh" "$LAB/micro/benches/failing-check.php" --images 8.4 --jit on --quick --out "$(mktemp -d)/micro.json" 2>&1)" || { echo "lab/micro.sh failed: ${out//$'\n'/ | }"; return 1; }
  grep -q 'SKIPPED, check failed: expected 4, got 3' <<<"$out" || { echo "the failed check is not reported: ${out//$'\n'/ | }"; return 1; }
  grep -q -E 'right variant +[0-9.]+ +[0-9.]+ \.\. ' <<<"$out" || { echo "the other case was not timed: ${out//$'\n'/ | }"; return 1; }
}

# A check that passes in the first process and fails in a later one: the case is SKIPPED (not ranked with the processes
# that passed), with the process named, and the other case is still timed.
check_micro_skips_case_failing_in_later_process() {
  local out
  out="$(bash "$LAB/micro.sh" "$LAB/micro/benches/failing-check-later.php" --images 8.4 --jit on --quick --procs 2 --out "$(mktemp -d)/micro.json" 2>&1)" || { echo "lab/micro.sh failed: ${out//$'\n'/ | }"; return 1; }
  grep -q 'passes once, then fails.*SKIPPED, check failed: state left by an earlier process (process 2' <<<"$out" || { echo "the case that fails in process 2 is not skipped: ${out//$'\n'/ | }"; return 1; }
  grep -q -E 'always right +[0-9.]+ +[0-9.]+ \.\. ' <<<"$out" || { echo "the other case was not timed: ${out//$'\n'/ | }"; return 1; }
}

# Asking for JIT on with a zero JIT buffer (JIT stays off) must fail, and so must an unknown image.
check_micro_refuses_wrong_state() {
  local out
  if out="$(bash "$LAB/micro.sh" "$LAB/micro/benches/sample.php" --images 8.4 --jit on --jit-buffer-size 0 --quick --out "$(mktemp -d)/micro.json" 2>&1)"; then
    echo "JIT on with a zero buffer exited 0: ${out//$'\n'/ | }"; return 1
  fi
  grep -q 'JIT requested on but it is off' <<<"$out" || { echo "no JIT message: ${out//$'\n'/ | }"; return 1; }
  if out="$(bash "$LAB/micro.sh" "$LAB/micro/benches/sample.php" --images nope --quick 2>&1)"; then
    echo "an unknown image exited 0: $out"; return 1
  fi
}

# The macro harness against the no-op Swoole server: a short run at a low rate (the numbers mean nothing) must be valid,
# with requests, a CPU cost per request and a latency in its JSON.
check_macro_noop_is_valid() {
  local out json rc=0
  json="$(mktemp -d)/macro.json"
  out="$(bash "$LAB/macro.sh" --image 8.4 --server "$LAB/servers/noop-swoole.php" --rate 500 --duration 5 --warmup 2 --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/macro.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'VALID' <<<"$out" || { echo "the run is not marked VALID: ${out//$'\n'/ | }"; return 1; }
  jq -e '.valid == true and .results.requests > 2000 and .results.cpu_usec_per_request > 0 and .results.latency_ms.p95 > 0
         and .results.error_rate == 0 and .results.dropped_iterations == 0 and .results.memory.vmhwm_mib > 0 and .results.connections_open > 0' "$json" >/dev/null \
    || { echo "the JSON does not hold a valid run with its numbers: $(jq -c .results "$json")"; return 1; }
}

# A rate that one VU cannot hold drops iterations: the run is printed, marked INVALID (JSON too), and exits 3.
check_macro_marks_invalid_run() {
  local out json rc=0
  json="$(mktemp -d)/macro.json"
  out="$(bash "$LAB/macro.sh" --image 8.4 --server "$LAB/servers/noop-swoole.php" --rate 20000 --duration 3 --warmup 0 --pre-vus 1 --max-vus 1 --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 3 ] || { echo "expected exit 3 for an invalid run, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q '^INVALID: .*dropped iterations' <<<"$out" || { echo "the table does not say INVALID: ${out//$'\n'/ | }"; return 1; }
  jq -e '.valid == false and .results.dropped_iterations > 0' "$json" >/dev/null || { echo "the JSON does not say invalid"; return 1; }
}

# A k6 script that fails: macro.sh exits 1 and no lab-macro container is left behind.
check_macro_cleans_up_after_failure() {
  local out left rc=0
  out="$(bash "$LAB/macro.sh" --image 8.4 --server "$LAB/servers/noop-swoole.php" --rate 100 --duration 2 --warmup 0 --script "$LAB/macro/fixtures/broken.js" --out "$(mktemp -d)/macro.json" 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "expected exit 1 for a broken k6 script, got $rc: ${out//$'\n'/ | }"; return 1; }
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-macro-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
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
  check_micro_sample
  check_micro_skips_failed_case
  check_micro_skips_case_failing_in_later_process
  check_micro_refuses_wrong_state
  check_macro_noop_is_valid
  check_macro_marks_invalid_run
  check_macro_cleans_up_after_failure
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
