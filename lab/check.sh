#!/usr/bin/env bash
# The lab's smoke suite: one line per check, `ok` or `FAIL: <reason>`, exit non-zero if any check fails.
#
#   bash lab/check.sh
#
# To add a check: write a function `check_<name>` that returns 0 or prints a reason on stdout and returns 1,
# then add its name to CHECKS. A check that has nothing to run (an image that is not built) prints `skip: <why>` and returns 0: the line
# reads `skip`, not `ok`.
set -uo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$LAB")"
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
  local v="$1" php_version with_swoole info want_swoole apt_sqlite
  read -r php_version _ with_swoole _ <<<"$(lab_source_release "$v")"
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

# check_source_extras <variant>: pcntl, sockets and Workerman 5.2.4 (both trees) are in the image; ext-event and Excimer 1.2.6 are there, or
# `not built` when lab/lib.sh says this variant is built without them. The phase-2 lines are checked by check_source_image.
check_source_extras() {
  local v="$1" with_event with_excimer info
  read -r _ _ _ with_event with_excimer <<<"$(lab_source_release "$v")"
  info="$(bash "$LAB/run.sh" "$v" php-info 2>&1)" || { echo "php-info failed: $info"; return 1; }
  grep -qx 'pcntl: present' <<<"$info" || { echo "pcntl is not present: ${info//$'\n'/ | }"; return 1; }
  grep -qx 'sockets: present' <<<"$info" || { echo "sockets is not present: ${info//$'\n'/ | }"; return 1; }
  if [ "$with_event" = 1 ]; then
    grep -qx 'event: 3.2.0' <<<"$info" || { echo "php-info does not report 'event: 3.2.0': ${info//$'\n'/ | }"; return 1; }
  else
    grep -qx 'event: not built' <<<"$info" || { echo "php-info does not report 'event: not built': ${info//$'\n'/ | }"; return 1; }
  fi
  if [ "$with_excimer" = 1 ]; then
    grep -qx 'excimer: 1.2.6' <<<"$info" || { echo "php-info does not report 'excimer: 1.2.6': ${info//$'\n'/ | }"; return 1; }
  else
    grep -qx 'excimer: not built' <<<"$info" || { echo "php-info does not report 'excimer: not built': ${info//$'\n'/ | }"; return 1; }
  fi
  grep -qx 'workerman: 5.2.4 (stock, nocache)' <<<"$info" || { echo "php-info does not report the two Workerman trees: ${info//$'\n'/ | }"; return 1; }
}

check_image_8_3() { check_source_image 8.3 && check_source_extras 8.3; }
check_image_8_4() { check_source_image 8.4 && check_source_extras 8.4; }
check_image_8_5() { check_source_image 8.5 && check_source_extras 8.5; }
check_image_8_6() { check_source_image 8.6 && check_source_extras 8.6; }

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

# The FFI bench runs on 8.5 with its default ffi.enable (preload allows FFI in CLI scripts): every case is timed and none is
# skipped, so each of its checks (a copy, a struct layout, a pack format, an unpack offset) passed; the JSON says what ffi.enable was.
check_micro_ffi_bench() {
  local out json rows
  json="$(mktemp -d)/micro.json"
  out="$(bash "$LAB/micro.sh" "$LAB/micro/benches/ffi.php" --images 8.5 --jit on --quick --procs 1 --out "$json" 2>&1)" || { echo "lab/micro.sh failed: ${out//$'\n'/ | }"; return 1; }
  ! grep -q 'SKIPPED' <<<"$out" || { echo "a case was skipped: $(grep 'SKIPPED' <<<"$out" | head -3 | tr '\n' '|')"; return 1; }
  rows="$(grep -c -E '^8\.5 +8\.5\.[0-9]+ +on +.* [0-9.]+ +[0-9.]+ \.\. [0-9.]+ +[0-9]+( +UNSTABLE.*)?$' <<<"$out")"
  [ "$rows" = 29 ] || { echo "expected 29 rows (28 cases and the empty loop), got $rows: ${out//$'\n'/ | }"; return 1; }
  grep -q '"ffi.enable": "preload"' "$json" || { echo "the JSON does not record ffi.enable: $(grep -c 'ffi.enable' "$json") mentions"; return 1; }
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

# The bake-off server passes every conformance case (HTTP/1.1 keep-alive, pipelining, a split request, a request with a body,
# the routes and their error bodies) and prints the socket settings it asked for at boot.
check_conformance_bake_swoole() {
  local out ok rc=0
  out="$(bash "$LAB/conformance.sh" --image 8.5 --server "$LAB/servers/bake-swoole.php" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/conformance.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" = 8 ] || { echo "expected 8 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  grep -q 'FAIL' <<<"$out" && { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'socket settings the server printed at boot: backlog=4096 tcp_nodelay=1' <<<"$out" || { echo "the socket line is missing: ${out//$'\n'/ | }"; return 1; }
}

# A server that answers wrongly: the conformance exits 1, names the cases that fail, and removes its containers.
check_conformance_fails_on_wrong_server() {
  local out left rc=0
  out="$(bash "$LAB/conformance.sh" --image 8.5 --server "$LAB/check/fixtures/wrong-swoole.php" 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "expected exit 1 for a wrong server, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q '^FAIL  noop: ' <<<"$out" || { echo "the failing case 'noop' is not named: ${out//$'\n'/ | }"; return 1; }
  grep -q '^FAIL  keep-alive: ' <<<"$out" || { echo "the failing case 'keep-alive' is not named: ${out//$'\n'/ | }"; return 1; }
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-conformance-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
}

# The count of other containers, with a fixture container that is not the run's own: a harness's JSON records only
# `other_containers.count` (never names: they would be other projects' and the results are committed), the fixture is counted,
# and the run's own containers (4 or 5) are not: the count stays within a margin of what ran before the run.
other_fixture_name=lab-check-other-fixture
other_fixture_start() {
  docker rm -f "$other_fixture_name" >/dev/null 2>&1 || true
  docker run -d --name "$other_fixture_name" "$LAB_IMAGE:8.5" sleep 600 >/dev/null
  docker ps -q | wc -l | tr -d ' '
}
other_fixture_stop() { docker rm -f "$other_fixture_name" >/dev/null 2>&1 || true; }
# other_containers_jq <running before the run, the fixture included>: a jq test on a run's JSON.
other_containers_jq() {
  echo ".other_containers | keys == [\"count\"] and .count >= 1 and .count <= $1 + 2"
}

# Other projects' container names must not reach a committed result: a run JSON holds only the count, and the results already
# committed list no name (an empty `names` from the first phases is fine).
check_public_guard() {
  local out
  # Why: the repo is public; the guard refuses e-mail addresses, home paths and the private denylist (tools/public-guard.sh).
  out="$(bash "$REPO/tools/public-guard.sh" tree 2>&1)" || { echo "${out//$'\n'/ | }"; return 1; }
}

check_public_guard_catches_leak() {
  # Why: the sample is built at run time, or the tree scan would flag this very line.
  if printf 'write to %s@%s from /%s/someone/x\n' someone realmail.io Users | bash "$REPO/tools/public-guard.sh" stdin >/dev/null 2>&1; then
    echo "the guard let an e-mail address and a home path through"; return 1
  fi
}

# AWS's traces: a private address, an `ip-N-N-N-N` host name, an id of each kind (8 or 17 hex digits) and a 12-digit account id are refused; the
# addresses that name no box (loopback, 0.0.0.0, the documentation ranges), version numbers and shorter ids pass. Built at run time, or the
# tree scan would flag these lines.
check_public_guard_catches_aws_traces() {
  local guard="$REPO/tools/public-guard.sh" sample kind hex8=deadbeef hex17=0abc123def4567890 dot=. dash=-
  for sample in "10${dot}0${dot}12${dot}34" "172${dot}31${dot}0${dot}9" "3${dot}98${dot}91${dot}79" "listening on 192${dot}168${dot}1${dot}20:80" "ip${dash}10${dash}0${dash}12${dash}34" "ip${dash}10${dash}0${dash}12${dash}34.ca-central-1.compute.internal" \
    "account $(printf '%s' 1234 5678 9012)" "arn:aws:iam::$(printf '%s' 1234 5678 9012):user/x"; do
    if printf '%s\n' "$sample" | bash "$guard" stdin >/dev/null 2>&1; then echo "the guard let '$sample' through"; return 1; fi
  done
  for kind in i sg vol eni ami subnet vpc pg key; do
    for sample in "$kind-$hex8" "$kind-$hex17" "(group $kind-$hex17)" "--id $kind-$hex8."; do
      if printf '%s\n' "$sample" | bash "$guard" stdin >/dev/null 2>&1; then echo "the guard let '$sample' through"; return 1; fi
    done
  done
  for sample in "listening on 127${dot}0${dot}0${dot}1:80" "bind 0${dot}0${dot}0${dot}0" "metadata at 169${dot}254${dot}169${dot}254" "the documentation range 192${dot}0${dot}2${dot}7" "198${dot}51${dot}100${dot}4" "203${dot}0${dot}113${dot}250" \
    "PHP 8${dot}5${dot}13" "k6 1${dot}8${dot}3" "Docker 2${dot}1${dot}12 and a 5-part 5${dot}2${dot}4${dot}1${dot}7" "a 13-digit epoch 1700000000000" "an 11-digit number 12345678901" "sg-12345 is too short" "the key-value pairs" "pg-dump" "mi-casa"; do
    printf '%s\n' "$sample" | bash "$guard" stdin >/dev/null 2>&1 || { echo "the guard refused '$sample', which names no box"; return 1; }
  done
}

# The Mac's per-user temp folder is not a home path, but it is as private: the guard refuses it, with or without /private.
check_public_guard_catches_temp_folder() {
  # Why: the sample is built at run time, or the tree scan would flag this very line.
  local dir v="var/fol"
  v="${v}ders"
  for dir in "/${v}/ab/xyz/T/tmp.1" "/private/${v}/ab/xyz/T/tmp.1"; do
    if printf 'wrote %s/run.json\n' "$dir" | bash "$REPO/tools/public-guard.sh" stdin >/dev/null 2>&1; then
      echo "the guard let $dir through"; return 1
    fi
  done
}

# The JSON files of a folder that name another container. Only an object is a run's record: a file that is an array (a list of counts,
# say) has no `other_containers` to read, and jq would fail on it.
files_naming_containers() {
  local json
  while IFS= read -r json; do
    jq -e 'if type == "object" then ((.other_containers.names // []) | length == 0) else true end' "$json" >/dev/null 2>&1 || printf ' %s' "$json"
  done < <(find "$1" -name '*.json')
}

check_results_hold_no_container_names() {
  local named
  named="$(files_naming_containers "$LAB/results")"
  [ -z "$named" ] || { echo "container names in:$named"; return 1; }
  # The fixtures: an array file and an object with no name pass, an object with a name is caught.
  named="$(files_naming_containers "$LAB/check/fixtures/container-names")"
  [ "$named" = " $LAB/check/fixtures/container-names/object-named.json" ] || { echo "the fixtures: expected only object-named.json, got:$named"; return 1; }
}

# The bake-off server under k6 on /posts/<id>, with --env, --label and the default file name: the run is valid, the JSON holds
# what the options said (extension, env, label, the server's socket line), the other containers and the memory under load.
check_macro_bake_swoole_posts_is_valid() {
  local out rc=0 json holds="" detail="" running
  running="$(other_fixture_start)"
  out="$(bash "$LAB/macro.sh" --image 8.5 --server "$LAB/servers/bake-swoole.php" --rate 500 --duration 5 --warmup 2 \
    --script "$LAB/macro/k6/posts.js" --path /posts/1 --env FOO=bar --label test 2>&1)" || rc=$?
  other_fixture_stop
  [ "$rc" = 0 ] || { echo "lab/macro.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'VALID' <<<"$out" || { echo "the run is not marked VALID: ${out//$'\n'/ | }"; return 1; }
  json="$REPO/$(sed -n 's/^wrote //p' <<<"$out")"
  [ -f "$json" ] || { echo "no JSON file at $json: ${out//$'\n'/ | }"; return 1; }
  jq -e '.valid == true and .results.requests > 2000 and .results.error_rate == 0
         and .label == "test" and .server.ext == ["swoole"] and .server.env == ["FOO=bar"]
         and .server.socket == {backlog: 4096, tcp_nodelay: 1}
         and ('"$(other_containers_jq "$running")"')
         and .results.memory.under_load.max_pss_anon_mib > 0 and .results.memory.under_load.max_pss_anon_mib < .results.memory.under_load.max_pss_mib and .results.memory.under_load.max_cgroup_current_mib > 0
         and (.results.memory.under_load.samples | keys == ["q1", "q2", "q3"])' "$json" >/dev/null && holds=yes
  detail="$(jq -c '{valid, label, other_containers, server: {ext: .server.ext, env: .server.env, socket: .server.socket}, memory: .results.memory.under_load}' "$json")"
  # Why: the default file name is part of what is tested, and it lands in lab/results/: do not leave it there.
  rm -f "$json"
  [[ "$json" == */macro-bake-swoole-test-8.5-500rps-*.json ]] || { echo "the label is not in the file name: $json"; return 1; }
  [ -n "$holds" ] || { echo "the JSON does not hold the run's options and numbers: $detail"; return 1; }
}

# The connection test against the bake-off server, a short run: every step up to --max is held (a step above it is not run),
# the JSON holds the max, both memory slopes and the server's socket line, and no container is left behind.
check_conns_holds_steps() {
  local out json rc=0 left
  json="$(mktemp -d)/conns.json"
  out="$(bash "$LAB/conns.sh" --image 8.5 --server "$LAB/servers/bake-swoole.php" --steps 200,500,900 --max 500 --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/conns.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  jq -e '.results.max_connections == 500 and .results.ceiling == null and (.steps | map(.target) == [200, 500])
         and .results.memory_per_connection.pss_kib_per_connection > 0
         and .results.memory_per_connection.cgroup_current_kib_per_connection > 0
         and .server.socket == {backlog: 4096, tcp_nodelay: 1} and .results.baseline.pss_kb > 0 and .results.baseline.pss_anon_kb > 0
         and (.other_containers | keys == ["count"])
         and (.steps | all(.probe.pss_anon_kb > 0 and .probe.pss_anon_kb < .probe.pss_kb))
         and (.steps | all(.probe.tcp_established == .held and .probe.fresh_http_code == 200))' "$json" >/dev/null \
    || { echo "the JSON does not hold a run that held 200 and 500 connections: $(jq -c '{results, steps: [.steps[] | {target, held, probe}]}' "$json")"; return 1; }
  grep -q '^  max connections (held, answered) *500 ' <<<"$out" || { echo "the table does not report 500 connections: ${out//$'\n'/ | }"; return 1; }
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-conns-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
}

# A server limited to 256 file descriptors cannot hold 300 connections: the run finds the ceiling under 256, names why, exits 0.
check_conns_finds_ceiling() {
  local out json rc=0
  json="$(mktemp -d)/conns.json"
  out="$(bash "$LAB/conns.sh" --image 8.5 --server "$LAB/servers/bake-swoole.php" --server-nofile 256 --steps 100,300 --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/conns.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  jq -e '.results.max_connections == 100 and .results.ceiling.step == 300 and .results.ceiling.held_at_stop < 256
         and (.results.ceiling.reason | length > 0) and .server.nofile == 256' "$json" >/dev/null \
    || { echo "the JSON does not hold a ceiling under 256 with a reason: $(jq -c '.results' "$json")"; return 1; }
  grep -q '^  stopped because ' <<<"$out" || { echo "the table does not say why it stopped: ${out//$'\n'/ | }"; return 1; }
}

# Two runs one after the other: the second must not fail on a source address the first one still holds in TIME_WAIT.
check_conns_back_to_back() {
  local out json1 json2 rc=0
  json1="$(mktemp -d)/conns.json"
  json2="$(mktemp -d)/conns.json"
  out="$(bash "$LAB/conns.sh" --image 8.5 --server "$LAB/servers/bake-swoole.php" --steps 100 --out "$json1" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "first run: lab/conns.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  out="$(bash "$LAB/conns.sh" --image 8.5 --server "$LAB/servers/bake-swoole.php" --steps 100 --out "$json2" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "second run: lab/conns.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  [ "$(jq -r '.client.source_addresses[0]' "$json1")" != "$(jq -r '.client.source_addresses[0]' "$json2")" ] \
    || { echo "both runs started from the same source address: $(jq -c '.client.source_addresses' "$json1")"; return 1; }
}

# The io_uring server (lab/servers/uring-noop.php, its loop on a ring through FFI) passes every conformance case, and says so at boot.
check_uring_noop_conformance() {
  local out ok rc=0
  out="$(bash "$LAB/conformance.sh" --image 8.5 --server "$LAB/servers/uring-noop.php" --ext sockets --seccomp-unconfined 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/conformance.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" = 8 ] || { echo "expected 8 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  grep -q '^event loop the server printed at boot: io_uring through FFI, 1 ring' <<<"$out" || { echo "the loop line is missing: ${out//$'\n'/ | }"; return 1; }
}

# A short stress run of the io_uring server, one request at a time and pipelined, with one ring and with two: every response echoes the id
# of its request, 0 lost, and the server's own statistics line is there (requests per turn).
check_uring_noop_stress() {
  local out rc=0 rings
  for rings in 1 2; do
    out="$(bash "$LAB/stress.sh" --image 8.5 --server "$LAB/servers/uring-noop.php" --seccomp-unconfined --env "URING_RINGS=$rings" --connections 100 \
      --requests 20000 --procs 2 --pipelines 1,16 2>&1)" || rc=$?
    [ "$rc" = 0 ] || { echo "$rings ring(s): lab/stress.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
    [ "$(grep -c '^ok    pipeline=.*"matched":20000,"mismatches":0,"lost":0' <<<"$out")" = 2 ] \
      || { echo "$rings ring(s): not two clean runs of 20,000: ${out//$'\n'/ | }"; return 1; }
    grep -q '^last busy second of the server: turns=[0-9]* requests=[0-9]* .*requests_per_turn=[0-9.]*' <<<"$out" \
      || { echo "$rings ring(s): the server's statistics line is missing: ${out//$'\n'/ | }"; return 1; }
  done
}

# A server that echoes the wrong id: the stress run finds the mismatches, names a first one, exits 1 and removes its containers.
check_stress_fails_on_wrong_echo() {
  local out rc=0 left
  out="$(bash "$LAB/stress.sh" --image 8.5 --server "$LAB/check/fixtures/wrong-echo.php" --connections 10 --requests 500 --procs 1 --pipelines 1 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "lab/stress.sh exited $rc, expected 1: ${out//$'\n'/ | }"; return 1; }
  grep -q '^FAIL  pipeline=1: .*"mismatches":[1-9]' <<<"$out" || { echo "no mismatch reported: ${out//$'\n'/ | }"; return 1; }
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-stress-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
}

# The connection test on the io_uring server: every step is held and answered while the process's own file descriptors stay under 100
# (the connections are direct descriptors of the ring, not descriptors of the process).
check_uring_noop_holds_connections_without_fds() {
  local out json rc=0
  json="$(mktemp -d)/conns.json"
  out="$(bash "$LAB/conns.sh" --image 8.5 --server "$LAB/servers/uring-noop.php" --ext sockets --seccomp-unconfined --steps 1000,3000 --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/conns.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  jq -e '.results.max_connections == 3000 and .results.ceiling == null
         and (.steps | all(.probe.server_fds > 0 and .probe.server_fds < 100 and .probe.tcp_established == .held and .probe.fresh_http_code == 200))' "$json" >/dev/null \
    || { echo "the JSON does not hold 3000 connections with few descriptors: $(jq -c '[.steps[] | {target, held, fds: .probe.server_fds}]' "$json")"; return 1; }
}

# Workerman's 5 request caches (function-local statics) are all filled in the stock tree and all empty in the nocache tree,
# after the same request went through the HTTP protocol twice.
check_workerman_caches() {
  local out rc=0
  out="$(bash "$LAB/run.sh" 8.5 php /lab/servers/workerman-caches.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "workerman-caches.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  [ "$(grep -c -E '^stock +[A-Za-z:]+ +filled$' <<<"$out")" = 5 ] || { echo "the stock tree does not show 5 filled caches: ${out//$'\n'/ | }"; return 1; }
  [ "$(grep -c -E '^nocache +[A-Za-z:]+ +empty$' <<<"$out")" = 5 ] || { echo "the nocache tree does not show 5 empty caches: ${out//$'\n'/ | }"; return 1; }
}

# Workerman's bake-off server passes every conformance case on both trees (Event loop, the handler's answers, keep-alive,
# pipelining, a split request, a body then reuse) and prints the socket settings it read back from its listening socket.
check_conformance_bake_workerman() {
  local tree out ok rc
  for tree in nocache stock; do
    rc=0
    out="$(bash "$LAB/conformance.sh" --image 8.5 --server "$LAB/servers/bake-workerman.php" \
      --ext pcntl --ext sockets --ext event --env "WORKERMAN_TREE=$tree" 2>&1)" || rc=$?
    [ "$rc" = 0 ] || { echo "$tree: lab/conformance.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
    ok="$(grep -c '^ok  ' <<<"$out")"
    [ "$ok" = 8 ] || { echo "$tree: expected 8 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
    grep -q 'FAIL' <<<"$out" && { echo "$tree: a case failed: ${out//$'\n'/ | }"; return 1; }
    grep -qxF 'event loop the server printed at boot: Workerman\Events\Event' <<<"$out" || { echo "$tree: the loop is not Workerman's Event loop: ${out//$'\n'/ | }"; return 1; }
    grep -qx 'socket settings the server printed at boot: backlog=4096 tcp_nodelay=1' <<<"$out" || { echo "$tree: the socket line is missing: ${out//$'\n'/ | }"; return 1; }
  done
}

# The server refuses to start on a tree that does not exist, and without ext-event (Workerman would fall back to select() and
# the numbers would not be the Event loop's): exit 1 and a message that names the problem.
check_workerman_server_refuses() {
  local out rc=0
  out="$(bash "$LAB/run.sh" 8.5 env WORKERMAN_TREE=bogus php -d extension=pcntl -d extension=sockets -d extension=event \
    /lab/servers/bake-workerman.php 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "unknown tree: expected exit 1, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q "WORKERMAN_TREE must be 'stock' or 'nocache', got 'bogus'" <<<"$out" || { echo "unknown tree: the message does not name the tree: ${out//$'\n'/ | }"; return 1; }
  rc=0
  out="$(bash "$LAB/run.sh" 8.5 php -d extension=pcntl -d extension=sockets /lab/servers/bake-workerman.php 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "no event: expected exit 1, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q 'ext-event is not loaded' <<<"$out" || { echo "no event: the message does not say so: ${out//$'\n'/ | }"; return 1; }
}

# Workerman's bake-off server under k6 on /posts/<id>, nocache tree: the run is valid, and the JSON holds the tree (label, env),
# the extensions in their load order and the socket line the server read back.
check_macro_bake_workerman_posts_is_valid() {
  local out rc=0 json detail
  json="$(mktemp -d)/macro.json"
  out="$(bash "$LAB/macro.sh" --image 8.5 --server "$LAB/servers/bake-workerman.php" --ext pcntl --ext sockets --ext event \
    --env WORKERMAN_TREE=nocache --label nocache --rate 500 --duration 5 --warmup 2 \
    --script "$LAB/macro/k6/posts.js" --path /posts/1 --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/macro.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'VALID' <<<"$out" || { echo "the run is not marked VALID: ${out//$'\n'/ | }"; return 1; }
  jq -e '.valid == true and .results.requests > 2000 and .results.error_rate == 0
         and .label == "nocache" and .server.ext == ["pcntl", "sockets", "event"] and .server.env == ["WORKERMAN_TREE=nocache"]
         and .server.socket == {backlog: 4096, tcp_nodelay: 1}
         and .results.memory.under_load.max_pss_anon_mib > 0 and .results.memory.under_load.max_pss_anon_mib < .results.memory.under_load.max_pss_mib' "$json" >/dev/null && return 0
  detail="$(jq -c '{valid, label, server: {ext: .server.ext, env: .server.env, socket: .server.socket}, memory: .results.memory.under_load}' "$json")"
  echo "the JSON does not hold the run's options and numbers: $detail"
  return 1
}

# The DIY server's parser, on a socket pair: a complete request, cut at every byte position, pipelined, a body split from its
# headers, Connection and HTTP/1.0 rules, every kind of 400, a client that leaves. Every case prints `ok`.
check_diy_parser() {
  local out ok rc=0
  out="$(bash "$LAB/run.sh" 8.5 php /lab/check/diy-parser-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "diy-parser-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" = 40 ] || { echo "expected 40 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  grep -q 'FAIL' <<<"$out" && { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
  return 0
}

# The DIY server's write path, on a socket pair whose client end does not read: a partial write leaves the rest buffered and the
# bytes arrive whole and in order; reading pauses over the buffer limit.
check_diy_partial_write() {
  local out ok rc=0
  out="$(bash "$LAB/run.sh" 8.5 php /lab/check/diy-partial-write-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "diy-partial-write-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" = 4 ] || { echo "expected 4 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  grep -q 'FAIL' <<<"$out" && { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
  return 0
}

# The DIY server's soft connection limit, on a socket pair and one TCP pair, without the loop: below the limit the bytes are today's,
# above it the response says close and the connection ends after it, a client that asked for close is not counted, and a close with
# unread bytes in the receive buffer reaches the client as the end of the stream and not as a reset.
check_diy_soft_limit() {
  local out ok rc=0
  out="$(bash "$LAB/run.sh" 8.5 php /lab/check/diy-soft-limit-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "diy-soft-limit-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" = 8 ] || { echo "expected 8 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  grep -q 'FAIL' <<<"$out" && { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
  return 0
}

# The DIY server passes every conformance case and prints the socket settings it read back from its listening socket.
check_conformance_bake_diy() {
  local out ok rc=0
  out="$(bash "$LAB/conformance.sh" --image 8.5 --server "$LAB/servers/bake-diy.php" --ext sockets --ext event 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/conformance.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" = 8 ] || { echo "expected 8 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  grep -q 'FAIL' <<<"$out" && { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'event loop the server printed at boot: epoll' <<<"$out" || { echo "the loop line is not epoll: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'socket settings the server printed at boot: backlog=4096 tcp_nodelay=1' <<<"$out" || { echo "the socket line is missing: ${out//$'\n'/ | }"; return 1; }
}

# The DIY server under k6 on /posts/<id>: the run is valid, and the JSON holds the extensions in their load order and the socket line.
check_macro_bake_diy_posts_is_valid() {
  local out rc=0 json detail
  json="$(mktemp -d)/macro.json"
  out="$(bash "$LAB/macro.sh" --image 8.5 --server "$LAB/servers/bake-diy.php" --ext sockets --ext event --label diy --rate 500 --duration 5 --warmup 2 \
    --script "$LAB/macro/k6/posts.js" --path /posts/1 --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/macro.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'VALID' <<<"$out" || { echo "the run is not marked VALID: ${out//$'\n'/ | }"; return 1; }
  jq -e '.valid == true and .results.requests > 2000 and .results.error_rate == 0
         and .label == "diy" and .server.ext == ["sockets", "event"]
         and .server.socket == {backlog: 4096, tcp_nodelay: 1}
         and .results.memory.under_load.max_pss_anon_mib > 0 and .results.memory.under_load.max_pss_anon_mib < .results.memory.under_load.max_pss_mib' "$json" >/dev/null && return 0
  detail="$(jq -c '{valid, label, server: {ext: .server.ext, socket: .server.socket}, memory: .results.memory.under_load}' "$json")"
  echo "the JSON does not hold the run's options and numbers: $detail"
  return 1
}

# The challenge app's own cases, through handler_handle on a small database: what the challenge's suite does not reach (the JWT
# rules, the body rules, one like per user, the feed's size and order, a write committed before the response).
check_app_cases() {
  local out ok rc=0
  out="$(bash "$LAB/run.sh" 8.5 php /lab/check/app-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "app-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" = 60 ] || { echo "expected 60 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  grep -q 'FAIL' <<<"$out" && { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
  return 0
}

# The S6 variants (APP_FEED_SQL, APP_FETCH, APP_JSON, APP_PRAGMAS) through the app's entry point on a small database: every combination answers
# the same bytes as the unset one (APP_JSON=sqlite: the same decoded values, and the same bytes but for U+2028 and U+2029), and the literal answers,
# the refused values and combinations, the presets and the join's plan hold (96 cases).
check_app_variants_cases() {
  local out ok rc=0
  out="$(bash "$LAB/run.sh" 8.5 php /lab/check/app-variants-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "app-variants-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" = 96 ] || { echo "expected 96 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  ! grep -q 'FAIL' <<<"$out" || { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
}

# The challenge's 42 checks (the golden feed byte for byte) against the server with each non-default value of the S6 switches (APP_JSON
# included: concat and sqlite each give the golden feed and posts), and with three of them together.
check_challenge_test_passes_each_s6_variant() {
  local out env left rc
  for env in APP_FEED_SQL=join APP_FEED_SQL=two-step APP_FETCH=num APP_FETCH=assoc-loop APP_FETCH=num-loop \
             APP_JSON=concat APP_JSON=sqlite "APP_JSON=sqlite APP_PRAGMAS=mmap-off" "APP_JSON=concat APP_FEED_SQL=join APP_PRAGMAS=mmap-off" \
             APP_PRAGMAS=mmap-off APP_PRAGMAS=cache-256m APP_PRAGMAS=cache-8m "APP_FEED_SQL=join APP_FETCH=num-loop APP_PRAGMAS=cache-8m"; do
    rc=0
    # shellcheck disable=SC2046 # one --env per word on purpose
    out="$(bash "$LAB/challenge-test.sh" --image 8.5 $(printf -- '--env %s ' $env) 2>&1)" || rc=$?
    [ "$rc" = 0 ] || { echo "$env: lab/challenge-test.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
    grep -qx 'passed=42 failed=0' <<<"$out" || { echo "$env: the summary is not 'passed=42 failed=0': ${out//$'\n'/ | }"; return 1; }
  done
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-challenge-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
}

# The switches reach the server: it says which variants it runs (and nothing when none is set), and it refuses a value that is not a name.
check_s6_switches_reach_the_server() {
  local log
  start_app_for_check lab-check-variants 18164 0 APP_FEED_SQL=join APP_FETCH=num APP_PRAGMAS=mmap-off || return 1
  log="$(docker logs lab-check-variants 2>&1)"
  docker rm -f lab-check-variants >/dev/null 2>&1
  grep -qx 'app variants: feed_sql=join fetch=num json=encode pragmas=mmap-off locking=normal group_commit=off checkpointer=off' <<<"$log" || { echo "the boot lines do not name the variants: ${log//$'\n'/ | }"; return 1; }
  start_app_for_check lab-check-variants 18164 0 || return 1
  log="$(docker logs lab-check-variants 2>&1)"
  docker rm -f lab-check-variants >/dev/null 2>&1
  ! grep -q 'app variants' <<<"$log" || { echo "an app with no switch names variants: ${log//$'\n'/ | }"; return 1; }
  log="$(start_app_for_check lab-check-variants 18164 0 APP_FETCH=both)" && { docker rm -f lab-check-variants >/dev/null 2>&1; echo "a bad APP_FETCH was accepted"; return 1; }
  docker rm -f lab-check-variants >/dev/null 2>&1
  grep -q 'APP_FETCH must be one of assoc, num, assoc-loop, num-loop, got "both"' <<<"$log" || { echo "the refusal does not say why: $log"; return 1; }
  # APP_JSON shows in the boot line, and a combination it cannot work with is refused at boot with the reason.
  start_app_for_check lab-check-variants 18164 0 APP_JSON=sqlite || return 1
  log="$(docker logs lab-check-variants 2>&1)"
  docker rm -f lab-check-variants >/dev/null 2>&1
  grep -qx 'app variants: feed_sql=reference fetch=assoc json=sqlite pragmas=default locking=normal group_commit=off checkpointer=off' <<<"$log" || { echo "the boot lines do not name APP_JSON: ${log//$'\n'/ | }"; return 1; }
  log="$(start_app_for_check lab-check-variants 18164 0 APP_JSON=sqlite APP_FEED_SQL=join)" && { docker rm -f lab-check-variants >/dev/null 2>&1; echo "APP_JSON=sqlite with APP_FEED_SQL=join was accepted"; return 1; }
  docker rm -f lab-check-variants >/dev/null 2>&1
  grep -q 'APP_JSON=sqlite cannot be set with APP_FEED_SQL=join' <<<"$log" || { echo "the refusal does not say why: $log"; return 1; }
}

# APP_DRIVER=ffi reads the feed and the posts through FFI straight to libsqlite3, on a small database: the same bytes as PDO's for every APP_JSON value
# and pragma preset, rows with escapes and a NUL byte, the PDO pragmas on the connection, the boot refusing another SQLite version than PDO's, no
# statement left un-reset, and the switch refused without the bench flag and with the SQL and fetch shapes it cannot read (31 cases).
check_app_ffi_cases() {
  local out ok rc=0
  out="$(bash "$LAB/run.sh" 8.5 php /lab/check/app-ffi-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "app-ffi-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" = 31 ] || { echo "expected 31 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  ! grep -q 'FAIL' <<<"$out" || { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
}

# APP_DRIVER reaches the server: unset it says nothing about a driver, ffi alone is refused with the reason, and with the bench flag the boot says the
# driver and SQLite's version and the feed and a post come out as PDO's bytes.
check_app_driver_reaches_the_server() {
  local log pdo ffi json
  start_app_for_check lab-check-driver 18167 0 || return 1
  log="$(docker logs lab-check-driver 2>&1)"
  pdo="$(docker exec lab-check-driver sh -c 'curl -s http://127.0.0.1:18167/feed; curl -s http://127.0.0.1:18167/posts/250000')"
  docker rm -f lab-check-driver >/dev/null 2>&1
  ! grep -q 'driver:' <<<"$log" || { echo "the default names a driver: ${log//$'\n'/ | }"; return 1; }
  log="$(start_app_for_check lab-check-driver 18167 0 APP_DRIVER=ffi)" && { docker rm -f lab-check-driver >/dev/null 2>&1; echo "APP_DRIVER=ffi without the bench flag was accepted"; return 1; }
  docker rm -f lab-check-driver >/dev/null 2>&1
  grep -q 'APP_DRIVER_BENCH=1' <<<"$log" || { echo "the refusal does not say why: $log"; return 1; }
  for json in APP_JSON=encode APP_JSON=sqlite; do
    start_app_for_check lab-check-driver 18167 0 APP_DRIVER=ffi APP_DRIVER_BENCH=1 "$json" || return 1
    log="$(docker logs lab-check-driver 2>&1)"
    ffi="$(docker exec lab-check-driver sh -c 'curl -s http://127.0.0.1:18167/feed; curl -s http://127.0.0.1:18167/posts/250000')"
    docker rm -f lab-check-driver >/dev/null 2>&1
    grep -Eqx 'driver: ffi \(SQLite [0-9.]+, reads only: for the micro bench\)' <<<"$log" || { echo "the boot lines do not name the driver: ${log//$'\n'/ | }"; return 1; }
    [ "$ffi" = "$pdo" ] || { echo "$json: the feed and a post differ from PDO's: ${ffi:0:200}"; return 1; }
  done
}

# The 42 checks against the server with APP_LOCKING=exclusive, and no container left behind.
check_challenge_test_passes_with_exclusive_locking() {
  local out left rc=0
  out="$(bash "$LAB/challenge-test.sh" --image 8.5 --env APP_LOCKING=exclusive 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/challenge-test.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'passed=42 failed=0' <<<"$out" || { echo "the summary is not 'passed=42 failed=0': ${out//$'\n'/ | }"; return 1; }
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-challenge-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
}

# APP_LOCKING reaches the server: it names the variant at boot, refuses a value that is not a name, and while it runs another process
# cannot open its database (the lock the switch keeps), where with the switch unset another process reads it.
check_app_locking_reaches_the_server() {
  local log other value
  for value in exclusive normal; do
    start_app_for_check lab-check-locking 18165 0 APP_LOCKING=$value || return 1
    log="$(docker logs lab-check-locking 2>&1)"
    # Unset (or the default name) the server says nothing about variants.
    if [ "$value" = exclusive ]; then
      grep -qx 'app variants: feed_sql=reference fetch=assoc json=encode pragmas=default locking=exclusive group_commit=off checkpointer=off' <<<"$log" \
        || { docker rm -f lab-check-locking >/dev/null 2>&1; echo "the boot lines do not name the variant: ${log//$'\n'/ | }"; return 1; }
    else
      ! grep -q 'app variants' <<<"$log" || { docker rm -f lab-check-locking >/dev/null 2>&1; echo "the default names a variant: ${log//$'\n'/ | }"; return 1; }
    fi
    docker exec lab-check-locking sh -c 'curl -s -o /dev/null http://127.0.0.1:18165/feed' >/dev/null 2>&1 || true
    other="$(docker exec lab-check-locking php -r '
      try { $db = new PDO("sqlite:" . $argv[1]); $db->exec("PRAGMA busy_timeout = 0"); $db->query("SELECT count(*) FROM likes")->fetchColumn(); echo "read"; }
      catch (PDOException $e) { echo $e->getMessage(); }' "$LAB_APP_DB" 2>&1)"
    docker rm -f lab-check-locking >/dev/null 2>&1
    case "$value:$other" in
      exclusive:*"database is locked"*) ;;
      normal:read) ;;
      *) echo "APP_LOCKING=$value: another process got '$other'"; return 1 ;;
    esac
  done
  log="$(start_app_for_check lab-check-locking 18165 0 APP_LOCKING=shared)" && { docker rm -f lab-check-locking >/dev/null 2>&1; echo "a bad APP_LOCKING was accepted"; return 1; }
  docker rm -f lab-check-locking >/dev/null 2>&1
  grep -q 'APP_LOCKING must be one of normal, exclusive, got "shared"' <<<"$log" || { echo "the refusal does not say why: $log"; return 1; }
}

# The point of APP_LOCKING: the lock calls of every transaction (fcntl) are gone from the count. Unset, a request makes about 2.4 of
# them; with exclusive locking, none beyond the few the process makes once (the opcache's).
check_app_locking_removes_the_lock_calls() {
  local value json out rc
  for value in normal exclusive; do
    json="$(mktemp -d)/syscalls.json"
    rc=0
    out="$(bash "$LAB/syscalls.sh" --image 8.5 --rate 300 --think-scale 0.2 --seconds 5 --env APP_LOCKING=$value --out "$json" 2>&1)" || rc=$?
    [ "$rc" = 0 ] || { echo "APP_LOCKING=$value: lab/syscalls.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
    if [ "$value" = normal ]; then
      jq -e '[.syscalls[] | select(.name == "fcntl") | .calls_per_request][0] > 1.5' "$json" >/dev/null || { echo "unset: fcntl is not above 1.5 a request: $(jq -c '.syscalls[:3]' "$json")"; return 1; }
    else
      jq -e '([.syscalls[] | select(.name == "fcntl") | .calls_per_request][0] // 0) < 0.05 and .total.calls_per_request < 4.2' "$json" >/dev/null \
        || { echo "exclusive: fcntl is not gone: $(jq -c '.syscalls[:4]' "$json")"; return 1; }
    fi
  done
}

# The DIY server's loop driven one turn at a time, and its group commit, over TCP with the clients in the test's process: a request is served
# through a hand-driven LOOP_ONCE, two writes of one turn are one commit and are answered after it, a write holds the requests behind it
# (responses in the order of the requests, two pipelined writes with no stall), Connection: close after a write.
check_diy_group_commit() {
  local out ok rc=0
  out="$(bash "$LAB/run.sh" 8.5 php -d extension=sockets -d extension=event /lab/check/diy-group-commit-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "diy-group-commit-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" = 9 ] || { echo "expected 9 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  ! grep -q 'FAIL' <<<"$out" || { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
}

# The loop presets (APP_LOOP) on the DIY server in the test's process: each builds the base it names (libevent's own method text proves it), a
# server on it serves requests, an unknown name is refused (9 cases); then the group commit's own cases (the order of the responses, the
# writes of a turn in one commit) on each preset.
check_diy_loop_presets() {
  local out ok rc=0 preset
  out="$(bash "$LAB/run.sh" 8.5 php -d extension=sockets -d extension=event /lab/check/diy-loop-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "diy-loop-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" = 9 ] || { echo "expected 9 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  ! grep -q 'FAIL' <<<"$out" || { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
  for preset in nolock changelist poll; do
    rc=0
    out="$(bash "$LAB/run.sh" 8.5 php -d extension=sockets -d extension=event /lab/check/diy-group-commit-test.php "$preset" 2>&1)" || rc=$?
    [ "$rc" = 0 ] || { echo "$preset: diy-group-commit-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
    ok="$(grep -c '^ok  ' <<<"$out")"
    [ "$ok" = 9 ] || { echo "$preset: expected 9 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
    ! grep -q 'FAIL' <<<"$out" || { echo "$preset: a case failed: ${out//$'\n'/ | }"; return 1; }
  done
}

# The challenge's 42 checks against the server with each loop preset, and with each of them and group commit, and no container left behind.
check_challenge_test_passes_with_loop_presets() {
  local out preset left group rc extra
  for preset in nolock changelist poll; do
    for group in 0 1; do
      extra=()
      [ "$group" = 0 ] || extra=(--env APP_GROUP_COMMIT=1)
      rc=0
      out="$(bash "$LAB/challenge-test.sh" --image 8.5 --env "APP_LOOP=$preset" "${extra[@]+"${extra[@]}"}" 2>&1)" || rc=$?
      [ "$rc" = 0 ] || { echo "$preset (group commit $group): lab/challenge-test.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
      grep -qx 'passed=42 failed=0' <<<"$out" || { echo "$preset (group commit $group): the summary is not 'passed=42 failed=0': ${out//$'\n'/ | }"; return 1; }
    done
  done
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-challenge-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
}

# APP_LOOP reaches the server: the `loop:` line says the method alone when it is unset (as it always did) and the preset with its flags when
# it is set (alone, and with 2 workers), and a name that is not a preset is refused at boot with the list.
check_app_loop_reaches_the_server() {
  local log
  start_app_for_check lab-check-loop 18166 0 || return 1
  log="$(docker logs lab-check-loop 2>&1)"
  docker rm -f lab-check-loop >/dev/null 2>&1
  grep -qx 'loop: epoll' <<<"$log" || { echo "unset, the loop line is not 'loop: epoll': ${log//$'\n'/ | }"; return 1; }
  start_app_for_check lab-check-loop 18166 0 APP_LOOP=changelist || return 1
  log="$(docker logs lab-check-loop 2>&1)"
  docker rm -f lab-check-loop >/dev/null 2>&1
  grep -qx 'loop: epoll (with changelist), preset changelist (flags EPOLL_USE_CHANGELIST)' <<<"$log" || { echo "the loop line does not name the preset: ${log//$'\n'/ | }"; return 1; }
  ! grep -q 'app variants' <<<"$log" || { echo "a loop preset is named as an app variant: ${log//$'\n'/ | }"; return 1; }
  CHECK_APP_EXT_EXTRA=pcntl start_app_for_check lab-check-loop 18166 0 APP_LOOP=poll APP_WORKERS=2 || return 1
  log="$(docker logs lab-check-loop 2>&1)"
  docker rm -f lab-check-loop >/dev/null 2>&1
  grep -qx 'loop: poll, preset poll (avoids epoll)' <<<"$log" || { echo "with workers the loop line does not name the preset: ${log//$'\n'/ | }"; return 1; }
  log="$(start_app_for_check lab-check-loop 18166 0 APP_LOOP=epoll)" && { docker rm -f lab-check-loop >/dev/null 2>&1; echo "a bad APP_LOOP was accepted"; return 1; }
  docker rm -f lab-check-loop >/dev/null 2>&1
  grep -q 'APP_LOOP must be one of nolock, changelist, poll, got "epoll"' <<<"$log" || { echo "the refusal does not say why: $log"; return 1; }
}

# The S9 switches through the app: the values and their refusals, the writes of a batch each in a savepoint (one that fails rolls back
# alone and answers 500), a DiyServer in the test's process with the real app (two writes in one turn, a like then a read pipelined, two
# likes pipelined), and lab/app/server.php as a process (a 201 survives SIGKILL, the checkpointer copies the WAL back and ends with the server,
# the telemetry line has the batches).
check_app_group_commit_cases() {
  local out ok rc=0
  out="$(bash "$LAB/run.sh" 8.5 php -d extension=sockets -d extension=event /lab/check/app-group-commit-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "app-group-commit-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" = 29 ] || { echo "expected 29 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  ! grep -q 'FAIL' <<<"$out" || { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
}

# The challenge's 42 checks against the server with group commit, with the checkpointer, and with both, and no container left behind.
check_challenge_test_passes_with_group_commit_and_checkpointer() {
  local out env left rc
  for env in APP_GROUP_COMMIT=1 APP_CHECKPOINTER=1000 "APP_GROUP_COMMIT=1 APP_CHECKPOINTER=1000"; do
    rc=0
    # shellcheck disable=SC2046 # one --env per word on purpose
    out="$(bash "$LAB/challenge-test.sh" --image 8.5 $(printf -- '--env %s ' $env) 2>&1)" || rc=$?
    [ "$rc" = 0 ] || { echo "$env: lab/challenge-test.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
    grep -qx 'passed=42 failed=0' <<<"$out" || { echo "$env: the summary is not 'passed=42 failed=0': ${out//$'\n'/ | }"; return 1; }
  done
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-challenge-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
}

# APP_WORKERS (several processes on one port, lab/app/workers.php): the switch's values and refusals, the supervision with children that only
# report, and lab/app/server.php as a process with 2 workers (boot lines, each worker's own database connection, both answering 200
# connections, every write committed before its response, a worker killed, SIGTERM, the refusals).
check_app_workers_cases() {
  local out ok rc=0
  out="$(bash "$LAB/run.sh" 8.5 php -d extension=sockets -d extension=event -d extension=pcntl /lab/check/app-workers-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "app-workers-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" = 25 ] || { echo "expected 25 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  ! grep -q 'FAIL' <<<"$out" || { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
}

# The challenge's 42 checks against the server with 2 workers (and with the reference's pragmas, which the step lab measures against), started
# the way the lab starts it (`--ext sockets --ext event --ext pcntl`), and no container left behind.
check_challenge_test_passes_with_workers() {
  local out env left rc
  for env in APP_WORKERS=2 "APP_WORKERS=2 APP_PRAGMAS=mmap-off"; do
    rc=0
    # shellcheck disable=SC2046 # one --env per word on purpose
    out="$(bash "$LAB/challenge-test.sh" --image 8.5 --ext sockets --ext event --ext pcntl $(printf -- '--env %s ' $env) 2>&1)" || rc=$?
    [ "$rc" = 0 ] || { echo "$env: lab/challenge-test.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
    grep -qx 'passed=42 failed=0' <<<"$out" || { echo "$env: the summary is not 'passed=42 failed=0': ${out//$'\n'/ | }"; return 1; }
  done
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-challenge-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
}

# wait_container_ends <container> <seconds>: waits until the container is no longer running; returns 1 when it still is.
wait_container_ends() {
  for _ in $(seq 1 $(( $2 * 5 ))); do
    [ "$(docker inspect -f '{{.State.Running}}' "$1")" = true ] || return 0
    sleep 0.2
  done
  return 1
}

# Two workers in a container, where the server is the container's first process: the boot lines, 200 connections with a request each answered
# by both processes (the telemetry lines say their pid), a worker killed with SIGKILL ends the container with exit code 1 (the parent stops
# the other worker and exits), and SIGTERM to the container's first process ends it with exit code 0.
check_app_workers_in_a_container() {
  local name=lab-check-workers log pid answered total code
  CHECK_APP_EXT_EXTRA=pcntl start_app_for_check "$name" 18166 0 APP_WORKERS=2 APP_TELEMETRY=1 || return 1
  log="$(docker logs "$name" 2>&1)"
  grep -Eqx 'workers: 2 \(pids [0-9]+ [0-9]+\)' <<<"$log" || { docker rm -f "$name" >/dev/null 2>&1; echo "the boot lines do not say the workers: ${log//$'\n'/ | }"; return 1; }
  docker exec "$name" php /lab/check/conn-client.php 18166 seq 200 >/dev/null
  sleep 2.2
  log="$(docker logs "$name" 2>&1)"
  answered="$(sed -n 's/^telemetry //p' <<<"$log" | jq -s '[.[] | select((.requests["GET /health"] // 0) > 0) | .pid] | unique | length')"
  total="$(sed -n 's/^telemetry //p' <<<"$log" | jq -s '[.[].requests["GET /health"] // 0] | add')"
  if [ "$answered" != 2 ] || [ "$total" != 200 ]; then
    docker rm -f "$name" >/dev/null 2>&1
    echo "expected 200 health checks answered by 2 processes, the telemetry says $total by $answered: $(grep '^telemetry' <<<"$log" | head -n 3 | tr '\n' ' ')"
    return 1
  fi
  pid="$(sed -n 's/^workers: 2 (pids \([0-9]*\) [0-9]*)$/\1/p' <<<"$log")"
  docker exec "$name" sh -c "kill -9 $pid"
  wait_container_ends "$name" 10 || { docker logs "$name" 2>&1 | tail -n 3; docker rm -f "$name" >/dev/null 2>&1; echo "the container still runs 10 s after a worker was killed"; return 1; }
  code="$(docker inspect -f '{{.State.ExitCode}}' "$name")"
  log="$(docker logs "$name" 2>&1)"
  docker rm -f "$name" >/dev/null 2>&1
  [ "$code" = 1 ] || { echo "after a worker was killed the container exited $code, not 1: ${log//$'\n'/ | }"; return 1; }
  grep -qx "server: worker $pid was killed by signal 9, stopping the others" <<<"$log" || { echo "the parent did not say which worker was killed: ${log//$'\n'/ | }"; return 1; }
  CHECK_APP_EXT_EXTRA=pcntl start_app_for_check "$name" 18166 0 APP_WORKERS=2 || return 1
  docker kill -s TERM "$name" >/dev/null
  wait_container_ends "$name" 10 || { docker rm -f "$name" >/dev/null 2>&1; echo "the container still runs 10 s after SIGTERM"; return 1; }
  code="$(docker inspect -f '{{.State.ExitCode}}' "$name")"
  docker rm -f "$name" >/dev/null 2>&1
  [ "$code" = 0 ] || { echo "after SIGTERM the container exited $code, not 0"; return 1; }
}

# The submission, submissions/php-Gcob: the lab's chosen variants in a clean copy, with no switch.
SUBMISSION="$REPO/submissions/php-Gcob"

# The lab's runners take a server file under submissions/ too: its path in the containers is under /submissions, a file under neither
# lab/ nor submissions/ is refused, and the folder is mounted only for a start whose command names a path in it.
check_lab_hook_accepts_submissions() {
  local got tmp args
  got="$(lab_in_container_path "$SUBMISSION/server.php" 2>&1)" || { echo "refused the submission's server.php: $got"; return 1; }
  [ "$got" = /submissions/php-Gcob/server.php ] || { echo "the submission's server.php is at '$got' in the containers, not /submissions/php-Gcob/server.php"; return 1; }
  got="$(lab_in_container_path "$REPO/README.md" 2>&1)" && { echo "accepted a file under neither lab/ nor submissions/"; return 1; }
  grep -qF 'under lab/ or submissions/' <<<"$got" || { echo "the refusal does not say where a file may be: $got"; return 1; }
  tmp="$(mktemp)"
  # Why a function in place of docker: only what is passed to docker matters here, and nothing may start.
  (
    docker() { printf '%s\n' "$@" >"$tmp"; }
    LAB_ENV=()
    lab_run_server_container probe 8.5 1 php /lab/app/server.php
    args="$(cat "$tmp")"
    ! grep -q '/submissions' <<<"$args" || { echo "a server under lab/ got the submissions mount"; exit 1; }
    lab_run_server_container probe 8.5 1 php /submissions/php-Gcob/server.php
    grep -qxF "$REPO/submissions:/submissions:ro" "$tmp" || { echo "a server under submissions/ did not get it, read-only: $(tr '\n' ' ' <"$tmp")"; exit 1; }
  ) || { local rc=$?; rm -f "$tmp"; return "$rc"; }
  rm -f "$tmp"
}

# Where a submission's rules are read from; what each part of check_submission looks at is named by the prefix of the problem it prints.
SUBMISSION_REPO_URL='https://github.com/Gcob/twelve-dollar-server-php'
SUBMISSION_SWITCHES='APP_WORKERS|APP_PRAGMAS|APP_SOFT_CONN_LIMIT|APP_TELEMETRY|APP_PROFILE|APP_JSON|APP_FEED_SQL|APP_FETCH|APP_DRIVER|APP_LOCKING|APP_GROUP_COMMIT|APP_CHECKPOINTER|APP_LOOP'

# submission_static_problems <folder>: one line per rule the folder breaks, none when it keeps them all (no Docker: the lint is apart).
#  getenv     the PHP reads only SQLITE_PATH, JWT_SECRET, HOST and PORT (getenv with one of the four, no $_ENV, no $_SERVER)
#  switch     none of the lab's switch names, matched as words: a constant like APP_JSON_FLAGS is not one
#  instrument none of the lab's instruments (FFI, Excimer, the telemetry and the profiler, the checkpointer, group commit)
#  flags      start.sh runs /opt/php-gcob/bin/php with the three extensions, then LAB_SERVER_PHP_FLAGS, in that order (read from lib.sh)
#  folder     only install.sh, build.sh, start.sh, README.md, .gitignore and *.php files
#  install    install.sh exists; every curl or wget in it is followed by a `sha256sum -c` of the file it fetched; every phpize, php-config and
#             php it runs is a full path (the machine may have another PHP first on its PATH)
#  pin        install.sh pins the same PHP and ext-event as the lab's images (lab/lib.sh, lab/images/install-extras.sh)
#  readme     README.md exists; each link to this repo is a /tree/main/ or /blob/main/ link to a path of the tree; no relative link; no
#             home path and no e-mail address (tools/public-guard.sh says the same of the whole tree)
submission_static_problems() {
  local dir="$1" f name call want got entry getenv_ok="^getenv\\(['\"](SQLITE_PATH|JWT_SECRET|HOST|PORT)['\"]\\)\$"
  for f in "$dir"/*.php; do
    [ -f "$f" ] || continue
    name="$(basename "$f")"
    while IFS= read -r call; do
      [[ "$call" =~ $getenv_ok ]] || echo "getenv: $name has $call (only SQLITE_PATH, JWT_SECRET, HOST and PORT are read)"
    done < <(grep -o 'getenv([^)]*)' "$f")
    grep -q '\$_ENV\|\$_SERVER\|putenv(' "$f" && echo "getenv: $name reads or sets the environment another way (\$_ENV, \$_SERVER or putenv)"
    grep -nwE "$SUBMISSION_SWITCHES" "$f" | sed "s|^|switch: $name:|"
    { grep -nE 'FFI|Excimer|DiyTelemetry|DiyProfile' "$f"; grep -niE 'checkpointer|group_commit' "$f"; } | sed "s|^|instrument: $name:|"
  done
  submission_install_problems "$dir"
  submission_readme_problems "$dir"
  if [ -f "$dir/start.sh" ]; then
    got="$(grep -v '^[[:space:]]*#' "$dir/start.sh" | grep -o -- '-d [^ ]*' | cut -c4- | paste -sd' ' -)"
    want="extension=pcntl extension=sockets extension=event"
    for entry in "${LAB_SERVER_PHP_FLAGS[@]}"; do
      [ "$entry" = -d ] || want="$want $entry"
    done
    [ "$got" = "$want" ] || echo "flags: start.sh passes '$got', not '$want'"
    grep -q '^exec /opt/php-gcob/bin/php ' "$dir/start.sh" || echo "flags: start.sh does not exec /opt/php-gcob/bin/php"
  else
    echo "flags: there is no start.sh"
  fi
  while IFS= read -r entry; do
    name="$(basename "$entry")"
    case "$name" in
      # Why: Finder leaves it in a folder it opened; it is not part of what is committed.
      .DS_Store) ;;
      install.sh | build.sh | start.sh | README.md | .gitignore | *.php) [ -f "$entry" ] || echo "folder: $name is not a file" ;;
      *) echo "folder: $name is not allowed (install.sh, build.sh, start.sh, README.md, .gitignore and *.php files only)" ;;
    esac
  done < <(find "$dir" -mindepth 1 -maxdepth 1 | sort)
}

# submission_install_problems <folder>: the `install` and `pin` lines of submission_static_problems, for the folder's install.sh.
submission_install_problems() {
  local file="$1/install.sh" line n=0 pending="" fetched="" version sha extras_sha extras_version
  if [ ! -f "$file" ]; then echo "install: there is no install.sh"; return 0; fi
  while IFS= read -r line; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [ -n "${line//[[:space:]]/}" ] || continue
    if [ -n "$pending" ]; then
      [[ "$line" == *"sha256sum -c"* && "$line" == *"$fetched"* ]] || echo "install: line $pending downloads without a sha256sum -c of the file on the next line"
      pending=""
    fi
    if [[ "$line" =~ (^|[\&\;\|\(])[[:space:]]*(curl|wget)[[:space:]] ]]; then
      fetched="$(grep -o -- '-o [^ ]*' <<<"$line" | head -n 1 | cut -c4- | tr -d '"')"
      if [ -n "$fetched" ]; then pending="$n"; else echo "install: line $n downloads without -o <file>, so nothing can check it"; fi
    fi
    if [[ "$line" =~ (^|[^/A-Za-z0-9_.$-])(phpize|php-config|php)([[:space:]]|$|\)) ]]; then
      echo "install: line $n runs ${BASH_REMATCH[2]} without its full path (use /opt/php-gcob/bin/${BASH_REMATCH[2]})"
    fi
  done <"$file"
  [ -z "$pending" ] || echo "install: line $pending downloads and the file ends before a sha256sum -c"
  read -r version sha _ <<<"$(lab_source_release 8.5)"
  grep -q "^PHP_VERSION=$version\$" "$file" || echo "pin: install.sh does not pin PHP $version (the lab's 8.5 image)"
  grep -q "^PHP_SHA256=$sha\([[:space:]]\|\$\)" "$file" || echo "pin: install.sh's PHP_SHA256 is not the lab's $sha"
  extras_version="$(sed -n 's/^EVENT_VERSION=//p' "$LAB/images/install-extras.sh")"
  extras_sha="$(sed -n 's/^EVENT_SHA256=\([0-9a-f]*\).*/\1/p' "$LAB/images/install-extras.sh")"
  grep -q "^EVENT_VERSION=$extras_version\$" "$file" || echo "pin: install.sh does not pin ext-event $extras_version (lab/images/install-extras.sh)"
  grep -q "^EVENT_SHA256=$extras_sha\([[:space:]]\|\$\)" "$file" || echo "pin: install.sh's EVENT_SHA256 is not the lab's $extras_sha"
}

# submission_readme_problems <folder>: the `readme` lines of submission_static_problems. The README is read in the challenge's repo, where lab/ does
# not exist, so every link goes to this repo on GitHub, branch main, and the paths it names must be in this tree.
submission_readme_problems() {
  local file="$1/README.md" link path
  if [ ! -f "$file" ]; then echo "readme: there is no README.md"; return 0; fi
  while IFS= read -r link; do
    case "$link" in
      "$SUBMISSION_REPO_URL"/tree/main/* | "$SUBMISSION_REPO_URL"/blob/main/*)
        path="${link#"$SUBMISSION_REPO_URL"/*/main/}"
        path="${path%%[#?]*}"
        [ -e "$REPO/$path" ] || echo "readme: $link names a path that is not in the tree" ;;
      *) echo "readme: $link is not a /tree/main/ or /blob/main/ link" ;;
    esac
  done < <(grep -oE "${SUBMISSION_REPO_URL}[^][:space:])>\`\"]*" "$file")
  while IFS= read -r link; do
    case "$link" in
      http://* | https://* | '#'*) ;;
      *) echo "readme: the link $link is relative, and the README is read outside this repo" ;;
    esac
  done < <(grep -oE '\]\([^)]*\)' "$file" | sed 's/^](//; s/)$//')
  grep -qE '/Users/|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$file" && echo "readme: README.md has a home path or an e-mail address"
  return 0
}

# submission_shellcheck_problems <folder>: the pinned shellcheck (warning level) on install.sh, build.sh and start.sh of the folder; a line
# `shellcheck: ...` per finding.
submission_shellcheck_problems() {
  local out files=() f
  for f in install.sh build.sh start.sh; do [ -f "$1/$f" ] && files+=("$f"); done
  [ "${#files[@]}" -gt 0 ] || return 0
  out="$(docker run --rm -v "$1:/src:ro" -w /src "$LAB_SHELLCHECK_IMAGE" --severity=warning --format=gcc "${files[@]}" 2>&1)" || sed 's|^|shellcheck: |' <<<"$out"
}

# submission_lint_problems <folder>: `php -l` on every PHP file of the folder, in the lab's php-lab:8.5 image; a line `lint: ...` per file that fails.
submission_lint_problems() {
  local out
  docker image inspect "$LAB_IMAGE:8.5" >/dev/null 2>&1 || { echo "lint: image $LAB_IMAGE:8.5 is missing (run lab/build.sh 8.5)"; return 0; }
  out="$(docker run --rm "${LAB_RESOURCE_FLAGS[@]}" -v "$1:/src:ro" "$LAB_IMAGE:8.5" sh -c '
    for f in /src/*.php; do
      [ -f "$f" ] || continue
      msg="$(php -l "$f" 2>&1)" || echo "$(basename "$f"): $(echo "$msg" | head -n 1)"
    done' 2>&1)"
  [ -z "$out" ] || sed 's|^|lint: |' <<<"$out"
}

check_submission() {
  local problems
  [ -d "$SUBMISSION" ] || { echo "submissions/php-Gcob does not exist"; return 1; }
  problems="$(submission_static_problems "$SUBMISSION"; submission_lint_problems "$SUBMISSION"; submission_shellcheck_problems "$SUBMISSION")"
  [ -z "$problems" ] || { echo "${problems//$'\n'/ | }"; return 1; }
}

# Each rule of check_submission fails on a copy that breaks only that rule, and a constant that looks like a switch (APP_JSON_FLAGS) passes.
check_submission_catches_violations() {
  local tmp kind prefix problems
  [ -d "$SUBMISSION" ] || { echo "submissions/php-Gcob does not exist"; return 1; }
  tmp="$(mktemp -d)"
  problems="$(submission_static_problems "$SUBMISSION")"
  [ -z "$problems" ] || { rm -rf "$tmp"; echo "the submission itself breaks a rule: ${problems//$'\n'/ | }"; return 1; }
  cp -R "$SUBMISSION" "$tmp/ok"
  printf '<?php\nconst APP_JSON_FLAGS = 1;\nconst APP_BODY_MAX_CHARS = 2;\n$x = getenv("PORT");\n' >"$tmp/ok/constants.php"
  # Links that are right (a folder with a trailing slash, a file with an anchor, a link to another site) are not refused.
  printf '\n[a](%s/tree/main/lab/results/)\n[b](%s/blob/main/lab/README.md#the-lab)\n[c](https://example.org/x)\n' "$SUBMISSION_REPO_URL" "$SUBMISSION_REPO_URL" >>"$tmp/ok/README.md"
  problems="$(submission_static_problems "$tmp/ok")"
  [ -z "$problems" ] || { rm -rf "$tmp"; echo "constants named like a switch, getenv of PORT, and right links were refused: ${problems//$'\n'/ | }"; return 1; }
  for kind in getenv getenv-all env-array switch instrument-ffi instrument-checkpointer flags flags-order folder subfolder lint \
    no-install unpinned-download bare-phpize bare-php-config bare-php wrong-pin shellcheck \
    no-readme readme-missing-path readme-missing-file readme-other-branch readme-relative-link readme-home-path readme-email; do
    rm -rf "$tmp/f"
    cp -R "$SUBMISSION" "$tmp/f"
    case "$kind" in
      getenv) prefix=getenv; printf '<?php\n$x = getenv("APP_HOME");\n' >"$tmp/f/extra.php" ;;
      getenv-all) prefix=getenv; printf '<?php\n$x = getenv();\n' >"$tmp/f/extra.php" ;;
      env-array) prefix=getenv; printf '<?php\n$x = $_ENV["PORT"];\n' >"$tmp/f/extra.php" ;;
      switch) prefix=switch; printf '<?php\n// APP_WORKERS=2 is built in\n' >"$tmp/f/extra.php" ;;
      instrument-ffi) prefix=instrument; printf '<?php\n// FFI\n' >"$tmp/f/extra.php" ;;
      instrument-checkpointer) prefix=instrument; printf '<?php\nfunction run_checkpointer() {}\n' >"$tmp/f/extra.php" ;;
      flags) prefix=flags; sed 's/opcache.jit=tracing/opcache.jit=function/' "$SUBMISSION/start.sh" >"$tmp/f/start.sh" ;;
      flags-order) prefix=flags; sed 's/-d extension=sockets -d extension=event/-d extension=event -d extension=sockets/' "$SUBMISSION/start.sh" >"$tmp/f/start.sh"
        cmp -s "$SUBMISSION/start.sh" "$tmp/f/start.sh" && { rm -rf "$tmp"; echo "the flags-order fixture changed nothing: start.sh does not put the extensions on one line"; return 1; } ;;
      folder) prefix=folder; printf 'x\n' >"$tmp/f/notes.txt" ;;
      subfolder) prefix=folder; mkdir "$tmp/f/vendor" ;;
      lint) prefix=lint; printf '<?php\nfunction (\n' >"$tmp/f/broken.php" ;;
      no-install) prefix=install; rm "$tmp/f/install.sh" ;;
      unpinned-download) prefix=install; printf 'curl -fsSL -o extra.tgz https://example.org/extra.tgz\ntar -xzf extra.tgz\n' >>"$tmp/f/install.sh" ;;
      bare-phpize) prefix=install; printf 'phpize\n' >>"$tmp/f/install.sh" ;;
      bare-php-config) prefix=install; printf 'x="$(php-config --include-dir)"\n' >>"$tmp/f/install.sh" ;;
      bare-php) prefix=install; printf 'php -v\n' >>"$tmp/f/install.sh" ;;
      wrong-pin) prefix=pin; sed 's/^PHP_SHA256=607602/PHP_SHA256=607603/' "$SUBMISSION/install.sh" >"$tmp/f/install.sh" ;;
      shellcheck) prefix=shellcheck; printf 'echo $(date)\n' >>"$tmp/f/build.sh" ;;
      no-readme) prefix=readme; rm "$tmp/f/README.md" ;;
      readme-missing-path) prefix=readme; printf '\n[gone](%s/tree/main/lab/results/2099-01-01-nothing)\n' "$SUBMISSION_REPO_URL" >>"$tmp/f/README.md" ;;
      readme-missing-file) prefix=readme; printf '\n[gone](%s/blob/main/lab/nothing.sh)\n' "$SUBMISSION_REPO_URL" >>"$tmp/f/README.md" ;;
      readme-other-branch) prefix=readme; printf '\n[x](%s/tree/phase-6-claude/lab)\n' "$SUBMISSION_REPO_URL" >>"$tmp/f/README.md" ;;
      readme-relative-link) prefix=readme; printf '\n[x](../../lab/README.md)\n' >>"$tmp/f/README.md" ;;
      readme-home-path) prefix=readme; printf '\nrun it from %s/someone/code\n' /Users >>"$tmp/f/README.md" ;;
      readme-email) prefix=readme; printf '\nwrite to someone%s\n' @work.org >>"$tmp/f/README.md" ;;
    esac
    case "$kind" in
      lint) problems="$(submission_lint_problems "$tmp/f")" ;;
      shellcheck) problems="$(submission_shellcheck_problems "$tmp/f")" ;;
      *) problems="$(submission_static_problems "$tmp/f")" ;;
    esac
    grep -q "^$prefix: " <<<"$problems" || { rm -rf "$tmp"; echo "a copy with the '$kind' violation passes: ${problems:-no problem printed}"; return 1; }
  done
  rm -rf "$tmp"
}

# The challenge's 42 checks against the submission, started the way the lab's runners start a server file (the three extensions, no --env:
# the copy reads no switch), and no container left behind.
check_submission_passes_challenge_test() {
  local out left rc=0
  out="$(bash "$LAB/challenge-test.sh" --image 8.5 --server "$SUBMISSION/server.php" --ext pcntl --ext sockets --ext event 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/challenge-test.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'passed=42 failed=0' <<<"$out" || { echo "the summary is not 'passed=42 failed=0': ${out//$'\n'/ | }"; return 1; }
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-challenge-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
}

# The submission as a container's first process: the boot lines (2 workers, the soft limit per process, the pragmas as SQLite reads them
# back, the loop, the socket), and 200 connections held open at once, each answered, with sockets in the process table of each worker (the
# copy has no telemetry to name the process that answered). A socket the worker did not have before is a connection it accepted.
check_submission_both_workers_answer() {
  local name=lab-check-submission log pids result
  CHECK_APP_SERVER=/submissions/php-Gcob/server.php CHECK_APP_EXT_EXTRA=pcntl start_app_for_check "$name" 18168 0 || return 1
  log="$(docker logs "$name" 2>&1)"
  if [ "$(grep -cE '^(workers: 2 \(pids [0-9]+ [0-9]+\)|listening on 0\.0\.0\.0:18168|soft connection limit: 64000 per process|sqlite: journal_mode=wal synchronous=1 mmap_size=0 cache_size=-65536|loop: [a-z]+|socket: backlog=4096 tcp_nodelay=1)$' <<<"$log")" != 6 ]; then
    docker rm -f "$name" >/dev/null 2>&1
    echo "the boot lines are not the six expected: ${log//$'\n'/ | }"
    return 1
  fi
  pids="$(sed -n 's/^workers: 2 (pids \([0-9]*\) \([0-9]*\))$/\1 \2/p' <<<"$log")"
  # shellcheck disable=SC2086 # the two process ids, one word each
  result="$(docker exec "$name" php /lab/check/hold-and-count.php 18168 200 $pids 2>&1)"
  docker rm -f "$name" >/dev/null 2>&1
  jq -e '.answered == 200 and ([.workers[] | .during - .before] | length == 2 and all(. > 0))' >/dev/null 2>&1 <<<"$result" \
    || { echo "expected 200 answers and new sockets in both workers: $result"; return 1; }
}

# Without HOST and PORT the submission listens on 0.0.0.0:80, the challenge's direct setup. Run in a container with a network of its own (as
# root, which may bind port 80 there): on the host network it could take, or collide with, the port 80 of another project's container.
check_submission_default_host_and_port() {
  local name=lab-check-submission-net log answer
  docker rm -f "$name" >/dev/null 2>&1
  docker run -d --name "$name" "${LAB_RESOURCE_FLAGS[@]}" --cpuset-cpus "$LAB_CPUSET_SERVER" -v "$LAB/data:/lab/data:ro" -v "$SUBMISSION:/submission:ro" \
    "$LAB_IMAGE:8.5" sh -c 'cp /lab/data/feed.db /tmp/feed.db && SQLITE_PATH=/tmp/feed.db JWT_SECRET=a-secret exec php -d extension=pcntl -d extension=sockets -d extension=event /submission/server.php' >/dev/null \
    || { echo "docker run failed"; return 1; }
  for _ in $(seq 1 120); do
    docker logs "$name" 2>&1 | grep -q '^listening on' && break
    [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || { log="$(docker logs "$name" 2>&1 | tr '\n' ' ')"; docker rm -f "$name" >/dev/null 2>&1; echo "the server exited: $log"; return 1; }
    sleep 0.5
  done
  log="$(docker logs "$name" 2>&1)"
  answer="$(docker exec "$name" php -r 'echo @file_get_contents("http://127.0.0.1:80/health");' 2>&1)"
  docker rm -f "$name" >/dev/null 2>&1
  grep -qx 'listening on 0.0.0.0:80' <<<"$log" || { echo "the boot line does not say 0.0.0.0:80: ${log//$'\n'/ | }"; return 1; }
  grep -q '"status":"ok"' <<<"$answer" || { echo "GET /health on port 80 inside the container answered: $answer"; return 1; }
}

# install.sh with one digit of PHP's sha256 changed stops at the check: it exits non-zero, sha256sum says FAILED, and configure never ran. A
# throwaway container of the pinned Ubuntu image (the apt step and the download run for real, that is the minute this check takes).
check_submission_install_stops_on_wrong_sha256() {
  local tmp out rc=0
  tmp="$(mktemp -d)"
  sed 's/^PHP_SHA256=607602/PHP_SHA256=607603/' "$SUBMISSION/install.sh" >"$tmp/install.sh"
  cmp -s "$SUBMISSION/install.sh" "$tmp/install.sh" && { rm -rf "$tmp"; echo "the fixture changed nothing: install.sh has no PHP_SHA256=607602 line"; return 1; }
  out="$(docker run --rm "${LAB_RESOURCE_FLAGS[@]}" -v "$tmp:/src:ro" "$(lab_base_image)" bash /src/install.sh 2>&1)" || rc=$?
  rm -rf "$tmp"
  [ "$rc" != 0 ] || { echo "install.sh exited 0 on a wrong sha256"; return 1; }
  grep -q 'php.tar.xz: FAILED' <<<"$out" || { echo "no 'php.tar.xz: FAILED' in the output: $(tail -5 <<<"$out" | tr '\n' ' ')"; return 1; }
  ! grep -q '^checking ' <<<"$out" || { echo "configure ran after the wrong sha256"; return 1; }
}

# The submission's own cases (lab/check/submission-test.php, run with the submissions folder mounted): the configuration refusals leave
# nothing listening, SIGTERM and a killed worker end the process as they should, and the soft limit's path on socket pairs; then
# lab/check/post-insert-test.php, the committed-before-return case of post_insert() and the failed commits of post_insert() and like_insert().
check_submission_cases() {
  local out ok rc=0
  out="$(LAB_RUN_SUBMISSIONS=1 bash "$LAB/run.sh" 8.5 php -d extension=sockets -d extension=event -d extension=pcntl /lab/check/submission-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "submission-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" = 16 ] || { echo "expected 16 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  ! grep -q 'FAIL' <<<"$out" || { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
  # post_insert(): a second connection reads the new row when it returns, and a commit made to fail (a deferred foreign key) is an exception, for a post and for a like.
  rc=0
  out="$(LAB_RUN_SUBMISSIONS=1 bash "$LAB/run.sh" 8.5 php /lab/check/post-insert-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "post-insert-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" = 3 ] || { echo "expected 3 ok post_insert and like_insert cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  ! grep -q 'FAIL' <<<"$out" || { echo "a post_insert or like_insert case failed: ${out//$'\n'/ | }"; return 1; }
}

# The feed bench times every case of the S6 variants (APP_JSON's and APP_DRIVER's too, and the raw FFI floor) and none is skipped (each case checked its answer against the reference's), and the
# plans saved next to its output are what SQLite says today.
check_micro_feed_bench() {
  local out rows plans
  out="$(bash "$LAB/micro.sh" "$LAB/micro/benches/feed.php" --images 8.5 --jit on --quick --procs 1 --out "$(mktemp -d)/micro.json" 2>&1)" || { echo "lab/micro.sh failed: ${out//$'\n'/ | }"; return 1; }
  ! grep -q 'SKIPPED' <<<"$out" || { echo "a case was skipped: $(grep 'SKIPPED' <<<"$out" | head -3 | tr '\n' '|')"; return 1; }
  rows="$(grep -c -E '^8\.5 +8\.5\.[0-9]+ +on +.* [0-9.]+ +[0-9.]+ \.\. [0-9.]+ +[0-9]+( +UNSTABLE.*)?$' <<<"$out")"
  [ "$rows" = 34 ] || { echo "expected 34 rows (33 cases and the empty loop), got $rows: ${out//$'\n'/ | }"; return 1; }
  plans="$(bash "$LAB/run.sh" 8.5 php /lab/micro/feed-plans.php 2>&1)" || { echo "feed-plans.php failed: ${plans//$'\n'/ | }"; return 1; }
  [ "$plans" = "$(cat "$LAB/micro/feed-run/feed-plans.txt")" ] || { echo "lab/micro/feed-run/feed-plans.txt is not what lab/micro/feed-plans.php prints: regenerate it"; return 1; }
}

# The parse bench times today's head parse and the lean one on k6's heads, and none is skipped: each case's check found the same five things
# (method, target, body length, authorization, close flag) in both, and the same verdict on the battery that holds every refusal.
check_micro_parse_bench() {
  local out rows
  out="$(bash "$LAB/micro.sh" "$LAB/micro/benches/parse.php" --images 8.5 --jit on --quick --procs 1 --out "$(mktemp -d)/micro.json" 2>&1)" || { echo "lab/micro.sh failed: ${out//$'\n'/ | }"; return 1; }
  ! grep -q 'SKIPPED' <<<"$out" || { echo "a case was skipped: $(grep 'SKIPPED' <<<"$out" | head -3 | tr '\n' '|')"; return 1; }
  rows="$(grep -c -E '^8\.5 +8\.5\.[0-9]+ +on +.* [0-9.]+ +[0-9.]+ \.\. [0-9.]+ +[0-9]+( +UNSTABLE.*)?$' <<<"$out")"
  [ "$rows" = 7 ] || { echo "expected 7 rows (6 cases and the empty loop), got $rows: ${out//$'\n'/ | }"; return 1; }
}

# The challenge app passes the challenge's own test suite (42 checks), twice in a row: the second run starts from a fresh copy of the
# seed (the suite's golden answers fail on a database the first run wrote to), and no container is left behind.
check_challenge_test_passes_on_app() {
  local out run left rc
  for run in 1 2; do
    rc=0
    out="$(bash "$LAB/challenge-test.sh" --image 8.5 2>&1)" || rc=$?
    [ "$rc" = 0 ] || { echo "run $run: lab/challenge-test.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
    grep -qx 'passed=42 failed=0' <<<"$out" || { echo "run $run: the summary is not 'passed=42 failed=0': ${out//$'\n'/ | }"; return 1; }
  done
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-challenge-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
}

# A server that answers one golden wrong: the harness exits non-zero, names the check that fails (and only that one), and removes
# its containers.
check_challenge_test_fails_on_wrong_golden() {
  local out left rc=0
  out="$(bash "$LAB/challenge-test.sh" --image 8.5 --server "$LAB/check/fixtures/wrong-golden-app.php" 2>&1)" || rc=$?
  [ "$rc" != 0 ] || { echo "expected a non-zero exit for a wrong server: ${out//$'\n'/ | }"; return 1; }
  grep -q '^  FAIL GET /posts/250000 == golden' <<<"$out" || { echo "the failing check is not named: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'passed=41 failed=1' <<<"$out" || { echo "expected 'passed=41 failed=1': ${out//$'\n'/ | }"; return 1; }
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-challenge-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
}

# The suite of the challenge on the app with a soft limit of 0 (every response says close, so every request of the suite is a new
# connection): the same 42 checks pass, and the variable did take effect: a client of a server with that limit sees the close.
check_challenge_test_passes_with_soft_limit_zero() {
  local out left rc=0 seq
  out="$(bash "$LAB/challenge-test.sh" --image 8.5 --env APP_SOFT_CONN_LIMIT=0 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/challenge-test.sh --env APP_SOFT_CONN_LIMIT=0 exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'passed=42 failed=0' <<<"$out" || { echo "the summary is not 'passed=42 failed=0': ${out//$'\n'/ | }"; return 1; }
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-challenge-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
  start_app_for_check lab-check-soft 18162 0 APP_SOFT_CONN_LIMIT=0 || return 1
  seq="$(docker exec lab-check-soft php /lab/check/conn-client.php 18162 seq 5)"
  docker rm -f lab-check-soft >/dev/null 2>&1
  jq -e '.answered == 5 and .close_header == 5 and .server_closed == 5 and .errors == []' <<<"$seq" >/dev/null     || { echo "with a limit of 0 every response should say close and end: $seq"; return 1; }
}

# The Done-when of the soft limit: with a limit of 2, three keep-alive connections opened one after the other: the first two answer as
# today and stay open, the third answers with Connection: close and the server ends it after the write.
check_soft_limit_closes_the_third_connection() {
  local seq
  start_app_for_check lab-check-soft 18162 0 APP_SOFT_CONN_LIMIT=2 || return 1
  seq="$(docker exec lab-check-soft php /lab/check/conn-client.php 18162 seq 3 --keep)"
  docker rm -f lab-check-soft >/dev/null 2>&1
  jq -e '.answered == 3 and .errors == [] and .connections == [{close_header: false, server_closed: false}, {close_header: false, server_closed: false}, {close_header: true, server_closed: true}]' <<<"$seq" >/dev/null     || { echo "expected the first two kept and the third closed with the header: $seq"; return 1; }
}

# soft_limit_scenario <port> <server nofile or ''> <soft limit> <idle> <new connections>: a server with that soft limit (and file descriptor
# limit) holds <idle> connections from the idle client (each with its one request), then a second client opens <new> connections one after
# the other, one request each. Prints one JSON object: the second client's summary (`seq`), the idle client's events (`idle_start`,
# `idle_end`) and whether the server is still running. Returns 1 with a reason when the harness itself fails.
soft_limit_scenario() {
  local port="$1" nofile="$2" soft="$3" idle="$4" total="$5" server=lab-check-soft client=lab-check-soft-client events tmp seq running
  tmp="$(mktemp -d)"
  docker rm -f "$server" "$client" >/dev/null 2>&1
  # Why the prefix: lab_run_server_container (lib.sh) reads LAB_SERVER_NOFILE (empty: the lab's 65,535) for this one start.
  LAB_SERVER_NOFILE="$nofile" start_app_for_check "$server" "$port" 0 "APP_SOFT_CONN_LIMIT=$soft" || return 1
  docker run -d --name "$client" --network host --ulimit nofile=20000:20000 -v "$LAB:/lab:ro" "$LAB_IMAGE:8.5" sleep 300 >/dev/null
  : >"$tmp/events"
  docker exec "$client" rm -f /tmp/idle-end
  docker exec "$client" php -d display_errors=stderr /lab/conns/client.php "$port" --hold "$idle" --path /health --body-regex '^\{"status":"ok",.*\}$' \
    --end-file /tmp/idle-end >"$tmp/events" 2>"$tmp/err" &
  for _ in $(seq 1 120); do grep -q '"event":"held"' "$tmp/events" && break; sleep 0.5; done
  grep -q '"event":"held"' "$tmp/events" || { echo "the idle client did not hold: $(cat "$tmp/events" "$tmp/err" 2>/dev/null | tr '\n' ' ')"; docker rm -f "$server" "$client" >/dev/null 2>&1; return 1; }
  seq="$(docker exec "$client" php /lab/check/conn-client.php "$port" seq "$total" 2>&1 | tail -n 1)"
  docker exec "$client" touch /tmp/idle-end
  wait
  running="$(docker inspect -f '{{.State.Running}}' "$server")"
  docker rm -f "$server" "$client" >/dev/null 2>&1
  jq -c -n --argjson seq "${seq:-null}" --slurpfile events "$tmp/events" --arg running "$running" \
    '{seq: $seq, idle_start: ($events | map(select(.event == "held")) | .[0]), idle_end: ($events | map(select(.event == "ended")) | .[0]), running: ($running == "true")}'
  rm -rf "$tmp"
}

# The idle count equals the soft limit: 50 idle connections each with its request keep alive, 20 new connections each close after their
# response, and the 50 are still open at the end.
check_soft_limit_keeps_idle_connections() {
  local out
  out="$(soft_limit_scenario 18163 "" 50 50 20)" || { echo "$out"; return 1; }
  jq -e '.running and .seq.answered == 20 and .seq.close_header == 20 and .seq.server_closed == 20 and .seq.errors == []
         and .idle_start.held == 50 and .idle_start.closed_by_server == 0 and .idle_end.held == 50 and .idle_end.closed_by_server == 0' <<<"$out" >/dev/null     || { echo "expected 20 closes after the response and the 50 idle still open: $out"; return 1; }
}

# A server limited to 256 file descriptors with a soft limit of 200: 200 idle connections are held and 2,000 new connections, one after
# the other, are all answered (each closed after its response, so the seat is free for the next) with no error; the 200 are still open.
check_soft_limit_serves_churn_at_256_fds() {
  local out
  out="$(soft_limit_scenario 18163 256 200 200 2000)" || { echo "$out"; return 1; }
  jq -e '.running and .seq.answered == 2000 and .seq.close_header == 2000 and .seq.server_closed == 2000 and .seq.errors == []
         and .idle_start.held == 200 and .idle_start.closed_by_server == 0 and .idle_end.held == 200 and .idle_end.closed_by_server == 0' <<<"$out" >/dev/null     || { echo "expected 2,000 answered with no error and the 200 idle still open: $(jq -c '{running, seq: (.seq | del(.errors) + {errors: (.errors | .[0:3])}), idle_start, idle_end}' <<<"$out")"; return 1; }
}

# The hard limit: a server with 64 file descriptors and no soft limit, 80 clients at once. The ones over the limit wait in the backlog, the
# server stops listening (a busy loop would show as CPU while they wait: under 0.2 s of CPU in 2 s), prints one line on stderr however many
# times it pauses, counts the pauses in its telemetry, and answers the waiting clients once the first ones close.
check_hard_fd_limit_pauses_accepts() {
  local server=lab-check-hard client=lab-check-hard-client tmp phase1 cpu0 cpu1 pauses lines left
  tmp="$(mktemp -d)"
  docker rm -f "$server" "$client" >/dev/null 2>&1
  # Why the prefix: lab_run_server_container (lib.sh) reads LAB_SERVER_NOFILE for this one start.
  LAB_SERVER_NOFILE=64 start_app_for_check "$server" 18164 0 APP_TELEMETRY=1 || return 1
  docker run -d --name "$client" --network host --ulimit nofile=20000:20000 -v "$LAB:/lab:ro" "$LAB_IMAGE:8.5" sleep 300 >/dev/null
  docker exec "$client" php /lab/check/conn-client.php 18164 burst 80 5 >"$tmp/events" 2>&1 &
  for _ in $(seq 1 40); do grep -q '"event":"phase1"' "$tmp/events" && break; sleep 0.5; done
  phase1="$(grep '"event":"phase1"' "$tmp/events")"
  # The client holds for 5 s after its first 1.5 s: this window is inside it.
  cpu0="$(docker exec "$server" awk '{ print $14 + $15 }' /proc/1/stat)"
  sleep 2
  cpu1="$(docker exec "$server" awk '{ print $14 + $15 }' /proc/1/stat)"
  wait
  sleep 1.2
  pauses="$(docker logs "$server" 2>&1 | sed -n 's/^telemetry //p' | jq -s 'map(.connections.accept_pauses // 0) | add')"
  lines="$(docker logs "$server" 2>&1 | grep -c 'out of file descriptors' || true)"
  docker rm -f "$server" "$client" >/dev/null 2>&1
  [ -n "$phase1" ] || { echo "the client printed no first phase: $(tr '\n' ' ' <"$tmp/events")"; return 1; }
  jq -e '.answered > 0 and .answered < 80 and .answered + .waiting == 80' <<<"$phase1" >/dev/null     || { echo "expected some of the 80 clients answered and the rest waiting: $phase1"; return 1; }
  jq -es 'map(select(.event == "done")) | .[0] | .answered == 80 and .errors == []' "$tmp/events" >/dev/null     || { echo "the waiting clients were not all answered: $(tr '\n' ' ' <"$tmp/events")"; return 1; }
  [ $(( cpu1 - cpu0 )) -lt 20 ] || { echo "the server used $(( cpu1 - cpu0 )) ticks of CPU (1/100 s) in 2 s while clients waited: it spins"; return 1; }
  [ "${pauses:-0}" -ge 1 ] || { echo "the telemetry counts no accept pause ($pauses)"; return 1; }
  [ "$lines" = 1 ] || { echo "expected one 'out of file descriptors' line on stderr, got $lines"; return 1; }
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-check-hard' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
  rm -rf "$tmp"
}

# The aggregator's library on rows copied from a real k6 run: the histogram error, the percentiles of a known set, the rows it keeps,
# a plateau found from k6's `vus` rows, a step's numbers and verdict (the 97 % rule included).
check_aggregate_cases() {
  local out ok rc=0
  out="$(bash "$LAB/run.sh" 8.5 php /lab/check/aggregate-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "aggregate-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q '^FAIL' <<<"$out" && { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" -ge 55 ] || { echo "expected at least 55 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  return 0
}

# realistic_script_diff <original load.js> <copy>: prints what differs between the copy and the original beyond the two changes the copy
# is allowed (every sleep scaled by THINK_SCALE; the options read from the env, with the THINK_SCALE constant that goes with them),
# nothing when the copy is the original with those two changes. The header of the copy (up to its marker line) is not compared.
realistic_script_diff() {
  local original="$1" copy="$2" want got unscaled
  want="$(awk '/^export const options = \{/ { skip = 1 } !skip { print } skip && /^\};$/ { skip = 0 }' "$original")"
  got="$(awk 'copied { print } /^\/\/ --- the original, from here ---$/ { copied = 1 }' "$copy" |
    grep -v -x -e 'export const options = JSON.parse(__ENV.REALISTIC_OPTIONS);' -e 'const THINK_SCALE = Number(__ENV.THINK_SCALE || 1);' |
    sed 's/ \* THINK_SCALE)/)/')"
  [ "$want" = "$got" ] || diff <(echo "$want") <(echo "$got") | head -n 6
  # A sleep left unscaled is the original's own line, which the comparison above cannot see.
  unscaled="$(grep 'sleep(' "$copy" | grep -v '^//' | grep -v -c ' \* THINK_SCALE)' || true)"
  [ "$unscaled" = 0 ] || echo "$unscaled sleep call(s) are not scaled by THINK_SCALE"
  [ "$(grep -c '^export const options = JSON.parse(__ENV.REALISTIC_OPTIONS);$' "$copy")" = 1 ] || echo "the options line is missing"
  [ "$(grep -c '^const THINK_SCALE = ' "$copy")" = 1 ] || echo "the THINK_SCALE constant is missing"
  return 0
}

# The k6 script is the bench's own load.js with the two changes and nothing else, and the diff is able to fail: a copy with a
# probability changed, or one sleep left unscaled, is reported.
check_realistic_script_is_the_benchs() {
  local original="$REPO/reference/twelve-dollar-server-challenge/bench/load.js" copy="$LAB/macro/k6/realistic.js" report dir
  [ -f "$original" ] || { echo "reference/twelve-dollar-server-challenge/bench/load.js is missing"; return 1; }
  report="$(realistic_script_diff "$original" "$copy")"
  [ -z "$report" ] || { echo "the copy differs from the original: ${report//$'\n'/ | }"; return 1; }
  dir="$(mktemp -d)"
  sed 's/const LIKE_PROB = 0.15/const LIKE_PROB = 0.25/' "$copy" >"$dir/probability.js"
  [ -n "$(realistic_script_diff "$original" "$dir/probability.js")" ] || { echo "a changed probability is not reported"; return 1; }
  sed 's/sleep(between(5, 15) \* THINK_SCALE)/sleep(between(5, 15))/' "$copy" >"$dir/unscaled.js"
  [ -n "$(realistic_script_diff "$original" "$dir/unscaled.js")" ] || { echo "an unscaled sleep is not reported"; return 1; }
  grep -q 'twelve-dollar-server-challenge/bench/load.js' "$copy" && grep -q "$(git -C "$REPO/reference/twelve-dollar-server-challenge" rev-parse HEAD)" "$copy" \
    || { echo "the header does not name the original's path and the challenge's commit"; return 1; }
}

# The realistic mode on the skeleton at low load: a staircase of 3 steps passes, with the numbers of each step (VUs, offered and
# achieved, users from the achieved rate, CPU per request, percentiles per endpoint) and the run's JSON, and the aggregator's
# request counts and percentiles are the ones of k6's own summary (within the histogram's error). No container is left behind.
check_realistic_staircase_passes() {
  local out rc=0 json detail left running
  json="$(mktemp -d)/realistic.json"
  running="$(other_fixture_start)"
  out="$(bash "$LAB/realistic.sh" --image 8.5 --think-scale 0.1 --staircase 50,50,150,8 --label test --out "$json" 2>&1)" || rc=$?
  other_fixture_stop
  [ "$rc" = 0 ] || { echo "lab/realistic.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'VALID' <<<"$out" || { echo "the run is not marked VALID: ${out//$'\n'/ | }"; return 1; }
  [ "$(grep -c -E '^ +[123] +[0-9]+ +[0-9.]+ +[0-9.]+ +[0-9]+ +[0-9.]+ +[0-9.]+ +[0-9.]+ +[0-9.]+% +pass$' <<<"$out")" = 3 ] \
    || { echo "expected 3 rows that pass: ${out//$'\n'/ | }"; return 1; }
  jq -e '.valid == true and .mode == "staircase" and .label == "test" and .load.think_scale == 0.1 and .load.users_per_rps == 9.45
         and (.load.vus == [48, 95, 142]) and .load.vu_cap > 0
         and (.results.steps | length == 3) and (.results.steps | map(.pass) | all)
         and (.results.steps | map(.achieved_rps >= 0.97 * .offered_rps) | all)
         and (.results.steps | map(.users - 9.45 * .achieved_rps | fabs < 0.001) | all)
         and (.results.steps | map(.cpu_usec_per_request > 0) | all)
         and (.results.steps | map(.latency_ms.endpoints | keys | (index("GET /feed") != null and index("GET /posts/:id") != null
              and (. - ["GET /feed", "GET /posts/:id", "POST /posts", "POST /posts/:id/like"] == []))) | all)
         and .k6.peak_memory_mib > 0 and .k6.local_ips == "127.0.1.1-127.0.1.4" and (.k6.client_ips_seen | keys | length) > 1
         and ('"$(other_containers_jq "$running")"')
         and .aggregator.unparsed == 0 and .aggregator.max_lag_s < .aggregator.lag_gate_s
         and (.results.per_second | length) > 20' "$json" >/dev/null \
    || { detail="$(jq -c '{valid, load, k6, aggregator, steps: [.results.steps[] | {step, vus, pass, reasons, achieved_rps, offered_rps, cpu_usec_per_request, endpoints: (.latency_ms.endpoints | keys)}]}' "$json")"; echo "the JSON does not hold the run's numbers: $detail"; return 1; }
  # The aggregator against k6's own summary: the same request counts per endpoint, the p95 of the two big endpoints within 3 %.
  jq -e '.results.run_total as $t | .results.k6_summary.metrics as $m
         | ($t | to_entries | map(select(.key == "GET /feed" or .key == "GET /posts/:id"))) as $big
         | ($t | map(.count) | add) == $m.http_reqs.count
         and ($big | length == 2)
         and ($big | map(.value.count > 500) | all)
         and ($big | map(. as $e | $m["http_req_duration{name:\($e.key)}"]["p(95)"] as $k6 | ($e.value.p95 - $k6 | fabs) <= 0.03 * $k6 + 0.02) | all)' "$json" >/dev/null \
    || { detail="$(jq -c '{run_total: .results.run_total, k6: (.results.k6_summary.metrics | {reqs: .http_reqs.count, feed: .["http_req_duration{name:GET /feed}"], post: .["http_req_duration{name:GET /posts/:id}"]})}' "$json")"; echo "the aggregator and k6's summary disagree: $detail"; return 1; }
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-realistic-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
  docker volume ls --format '{{.Name}}' | grep -x lab-realistic-run >/dev/null && { echo "the volume lab-realistic-run is left behind"; return 1; }
  return 0
}

# --no-series: a small staircase passes with no sampler and a poll that reads only k6 and the aggregator. The per-step results are
# there, the per-second rows hold the aggregator's latency and no reading of the server, the JSON says the probes were off and holds
# no memory peak of the server (nothing read it), and the table says the per-second part is off. At 100 req/s (about 1,200 requests a
# step), like the failing-step check, but the busy Docker VM still fails a step on the 97 % rule now and then (one in a full suite
# run): this check is about the probes, so a step may fail on that rule alone, with nothing else wrong. No container is left behind.
check_realistic_no_series() {
  local out rc=0 json left
  json="$(mktemp -d)/realistic.json"
  out="$(bash "$LAB/realistic.sh" --image 8.5 --think-scale 0.2 --staircase 100,100,200,12 --no-series --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/realistic.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'VALID' <<<"$out" || { echo "the run is not marked VALID: ${out//$'\n'/ | }"; return 1; }
  grep -q '^per second: off (--no-series' <<<"$out" || { echo "the table does not say the per-second part is off: ${out//$'\n'/ | }"; return 1; }
  jq -e '.valid == true and .per_second_probes == false and (.results.steps | length >= 1)
         and (.results.steps | map(.pass or (.reasons | all(startswith("achieved below 97 %")))) | all)
         and (.results.steps | map(.cpu_usec_per_request > 0 and .latency_ms.overall.p99 > 0) | all)
         and .results.series == null and (.results.per_second | length) > 10
         and (.results.per_second | map(has("server") or has("telemetry")) | any | not)
         and .server_memory.pss_anon_peak_mib == null and .server_memory.memory_current_peak_mib == null
         and .k6.peak_memory_mib > 0 and .aggregator.unparsed == 0' "$json" >/dev/null \
    || { echo "the JSON does not hold a run without the per-second probes: $(jq -c '{valid, per_second_probes, steps: [.results.steps[] | {step, pass, reasons}], series: (.results.series | type), per_second: (.results.per_second | length), server_memory}' "$json")"; return 1; }
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-realistic-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
}

# A step above the capacity of the server fails on the 97 % rule, and the staircase stops there: against a server that spends 4 ms per
# request (about 190 to 250 req/s at most), 100 req/s passes and 300 req/s does not. The first step has room on purpose, and it is in the
# count, not in the latency: at 40 to 60 req/s a plateau of 8 to 12 s holds 300 to 500 requests, whose count alone varies by 2 or 3 %
# (the VUs' think times are random), so the 97 % rule failed it by chance (93 % and 96.7 %, with a p95 of 13 to 17 ms, far from the
# 29 to 58 ms of mean latency the rule leaves). 100 req/s over 12 s of data is about 1,200 requests.
check_realistic_stops_at_a_failing_step() {
  local out rc=0 json detail
  json="$(mktemp -d)/realistic.json"
  out="$(bash "$LAB/realistic.sh" --image 8.5 --server "$LAB/check/fixtures/slow-app.php" --think-scale 0.2 --staircase 100,200,300,15 --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "a failing step is a result, expected exit 0, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q '^STOPPED at step 2: achieved below 97 % of offered' <<<"$out" || { echo "the run did not stop at step 2 on the 97 % rule: ${out//$'\n'/ | }"; return 1; }
  jq -e '.valid == true and .results.stopped_at_step == 2 and (.results.steps | length == 2)
         and .results.steps[0].pass == true and .results.steps[1].pass == false
         and .results.steps[1].reasons[0] == "achieved below 97 % of offered"
         and (.results.steps[1].achieved_rps < 0.97 * .results.steps[1].offered_rps)' "$json" >/dev/null \
    || { detail="$(jq -c '[.results.steps[] | {step, vus, pass, reasons, achieved_rps, offered_rps}]' "$json")"; echo "the JSON does not say the run stopped on the 97 % rule at step 2: $detail"; return 1; }
}

# More VUs than the cap is refused with exit 2 before any container starts.
check_realistic_refuses_vus_above_the_cap() {
  local out rc=0
  out="$(bash "$LAB/realistic.sh" --image 8.5 --think-scale 1 --hold 1000,5 --vu-cap 100 2>&1)" || rc=$?
  [ "$rc" = 2 ] || { echo "expected exit 2 above the VU cap, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q 'above the VU cap of 100' <<<"$out" || { echo "the message does not say why: ${out//$'\n'/ | }"; return 1; }
  [ -z "$(docker ps -a --format '{{.Names}}' | grep '^lab-realistic-' || true)" ] || { echo "a container was started"; return 1; }
}

# The VU cap and what binds it, refused before any container starts. Today's cap is the file descriptors the idle connections leave
# (5,400); with APP_SOFT_CONN_LIMIT in --env every request of k6 reconnects, so the file descriptors no longer bind: the cap is k6's
# memory or the local ports of its source addresses, whichever is lower. A cap given by hand wins, and the message says which one bound.
check_realistic_vu_cap_is_bound_by() {
  local out rc
  rc=0
  out="$(bash "$LAB/realistic.sh" --image 8.5 --think-scale 1 --hold 573,5 2>&1)" || rc=$?
  [ "$rc" = 2 ] && grep -q 'above the VU cap of 5400, bound by file descriptors' <<<"$out" \
    || { echo "without a soft limit the cap is the file descriptors' 5,400 (exit $rc): ${out//$'\n'/ | }"; return 1; }
  rc=0
  out="$(bash "$LAB/realistic.sh" --image 8.5 --think-scale 1 --hold 200000,5 --env APP_SOFT_CONN_LIMIT=1000 2>&1)" || rc=$?
  [ "$rc" = 2 ] && grep -q -E 'above the VU cap of [0-9]+, bound by k6 memory' <<<"$out" && ! grep -q 'cap of 5400' <<<"$out" \
    || { echo "with a soft limit the cap should be k6's memory (exit $rc): ${out//$'\n'/ | }"; return 1; }
  rc=0
  out="$(bash "$LAB/realistic.sh" --image 8.5 --think-scale 1 --hold 200000,5 --env APP_SOFT_CONN_LIMIT=1000 --local-ips 127.0.1.1-127.0.1.1 2>&1)" || rc=$?
  [ "$rc" = 2 ] && grep -q 'above the VU cap of 10500, bound by local ports' <<<"$out" \
    || { echo "with one source address the cap should be its 10,500 ports (exit $rc): ${out//$'\n'/ | }"; return 1; }
  rc=0
  out="$(bash "$LAB/realistic.sh" --image 8.5 --think-scale 1 --hold 1000,5 --env APP_SOFT_CONN_LIMIT=1000 --vu-cap 100 2>&1)" || rc=$?
  [ "$rc" = 2 ] && grep -q 'above the VU cap of 100, bound by --vu-cap' <<<"$out" \
    || { echo "a cap given by hand wins (exit $rc): ${out//$'\n'/ | }"; return 1; }
  [ -z "$(docker ps -a --format '{{.Names}}' | grep '^lab-realistic-' || true)" ] || { echo "a container was started"; return 1; }
}

# A run whose aggregator falls behind (a gate no real run can meet) or whose k6 passes its memory budget (a budget k6 cannot live in)
# is printed, marked INVALID with its reason, and exits 3.
check_realistic_marks_invalid_run() {
  local out rc json
  json="$(mktemp -d)/realistic.json"
  rc=0
  out="$(bash "$LAB/realistic.sh" --image 8.5 --think-scale 0.1 --hold 50,6 --lag-gate 0.1 --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 3 ] || { echo "expected exit 3 for a lag above the gate, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q '^INVALID: the aggregator fell behind k6: lag' <<<"$out" || { echo "the lag is not the reason: ${out//$'\n'/ | }"; return 1; }
  jq -e '.valid == false' "$json" >/dev/null || { echo "the JSON does not say invalid"; return 1; }
  rc=0
  out="$(bash "$LAB/realistic.sh" --image 8.5 --think-scale 0.1 --hold 50,6 --k6-memory 50 --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 3 ] || { echo "expected exit 3 for a k6 above its memory budget, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q '^INVALID: k6 .*memory budget' <<<"$out" || { echo "the memory budget is not the reason: ${out//$'\n'/ | }"; return 1; }
  jq -e '.valid == false' "$json" >/dev/null || { echo "the JSON does not say invalid"; return 1; }
}

# The server dies in the middle of a run: the harness exits 1 with that reason and leaves no container and no volume behind.
check_realistic_cleans_up_after_failure() {
  local log pid rc=0 left
  log="$(mktemp -d)/realistic.log"
  bash "$LAB/realistic.sh" --image 8.5 --think-scale 0.1 --hold 100,60 --out "$(dirname "$log")/realistic.json" >"$log" 2>&1 &
  pid=$!
  # The aggregator starts just before k6: the run is about to be under load.
  for _ in $(seq 1 240); do
    docker ps --format '{{.Names}}' | grep -x lab-realistic-agg >/dev/null && break
    sleep 0.5
  done
  sleep 6
  docker kill lab-realistic-server >/dev/null 2>&1 || true
  wait "$pid" || rc=$?
  [ "$rc" = 1 ] || { echo "expected exit 1 when the server dies, got $rc: $(tr '\n' ' ' <"$log")"; return 1; }
  grep -q 'the server container died during the run' "$log" || { echo "the reason is not reported: $(tr '\n' ' ' <"$log")"; return 1; }
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-realistic-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
  docker volume ls --format '{{.Name}}' | grep -x lab-realistic-run >/dev/null && { echo "the volume lab-realistic-run is left behind"; return 1; }
  return 0
}

# The calibration at a short length: it prints k6's memory per VU, the VU cap and the scale, and the JSON holds them.
check_realistic_calibrates() {
  local out rc=0 json
  json="$(mktemp -d)/realistic.json"
  out="$(bash "$LAB/realistic.sh" --image 8.5 --think-scale 0.1 --calibrate --calibrate-seconds 10 --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/realistic.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q '^k6 memory per VU: ' <<<"$out" && grep -q '^VU cap: ' <<<"$out" && grep -q '^scale for 20,000 req/s under the cap: ' <<<"$out" \
    || { echo "the calibration does not print the memory per VU, the cap and the scale: ${out//$'\n'/ | }"; return 1; }
  jq -e '.mode == "calibrate" and .valid == true and .calibration.mib_per_vu > 0 and .calibration.vu_cap > 0 and .calibration.vu_cap <= 5400
         and .calibration.scale_for_20000_rps > 0 and .calibration.scale_for_20000_rps <= 1
         and .calibration.aggregator_max_lag_s[0] > 0 and (.calibration.achieved_over_offered | all(. > 0.9))
         and (.runs | length == 2)' "$json" >/dev/null || { echo "the JSON does not hold the calibration: $(jq -c .calibration "$json")"; return 1; }
}

# The per-second series' pieces on real data: mxFrame read from the -shm file of a real WAL (written, checkpointed, written again), the page
# faults read from a /proc stat line, the telemetry lines read back from a log, and the merge of latency, readings and telemetry into one
# row per second (a missed reading leaves a null, never a delta over two seconds).
check_series_cases() {
  local out ok rc=0
  out="$(bash "$LAB/run.sh" 8.5 php /lab/check/series-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "series-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q '^FAIL' <<<"$out" && { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" -ge 30 ] || { echo "expected at least 30 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  return 0
}

# The telemetry line: the longest callback, the GC and fault deltas, the app's fields, and which second each line is for.
check_telemetry_cases() {
  local out ok rc=0
  out="$(bash "$LAB/run.sh" 8.5 php /lab/check/telemetry-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "telemetry-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q '^FAIL' <<<"$out" && { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" -ge 17 ] || { echo "expected at least 17 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  return 0
}

# start_app_for_check <container> <port> <cold 0|1> [K=V]...: the app on a fresh copy of the seed through lab_start_app, waited on until it
# listens. Prints the failure and returns 1 when it never does. CHECK_APP_EXT_EXTRA (one extension name, set for that one call) is loaded after
# sockets and event: `pcntl` for APP_WORKERS. CHECK_APP_SERVER (set for that one call) is the server file as the container sees it (default
# /lab/app/server.php; /submissions/php-Gcob/server.php for the submission).
# Why disable SC2034: LAB_COLD, LAB_EXT and LAB_ENV are read by lab_start_app and lab_build_php_flags (lib.sh), which shellcheck does not follow.
# shellcheck disable=SC2034
start_app_for_check() {
  local name="$1" port="$2"
  LAB_COLD="$3"
  shift 3
  LAB_EXT=(sockets event ${CHECK_APP_EXT_EXTRA:+"$CHECK_APP_EXT_EXTRA"})
  LAB_ENV=("$@")
  lab_build_php_flags
  docker rm -f "$name" >/dev/null 2>&1
  lab_start_app "$name" 8.5 "$port" "${CHECK_APP_SERVER:-/lab/app/server.php}" || { echo "lab_start_app failed"; return 1; }
  for _ in $(seq 1 120); do
    docker logs "$name" 2>&1 | grep -q '^listening on' && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || { echo "the app exited: $(docker logs "$name" 2>&1 | tr '\n' ' ')"; return 1; }
    sleep 0.5
  done
  echo "the app did not listen within 60 s"
  return 1
}

# The page cache and the copy of the seed: after a plain copy the whole file is resident, with LAB_COLD=1 almost none of it is (read by
# lab/macro/fincore.php just before the app opens the copy), and the cold app reads the database from disk (major faults) the warm one does
# not. The two readings are of the same file, a few seconds apart.
check_cold_start_evicts_the_copy() {
  local warm cold res size rc=0 majors
  start_app_for_check lab-check-warm 18160 0 || return 1
  warm="$(lab_fincore_line lab-check-warm)"
  docker rm -f lab-check-warm >/dev/null 2>&1
  start_app_for_check lab-check-cold 18160 1 APP_TELEMETRY=1 || { docker rm -f lab-check-cold >/dev/null 2>&1; return 1; }
  cold="$(lab_fincore_line lab-check-cold)"
  # Reads that need the pages: the feed and a few posts.
  docker exec lab-check-cold sh -c 'for i in 1 2 3 4 5 6 7 8; do curl -s -o /dev/null http://127.0.0.1:18160/posts/$((i * 50000)); done; curl -s -o /dev/null http://127.0.0.1:18160/feed'
  sleep 2.5
  majors="$(docker logs lab-check-cold 2>&1 | sed -n 's/^telemetry .*"majflt":\([0-9]*\).*/\1/p' | awk '{ s += $1 } END { print s + 0 }')"
  docker rm -f lab-check-cold >/dev/null 2>&1
  size="$(sed -n 's/.*size_bytes=\([0-9]*\).*/\1/p' <<<"$warm")"
  res="$(sed -n 's/.*resident_bytes=\([0-9]*\).*/\1/p' <<<"$warm")"
  [ -n "$size" ] && [ "$size" -gt 100000000 ] && [ "$res" -ge $(( size * 95 / 100 )) ] || { echo "the warm copy is not (almost) all resident: $warm"; return 1; }
  res="$(sed -n 's/.*resident_bytes=\([0-9]*\).*/\1/p' <<<"$cold")"
  [ -n "$res" ] && [ "$res" -le $(( size / 20 )) ] || { echo "the cold copy is more than 5 % resident: $cold"; return 1; }
  [ "$majors" -gt 0 ] || { echo "the cold app made no major page fault reading the database ($majors)"; return 1; }
  return 0
}

# The app's telemetry: off by default (no line), and with APP_TELEMETRY=1 one line a second with the requests per endpoint that the app was
# asked for (known requests sent here), the loop's longest callback, GC and faults, and a different second on every line.
check_app_telemetry() {
  local log lines seconds distinct total
  start_app_for_check lab-check-tel 18161 0 || return 1
  docker exec lab-check-tel sh -c 'curl -s -o /dev/null http://127.0.0.1:18161/feed'
  sleep 2.2
  log="$(docker logs lab-check-tel 2>&1)"
  docker rm -f lab-check-tel >/dev/null 2>&1
  ! grep -q '^telemetry ' <<<"$log" || { echo "a telemetry line was printed with APP_TELEMETRY unset"; return 1; }
  start_app_for_check lab-check-tel 18161 0 APP_TELEMETRY=1 || return 1
  docker exec lab-check-tel sh -c 'for i in 1 2 3; do curl -s -o /dev/null http://127.0.0.1:18161/feed; done; curl -s -o /dev/null http://127.0.0.1:18161/posts/7; sleep 3.5; curl -s -o /dev/null http://127.0.0.1:18161/health'
  sleep 1.2
  log="$(docker logs lab-check-tel 2>&1 | grep '^telemetry ')"
  docker rm -f lab-check-tel >/dev/null 2>&1
  lines="$(wc -l <<<"$log" | tr -d ' ')"
  seconds="$(sed -n 's/^telemetry {"second":\([0-9]*\),.*/\1/p' <<<"$log")"
  distinct="$(sort -u <<<"$seconds" | wc -l | tr -d ' ')"
  [ "$lines" -ge 4 ] && [ "$lines" = "$distinct" ] || { echo "expected 4 or more lines with a different second each, got $lines lines, $distinct seconds: ${seconds//$'\n'/ }"; return 1; }
  [ "$(awk 'NR > 1 && $1 != prev + 1 { bad = 1 } { prev = $1 } END { print bad + 0 }' <<<"$seconds")" = 0 ] || { echo "the seconds are not consecutive: ${seconds//$'\n'/ }"; return 1; }
  total="$(sed -n 's/^telemetry {"second":[0-9]*,"requests":{\(.*\)},"wal_bytes".*/\1/p' <<<"$log" | tr ',' '\n' | awk -F: 'NF > 1 { s += $NF } END { print s + 0 }')"
  [ "$total" = 5 ] || { echo "5 requests were sent (3 feed, 1 post, 1 health), the lines count $total: $(tr '\n' ' ' <<<"$log")"; return 1; }
  grep -q '^telemetry {"second":[0-9]*,"requests":{"GET /feed":3,"GET /posts/:id":1},"wal_bytes":[0-9]*,"longest_callback_ms":[0-9.]*,"gc_runs":[0-9]*,"gc_collected":[0-9]*,"minflt":[0-9]*,"majflt":[0-9]*,"connections":{"open_peak":[0-9]*,"limit_closes":0,"accept_pauses":0}}$' <<<"$log" \
    || { echo "no line holds the first four requests under their endpoints: $(tr '\n' ' ' <<<"$log")"; return 1; }
}

# idle_client_run <port> <path> <body regex> <seconds before the end file>: runs the idle client's hold mode against the idle-timeout fixture
# (it closes every connection that sat idle for 2 s) with 50 connections; prints the client's events, one JSON object per line.
# shellcheck disable=SC2034
idle_client_run() {
  local port="$1" client="lab-check-idle-client" events
  docker rm -f lab-check-idle-server "$client" >/dev/null 2>&1
  LAB_EXT=(sockets event)
  LAB_ENV=()
  lab_build_php_flags
  lab_start_server lab-check-idle-server 8.5 "$port" /lab/check/fixtures/idle-timeout-app.php || return 1
  for _ in $(seq 1 60); do docker logs lab-check-idle-server 2>&1 | grep -q '^listening on' && break; sleep 0.5; done
  docker run -d --name "$client" --network host --ulimit nofile=20000:20000 -v "$LAB:/lab:ro" "$LAB_IMAGE:8.5" sleep 300 >/dev/null
  # The end file appears after $4 seconds, from outside.
  ( sleep "$4"; docker exec "$client" touch /tmp/idle-end ) &
  events="$(docker exec "$client" php -d display_errors=stderr /lab/conns/client.php "$port" --hold 50 --path "$2" --body-regex "$3" --end-file /tmp/idle-end 2>&1)"
  wait
  docker rm -f lab-check-idle-server "$client" >/dev/null 2>&1
  echo "$events"
}

# The idle client's hold mode (the seam of --idle): against a server that closes connections idle for 2 s, the client holds 50 and reports
# them held at the start; ended at once they are all still there, ended 4 s later the server has closed every one of them and the client says
# so; an answer whose body does not match the pattern is a failure with its reason, nothing is held.
check_idle_client_hold_mode() {
  local out
  out="$(idle_client_run 18170 /health '^\{"status":"ok",.*\}$' 0)" || { echo "the client run failed: $out"; return 1; }
  jq -es '(map(select(.event == "held")) | .[0]) as $h | (map(select(.event == "ended")) | .[0]) as $e
    | $h.held == 50 and $h.closed_by_server == 0 and $h.failure == null and $h.rss_kb > 0 and $e.held == 50 and $e.closed_by_server == 0' <<<"$out" >/dev/null \
    || { echo "held and ended at once: expected 50 held, none closed: $(tr '\n' ' ' <<<"$out")"; return 1; }
  out="$(idle_client_run 18170 /health '^\{"status":"ok",.*\}$' 4)" || { echo "the client run failed: $out"; return 1; }
  jq -es '(map(select(.event == "held")) | .[0]) as $h | (map(select(.event == "ended")) | .[0]) as $e
    | $h.held == 50 and $e.held == 0 and $e.closed_by_server == 50' <<<"$out" >/dev/null \
    || { echo "ended 4 s later: expected all 50 closed by the server: $(tr '\n' ' ' <<<"$out")"; return 1; }
  out="$(idle_client_run 18170 /health '^nothing like this$' 0)" || { echo "the client run failed: $out"; return 1; }
  jq -es '(map(select(.event == "held")) | .[0]) as $h | $h.held == 0 and $h.failure == "bad answer" and ($h.detail | contains("status"))' <<<"$out" >/dev/null \
    || { echo "a body that does not match the pattern: expected the failure 'bad answer': $(tr '\n' ' ' <<<"$out")"; return 1; }
}

# check_series_rows <json> <jq path of the rows>: the rows are one per second with no gap, every row has the server's readings (CPU, memory,
# fds) and the server's telemetry line, and its endpoints as an object. The CPU of the first row (a partial second, before the load) and of
# the last (after it) can be a true 0; the rows between must have used some. Prints which clause failed and the seconds (as seconds into the run)
# that break it, returns 1.
check_series_rows() {
  local verdict
  verdict="$(jq -c "$2"' as $rows
    | ($rows | map(.second)) as $s
    | def at: . as $r | ($r.second - $rows[0].second);
      {clauses: {
         enough_rows: (($rows | length) > 5),
         no_gap: ([range(1; $s | length) | select($s[.] != $s[. - 1] + 1)] | length == 0),
         endpoints_are_objects: ($rows | map(.endpoints | type == "object") | all),
         server_readings: ($rows | map(.server != null and .server.cpu_usec >= 0 and .server.pss_anon_kb > 0 and .server.memory_current > 0 and .server.fds > 0) | all),
         server_cpu_in_the_rows_between: ($rows | .[1:-1] | map(.server != null and .server.cpu_usec > 0) | all),
         telemetry_every_second: ($rows | map(.telemetry != null) | all)},
       offending: {gaps_after_row: [range(1; $s | length) | select($s[.] != $s[. - 1] + 1) | . - 1],
                   server_missing_or_zero: [$rows | to_entries[] | select(.value.server == null or .value.server.cpu_usec < 0 or .value.server.pss_anon_kb <= 0 or .value.server.memory_current <= 0 or .value.server.fds <= 0
                                            or (.key > 0 and .key < ($rows | length) - 1 and .value.server.cpu_usec <= 0)) | {row: (.value | at), server: .value.server}],
                   telemetry_missing: [$rows[] | select(.telemetry == null) | at]},
       rows: ($rows | length)}' "$1")"
  jq -e '.clauses | all' <<<"$verdict" >/dev/null \
    || { echo "the per-second rows fail $(jq -c '[.clauses | to_entries[] | select(.value == false) | .key]' <<<"$verdict"): $(jq -c '{offending, rows}' <<<"$verdict")"; return 1; }
}

# The realistic mode with 3,000 idle connections: held at the start and at the end (the server counts them too), no k6 connection error, the
# client's memory is measured, one row per second of the run with latency per endpoint and the server's readings and telemetry (the
# telemetry's request count is the aggregator's within 3 %), the WAL's frames show the writes, and the copy was fully resident (no --cold).
check_realistic_idle_run() {
  local out rc=0 json left verdict
  json="$(mktemp -d)/realistic.json"
  out="$(bash "$LAB/realistic.sh" --image 8.5 --think-scale 0.1 --idle 3000 --hold 40,12 --label test --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/realistic.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'VALID' <<<"$out" || { echo "the run is not marked VALID: ${out//$'\n'/ | }"; return 1; }
  grep -q '^idle connections: 3000 requested, 3000 held at the start and 3000 at the end, 0 closed by the server' <<<"$out" \
    || { echo "the table does not report 3,000 held at the start and at the end: ${out//$'\n'/ | }"; return 1; }
  grep -q '^k6 connection errors: 0$' <<<"$out" || { echo "the table does not say k6 had no connection error"; return 1; }
  # Every clause is a named boolean, so that a failure says which one (and the numbers behind the counting ones).
  # The telemetry's count against the aggregator's is made on the seconds both sides cover whole: not the first row (the sampler starts in
  # the middle of a second) nor the last (its telemetry line is printed a moment after the run's last reading). A line the server lost is a
  # whole second (about 40 requests here), so the tolerance is 2 % and 8 requests: the requests that sit on the edges of the window
  # (k6 stamps a request when it ends, the server counts it when it starts) can fall on either side.
  verdict="$(jq -c '
    .results.series as $rows
    | ($rows | .[1:-1]) as $inner
    | ([$inner[].telemetry.requests // {} | to_entries[].value] | add // 0) as $tel
    | ([$inner[].requests] | add // 0) as $agg
    | {clauses: {
         idle_held_at_start_and_end: (.idle.requested == 3000 and .idle.held_at_start == 3000 and .idle.held_at_end == 3000),
         server_counts_the_idle_connections: (.idle.server_established_at_start == 3000 and .idle.server_established_at_end == 3000),
         fds_and_client_memory: (.idle.server_fds_open_with_idle > 3000 and .idle.client.memory_current_mib_at_end > 1 and .idle.client.rss_mib > 1),
         no_k6_connection_error: (.k6_connection_errors == 0),
         warm_copy: (.cold.requested == false and .cold.resident_share > 0.95),
         telemetry_on: (.server.env | index("APP_TELEMETRY=1") != null),
         wal_frames_seen: (([$rows[].server.wal_frames] | max) > 0),
         wal_bytes_seen: (([$rows[].server.wal_bytes] | max) > 0),
         longest_callback_seen: (([$rows[].telemetry.longest_callback_ms] | max) > 0),
         feed_endpoint_seen: ([$rows[].endpoints | keys[]] | unique | index("GET /feed") != null),
         telemetry_counts_the_requests: (($tel - $agg | fabs) <= 0.02 * $agg + 8)},
       numbers: {rows: ($rows | length), telemetry_requests: $tel, aggregator_requests: $agg,
                 rows_without_telemetry: [$rows[] | select(.telemetry == null) | .second],
                 rows_without_server: [$rows[] | select(.server == null) | .second],
                 wal_frames_max: ([$rows[].server.wal_frames] | max), longest_callback_max: ([$rows[].telemetry.longest_callback_ms] | max)}}' "$json")"
  jq -e '.clauses | all' <<<"$verdict" >/dev/null \
    || { echo "the JSON does not hold the idle run, failing clauses $(jq -c '[.clauses | to_entries[] | select(.value == false) | .key]' <<<"$verdict"), numbers $(jq -c '.numbers' <<<"$verdict"), idle $(jq -c '.idle' "$json")"; return 1; }
  check_series_rows "$json" '.results.series' || return 1
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-realistic-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
}

# The realistic mode with a soft limit equal to the idle count (300): every k6 request is a new connection that the server closes after its
# response, the 300 idle connections are all held at the end, k6 has no connection error, the server's close count is k6's request count
# within 1 %, nothing paused accepting, and the JSON says what bound the VU cap and the peak of the server's file descriptors (which a
# --no-series run does not read, and says so).
check_realistic_soft_limit_run() {
  local out rc=0 json verdict
  json="$(mktemp -d)/realistic.json"
  out="$(bash "$LAB/realistic.sh" --image 8.5 --think-scale 0.1 --idle 300 --hold 100,15 --env APP_SOFT_CONN_LIMIT=300 --label test --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/realistic.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'VALID' <<<"$out" || { echo "the run is not marked VALID: ${out//$'\n'/ | }"; return 1; }
  verdict="$(jq -c '
    ($ARGS.named.requests) as $k6
    | .server_connections as $c
    | {clauses: {
         idle_held: (.idle.held_at_start == 300 and .idle.held_at_end == 300 and .idle.closed_by_server_at_end == 0),
         no_k6_connection_error: (.k6_connection_errors == 0),
         closes_within_1_percent: ($c.telemetry != null and ($c.telemetry.close_responses - $k6 | fabs) <= 0.01 * $k6),
         no_accept_pause: ($c.telemetry.accept_pauses == 0),
         open_peak_above_the_idle: ($c.telemetry.open_peak > 300),
         soft_limit_recorded: ($c.soft_limit == 300),
         cap_not_bound_by_fds: (.load.vu_cap_bound_by == "k6 memory" or .load.vu_cap_bound_by == "local ports"),
         fds_peak_read: ($c.fds_peak > 300 and $c.fds_peak_note == null)},
       numbers: {k6_requests: $k6, server_connections: $c, bound_by: .load.vu_cap_bound_by}}' --argjson requests "$(jq '.results.run_total | map(.count) | add' "$json")" "$json")"
  jq -e '.clauses | all' <<<"$verdict" >/dev/null \
    || { echo "the JSON does not hold the run, failing clauses $(jq -c '[.clauses | to_entries[] | select(.value == false) | .key]' <<<"$verdict"), numbers $(jq -c '.numbers' <<<"$verdict")"; return 1; }
  grep -q '^server connections: soft limit 300, ' <<<"$out" || { echo "the table does not report the server's connections: ${out//$'\n'/ | }"; return 1; }
  out="$(bash "$LAB/realistic.sh" --image 8.5 --think-scale 0.1 --idle 100 --hold 40,8 --env APP_SOFT_CONN_LIMIT=100 --no-series --label test --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "--no-series: lab/realistic.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  jq -e '.server_connections.fds_peak == null and (.server_connections.fds_peak_note | contains("--no-series")) and .server_connections.telemetry.close_responses > 0' "$json" >/dev/null \
    || { echo "--no-series: the JSON should say the fd peak was not read: $(jq -c '.server_connections' "$json")"; return 1; }
  [ -z "$(docker ps -a --format '{{.Names}}' | grep '^lab-realistic-' || true)" ] || { echo "containers left behind"; return 1; }
}

# The realistic mode with 2 workers, 300 idle connections, about 190 VUs and a soft limit of 180 a process. The 300 idle connections split about
# 150 and 150 (never past 180, so none is closed), and with the VUs' connections each process hovers around its limit, so a good share of the
# responses of k6 say close (a connection that closes frees a seat, so not all of them). Valid; the telemetry of both processes summed (the
# closes are above a tenth of k6's request count and not above it; the peak is the sum of the two peaks and says so; the rows say 2 processes and count the requests the aggregator counted within
# 2 %); the file descriptors of both processes counted; the extensions recorded.
check_realistic_workers_run() {
  local out rc=0 json verdict
  json="$(mktemp -d)/realistic.json"
  out="$(bash "$LAB/realistic.sh" --image 8.5 --think-scale 0.1 --idle 300 --hold 200,15 --ext sockets --ext event --ext pcntl --env APP_WORKERS=2 --env APP_SOFT_CONN_LIMIT=180 --label test --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/realistic.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'VALID' <<<"$out" || { echo "the run is not marked VALID: ${out//$'\n'/ | }"; return 1; }
  verdict="$(jq -c '
    ($ARGS.named.requests) as $k6
    | .server_connections as $c
    | .results.series as $rows
    | ($rows | .[1:-1]) as $inner
    | ([$inner[].telemetry.requests // {} | to_entries[].value] | add // 0) as $tel
    | ([$inner[].requests] | add // 0) as $agg
    | {clauses: {
         idle_held: (.idle.held_at_start == 300 and .idle.held_at_end == 300 and .idle.closed_by_server_at_end == 0),
         no_k6_connection_error: (.k6_connection_errors == 0),
         two_processes_in_the_summary: ($c.telemetry.processes == 2 and $c.telemetry.open_peak_note != null),
         some_responses_close: ($c.telemetry != null and $c.telemetry.close_responses > 0.1 * $k6 and $c.telemetry.close_responses <= $k6),
         no_accept_pause: ($c.telemetry.accept_pauses == 0),
         peak_is_the_sum_of_two_peaks: ($c.telemetry.open_peak >= 300 and $c.telemetry.open_peak <= 600),
         rows_say_two_processes: (([$rows[].telemetry.processes // 0] | max) == 2),
         telemetry_counts_the_requests: (($tel - $agg | fabs) <= 0.02 * $agg + 8),
         fds_of_both_processes: ($c.fds_peak > 300 and $c.fds_peak_note == null),
         extensions_recorded: (.server.ext == ["sockets", "event", "pcntl"] and (.server.env | index("APP_WORKERS=2") != null))},
       numbers: {k6_requests: $k6, server_connections: $c, telemetry_requests: $tel, aggregator_requests: $agg}}' --argjson requests "$(jq '.results.run_total | map(.count) | add' "$json")" "$json")"
  jq -e '.clauses | all' <<<"$verdict" >/dev/null \
    || { echo "the JSON does not hold the run, failing clauses $(jq -c '[.clauses | to_entries[] | select(.value == false) | .key]' <<<"$verdict"), numbers $(jq -c '.numbers' <<<"$verdict")"; return 1; }
  grep -q '^server connections: soft limit 180, .* open at most (sum of the peak of each process, 2 processes), ' <<<"$out" || { echo "the table does not say the peak is a sum over 2 processes: ${out//$'\n'/ | }"; return 1; }
  [ -z "$(docker ps -a --format '{{.Names}}' | grep '^lab-realistic-' || true)" ] || { echo "containers left behind"; return 1; }
}

# A server that closes connections idle for 2 s: the run is INVALID with the reason (every one of the 200 idle connections was closed), exits 3,
# and leaves no container behind.
check_realistic_idle_closed_by_the_server_fails() {
  local out rc=0 json left
  json="$(mktemp -d)/realistic.json"
  out="$(bash "$LAB/realistic.sh" --image 8.5 --server "$LAB/check/fixtures/idle-timeout-app.php" --think-scale 0.1 --idle 200 --hold 20,10 --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 3 ] || { echo "expected exit 3 when the server closes idle connections, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q '^INVALID: .*the server closed 200 of the 200 idle connections during the run: 0 held at the end' <<<"$out" \
    || { echo "the reason is not reported: ${out//$'\n'/ | }"; return 1; }
  jq -e '.valid == false and .idle.held_at_start == 200 and .idle.held_at_end == 0 and .idle.closed_by_server_at_end == 200' "$json" >/dev/null \
    || { echo "the JSON does not say 200 held then 0: $(jq -c '{valid, idle}' "$json")"; return 1; }
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-realistic-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
}

# macro.sh on the app: --fresh-db starts it through lab_start_app, --cold evicts the copy (almost none of it resident, and the app reads the
# database from disk: major faults), --per-second gives one row per second with the latency of /posts/:id and the server's readings, and the
# aggregator saw exactly the requests k6's own summary counted.
check_macro_fresh_db_cold_per_second() {
  local out rc=0 json
  json="$(mktemp -d)/macro.json"
  out="$(bash "$LAB/macro.sh" --image 8.5 --server "$LAB/app/server.php" --fresh-db --cold --per-second --rate 400 --duration 8 --warmup 0 \
    --script "$LAB/macro/k6/posts.js" --path /posts/1 --label app --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/macro.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'VALID' <<<"$out" || { echo "the run is not marked VALID: ${out//$'\n'/ | }"; return 1; }
  jq -e '.valid == true and .cold.requested == true and .cold.resident_share < 0.05 and .server.ext == ["sockets", "event"]
         and (.server.env | index("APP_TELEMETRY=1") != null) and .results.error_rate == 0
         and .results.per_second.aggregator.requests == .results.requests and .results.per_second.aggregator.unparsed == 0
         and .results.per_second.aggregator.connection_errors == 0
         and ([.results.per_second.rows[].server.majflt] | add) > 0
         and ([.results.per_second.rows[].endpoints | keys[]] | unique == ["/posts/:id"])
         and ([.results.per_second.rows[].requests] | add) == .results.requests' "$json" >/dev/null \
    || { echo "the JSON does not hold the cold per-second run: $(jq -c '{valid, cold, requests: .results.requests, per_second: (.results.per_second | {aggregator, rows: (.rows | length)})}' "$json")"; return 1; }
  check_series_rows "$json" '.results.per_second.rows' || return 1
  grep -q '^sec  VUs  req  /posts/:id ' <<<"$out" || { echo "the table has no per-second header: ${out//$'\n'/ | }"; return 1; }
  [ -z "$(docker ps -a --format '{{.Names}}' | grep '^lab-macro-' || true)" ] || { echo "containers left behind"; return 1; }
  docker volume ls --format '{{.Name}}' | grep -x lab-macro-run >/dev/null && { echo "the volume lab-macro-run is left behind"; return 1; }
  return 0
}

# Without --fresh-db the bake-off server keeps copying its own seed: --cold alone is refused before any container starts.
check_macro_cold_needs_fresh_db() {
  local out rc=0
  out="$(bash "$LAB/macro.sh" --image 8.5 --server "$LAB/servers/noop-swoole.php" --rate 100 --duration 2 --cold 2>&1)" || rc=$?
  [ "$rc" = 2 ] || { echo "expected exit 2 for --cold without --fresh-db, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q -- '--cold needs --fresh-db' <<<"$out" || { echo "the message does not say why: ${out//$'\n'/ | }"; return 1; }
  [ -z "$(docker ps -a --format '{{.Names}}' | grep '^lab-macro-' || true)" ] || { echo "a container was started"; return 1; }
}

# The fold of a profile into the steps (lab/profile/fold-lib.php) on a hand-written profile of 1,000 samples whose shares are known: the
# leaf frame decides (an unnamed leaf is unclassified, even under a known frame), a stack with no route function is shared, the rules refuse a bad line.
# Then the command line: the table on the fixture (every row, the all row at 100 %, the unknown frame named), microseconds with
# --us-per-req, and an empty profile or a missing file refused.
check_fold_cases() {
  local out ok rc=0 fixture=/lab/check/fixtures/profile-collapsed.txt table
  out="$(bash "$LAB/run.sh" 8.5 php /lab/check/fold-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "fold-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q '^FAIL' <<<"$out" && { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" -ge 25 ] || { echo "expected at least 25 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  table="$(bash "$LAB/run.sh" 8.5 php /lab/profile/fold.php "$fixture" --us-per-req 40 2>&1)" || { echo "fold.php failed on the fixture: ${table//$'\n'/ | }"; return 1; }
  grep -q '^all .*100.0% 40.0us$' <<<"$table" || { echo "the all row is not 100.0% 40.0us: ${table//$'\n'/ | }"; return 1; }
  grep -q '^unclassified .* 1.0% 0.4us$' <<<"$table" || { echo "the unknown frame is not 1.0 % unclassified: ${table//$'\n'/ | }"; return 1; }
  grep -q 'unclassified: 10 samples (1.0%), leaf frames: mysteryFrame (10)' <<<"$table" || { echo "the unknown frame is not named: ${table//$'\n'/ | }"; return 1; }
  rc=0
  bash "$LAB/run.sh" 8.5 sh -c ': > /tmp/empty; php /lab/profile/fold.php /tmp/empty' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || { echo "an empty profile should exit 1, got $rc"; return 1; }
  rc=0
  bash "$LAB/run.sh" 8.5 php /lab/profile/fold.php /lab/check/fixtures/not-there.txt >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || { echo "a missing file should exit 1, got $rc"; return 1; }
}

# Where Excimer's samples land (lab/profile/calibrate.php), JIT on and off: an internal function's time (hash) is its calling PHP
# function's, within 5 points of the share measured without the profiler; the CPU time of a spinning libevent loop and of a socket
# pair ping-pong is all in the callbacks, and the samples add up to the CPU the process used (the kernel's time is counted).
check_excimer_calibration() {
  local jit out rc
  for jit in tracing disable; do
    rc=0
    out="$(bash "$LAB/run.sh" 8.5 php -d extension=sockets -d extension=event -d extension=excimer -d memory_limit=-1 -d opcache.enable_cli=1 -d "opcache.jit=$jit" \
      -d opcache.jit_buffer_size=32M -d opcache.file_update_protection=0 -d zend.assertions=-1 /lab/profile/calibrate.php hash --seconds 4 2>&1)" || rc=$?
    [ "$rc" = 0 ] || { echo "the hash calibration exited $rc with opcache.jit=$jit: ${out//$'\n'/ | }"; return 1; }
    grep -q "^jit: $([ "$jit" = tracing ] && echo on || echo off)\$" <<<"$out" || { echo "the JIT is not as asked ($jit): ${out//$'\n'/ | }"; return 1; }
    grep -q 'hash (the internal function) 0.0%' <<<"$out" || { echo "samples landed on a frame of the internal function: ${out//$'\n'/ | }"; return 1; }
    rc=0
    out="$(bash "$LAB/run.sh" 8.5 php -d extension=sockets -d extension=event -d extension=excimer -d memory_limit=-1 -d opcache.enable_cli=1 -d "opcache.jit=$jit" \
      -d opcache.jit_buffer_size=32M -d opcache.file_update_protection=0 -d zend.assertions=-1 /lab/profile/calibrate.php loop --seconds 2 2>&1)" || rc=$?
    [ "$rc" = 0 ] || { echo "the loop calibration exited $rc with opcache.jit=$jit: ${out//$'\n'/ | }"; return 1; }
    [ "$(grep -c ': ok$' <<<"$out")" = 2 ] || { echo "the loop calibration did not pass its two cases with opcache.jit=$jit: ${out//$'\n'/ | }"; return 1; }
  done
}

# check_profile_json <json> <step table text>: the JSON of a profiled run holds the profile (samples, the cgroup's user and system CPU,
# unclassified under 5 %), and the table has a column for each of the five endpoints and a row for each step. The four endpoints of the
# bench's journey have samples; S9 is empty (the commit is inside the write query).
check_profile_json() {
  local json="$1" fold="$2" row
  jq -e '.profile.samples > 100 and .profile.cgroup.user_usec > 0 and .profile.cgroup.system_usec > 0 and .profile.unclassified_share < 0.05
         and .profile.samples_over_cgroup_cpu > 0.8 and .profile.samples_over_cgroup_cpu < 1.2 and .server.ext == ["sockets", "event", "excimer"]
         and (.server.env | index("APP_TELEMETRY=0") != null) and (.server.env | index("APP_PROFILE=/tmp/profile.collapsed") != null)' "$json" >/dev/null \
    || { echo "the JSON does not hold a sound profile: $(jq -c '{profile: (.profile | del(.fold)), ext: .server.ext, env: .server.env}' "$json")"; return 1; }
  grep -q '^step  *GET /health  *GET /feed  *GET /posts/:id  *POST /posts  *POST /posts/:id/like  *shared  *all$' <<<"$fold" || { echo "the table has not the five endpoints, shared and all: ${fold//$'\n'/ | }"; return 1; }
  for row in 'S1 accept' 'S2 read' 'S3 route' 'S4 verify' 'S5 validate' 'S6 query' 'S7 build' 'S8 write' 'S9 durability' 'event loop' 'unclassified'; do
    grep -q "^$row" <<<"$fold" || { echo "the table has no row '$row': ${fold//$'\n'/ | }"; return 1; }
  done
  grep -q '^all .*100.0%' <<<"$fold" || { echo "the all row is not 100.0 %: ${fold//$'\n'/ | }"; return 1; }
  # The weight of each column in all the samples: health (only the harness's own polls), feed, post, create, like, shared.
  row="$(awk '/^weight in all samples/ { print $5, $6, $7, $8, $9, $10 }' <<<"$fold")"
  [ -n "$row" ] || { echo "the table has no weight row: ${fold//$'\n'/ | }"; return 1; }
  read -r _ feed post create like shared <<<"$row"
  for w in "$feed" "$post" "$create" "$like"; do
    [ "$w" != 0.0% ] || { echo "an endpoint of the journey has no sample: weights feed $feed, post $post, create $create, like $like, shared $shared"; return 1; }
  done
  grep -q '^S9 durability  *0.0%' <<<"$fold" || { echo "S9 is not empty: ${fold//$'\n'/ | }"; return 1; }
}

# A 20 s profiled run of the realistic mode (the bench's journey, scaled): the collapsed stacks are copied out of the container, the fold
# is printed with the cgroup's user and system CPU of the window, no container or volume is left, and an image with no Excimer is refused
# before anything starts.
check_realistic_profile_smoke() {
  local out rc=0 dir json collapsed fold
  dir="$(mktemp -d)"
  json="$dir/realistic.json"
  collapsed="$dir/profile.collapsed"
  out="$(bash "$LAB/realistic.sh" --image 8.5 --think-scale 0.1 --warmup 100,5 --hold 300,20 --ramp 3 --profile "$collapsed" --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/realistic.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  [ -s "$collapsed" ] || { echo "no collapsed stacks were copied out"; return 1; }
  grep -q '^/lab/app/server.php;DiyServer::run;' "$collapsed" || { echo "the collapsed stacks do not look like the app's: $(head -n 2 "$collapsed")"; return 1; }
  fold="$(jq -r '.profile.fold' "$json")"
  check_profile_json "$json" "$fold" || return 1
  grep -q '^cgroup CPU over the profiled window: user [0-9]* ms, system [0-9]* ms' <<<"$out" || { echo "the cgroup's user and system split is not printed: ${out//$'\n'/ | }"; return 1; }
  grep -q '^S6 query SQLite ' <<<"$out" || { echo "the table is not printed: ${out//$'\n'/ | }"; return 1; }
  [ -z "$(docker ps -a --format '{{.Names}}' | grep '^lab-realistic-' || true)" ] || { echo "containers left behind"; return 1; }
  docker volume ls --format '{{.Name}}' | grep -x lab-realistic-run >/dev/null && { echo "the volume lab-realistic-run is left behind"; return 1; }
  rc=0
  out="$(bash "$LAB/realistic.sh" --image 8.6 --think-scale 0.1 --hold 100,5 --profile "$dir/none.collapsed" --out "$dir/none.json" 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "an image with no Excimer should exit 1, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q 'this image has no Excimer' <<<"$out" || { echo "the message does not say why: ${out//$'\n'/ | }"; return 1; }
  [ -z "$(docker ps -a --format '{{.Names}}' | grep '^lab-realistic-' || true)" ] || { echo "containers left behind after the refusal"; return 1; }
  return 0
}

# macro.sh takes --profile too (with the app, --fresh-db): the same collapsed stacks and fold; without --fresh-db it is refused.
check_macro_profile() {
  local out rc=0 dir json
  dir="$(mktemp -d)"
  json="$dir/macro.json"
  out="$(bash "$LAB/macro.sh" --image 8.5 --server "$LAB/app/server.php" --fresh-db --rate 300 --duration 8 --warmup 2 \
    --script "$LAB/macro/k6/posts.js" --path /posts/1 --profile "$dir/profile.collapsed" --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/macro.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  [ -s "$dir/profile.collapsed" ] || { echo "no collapsed stacks were copied out"; return 1; }
  jq -e '.profile.samples > 100 and .profile.cgroup.user_usec > 0 and .profile.cgroup.system_usec > 0 and .profile.unclassified_share < 0.05
         and (.profile.fold | test("GET /posts/:id")) and .server.ext == ["sockets", "event", "excimer"]' "$json" >/dev/null \
    || { echo "the JSON does not hold a sound profile: $(jq -c '.profile | del(.fold)' "$json")"; return 1; }
  grep -q '^S6 query SQLite ' <<<"$out" || { echo "the table is not printed: ${out//$'\n'/ | }"; return 1; }
  [ -z "$(docker ps -a --format '{{.Names}}' | grep '^lab-macro-' || true)" ] || { echo "containers left behind"; return 1; }
  rc=0
  out="$(bash "$LAB/macro.sh" --image 8.5 --server "$LAB/servers/noop-swoole.php" --rate 100 --duration 2 --profile "$dir/x" 2>&1)" || rc=$?
  [ "$rc" = 2 ] || { echo "expected exit 2 for --profile without --fresh-db, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q -- '--profile needs --fresh-db' <<<"$out" || { echo "the message does not say why: ${out//$'\n'/ | }"; return 1; }
}

# The aggregator keeps up with k6 at the rows of 40,000 req/s (about 12 rows a request): a recorded CSV, replayed at 480,000 rows a
# second for 10 s, is read in full (every row, every request counted, none unparsed) with a lag under 3 s, and the feeder itself
# was never more than a second late (a feeder that blocks on a full FIFO proves nothing).
check_replay_keeps_up() {
  local out rc=0 fed result cfg
  cfg='{"fifo":"/tmp/csv","status":"/tmp/status.json","result":"/tmp/result.json","steps":[],"stop_on_fail":false,"users_per_rps":9.45,"server_cgroup":null,"k6_cgroup":null,"limits":{"p95_ms":500,"p99_ms":1000,"error_rate":0.01,"achieved_ratio":0.97}}'
  out="$(docker run --rm --cpuset-cpus "$LAB_CPUSET_K6" -v "$LAB:/lab:ro" -e "AGG_CONFIG=$cfg" "$LAB_IMAGE:8.5" sh -c '
    mkfifo /tmp/csv
    php -d memory_limit=-1 -d opcache.enable_cli=1 -d opcache.jit=tracing -d opcache.jit_buffer_size=32M /lab/macro/aggregate.php &
    sleep 1
    php /lab/macro/replay.php /lab/check/fixtures/k6-rows.csv /tmp/csv 480000 10
    wait
    cat /tmp/result.json' 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "the replay exited $rc: ${out//$'\n'/ | }"; return 1; }
  fed="$(grep '^fed ' <<<"$out")"
  result="$(grep '^{' <<<"$out")"
  [ -n "$fed" ] && [ -n "$result" ] || { echo "no feeder line or no result: ${out//$'\n'/ | }"; return 1; }
  awk -v f="$fed" 'BEGIN { split(f, a, " "); split(a[5], b, "="); exit !(b[2] <= 1.0) }' || { echo "the feeder was late, the replay proves nothing: $fed"; return 1; }
  jq -e --arg fed "$fed" '($fed | capture("requests=(?<r>[0-9]+)").r | tonumber) as $requests
    | ($fed | capture("rows=(?<r>[0-9]+)").r | tonumber) as $rows
    | .requests == $requests and .rows >= $rows and .unparsed == 0 and .lag_max_s < 3 and $rows > 4000000' <<<"$result" >/dev/null \
    || { echo "the aggregator did not keep up ($fed): $(jq -c '{rows, requests, unparsed, lag_max_s}' <<<"$result")"; return 1; }
}

# steplab_verdicts <case> [floor]: one line per non-reference variant of a recorded comparison (lab/check/fixtures/steplab/<case>): its
# name, verdict, median paired difference and the rounds that made a pair.
steplab_verdicts() {
  local dir="$LAB/check/fixtures/steplab/$1" summary floor_args=()
  [ -z "${2:-}" ] || floor_args=(--floor "$2")
  summary="$(mktemp)"
  bash "$LAB/steplab-summary.sh" "$dir" ${floor_args[@]+"${floor_args[@]}"} --json "$summary" >/dev/null 2>&1 || { echo "summary.sh failed on $1"; return 1; }
  jq -r '.variants[] | select(.reference | not) | [.variant, .verdict, (.median_difference_us | tostring), (.pairs | map(.round | tostring) | join(","))] | join("|")' "$summary"
  rm -f "$summary"
}

# The step lab's verdict on recorded run files (fixtures, no container): identical variants are within the noise; a variant 1 ms slower in
# every round is beyond it (and its twin of the reference is not); mixed signs are within, even with a median over the floor; the same
# sign under the floor is within; no floor means not judged; a round where either run is invalid has no pair; exactly one pair is a screen
# (beats the floor only when lower by at least the floor, never beyond the noise); no pair has no verdict. The tables list the runs round by round in the variants' order, and print the rule.
check_steplab_verdicts() {
  local got out
  got="$(steplab_verdicts identical 5)" || { echo "$got"; return 1; }
  [ "$got" = "twin|within the noise|0|1,2,3" ] || { echo "identical variants: $got"; return 1; }
  got="$(steplab_verdicts beyond 5)" || { echo "$got"; return 1; }
  [ "$got" = $'slow|beyond the noise|1000|1,2,3\nsame|within the noise|0|1,2,3' ] || { echo "a variant 1 ms slower: $got"; return 1; }
  got="$(steplab_verdicts mixed 5)" || { echo "$got"; return 1; }
  [ "$got" = "var|within the noise|10|1,2,3" ] || { echo "mixed signs: $got"; return 1; }
  got="$(steplab_verdicts under-floor 5)" || { echo "$got"; return 1; }
  [ "$got" = "var|within the noise|2.5|1,2,3" ] || { echo "under the floor: $got"; return 1; }
  got="$(steplab_verdicts under-floor)" || { echo "$got"; return 1; }
  [ "$got" = "var|no floor: not judged|2.5|1,2,3" ] || { echo "no floor: $got"; return 1; }
  got="$(steplab_verdicts invalid-round 5)" || { echo "$got"; return 1; }
  [ "$got" = "var|beyond the noise|11|1,3" ] || { echo "an invalid round of the variant: $got"; return 1; }
  got="$(steplab_verdicts ref-invalid 5)" || { echo "$got"; return 1; }
  [ "$got" = "var|beyond the noise|11|1,3" ] || { echo "an invalid round of the reference: $got"; return 1; }
  got="$(steplab_verdicts one-pair 5)" || { echo "$got"; return 1; }
  [ "$got" = "var|screen: not better in one pair|10|1" ] || { echo "a single pair, slower: $got"; return 1; }
  got="$(steplab_verdicts screen-beats 5)" || { echo "$got"; return 1; }
  [ "$got" = "var|screen: beats the floor|-10|1" ] || { echo "a single pair, 10 us lower: $got"; return 1; }
  got="$(steplab_verdicts screen-not-better 5)" || { echo "$got"; return 1; }
  [ "$got" = $'slower|screen: not better in one pair|10|1\nunder|screen: not better in one pair|-2|1' ] || { echo "a single pair, slower or lower by less than the floor: $got"; return 1; }
  got="$(steplab_verdicts screen-beats)" || { echo "$got"; return 1; }
  [ "$got" = "var|no floor: not judged|-10|1" ] || { echo "a single pair without a floor: $got"; return 1; }
  got="$(steplab_verdicts no-pair 5)" || { echo "$got"; return 1; }
  [ "$got" = "var|no verdict|null|" ] || { echo "no pair: $got"; return 1; }
  out="$(bash "$LAB/steplab-summary.sh" "$LAB/check/fixtures/steplab/beyond" --floor 5 2>&1)" || { echo "summary.sh failed: ${out//$'\n'/ | }"; return 1; }
  [ "$(grep -E '^ +[123] +(ref|slow|same) +' <<<"$out" | awk '{ printf "%s%s ", $1, $2 }')" = "1ref 1slow 1same 2ref 2slow 2same 3ref 3slow 3same " ] \
    || { echo "the rows are not one per run in round order: ${out//$'\n'/ | }"; return 1; }
  grep -q '^Rule: a variant is beyond the noise when' <<<"$out" || { echo "the rule is not printed: ${out//$'\n'/ | }"; return 1; }
  grep -qE '^slow +3/3 .*\+1000 \+1000 \+1000 .*beyond the noise' <<<"$out" || { echo "the variant table has no row for slow with its pairs and verdict: ${out//$'\n'/ | }"; return 1; }
  # The host's state per run: the load average in the middle of the plateau and the fsync median, from each run's `host` object, in columns that only appear when a run has them.
  grep -qE '^ +2 +slow +yes +[0-9.]+ +[0-9.]+ +[0-9.]+ +[0-9.]+ +[0-9-]+ +1\.6 +2\.5 +pass$' <<<"$out" \
    || { echo "the run table has no load1 1.6 and fsync ms 2.5 on the row of slow, round 2: ${out//$'\n'/ | }"; return 1; }
  grep -qE '^ +1 +ref +.* +0\.5 +1\.25 +pass$' <<<"$out" || { echo "the run table has no load1 0.5 and fsync ms 1.25 on the row of ref, round 1: ${out//$'\n'/ | }"; return 1; }
  out="$(bash "$LAB/steplab-summary.sh" "$LAB/check/fixtures/steplab/identical" --floor 5 2>&1)" || { echo "summary.sh failed on a folder without host objects: ${out//$'\n'/ | }"; return 1; }
  # Earlier runs have no host readings: their table has no such columns (the results folders' READMEs hold it byte for byte).
  grep -q 'load1' <<<"$out" && { echo "a folder of runs without host readings prints the load1 column: ${out//$'\n'/ | }"; return 1; }
  grep -qE '^ +1 +ref +.* +[0-9-]+ +pass$' <<<"$out" || { echo "the table of runs without host readings changed shape: ${out//$'\n'/ | }"; return 1; }
}

# steplab_order <variants and options...>: the order of each round that `lab/steplab.sh --dry-run` prints, one `round <n>: <names>` per line
# joined with `|`, without starting a server.
steplab_order() {
  local out
  out="$(bash "$LAB/steplab.sh" --dry-run --image 8.5 --rate 100 --think-scale 0.2 --seconds 6 "$@" 2>&1)" || { echo "steplab.sh --dry-run failed: ${out//$'\n'/ | }"; return 1; }
  grep '^round ' <<<"$out" | paste -sd'|' -
}

# The order of the rounds: round 1 runs the reference last (a one-pair screen is round 1 alone, and the second run of a pair reads about 0.2 us
# lower, which must work against the variant), the rounds alternate from there, counted from the folder's round number so that adding rounds with
# --first-round keeps the alternation; with 3 variants the odd rounds run them in reverse; `--order fixed` is the order given in every round.
check_steplab_order() {
  local got out rc=0
  got="$(steplab_order --pairs 4 --variant a= --variant b=)" || { echo "$got"; return 1; }
  [ "$got" = "round 1: b a|round 2: a b|round 3: b a|round 4: a b" ] || { echo "2 variants, 4 rounds: $got"; return 1; }
  got="$(steplab_order --pairs 4 --variant a= --variant b= --variant c=)" || { echo "$got"; return 1; }
  [ "$got" = "round 1: c b a|round 2: a b c|round 3: c b a|round 4: a b c" ] || { echo "3 variants, 4 rounds: $got"; return 1; }
  got="$(steplab_order --pairs 2 --first-round 2 --variant a= --variant b=)" || { echo "$got"; return 1; }
  [ "$got" = "round 2: a b|round 3: b a" ] || { echo "--first-round 2: $got"; return 1; }
  got="$(steplab_order --pairs 3 --first-round 5 --variant a= --variant b= --variant c=)" || { echo "$got"; return 1; }
  [ "$got" = "round 5: c b a|round 6: a b c|round 7: c b a" ] || { echo "--first-round 5, 3 variants: $got"; return 1; }
  got="$(steplab_order --pairs 3 --order fixed --variant a= --variant b=)" || { echo "$got"; return 1; }
  [ "$got" = "round 1: a b|round 2: a b|round 3: a b" ] || { echo "--order fixed: $got"; return 1; }
  got="$(steplab_order --pairs 2 --order alternate --variant a=)" || { echo "$got"; return 1; }
  [ "$got" = "round 1: a|round 2: a" ] || { echo "one variant: $got"; return 1; }
  out="$(bash "$LAB/steplab.sh" --dry-run --image 8.5 --rate 100 --think-scale 0.2 --seconds 6 --pairs 1 --order sideways --variant a= 2>&1)" || rc=$?
  [ "$rc" = 2 ] || { echo "--order sideways: expected exit 2, got $rc: ${out//$'\n'/ | }"; return 1; }
  rc=0
  out="$(bash "$LAB/steplab.sh" --dry-run --image 8.5 --rate 100 --think-scale 0.2 --seconds 6 --pairs 1 --floor 3 --floor-from "$LAB/check/fixtures/steplab/aa-outlier" --variant a= 2>&1)" || rc=$?
  [ "$rc" = 2 ] || { echo "--floor with --floor-from: expected exit 2, got $rc: ${out//$'\n'/ | }"; return 1; }
  rc=0
  out="$(bash "$LAB/steplab.sh" --dry-run --image 8.5 --rate 100 --think-scale 0.2 --seconds 6 --pairs 1 --floor-from "$LAB/check/fixtures/steplab/no-such-folder" --variant a= 2>&1)" || rc=$?
  [ "$rc" = 2 ] || { echo "--floor-from a missing folder: expected exit 2, got $rc: ${out//$'\n'/ | }"; return 1; }
  # Why a dry run reads the floor too: a folder that gives none must stop the comparison before hours of runs, not after them.
  rc=0
  out="$(bash "$LAB/steplab.sh" --dry-run --image 8.5 --rate 100 --think-scale 0.2 --seconds 6 --pairs 1 --floor-from "$LAB/check/fixtures/steplab/one-pair" --variant a= 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "--floor-from a folder with one pair: expected exit 1, got $rc: ${out//$'\n'/ | }"; return 1; }
  out="$(bash "$LAB/steplab.sh" --dry-run --image 8.5 --rate 100 --think-scale 0.2 --seconds 6 --pairs 1 --floor-from "$LAB/check/fixtures/steplab/aa-outlier" --variant a= 2>&1)" \
    || { echo "--floor-from an A/A folder: ${out//$'\n'/ | }"; return 1; }
  grep -qE '^floor: 0\.358 us ' <<<"$out" || { echo "the dry run does not say the floor: ${out//$'\n'/ | }"; return 1; }
}

# The floor of an A/A folder, one rule for every pair: |median of the paired differences| + their interquartile range (quartiles by linear
# interpolation, inclusive), every run counted that is valid with a CPU per request, whether its step passed the 97 % rule or not.
#  - aa-outlier is 5a's A/A at 24,000 req/s: its differences, in round order, -0.2604 +2.5650 -0.1607 -0.2665 -0.0633 (round 2's run of b failed the
#    97 % rule). Worked out by hand: sorted -0.2665 -0.2604 -0.1607 -0.0633 +2.5650, median -0.1607, q1 -0.2604 (2nd), q3 -0.0633 (4th), range
#    0.1971, floor 0.1607 + 0.1971 = 0.3578: neither the largest absolute difference (2.565) nor exclusive quartiles (1.68).
#  - aa-even has 4 pairs (+1 +2 +3 +10; round 5's b is invalid and has none): median 2.5, q1 at position 0.75 = 1.75, q3 at 2.25 = 3 + 0.25 * 7 = 4.75,
#    range 3, floor 5.5.
check_steplab_floor() {
  local got out rc=0 summary dir="$LAB/check/fixtures/steplab"
  got="$(bash "$LAB/steplab-floor.sh" "$dir/aa-outlier" 2>&1 | jq -c '[.floor_us, .median_difference_us, .iqr_us, .pairs]')" || { echo "steplab-floor.sh failed on aa-outlier: $got"; return 1; }
  [ "$got" = "[0.358,-0.161,0.197,5]" ] || { echo "aa-outlier: expected [0.358,-0.161,0.197,5], got $got"; return 1; }
  got="$(bash "$LAB/steplab-floor.sh" "$dir/aa-even" 2>&1 | jq -c '[.floor_us, .median_difference_us, .iqr_us, .pairs]')" || { echo "steplab-floor.sh failed on aa-even: $got"; return 1; }
  [ "$got" = "[5.5,2.5,3,4]" ] || { echo "aa-even: expected [5.5,2.5,3,4], got $got"; return 1; }
  out="$(bash "$LAB/steplab-floor.sh" "$dir/one-pair" 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "one pair: expected exit 1, got $rc: $out"; return 1; }
  grep -q 'at least 2' <<<"$out" || { echo "one pair: the message does not say 2 pairs are needed: $out"; return 1; }
  rc=0
  out="$(bash "$LAB/steplab-floor.sh" 2>&1)" || rc=$?
  [ "$rc" = 2 ] || { echo "no folder: expected exit 2, got $rc: $out"; return 1; }

  # The summary reads it with --floor-from, records the folder and the value, and judges a variant against it; both flags together are a usage error.
  summary="$(mktemp)"
  out="$(bash "$LAB/steplab-summary.sh" "$dir/beyond" --floor-from "$dir/aa-outlier" --json "$summary" 2>&1)" || { echo "summary.sh --floor-from failed: ${out//$'\n'/ | }"; return 1; }
  jq -e '.floor_us == 0.358 and (.floor_from | endswith("aa-outlier"))
         and (.floor_rule | type) == "string" and (.variants[] | select(.variant == "slow") | .verdict) == "beyond the noise"' "$summary" >/dev/null \
    || { echo "summary.json does not record the floor: $(jq -c '{floor_us, floor_from, floor_rule}' "$summary")"; rm -f "$summary"; return 1; }
  grep -qE '^Floor: 0\.358 us, from .*aa-outlier' <<<"$out" || { echo "the table does not say where the floor comes from: ${out//$'\n'/ | }"; rm -f "$summary"; return 1; }
  rc=0
  out="$(bash "$LAB/steplab-summary.sh" "$dir/beyond" --floor 5 --floor-from "$dir/aa-outlier" 2>&1)" || rc=$?
  [ "$rc" = 2 ] || { echo "summary.sh --floor with --floor-from: expected exit 2, got $rc: ${out//$'\n'/ | }"; rm -f "$summary"; return 1; }

  # Runs that carry their position: listed in the order they ran, a run whose step failed the 97 % rule counts and is flagged with `*`
  # (a failed_rule count per variant), and the folder says its order. Runs of 5a, with no position, print what they always printed.
  out="$(bash "$LAB/steplab-summary.sh" "$dir/aa-outlier" --floor 1 --json "$summary" 2>&1)" || { echo "summary.sh failed on aa-outlier: ${out//$'\n'/ | }"; rm -f "$summary"; return 1; }
  [ "$(grep -E '^ +[1-5] +[ab] +' <<<"$out" | awk '{ printf "%s%s ", $1, $2 }')" = "1b 1a 2a 2b 3b 3a 4a 4b 5b 5a " ] \
    || { echo "the rows are not in the order the runs ran: ${out//$'\n'/ | }"; rm -f "$summary"; return 1; }
  grep -qE '^ +2 +b +yes +[0-9.]+ +28\.5\* +.*FAIL: achieved below 97 % of offered$' <<<"$out" || { echo "the run of b that failed the rule has no * on its us/req: ${out//$'\n'/ | }"; rm -f "$summary"; return 1; }
  [ "$(grep -cE '^ +[1-5] +[ab] +yes +[0-9.]+ +[0-9.]+\* ' <<<"$out")" = 1 ] || { echo "only that run should have a *: ${out//$'\n'/ | }"; rm -f "$summary"; return 1; }
  jq -e '.order == "alternate" and .floor_from == null and (.variants | map({(.variant): .failed_rule}) | add) == {a: 0, b: 1}
         and (.variants[] | select(.variant == "b") | .valid_runs == 5 and (.pairs | length) == 5)' "$summary" >/dev/null \
    || { echo "summary.json: $(jq -c '{order, floor_from, failed: [.variants[] | {variant, failed_rule, valid_runs}]}' "$summary")"; rm -f "$summary"; return 1; }
  out="$(bash "$LAB/steplab-summary.sh" "$LAB/results/2026-11-23-s1-fd-wall/aa-24000" --json "$summary" 2>&1)" || { echo "summary.sh failed on 5a's A/A: ${out//$'\n'/ | }"; rm -f "$summary"; return 1; }
  grep -q '\*' <<<"$out" && { echo "runs without a position print a *: ${out//$'\n'/ | }"; rm -f "$summary"; return 1; }
  grep -q '^Floor:' <<<"$out" && { echo "runs without a position print a Floor line: ${out//$'\n'/ | }"; rm -f "$summary"; return 1; }
  [ "$(grep -E '^ +[1-5] +[ab] +' <<<"$out" | awk '{ printf "%s%s ", $1, $2 }')" = "1a 1b 2a 2b 3a 3b 4a 4b 5a 5b " ] || { echo "5a's rows changed order: ${out//$'\n'/ | }"; rm -f "$summary"; return 1; }
  jq -e '.order == null and (.variants[] | select(.variant == "b") | .failed_rule) == 1' "$summary" >/dev/null || { echo "5a's summary.json: $(jq -c '{order}' "$summary")"; rm -f "$summary"; return 1; }
  rm -f "$summary"
}

# The count of lab/syscalls.sh reads strace -c's table (a real one, lab/check/fixtures/strace-c.txt) into `<syscall> <calls> <errors>` lines,
# whatever the errors column does (strace leaves it blank when a syscall never failed), the time columns dropped, the total last.
check_syscalls_table_parse() {
  local got want
  got="$(awk -f "$LAB/syscalls-table.awk" "$LAB/check/fixtures/strace-c.txt")" || { echo "awk failed"; return 1; }
  want=$'read 1899 0\nopenat 1267 633\nfstat 1268 0\nclock_nanosleep 633 0\nnewfstatat 633 633\nclose 633 0\nlseek 634 0\nrestart_syscall 1 0\ntotal 6968 1266'
  [ "$got" = "$want" ] || { echo "the table is not read as expected: ${got//$'\n'/ | }"; return 1; }
}

# The TIME_WAIT count on k6's source addresses (probe.sh time-wait) reads a real /proc/net/tcp (lab/check/fixtures/proc-net-tcp-time-wait.txt:
# 3 sockets the client closed first on 127.0.1.2, 2 the server closed first on 127.0.1.3 (the address is then the remote one), 2 on
# 127.0.1.4, 1 on 127.0.0.9 outside the range): each address counts the sockets that have it at either end, the busiest address is the max.
check_time_wait_count() {
  local got want
  got="$(bash "$LAB/macro/probe.sh" time-wait 127.0.1.1-127.0.1.4 "$LAB/check/fixtures/proc-net-tcp-time-wait.txt" 2>&1)" || { echo "probe.sh failed: ${got//$'\n'/ | }"; return 1; }
  want=$'time_wait 127.0.1.1 0\ntime_wait 127.0.1.2 3\ntime_wait 127.0.1.3 2\ntime_wait 127.0.1.4 2\ntime_wait_summary max 3\ntime_wait_summary in_range 7\ntime_wait_summary all 8'
  [ "$got" = "$want" ] || { echo "the count is not the fixture's: ${got//$'\n'/ | }"; return 1; }
  # Two ranges, as steplab counts them (k6's addresses, then the idle client's 127.0.0.2 to 127.0.0.9 here): the socket on 127.0.0.9 now counts.
  got="$(bash "$LAB/macro/probe.sh" time-wait 127.0.1.1-127.0.1.4,127.0.0.2-127.0.0.9 "$LAB/check/fixtures/proc-net-tcp-time-wait.txt" 2>&1)" || { echo "probe.sh failed on two ranges: ${got//$'\n'/ | }"; return 1; }
  want=$'time_wait 127.0.1.1 0\ntime_wait 127.0.1.2 3\ntime_wait 127.0.1.3 2\ntime_wait 127.0.1.4 2'
  for n in 2 3 4 5 6 7 8; do want="$want"$'\n'"time_wait 127.0.0.$n 0"; done
  want="$want"$'\ntime_wait 127.0.0.9 1\ntime_wait_summary max 3\ntime_wait_summary in_range 8\ntime_wait_summary all 8'
  [ "$got" = "$want" ] || { echo "the count over two ranges is not the fixture's: ${got//$'\n'/ | }"; return 1; }
}

# The CPU layouts: unset is the Mac's Docker VM (server 2, k6 4-11, probe 0-1, no idle sibling), as before the x86 layout existed; x86-8
# reads a fixture of /sys/devices/system/cpu for two shapes of 4 cores of 2 threads (the siblings as a list, then as ranges) and keeps
# the server's hyperthread sibling out of every other cpuset; a host of 2 cores, and a name it does not know, stop the script.
check_cpu_layouts() {
  local tmp got want core i a b c list pairs
  tmp="$(mktemp -d)"
  got="$(env -u LAB_CPU_LAYOUT bash -c 'source "$1"; echo "$LAB_CPUSET_SERVER|$LAB_CPUSET_K6|$LAB_CPUSET_PROBE|$LAB_CPUSET_IDLE_SIBLING"' _ "$LAB/lib.sh" 2>&1)"
  [ "$got" = "2|4-11|0-1|" ] || { rm -rf "$tmp"; echo "the default layout changed: $got"; return 1; }
  # A c5.2xlarge pairs vCPU n with n+4 (a list); other hosts pair 2n with 2n+1 (the kernel prints a range).
  for core in "0,4 1,5 2,6 3,7|1|5|0,2,3,4,6,7|0,4" "0-1 2-3 4-5 6-7|2|3|0,1,4,5,6,7|0,1"; do
    rm -rf "$tmp/cpu"
    for i in 0 1 2 3 4 5 6 7; do mkdir -p "$tmp/cpu/cpu$i/topology"; done
    read -r -a pairs <<<"${core%%|*}"
    for list in "${pairs[@]}"; do
      IFS=,- read -r a b <<<"$list"
      for c in "$a" "${b:-$a}"; do printf '%s\n' "$list" >"$tmp/cpu/cpu$c/topology/thread_siblings_list"; done
    done
    want="${core#*|}"
    got="$(env LAB_CPU_LAYOUT=x86-8 LAB_SYSFS_CPU="$tmp/cpu" bash -c 'source "$1"; echo "$LAB_CPUSET_SERVER|$LAB_CPUSET_IDLE_SIBLING|$LAB_CPUSET_K6|$LAB_CPUSET_PROBE"' _ "$LAB/lib.sh" 2>&1)"
    [ "$got" = "$want" ] || { rm -rf "$tmp"; echo "x86-8 on '${core%%|*}': got $got, want $want"; return 1; }
  done
  rm -rf "$tmp/cpu"
  for i in 0 1 2 3; do mkdir -p "$tmp/cpu/cpu$i/topology"; echo "$((i / 2 * 2))-$((i / 2 * 2 + 1))" >"$tmp/cpu/cpu$i/topology/thread_siblings_list"; done
  got="$(env LAB_CPU_LAYOUT=x86-8 LAB_SYSFS_CPU="$tmp/cpu" bash -c 'source "$1"; echo sourced' _ "$LAB/lib.sh" 2>&1)" && { rm -rf "$tmp"; echo "x86-8 accepted a host of 2 cores"; return 1; }
  grep -q 'wants 4 cores' <<<"$got" || { rm -rf "$tmp"; echo "no message for a host of 2 cores: $got"; return 1; }
  rm -rf "$tmp"
  got="$(env LAB_CPU_LAYOUT=nope bash -c 'source "$1"; echo sourced' _ "$LAB/lib.sh" 2>&1)" && { echo "an unknown layout was accepted"; return 1; }
  grep -q 'unknown LAB_CPU_LAYOUT' <<<"$got" || { echo "no message for an unknown layout: $got"; return 1; }
  [ "$(bash -c 'source "$1"; lab_cpuset_count 4-11; lab_cpuset_count 0,2,3,4,6,7; lab_cpuset_count 0-1,4' _ "$LAB/lib.sh" | paste -sd, -)" = "8,6,3" ] || { echo "lab_cpuset_count is wrong"; return 1; }
}

# The two Swoole entries run unchanged: the copies under lab/servers/swoole-entries/ are byte for byte the challenge's files, and the
# two lines of tzimpel's build.sh that patch Swoole (the `perl -0pi` substitution and its "applied exactly twice" check) are the ones in
# lab/images/install-swoole-tzimpel.sh.
check_swoole_entries_are_unchanged() {
  local sub="$REPO/reference/twelve-dollar-server-challenge/submissions" f
  [ -d "$sub" ] || { echo "reference/twelve-dollar-server-challenge/submissions is missing"; return 1; }
  for f in php-swoole-mattsplat/server.php php-swoole-tzimpel/server.php php-swoole-tzimpel/php.ini; do
    cmp -s "$sub/$f" "$LAB/servers/swoole-entries/$f" || { echo "lab/servers/swoole-entries/$f is not the challenge's $f"; return 1; }
  done
  [ "$(sed -n 17,18p "$sub/php-swoole-tzimpel/build.sh")" = "$(grep -A1 '^perl -0pi' "$LAB/images/install-swoole-tzimpel.sh")" ] \
    || { echo "the patch lines of lab/images/install-swoole-tzimpel.sh are not lines 17 and 18 of the entry's build.sh"; return 1; }
}

# `--php-ini` (lab_build_php_flags with LAB_PHP_INI_FILE) makes the file the whole configuration: `-c <file>`, the extensions, nothing of the
# lab's own flags; without it the flags are the lab's, as before.
# Why disable SC2034: lab_build_php_flags (lib.sh) reads the three variables.
# shellcheck disable=SC2034
check_php_ini_flags() {
  local got
  got="$(LAB_EXT=(/opt/x/swoole.so) LAB_INI=() LAB_PHP_INI_FILE=/lab/x/php.ini; lab_build_php_flags; echo "${LAB_PHP_FLAGS[*]}")"
  [ "$got" = "-c /lab/x/php.ini -d extension=/opt/x/swoole.so" ] || { echo "with a php.ini the flags are: $got"; return 1; }
  got="$(LAB_EXT=(swoole) LAB_INI=() LAB_PHP_INI_FILE=""; lab_build_php_flags; echo "${LAB_PHP_FLAGS[*]}")"
  [ "$got" = "-d extension=swoole ${LAB_SERVER_PHP_FLAGS[*]}" ] || { echo "without a php.ini the flags are: $got"; return 1; }
}

# lab_containers_left: the containers and volume the realistic runs and the syscall sidecar leave, as one line (empty when none).
lab_containers_left() {
  local left
  left="$(docker ps -a --format '{{.Names}}' | grep -E '^lab-(realistic|syscalls)-' || true)"
  docker volume ls --format '{{.Name}}' | grep -x lab-realistic-run >/dev/null && left="$left lab-realistic-run (volume)"
  echo "${left//$'\n'/ }"
}

# The step lab live, at a low rate and a short plateau (the shape of its output, not a measurement): two variants for two rounds, the
# second one sets an environment variable the server must receive. One row per run in round order, one per variant with 2 pairs and a
# verdict (the floor is given), the TIME_WAIT counts before and after every run in the run's JSON, the idle connections held to the end,
# the telemetry off, and no container left behind.
check_steplab_live() {
  local out dir rc=0 pairs
  dir="$(mktemp -d)"
  out="$(bash "$LAB/steplab.sh" --image 8.5 --rate 100 --think-scale 0.2 --idle 200 --seconds 6 --pairs 2 --warmup 20,3 --floor 5 \
    --idle-time-wait-max 0 --variant ref= --variant twin=APP_UNUSED=1 --out "$dir" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/steplab.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  # Round 1 runs the reference last, round 2 in the order given; the progress line says each round's order.
  [ "$(grep -E '^ +[12] +(ref|twin) +' <<<"$out" | awk '{ printf "%s%s ", $1, $2 }')" = "1twin 1ref 2ref 2twin " ] \
    || { echo "the rows are not one per run in the order the runs ran: ${out//$'\n'/ | }"; return 1; }
  grep -q '^\[1/4\] round 1, twin (position 1 of 2, order: twin ref)$' <<<"$out" && grep -q '^\[3/4\] round 2, ref (position 1 of 2, order: ref twin)$' <<<"$out" \
    || { echo "the progress lines do not say the order of each round: ${out//$'\n'/ | }"; return 1; }
  grep -qE '^twin +2/2 .* (beyond|within) the noise$' <<<"$out" || { echo "no row for twin with its 2 valid runs and a verdict: ${out//$'\n'/ | }"; return 1; }
  grep -q '^Rule: a variant is beyond the noise when' <<<"$out" || { echo "the rule is not printed: ${out//$'\n'/ | }"; return 1; }
  grep -qE '^ +load1 +fsync ms|load1 +fsync ms' <<<"$out" || { echo "the run table has no load1 and fsync ms columns: ${out//$'\n'/ | }"; return 1; }
  for f in ref-1 ref-2 twin-1 twin-2; do
    jq -e '.steplab.time_wait.before.max >= 0 and .steplab.time_wait.after.max >= 0 and .steplab.time_wait.before.all >= .steplab.time_wait.before.in_range
           and ([.steplab.time_wait.after.per_address | keys[] | select(startswith("127.0.0."))] | length) >= 1
           and .steplab.time_wait.before.limit_per_address == 2500 and .steplab.time_wait.before.idle_limit_per_address == 0
           and .steplab.time_wait.before.idle_max == 0
           and .per_second_probes == false and .valid == true and .idle.held_at_end == 200 and (.server.env | index("APP_TELEMETRY=0") != null)
           and .load.warmup == "20,3" and .results.steps[0].cpu_usec_per_request > 0
           and .host.fsync_ms > 0 and (.host.plateau.load1 | type) == "number" and .host.plateau.steal_pct >= 0 and (.host.before.cpu_busy_pct | type) == "number"' "$dir/$f.json" >/dev/null \
      || { echo "$f.json does not hold the run as the runner sets it up: $(jq -c '{valid, steplab: .steplab.time_wait, env: .server.env, idle: .idle.held_at_end}' "$dir/$f.json" 2>&1)"; return 1; }
  done
  # The idle client of the run before left its sockets on the idle addresses: the next run (ref-1, the second of round 1) waited for them to go
  # (its 200 connections would collide with them at random), where the gate once let it through.
  jq -e '.steplab.time_wait.before.waited_s > 0' "$dir/ref-1.json" >/dev/null || { echo "the run after one with idle connections did not wait for their TIME_WAIT sockets: $(jq -c '.steplab.time_wait.before' "$dir/ref-1.json")"; return 1; }
  jq -e '.server.env | index("APP_UNUSED=1") != null' "$dir/twin-1.json" >/dev/null || { echo "the variant's environment did not reach the server"; return 1; }
  jq -e '.server.env | index("APP_UNUSED=1") == null' "$dir/ref-1.json" >/dev/null || { echo "the reference got the variant's environment"; return 1; }
  jq -e '.steplab.variant_index == 1 and .steplab.round == 2 and .steplab.reference == "ref" and .steplab.position == 1 and .steplab.order == "alternate"' "$dir/twin-2.json" >/dev/null || { echo "the run's steplab object is wrong"; return 1; }
  jq -e '.steplab.variant_index == 0 and .steplab.round == 1 and .steplab.position == 1 and .steplab.order == "alternate"' "$dir/ref-1.json" >/dev/null || { echo "the reference of round 1 does not say it ran second: $(jq -c '.steplab | {round, position, order}' "$dir/ref-1.json")"; return 1; }
  pairs="$(jq -r '.variants[] | select(.variant == "twin") | .pairs | length' "$dir/summary.json")"
  [ "$pairs" = 2 ] || { echo "summary.json has $pairs pairs for twin, expected 2"; return 1; }
  # Why: the runner's temp folder is a per-user path on the Mac; the files go to a public repository, so they hold <tmp> instead.
  # The runner's folder is a sibling of this test's own (both come from mktemp -d); the steplab object's own `command` names the test's
  # --out, which is the caller's choice, so only the run's `command` and the table's text are read.
  local tmp_hits="" f
  for f in ref-1 ref-2 twin-1 twin-2; do
    jq -r '.command' "$dir/$f.json" | grep -q -F "$(dirname "$dir")" && tmp_hits="$tmp_hits $f.json"
    grep -q -F "$(dirname "$dir")" "$dir/$f.txt" && tmp_hits="$tmp_hits $f.txt"
  done
  [ -z "$tmp_hits" ] || { echo "the runner's temp folder is in:$tmp_hits"; return 1; }
  grep -q -F '<tmp>/ref-1.json' "$dir/ref-1.txt" && jq -e '.command | contains("<tmp>/ref-1.json")' "$dir/ref-1.json" >/dev/null \
    || { echo "the run files do not name <tmp> where the runner's folder was"; return 1; }
  [ -z "$(lab_containers_left)" ] || { echo "left behind: $(lab_containers_left)"; return 1; }
}

# A server that dies at boot is a harness failure: exit 1 with the run's reason, and no container or volume left behind.
check_steplab_cleans_up_after_failure() {
  local out rc=0
  out="$(bash "$LAB/steplab.sh" --image 8.5 --rate 100 --think-scale 0.2 --seconds 6 --pairs 1 --warmup 20,3 \
    --server-variant crash="$LAB/check/fixtures/crash-app.php" --out "$(mktemp -d)" 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "expected exit 1 when the server dies, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q 'the server container exited' <<<"$out" || { echo "the reason is not reported: ${out//$'\n'/ | }"; return 1; }
  [ -z "$(lab_containers_left)" ] || { echo "left behind: $(lab_containers_left)"; return 1; }
}

# probe.sh reads the VM's CPU state from two captures of /proc/stat (a real file's shape: the aggregate line first, then one line per CPU, guest time
# already inside user time): between the fixtures the aggregate line moved by user 300, system 100, idle 500, iowait 50, softirq 20 and steal 30,
# 1,000 jiffies in all, so 45.00 % of them were busy (everything but idle and iowait) and 3.00 % were stolen. The CPU lines would give other numbers.
check_host_cpu_share_parse() {
  local got want
  got="$(bash "$LAB/macro/probe.sh" cpu-share "$LAB/check/fixtures/proc-stat-before.txt" "$LAB/check/fixtures/proc-stat-after.txt" 2>&1)" \
    || { echo "probe.sh failed: ${got//$'\n'/ | }"; return 1; }
  want=$'host cpu_busy_pct 45.00\nhost steal_pct 3.00'
  [ "$got" = "$want" ] || { echo "the shares are not the fixtures': ${got//$'\n'/ | }"; return 1; }
}

# The disk probe, in the lab's own image: the median of 20 writes of 4 KiB each followed by fdatasync is a positive number of milliseconds, and the
# probe leaves no file behind.
check_host_fsync_probe() {
  local out rc=0
  docker image inspect "$LAB_IMAGE:8.5" >/dev/null 2>&1 || { echo "image $LAB_IMAGE:8.5 is missing (run lab/build.sh 8.5)"; return 1; }
  out="$(docker run --rm -v "$LAB:/lab:ro" "$LAB_IMAGE:8.5" sh -c 'bash /lab/macro/probe.sh fsync /tmp/fsync-check.dat 20; test ! -e /tmp/fsync-check.dat && echo gone' 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "probe.sh fsync exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qE '^host fsync_ms [0-9]+(\.[0-9]+)?$' <<<"$out" && awk '$1 == "host" && $2 == "fsync_ms" { exit !($3 > 0) }' <<<"$out" \
    || { echo "no positive fsync_ms line: ${out//$'\n'/ | }"; return 1; }
  grep -qx gone <<<"$out" || { echo "the probe left its file behind: ${out//$'\n'/ | }"; return 1; }
}

# The series driver's dry run reads a series file (a comment, a blank line, a quoted argument) and prints each series' command, when it would start and
# end and the gap, without a container, a folder or a file: the number of containers is the same before and after, and nothing is written.
check_stages_dry_run() {
  local out dir before after rc=0
  dir="$(mktemp -d)/out"
  before="$(docker ps -a -q | wc -l)"
  out="$(bash "$LAB/stages.sh" "$LAB/check/fixtures/stages/two-series.txt" --dry-run --out "$dir" --gap 45 2>&1)" || rc=$?
  after="$(docker ps -a -q | wc -l)"
  [ "$rc" = 0 ] || { echo "lab/stages.sh --dry-run exited $rc: ${out//$'\n'/ | }"; return 1; }
  [ "$before" = "$after" ] || { echo "a dry run changed the containers: $before before, $after after"; return 1; }
  [ ! -e "$dir" ] || { echo "a dry run wrote $dir"; return 1; }
  grep -qF -e 'command: bash lab/steplab.sh --image 8.5 --rate 100 --think-scale 0.2 --seconds 6 --pairs 1 --variant ref= --variant-args '"'"'ref=--image 8.5'"'"' --out ' <<<"$out" \
    || { echo "the first series' command is not printed with its quoted argument as one word: ${out//$'\n'/ | }"; return 1; }
  [ "$(grep -c '^  command: ' <<<"$out")" = 2 ] || { echo "expected 2 commands: ${out//$'\n'/ | }"; return 1; }
  [ "$(grep -c '^  start: ' <<<"$out")" = 2 ] && [ "$(grep -c '^  end: ' <<<"$out")" = 2 ] || { echo "each series must show its start and end: ${out//$'\n'/ | }"; return 1; }
  [ "$(grep -c '^  gap: 45 s' <<<"$out")" = 1 ] || { echo "the gap is printed once, after the first series only: ${out//$'\n'/ | }"; return 1; }
}

# A series that exits non-zero stops the file and its code is returned (a flag steplab does not know: exit 2): stages.json holds the one series that
# ran, the second never started; with --keep-going both run and the first code is returned. With an unlabelled container on the VM (this check's
# own `sleep`, removed whatever happens) the driver refuses before starting the series, exits 1 and stages.json says why; --allow-busy runs it
# and marks it busy.
check_stages_stops_and_refuses() {
  local out dir rc=0 stranger=lab-check-stranger
  dir="$(mktemp -d)"
  out="$(bash "$LAB/stages.sh" "$LAB/check/fixtures/stages/bad-flags.txt" --allow-busy --gap 0 --out "$dir/stop" 2>&1)" || rc=$?
  [ "$rc" = 2 ] || { echo "expected steplab's exit 2 to be returned, got $rc: ${out//$'\n'/ | }"; return 1; }
  jq -e '(.series | length) == 1 and .series[0].name == "broken" and .series[0].exit_code == 2 and .series[0].refused == false' "$dir/stop/stages.json" >/dev/null \
    || { echo "stages.json does not stop at the failing series: $(jq -c . "$dir/stop/stages.json" 2>&1)"; return 1; }
  rc=0
  out="$(bash "$LAB/stages.sh" "$LAB/check/fixtures/stages/bad-flags.txt" --allow-busy --keep-going --gap 0 --out "$dir/keep" 2>&1)" || rc=$?
  [ "$rc" = 2 ] || { echo "--keep-going: expected the first code, 2, got $rc: ${out//$'\n'/ | }"; return 1; }
  jq -e '(.series | map(.name)) == ["broken", "after"] and (.series | all(.exit_code == 2))' "$dir/keep/stages.json" >/dev/null \
    || { echo "--keep-going did not run both series: $(jq -c . "$dir/keep/stages.json" 2>&1)"; return 1; }
  docker run -d --name "$stranger" --network none "$LAB_IMAGE:8.5" sleep 120 >/dev/null 2>&1 || { echo "cannot start the unlabelled container"; return 1; }
  rc=0
  out="$(bash "$LAB/stages.sh" "$LAB/check/fixtures/stages/bad-flags.txt" --gap 0 --out "$dir/refuse" 2>&1)" || rc=$?
  if [ "$rc" != 1 ]; then docker rm -f "$stranger" >/dev/null 2>&1; echo "expected a refusal (exit 1) with another container running, got $rc: ${out//$'\n'/ | }"; return 1; fi
  grep -q 'not quiet' <<<"$out" || { docker rm -f "$stranger" >/dev/null 2>&1; echo "the refusal does not say the VM is not quiet: ${out//$'\n'/ | }"; return 1; }
  jq -e '(.series | length) == 1 and .series[0].refused == true and .series[0].other_containers >= 1 and .series[0].start == null and .series[0].exit_code == null' \
    "$dir/refuse/stages.json" >/dev/null || { docker rm -f "$stranger" >/dev/null 2>&1; echo "stages.json does not record the refusal: $(jq -c . "$dir/refuse/stages.json" 2>&1)"; return 1; }
  [ ! -e "$dir/refuse/broken" ] || { docker rm -f "$stranger" >/dev/null 2>&1; echo "the refused series ran anyway"; return 1; }
  rc=0
  out="$(bash "$LAB/stages.sh" "$LAB/check/fixtures/stages/bad-flags.txt" --allow-busy --gap 0 --out "$dir/busy" 2>&1)" || rc=$?
  docker rm -f "$stranger" >/dev/null 2>&1
  [ "$rc" = 2 ] || { echo "--allow-busy: expected the series to run and exit 2, got $rc: ${out//$'\n'/ | }"; return 1; }
  jq -e '.series[0].busy == true and .series[0].other_containers >= 1 and .allow_busy == true' "$dir/busy/stages.json" >/dev/null \
    || { echo "--allow-busy does not mark the series busy: $(jq -c . "$dir/busy/stages.json" 2>&1)"; return 1; }
  [ -z "$(docker ps -a --format '{{.Names}}' | grep -x "$stranger" || true)" ] || { echo "the unlabelled container is still there"; return 1; }
}

# Two one-run series live, a second of gap between them: stages.json names the commit (40 hex) and holds both with start before end and exit 0, the second starts at least the gap
# after the first ended, each series has its folder with the summary, and each run's JSON has the host's state as numbers (--allow-busy: other
# projects' containers may run during a smoke; the count and the flag agree).
check_stages_live() {
  local out dir rc=0 f
  dir="$(mktemp -d)"
  out="$(bash "$LAB/stages.sh" "$LAB/check/fixtures/stages/live.txt" --allow-busy --gap 1 --out "$dir" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/stages.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  jq -e '(.commit | test("^[0-9a-f]{40}$")) and (.dirty | type) == "boolean"' "$dir/stages.json" >/dev/null \
    || { echo "stages.json does not name the commit (40 hex) and say whether a tracked file differs: $(jq -c '{commit, dirty}' "$dir/stages.json" 2>&1)"; return 1; }
  [ "$(jq -r '.commit' "$dir/stages.json")" = "$(git -C "$REPO" rev-parse HEAD)" ] || { echo "stages.json's commit is not the checkout's HEAD"; return 1; }
  jq -e '(.series | length) == 2 and (.series | map(.name)) == ["solo-a", "solo-b"] and (.series | all(.exit_code == 0 and .refused == false and (.start < .end)))
         and (.series | all((.busy == (.other_containers > 0))))
         and ((.series[1].start | fromdateiso8601) - (.series[0].end | fromdateiso8601)) >= 1 and .gap_s == 1' "$dir/stages.json" >/dev/null \
    || { echo "stages.json is not as expected: $(jq -c . "$dir/stages.json" 2>&1)"; return 1; }
  for f in solo-a/ref-1 solo-b/ref-1; do
    [ -s "$dir/$f.json" ] && [ -s "$dir/${f%/*}/summary.txt" ] || { echo "$f.json or its summary is missing"; return 1; }
    jq -e '.host as $h | ([$h.before.load1, $h.before.load5, $h.before.cpu_busy_pct, $h.before.steal_pct, $h.plateau.load1, $h.plateau.load5, $h.plateau.cpu_busy_pct,
              $h.plateau.steal_pct, $h.fsync_ms, $h.other_containers] | all(type == "number")) and $h.fsync_ms > 0 and $h.before.steal_pct >= 0 and $h.plateau.steal_pct >= 0
           and $h.before.cpu_busy_pct >= 0 and $h.before.cpu_busy_pct <= 100 and $h.plateau.cpu_busy_pct <= 100 and $h.other_containers == .other_containers.count
           and ($h | has("before_reason") or has("plateau_reason") or has("fsync_reason") | not)' "$dir/$f.json" >/dev/null \
      || { echo "$f.json has no complete host state: $(jq -c '.host | del(.docker_desktop, .vm_kernel, .limits)' "$dir/$f.json")"; return 1; }
  done
  grep -q 'load1' "$dir/solo-a/summary.txt" && grep -q 'fsync' "$dir/solo-a/summary.txt" || { echo "the summary does not print load1 and fsync ms"; return 1; }
  [ -z "$(lab_containers_left)" ] || { echo "left behind: $(lab_containers_left)"; return 1; }
}

# The syscall count live, at a low rate: the table's total per request is positive, the write family (one response per request on the
# skeleton) is near 1, the window holds as many rows as seconds, the JSON keeps no path, and no container is left behind.
check_syscalls_live() {
  local out json rc=0
  json="$(mktemp -d)/syscalls.json"
  out="$(bash "$LAB/syscalls.sh" --image 8.5 --rate 300 --think-scale 0.2 --seconds 5 --out "$json" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/syscalls.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qE '^total +[0-9]+ +[0-9.]+ +[0-9]+$' <<<"$out" || { echo "the table has no total row: ${out//$'\n'/ | }"; return 1; }
  jq -e '.total.calls_per_request > 0 and .requests > 0 and .window.seconds == 5 and (.syscalls | length) > 3
         and (.write_family.calls_per_request >= 0.8 and .write_family.calls_per_request <= 1.3)
         and (.syscalls | map(.calls_per_request) | all(. >= 0)) and (.syscalls | map(has("seconds") or has("usecs_per_call")) | any | not)' "$json" >/dev/null \
    || { echo "the JSON does not hold the count: $(jq -c 'del(.syscalls)' "$json")"; return 1; }
  grep -q '/Users/\|/home/' "$json" && { echo "the JSON holds a path"; return 1; }
  [ -z "$(lab_containers_left)" ] || { echo "left behind: $(lab_containers_left)"; return 1; }
  return 0
}

# A server that dies before its plateau ends the count with exit 1 and its reason, and leaves no container, sidecar or volume behind.
check_syscalls_cleans_up_after_failure() {
  local out rc=0
  out="$(bash "$LAB/syscalls.sh" --image 8.5 --rate 300 --think-scale 0.2 --seconds 5 --server "$LAB/check/fixtures/crash-app.php" --out "$(mktemp -d)/x.json" 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "expected exit 1 when the server dies, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q 'ended (exit 1) before its plateau' <<<"$out" || { echo "the reason is not reported: ${out//$'\n'/ | }"; return 1; }
  [ -z "$(lab_containers_left)" ] || { echo "left behind: $(lab_containers_left)"; return 1; }
}

# lab/post-plan.sh on the seed reports what it read and ends on a verdict line (whichever it is: the script reports, it does not
# judge). The fixture, a schema change halfway through the executions, must move the re-prepare counter and make the verdict `timing
# needed`: a fixture that left the counter at 0 would prove nothing about the closed verdict. A missing seed is an error.
check_post_plan() {
  local out rc=0 last fixture seed_rc=0
  out="$(bash "$LAB/post-plan.sh" --image 8.5 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/post-plan.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  last="$(tail -n 1 <<<"$out")"
  grep -q -E '^post-plan: (closed|timing needed \(.+\))$' <<<"$last" || { echo "the last line is not a verdict: $last"; return 1; }
  grep -q -E '^sqlite: 3\.[0-9]+\.[0-9]+' <<<"$out" || { echo "no SQLite version: ${out//$'\n'/ | }"; return 1; }
  grep -q -E '^ENABLE_STAT4: (yes|no)$' <<<"$out" || { echo "no ENABLE_STAT4 line: ${out//$'\n'/ | }"; return 1; }
  [ "$(grep -c -E '^  SQLITE_STMTSTATUS_REPREPARE: [0-9]+$' <<<"$out")" = 2 ] || { echo "expected 2 re-prepare counts: ${out//$'\n'/ | }"; return 1; }
  [ "$(grep -c -E '^    SEARCH ' <<<"$out")" -ge 6 ] || { echo "expected the EXPLAIN QUERY PLAN of both forms: ${out//$'\n'/ | }"; return 1; }
  rc=0
  fixture="$(bash "$LAB/post-plan.sh" --image 8.5 --force-reprepare 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "the fixture: lab/post-plan.sh exited $rc: ${fixture//$'\n'/ | }"; return 1; }
  grep -q -E '^  SQLITE_STMTSTATUS_REPREPARE: [1-9][0-9]*$' <<<"$fixture" || { echo "the schema change did not move the re-prepare counter: ${fixture//$'\n'/ | }"; return 1; }
  [ "$(tail -n 1 <<<"$fixture" | cut -c1-26)" = "post-plan: timing needed (" ] || { echo "the fixture's verdict is not 'timing needed': $(tail -n 1 <<<"$fixture")"; return 1; }
  bash "$LAB/post-plan.sh" --image 8.5 --seed "$LAB/data/missing-feed.db" >/dev/null 2>&1 || seed_rc=$?
  [ "$seed_rc" = 1 ] || { echo "a missing seed should exit 1, got $seed_rc"; return 1; }
}

# php-lab:8.5-sqlite runs on the SQLite built by lab/images/install-sqlite-tuned.sh: the version that script pins, the single-thread options
# it sets, and php's `ldd` pointing at /opt/sqlite-tuned; the instrumented (-fprofile-generate) library is gone, Ubuntu's libsqlite3.so.0
# is still its package's and still usable (php on LD_LIBRARY_PATH reads Ubuntu's version). The training refuses to run nothing: the image
# is built only when the count it prints is above 0, so the check runs the trainer on a small database with 0 loops, which must fail.
# Skips when the image is not built (lab/build.sh 8.5-sqlite).
check_sqlite_tuned() {
  local want out opt system_dir system_version schema app rc=0
  docker image inspect "$LAB_IMAGE:8.5-sqlite" >/dev/null 2>&1 || { echo "skip: image $LAB_IMAGE:8.5-sqlite is not built (run lab/build.sh 8.5-sqlite)"; return 0; }
  want="$(sed -n 's/^SQLITE_VERSION=//p' "$LAB/images/install-sqlite-tuned.sh")"
  [ -n "$want" ] || { echo "no SQLITE_VERSION in lab/images/install-sqlite-tuned.sh"; return 1; }
  out="$(bash "$LAB/run.sh" 8.5-sqlite php -r '
    $db = new PDO("sqlite::memory:");
    echo "version: ", $db->query("select sqlite_version()")->fetchColumn(), "\n";
    echo "options: ", implode(" ", $db->query("pragma compile_options")->fetchAll(PDO::FETCH_COLUMN)), "\n";' 2>&1)" || { echo "php failed: $out"; return 1; }
  grep -qx "version: $want" <<<"$out" || { echo "the image's SQLite is not $want: ${out//$'\n'/ | }"; return 1; }
  for opt in THREADSAFE=0 DEFAULT_MEMSTATUS=0 DQS=0 LIKE_DOESNT_MATCH_BLOBS MAX_EXPR_DEPTH=0 OMIT_DEPRECATED OMIT_PROGRESS_CALLBACK OMIT_SHARED_CACHE USE_ALLOCA; do
    grep -q -E "^options: (.* )?$opt( |$)" <<<"$out" || { echo "compile option $opt is missing: ${out//$'\n'/ | }"; return 1; }
  done
  out="$(bash "$LAB/run.sh" 8.5-sqlite sh -c 'ldd "$(command -v php)" | grep sqlite; nm -D /opt/sqlite-tuned/lib/libsqlite3.so.0 | grep -c gcov; dpkg --verify libsqlite3-0 | grep -c "libsqlite3[.]so"; dpkg -L libsqlite3-0 | grep "libsqlite3.so.0$"' 2>&1)" || true
  grep -q -E '^[[:space:]]*libsqlite3\.so\.0 => /opt/sqlite-tuned/lib/libsqlite3\.so\.0 ' <<<"$out" || { echo "php does not load /opt/sqlite-tuned/lib/libsqlite3.so.0: ${out//$'\n'/ | }"; return 1; }
  [ "$(sed -n '2p' <<<"$out")" = 0 ] || { echo "the library still holds profiling code (__gcov symbols): the -fprofile-use build did not replace it: ${out//$'\n'/ | }"; return 1; }
  # Why: the base image has no /usr/share/doc, so `dpkg --verify` lists those files as missing; only the library's own line matters.
  [ "$(sed -n '3p' <<<"$out")" = 0 ] || { echo "Ubuntu's libsqlite3.so.0 does not match its package: ${out//$'\n'/ | }"; return 1; }
  system_dir="$(dirname "$(tail -n 1 <<<"$out")")"
  system_version="$(bash "$LAB/run.sh" 8.5-sqlite env "LD_LIBRARY_PATH=$system_dir" php -r 'echo (new PDO("sqlite::memory:"))->query("select sqlite_version()")->fetchColumn();' 2>&1)"
  [ "$system_version" = 3.45.1 ] || { echo "Ubuntu's library no longer answers 3.45.1 when it is put first: $system_version"; return 1; }
  schema="$(cd -P "$REPO/reference/twelve-dollar-server-challenge" 2>/dev/null && pwd)/schema.sql"
  app="$REPO/submissions/php-Gcob/app.php"
  [ -f "$schema" ] && [ -f "$app" ] || { echo "the challenge's schema.sql or the submission's app.php is missing"; return 1; }
  out="$(docker run --rm -v "$LAB:/lab:ro" -v "$schema:/schema.sql:ro" -v "$app:/app.php:ro" "$LAB_IMAGE:8.5-sqlite" sh -c '
    php /lab/images/sqlite-train.php generate /schema.sql /tmp/t.db --scale 0.002 >/dev/null || exit 9
    php /lab/images/sqlite-train.php run /app.php /tmp/t.db --loops 200 || exit 8
    php /lab/images/sqlite-train.php run /app.php /tmp/t.db --loops 0' 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "the trainer with 0 loops should exit 1, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q -E '^training: [1-9][0-9]* statements ' <<<"$out" || { echo "the trainer ran no statement with 200 loops: ${out//$'\n'/ | }"; return 1; }
  grep -q 'the training ran no statement' <<<"$out" || { echo "the 0-loop failure has no reason: ${out//$'\n'/ | }"; return 1; }
}

# The bash scripts of the lab, one repo-relative path per line: every `*.sh` and every file whose first line is a bash or sh
# shebang, except the fixtures (they hold deliberate warnings) and the seed data.
lab_bash_scripts() {
  local f
  find "$LAB" -type f ! -path "$LAB/data/*" ! -path "$LAB/check/fixtures/*" | sort | while IFS= read -r f; do
    if [[ "$f" == *.sh ]] || head -n 1 "$f" 2>/dev/null | grep -q -a -E '^#!.*(bash|[ /]sh)( |$)'; then
      echo "lab/${f#"$LAB"/}"
    fi
  done
}

# Runs the pinned shellcheck on repo-relative paths (shellcheck_run <path>...), the repo mounted read-only, warnings and up.
# Prints its findings (`file:line:col: severity: message [SCxxxx]`), returns shellcheck's exit code (1 = findings).
shellcheck_run() {
  docker run --rm -v "$LAB/..:/repo:ro" -w /repo "$LAB_SHELLCHECK_IMAGE" --severity=warning --format=gcc --external-sources "$@" 2>&1
}

# Every bash script of the lab passes shellcheck at warning level.
check_shellcheck() {
  local scripts=() script out rc=0
  # Why: macOS ships bash 3.2, which has no mapfile.
  while IFS= read -r script; do scripts+=("$script"); done < <(lab_bash_scripts)
  [ "${#scripts[@]}" -gt 0 ] || { echo "no bash script found under lab/"; return 1; }
  out="$(shellcheck_run "${scripts[@]}")" || rc=$?
  [ "$rc" = 0 ] || { echo "shellcheck exited $rc: ${out//$'\n'/ | }"; return 1; }
}

# The fixture holds one known warning: shellcheck must fail on it, and the normal scan must not include it. Together they
# prove check_shellcheck is able to fail.
check_shellcheck_catches_warning() {
  local out rc=0
  out="$(shellcheck_run lab/check/fixtures/lint-warning.sh)" || rc=$?
  [ "$rc" = 1 ] || { echo "expected exit 1 on the fixture, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q 'lint-warning.sh:5:.*SC2046' <<<"$out" || { echo "the fixture's SC2046 is not reported: ${out//$'\n'/ | }"; return 1; }
  if lab_bash_scripts | grep -q 'check/fixtures'; then
    echo "the fixture is part of the normal scan"; return 1
  fi
}

# results_check <root>: every <root>/*/summarize.sh is run from its folder, and what it prints must be in that folder's README.md, so
# a README cannot drift from its raw files. A README with the lines `<!-- BEGIN summarize -->` and `<!-- END summarize -->` holds the
# output between them exactly (a stale extra line, a missing one, a changed one all fail); a README without them only has to hold every
# non-empty line the script prints, byte for byte, somewhere. One line per folder on stderr: `ok`, `skip` (no summarize.sh) or the
# first difference. Returns 1 if any folder fails or none was checked.
results_check() {
  local root="$1" dir name out rc checked=0 failed=0 missing begins ends
  out="$(mktemp)"
  for dir in "$root"/*/; do
    dir="${dir%/}"
    name="${dir##*/}"
    if [ ! -f "$dir/summarize.sh" ]; then
      echo "  skip  $name (no summarize.sh)" >&2
      continue
    fi
    checked=$((checked + 1))
    rc=0
    bash "$dir/summarize.sh" >"$out" 2>/dev/null </dev/null || rc=$?
    if [ "$rc" != 0 ]; then
      echo "  FAIL  $name: summarize.sh exited $rc" >&2; failed=1; continue
    fi
    if [ ! -s "$out" ]; then
      echo "  FAIL  $name: summarize.sh prints nothing" >&2; failed=1; continue
    fi
    [ -f "$dir/README.md" ] || { echo "  FAIL  $name: no README.md" >&2; failed=1; continue; }
    begins="$(grep -c '^<!-- BEGIN summarize -->$' "$dir/README.md" || true)"
    ends="$(grep -c '^<!-- END summarize -->$' "$dir/README.md" || true)"
    if [ "$begins" != 0 ] || [ "$ends" != 0 ]; then
      if [ "$begins" != 1 ] || [ "$ends" != 1 ]; then
        echo "  FAIL  $name: README.md needs exactly one BEGIN and one END summarize line, has $begins and $ends" >&2; failed=1; continue
      fi
      missing="$(diff <(sed -n '/^<!-- BEGIN summarize -->$/,/^<!-- END summarize -->$/p' "$dir/README.md" | sed '1d;$d') "$out" | sed -n '/^[<>]/{p;q;}')"
      if [ -n "$missing" ]; then
        echo "  FAIL  $name: README.md's summarize block differs from summarize.sh (< README, > script): $missing" >&2; failed=1
      else
        echo "  ok    $name (the block, $(wc -l <"$out" | tr -d ' ') lines)" >&2
      fi
      continue
    fi
    # Why: awk compares whole lines as bytes (a set lookup), which grep -x with a pattern would not do for `|` and `.`.
    missing="$(awk 'NR == FNR { seen[$0] = 1; next } $0 != "" && !($0 in seen) { print; exit }' "$dir/README.md" "$out")"
    if [ -n "$missing" ]; then
      echo "  FAIL  $name: README.md lacks the line: $missing" >&2; failed=1
    else
      echo "  ok    $name ($(grep -c . "$out") lines)" >&2
    fi
  done
  rm -f "$out"
  [ "$checked" -gt 0 ] || { echo "  FAIL  no summarize.sh under $root" >&2; return 1; }
  return "$failed"
}

# Every results folder with a summarize.sh still prints, line for line, tables that its README holds.
check_results_regenerate() {
  local report rc=0
  report="$(results_check "$LAB/results" 2>&1)" || rc=$?
  echo "$report" >&2
  [ "$rc" = 0 ] || { echo "a README differs from its summarize.sh: ${report//$'\n'/ | }"; return 1; }
}

# The fixtures: one README misses a line of its summarize.sh (it holds a near copy), one has a stale extra line in its
# BEGIN/END block (the line check alone would pass it, every printed line is in the file), a folder without a script is skipped, and
# folders that are right pass: with the lines anywhere, and with a block that is exact (prose outside it is free).
check_results_check_catches_drift() {
  local out rc=0 good
  out="$(results_check "$LAB/check/fixtures/results-drift" 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "expected exit 1 on the drifted fixtures, got $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qxF '  FAIL  drifted: README.md lacks the line: | b | 2 | µs |' <<<"$out" || { echo "the missing line is not named: ${out//$'\n'/ | }"; return 1; }
  grep -qxF "  FAIL  stale-block: README.md's summarize block differs from summarize.sh (< README, > script): < | c | 3 |" <<<"$out" \
    || { echo "the stale line of the block is not named: ${out//$'\n'/ | }"; return 1; }
  grep -qxF '  skip  hand-written (no summarize.sh)' <<<"$out" || { echo "the folder without a script is not named as skipped: ${out//$'\n'/ | }"; return 1; }
  grep -q 'FAIL  hand-written' <<<"$out" && { echo "the folder without a script fails"; return 1; }
  good="$(mktemp -d)"
  mkdir "$good/whole" "$good/block"
  printf '%s\n' 'echo "| a | 1 |"' 'echo' 'echo "| b | 2 | µs |"' >"$good/whole/summarize.sh"
  printf '%s\n' 'prose' '| a | 1 |' '| b | 2 | µs |' >"$good/whole/README.md"
  cp "$good/whole/summarize.sh" "$good/block/summarize.sh"
  printf '%s\n' 'prose with | z | 9 | in it' '<!-- BEGIN summarize -->' '| a | 1 |' '' '| b | 2 | µs |' '<!-- END summarize -->' 'more prose' >"$good/block/README.md"
  rc=0
  out="$(results_check "$good" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "a README that holds every line fails: ${out//$'\n'/ | }"; return 1; }
  # A block that lost a line, and a block with one marker only, fail.
  printf '%s\n' '<!-- BEGIN summarize -->' '| a | 1 |' '' '<!-- END summarize -->' '| b | 2 | µs |' >"$good/block/README.md"
  rc=0
  out="$(results_check "$good" 2>&1)" || rc=$?
  [ "$rc" = 1 ] && grep -qF "block differs from summarize.sh (< README, > script): > | b | 2 | µs |" <<<"$out" \
    || { echo "a block that lost a line passes or is not named (exit $rc): ${out//$'\n'/ | }"; rm -rf "$good"; return 1; }
  printf '%s\n' '<!-- BEGIN summarize -->' '| a | 1 |' '' '| b | 2 | µs |' >"$good/block/README.md"
  rc=0
  out="$(results_check "$good" 2>&1)" || rc=$?
  rm -rf "$good"
  [ "$rc" = 1 ] && grep -qF "needs exactly one BEGIN and one END summarize line, has 1 and 0" <<<"$out" \
    || { echo "a block with no END passes or is not named (exit $rc): ${out//$'\n'/ | }"; return 1; }
}

# The score search (lab/score/): the next-step rule, the plateau window, the per-run numbers and the walls, each on fixtures; the search itself runs
# against a fake controller and a fake k6. Only the sampler part needs Docker (the image `php-lab:8.5`, for bash 5 and a Linux /proc), and the
# refusals copy `bench/load.js` from the challenge's clone in `reference/`.
# score_check_steps: the arithmetic of the search (Jacob's 5 % steps, rounded to the nearest n; holds start at the highest pass).
score_check_steps() {
  local got
  # shellcheck source=score/score-lib.sh
  source "$LAB/score/score-lib.sh" || { echo "lab/score/score-lib.sh does not load"; return 1; }
  got="$(u=71000; for _ in 1 2 3 4 5 6 7 8; do printf '%s ' "$u"; u="$(score_next_up "$u" 5 1000)"; done)"
  [ "$got" = "71000 75000 79000 83000 87000 91000 96000 101000 " ] || { echo "probes up from 71,000: $got"; return 1; }
  got="$(score_next_down 71000 5 1000)"
  [ "$got" = 67000 ] || { echo "5 % under 71,000 is 67,000 (rounded), got $got"; return 1; }
  got="$(score_next_down 67000 5 1000) $(score_next_down 64000 5 1000)"
  [ "$got" = "64000 61000" ] || { echo "holds down from 67,000: $got"; return 1; }
  got="$(score_round 74550 1000) $(score_round 70775 1000) $(score_round 70500 1000) $(score_round 70499 1000)"
  [ "$got" = "75000 71000 71000 70000" ] || { echo "rounding to the nearest 1,000 (half up): $got"; return 1; }
  got="$(score_next_up 200 50 10) $(score_next_down 300 50 10)"
  [ "$got" = "300 150" ] || { echo "the smoke's size (step 50 %, round 10): $got"; return 1; }
  # The finer search (phase 8): one probe halfway between the last pass and the fail, then holds 2.5 % apart. By hand: (135,000 + 142,000) / 2 = 138,500, which
  # rounds half up to 139,000; 139,000 x 0.975 = 135,525 -> 136,000; 136,000 x 0.975 = 132,600 -> 133,000; 135,000 x 0.975 = 131,625 -> 132,000.
  got="$(score_halfway 135000 142000 1000) $(score_halfway 71000 75000 1000) $(score_halfway 135000 136000 1000)|$(score_halfway 130000 135000 5000)|"
  [ "$got" = "139000 73000 ||" ] || { echo "the probe between a pass and a fail (139,000 between 135,000 and 142,000; nothing when one unit apart): $got"; return 1; }
  got="$(score_next_down_by 139000 25 1000) $(score_next_down_by 136000 25 1000) $(score_next_down_by 135000 25 1000) $(score_next_down_by 71000 25 1000)"
  [ "$got" = "136000 133000 132000 69000" ] || { echo "holds 2.5 % apart from 139,000, 136,000, 135,000 and 71,000: $got"; return 1; }
  got="$(score_next_down_by 139000 50 1000) $(score_next_down 139000 5 1000) $(score_next_down_by 139000 50 1000)"
  [ "$got" = "132000 132000 132000" ] || { echo "5 % as 50 thousandths gives the whole-percent steps: $got"; return 1; }
}

# score_run <options of make-run.awk> -- <k6 exit> [files to add to the folder: name=text]...: makes a run's sampler files in a temporary folder
# (lab/check/fixtures/score/make-run.awk) and prints lab/score/score-lib.sh's run JSON for it (100 users, k6 started 2 s before the first
# REST row).
score_run() {
  local opts=() dir code kv
  while [ "$1" != "--" ]; do opts+=("$1"); shift; done
  shift
  code="$1"
  shift
  dir="$(mktemp -d)"
  awk -v "dir=$dir" -v "opts=${opts[*]-}" -f "$LAB/check/fixtures/score/make-run.awk" || return 1
  for kv in "$@"; do printf '%s\n' "${kv#*=}" >"$dir/${kv%%=*}"; done
  score_run_json "$dir" hold 100 10 "$code" 4 1699999998 systemd
  rm -rf "$dir"
}

# score_expect <what> <json> <jq expression> <expected>: fails with a message when the expression does not print the expected text.
score_expect() {
  local got
  got="$(jq -r "$3" <<<"$2")" || { echo "$1: jq failed on $3"; return 1; }
  [ "$got" = "$4" ] || { echo "$1: $3 is '$got', expected '$4'"; return 1; }
}

# The numbers of a passing run, from the hand arithmetic written in make-run.awk.
score_check_numbers() {
  local j
  j="$(score_run -- 0)" || { echo "score_run_json failed: $j"; return 1; }
  score_expect "a passing run" "$j" '[.kind, .users, .k6_exit, .pass, .void, .wall] | join(" ")' "hold 100 0 true false " || return 1
  score_expect "the summary" "$j" '[.p95_ms, .p99_ms, .error_rate, .http_reqs] | join(" ")' "120 300 0 10160" || return 1
  score_expect "the plateau window (seconds where vus is 100, matched by time)" "$j" '.plateau | [.start, .end, .seconds, .http_reqs, .req_per_s] | join(" ")' "1700000005 1700000015 10 10000 1000" || return 1
  j="$(score_run instant=1 early404=2 -- 0)" && score_expect "a run whose users are there from the start and whose first rows have no http_reqs (404): 0 requests then" "$j" '.plateau | [.start, .seconds, .http_reqs] | join(" ")' "1700000000 15 10100" || return 1
  j="$(score_run -- 0)" || return 1
  score_expect "the VU init time (first row with vus > 0 minus the container start)" "$j" '.vu_init_s' "3" || return 1
  score_expect "us per request (500: 0.5 core for 10 s over 10,000 requests, server rows .4 after the REST rows)" "$j" '.server.us_per_req' "500" || return 1
  score_expect "the service share" "$j" '.server.service_share' "0.5" || return 1
  score_expect "the box's busy share" "$j" '.server | [.cpu_busy_median, .cpu_busy_max] | join(" ")' "0.6 0.6" || return 1
  score_expect "others (box busy minus the service minus the sampler, over the 2 CPUs)" "$j" '.server.others_median' "0.3475" || return 1
  score_expect "accepts a second" "$j" '.server | [.accepts_per_s_median, .accepts_per_s_max_plateau, .accepts_per_s_max_run] | join(" ")' "40 55 90" || return 1
  score_expect "the peaks" "$j" '.server | [.memory_current_peak, .rss_peak, .mem_available_min_kb, .tcp_inuse_peak, .tcp_tw_peak, .tcp_mem_peak] | join(" ")' "118000000 59000000 2000000 180 18 36" || return 1
  score_expect "the differences" "$j" '.server | [.listen_overflows, .listen_drops, .retrans_segs] | join(" ")' "0 0 54" || return 1
  score_expect "the ENA counters" "$j" '.server.ena_allowance_diff | [.bw_in_allowance_exceeded, .pps_allowance_exceeded] | join(" ")' "0 0" || return 1
  score_expect "the OOM lines" "$j" '.server | [.oom_lines_start, .oom_lines_end] | join(" ")' "1 1" || return 1
  score_expect "the fds' max a process" "$j" '.server.fds_max | [.["11"], .["12"]] | join(" ")' "120 130" || return 1
  score_expect "the load box" "$j" '.loadbox | [(.cpu_max * 100 | round), .k6_memory_peak_bytes, .k6_cgroup_layout] | join(" ")' "30 228589568 systemd" || return 1
  score_expect "the healthy seconds" "$j" '.healthy_s' "4" || return 1
}

# Each wall of a failed run (k6 exited 99), one fixture each, and the two orders the rule decides.
score_check_walls() {
  local j
  j="$(score_run -- 99)" && score_expect "a failed run with room left" "$j" '[.pass, .wall] | join(" ")' "false latency-below-saturation" || return 1
  j="$(score_run lbspike=0.9 lbspikes=5,6,7,8,9 -- 99)" && score_expect "the load box at 90 % for 5 seconds in a row on a 10 s plateau" "$j" '[.void, .wall] | join(" ")' "true k6" || return 1
  # The shape of the real 71,000-user probe on AWS: k6's garbage collector took the load box to 90 % or more for 1 or 2 seconds, 6 seconds in 120.
  j="$(score_run lbspike=0.9 plateau=120 lbspikes=8,9,41,42,75,76 -- 99)" \
    && score_expect "6 spike seconds of 120, at most 2 in a row: not void" "$j" '[.void, .wall, .loadbox.plateau_seconds, .loadbox.seconds_over_85, .loadbox.longest_streak_over_85] | join(" ")' "false latency-below-saturation 120 6 2" || return 1
  j="$(score_run lbspike=0.9 plateau=120 lbspikes=10,19,28,37,46,55,64,73,82,91,100,109 -- 99)" \
    && score_expect "12 seconds of 120 (10 %), apart: not void" "$j" '[.void, .loadbox.seconds_over_85, .loadbox.longest_streak_over_85] | join(" ")' "false 12 1" || return 1
  j="$(score_run lbspike=0.9 plateau=120 lbspikes=10,19,28,37,46,55,64,73,82,91,100,109,118 -- 99)" \
    && score_expect "13 seconds of 120 (over 10 %), apart: void" "$j" '[.void, .wall, .loadbox.seconds_over_85, .loadbox.longest_streak_over_85] | join(" ")' "true k6 13 1" || return 1
  j="$(score_run lbspike=0.9 plateau=120 lbspikes=20,21,22,23 -- 99)" \
    && score_expect "4 seconds in a row: not void" "$j" '[.void, .loadbox.longest_streak_over_85] | join(" ")' "false 4" || return 1
  j="$(score_run lbspike=0.9 plateau=120 lbspikes=20,21,22,23,24 -- 99)" \
    && score_expect "5 seconds in a row: void" "$j" '[.void, .wall, .loadbox.seconds_over_85, .loadbox.longest_streak_over_85] | join(" ")' "true k6 5 5" || return 1
  # k6's saturation voids only a run that fails: its garbage collector can only make the measured latency worse, so a run that passes despite it is a valid pass.
  j="$(score_run lbspike=0.9 plateau=120 lbspikes=20,21,22,23,24 -- 0)" \
    && score_expect "5 seconds in a row over 85 % but k6 exited 0: a valid pass, not void, and the run still says k6 was over the line" "$j" '[.pass, .void, (.wall // "none"), .loadbox.over_line] | join(" ")' "true false none true" || return 1
  j="$(score_run k6mib=7100 -- 0)" && score_expect "k6 over 90 % of the load box's memory but it passed: a valid pass" "$j" '[.pass, .void, (.wall // "none"), .loadbox.over_line] | join(" ")' "true false none true" || return 1
  j="$(score_run k6mib=7100 -- 99)" && score_expect "k6 over 90 % of the load box's memory and it failed: void" "$j" '[.pass, .void, .wall] | join(" ")' "false true k6" || return 1
  j="$(score_run -- 0)" && score_expect "a quiet load box is not over the line" "$j" '.loadbox.over_line' "false" || return 1
  j="$(score_run oom=1 -- 99)" && score_expect "a new OOM line" "$j" '.wall' "memory" || return 1
  j="$(score_run avail=51200 -- 99)" && score_expect "MemAvailable under 100 MiB" "$j" '.wall' "memory" || return 1
  j="$(score_run -- 99 server-died.txt=died)" && score_expect "the service died with no OOM line and MemAvailable high: its own wall, not memory" "$j" '[.wall, .service_died] | join(" ")' "died true" || return 1
  j="$(score_run oom=1 -- 99 server-died.txt=died)" && score_expect "the service died and an OOM line appeared: memory, and the death is still recorded" "$j" '[.wall, .service_died] | join(" ")' "memory true" || return 1
  j="$(score_run avail=51200 -- 99 server-died.txt=died)" && score_expect "the service died and MemAvailable fell under 100 MiB: memory" "$j" '.wall' "memory" || return 1
  j="$(score_run ena=3 -- 99 server-died.txt=died)" && score_expect "the service died and an ENA counter grew: died comes before network" "$j" '.wall' "died" || return 1
  j="$(score_run ena=3 -- 99)" && score_expect "an ENA counter grew" "$j" '.wall' "network" || return 1
  j="$(score_run drops=4 -- 99)" && score_expect "ListenDrops grew" "$j" '.wall' "fds" || return 1
  j="$(score_run fds=65500 -- 99 'k6.log=time="x" level=warning msg="Request Failed" error="Get: dial tcp: i/o timeout"')" && score_expect "dial errors with a process within 100 fds of 65,535" "$j" '.wall' "fds" || return 1
  j="$(score_run fds=100 -- 99 'k6.log=time="x" level=warning msg="Request Failed" error="Get: dial tcp: i/o timeout"')" && score_expect "dial errors with fds far from the limit" "$j" '.wall' "latency-below-saturation" || return 1
  j="$(score_run fds=65500 -- 99)" && score_expect "a process near 65,535 fds but no dial error" "$j" '.wall' "latency-below-saturation" || return 1
  j="$(score_run svc=0.9 -- 99)" && score_expect "the service over 88 % of a core on the plateau" "$j" '.wall' "cpu" || return 1
  # The wall reads the plateau's median second of the service's share: a few seconds at 100 % lift the mean over the line, not the median, and the reverse.
  j="$(score_run svc=0.85 svcspike=1.0 svcspikes=7,8,9 -- 99)" && score_expect "the service's mean share over 88 % (3 seconds at 100 %, 7 at 85 %) but its median second under: not the CPU" "$j" '[.server.service_share > 0.88, .wall] | join(" ")' "true latency-below-saturation" || return 1
  j="$(score_run svc=0.9 svcspike=0.5 svcspikes=7,8,9 -- 99)" && score_expect "the service's mean share under 88 % (3 seconds at 50 %, 7 at 90 %) but its median second over: the CPU" "$j" '[.server.service_share < 0.88, .wall] | join(" ")' "true cpu" || return 1
  j="$(score_run svc=0.4 busy=0.95 -- 99)" && score_expect "the box busy but the service under 88 %: the others are the load" "$j" '.wall' "latency-below-saturation" || return 1
  j="$(score_run svc=0.95 busy=0.95 oom=1 -- 99)" && score_expect "an OOM line with the CPU at 95 %" "$j" '.wall' "memory" || return 1
  j="$(score_run svc=0.9 busy=0.9 ena=2 -- 99)" && score_expect "an ENA counter grown with the CPU at 90 %" "$j" '.wall' "network" || return 1
  j="$(score_run svc=0.9 busy=0.9 cavail=500 -- 99)" && score_expect "conntrack_allowance_available going up is a gauge, not a counter that grew: the wall is the CPU" "$j" '.wall' "cpu" || return 1
  j="$(score_run -- 0)" && score_expect "a passing run has no wall" "$j" '.wall' "null" || return 1
  # Network is the packets-a-second allowance, on a run that failed. The passing runs of the phase-7 session grew it with the box under 60 %.
  j="$(score_run svc=0.5 busy=0.95 ena=2 -- 99)" && score_expect "a failing run with pps_allowance_exceeded grown and the box 95 % busy" "$j" '.wall' "network" || return 1
  j="$(score_run svc=0.5 busy=0.95 ena=2 -- 0)" && score_expect "a passing run with pps_allowance_exceeded grown names no wall" "$j" '[.pass, .wall, .server.ena_allowance_diff.pps_allowance_exceeded] | map(tostring) | join(" ")' "true null 2" || return 1
  j="$(score_run bwena=3 -- 99)" && score_expect "another allowance counter grown (bandwidth in) is not the packets-a-second wall" "$j" '.wall' "latency-below-saturation" || return 1
  # TCP memory: new `TCP: out of memory` lines in the kernel log of a run that failed (the start file has one old line, which does not count).
  j="$(score_run tcpoom=2 -- 99)" && score_expect "2 new TCP out of memory lines in a failing run" "$j" '[.wall, .server.tcp_oom_lines_start, .server.tcp_oom_lines_end] | map(tostring) | join(" ")' "tcp-memory 1 3" || return 1
  j="$(score_run tcpoom=2 -- 0)" && score_expect "2 new TCP out of memory lines in a passing run: no wall" "$j" '.wall' "null" || return 1
  j="$(score_run -- 99)" && score_expect "the old TCP out of memory line alone is not new" "$j" '.wall' "latency-below-saturation" || return 1
  j="$(score_run tcpoom=2 oom=1 -- 99)" && score_expect "TCP memory and the OOM killer: memory comes first" "$j" '.wall' "memory" || return 1
  j="$(score_run tcpoom=2 ena=2 -- 99)" && score_expect "TCP memory and pps grown: network comes first" "$j" '.wall' "network" || return 1
  j="$(score_run tcpoom=2 drops=4 -- 99)" && score_expect "TCP memory and ListenDrops: TCP memory comes before fds" "$j" '.wall' "tcp-memory" || return 1
  j="$(score_run tcpoom=2 svc=0.9 -- 99)" && score_expect "TCP memory and the service over 88 %: TCP memory comes before the CPU" "$j" '.wall' "tcp-memory" || return 1
  j="$(score_run tcpoom=2 lbspike=0.9 lbspikes=5,6,7,8,9 -- 99)" && score_expect "TCP memory and k6 over the line: k6 comes first" "$j" '.wall' "k6" || return 1
  j="$(score_run -- 99 server-end.txt=)" && score_expect "no end file: the TCP out of memory lines at the end are unknown, not zero" "$j" '[.server.tcp_oom_lines_end, .wall] | map(tostring) | join(" ")' "null latency-below-saturation" || return 1
  # The service's cgroup can disappear while the sampler goes on (a failed unit with Restart=no): the cgroup columns are empty from then on, the
  # end file is there with the OOM lines. An OOM line new in the run names the wall; an end file that is missing is unknown, never zero.
  j="$(score_run nocg=12 oom=1 -- 99 server-died.txt=died)" && score_expect "the cgroup gone at second 12 with an OOM line in the end file: memory" "$j" '[.wall, .service_died] | join(" ")' "memory true" || return 1
  j="$(score_run nocg=12 -- 99 server-died.txt=died)" && score_expect "the cgroup gone at second 12, no OOM line: died" "$j" '.wall' "died" || return 1
  j="$(score_run -- 99 server-died.txt=died server-end.txt=)" && score_expect "no end file (the sampler died with the service): the OOM lines and the ENA counters at the end are unknown, not zero" "$j" '.server | [.oom_lines_end, .ena_allowance_diff] | map(tostring) | join(" ")' "null null" || return 1
  j="$(score_run srvrows=0 -- 99)" && score_expect "a server.csv with its header and no row: empty server numbers, no crash" "$j" '.server | [.listen_drops, .listen_overflows, .retrans_segs, .service_share, .us_per_req, .rows] | map(tostring) | join(" ")' "null null null null null 0" || return 1
}

# score_search <exits> [search.sh options]...: runs lab/score/search.sh against the fake controller and the fake k6 (lab/check/fixtures/score/),
# whose runs exit with the codes of <exits> in order. Leaves the folder in SCORE_OUT, the log in SCORE_LOG, the output in SCORE_TEXT and the
# search's exit code in SCORE_RC.
score_search() {
  local exits="$1" fx="$LAB/check/fixtures/score" tmp
  shift
  tmp="$(mktemp -d)"
  SCORE_OUT="$tmp/search" SCORE_LOG="$tmp/log" SCORE_RC=0
  echo "$exits" >"$tmp/exits"
  : >"$SCORE_LOG"
  SCORE_TEXT="$(FAKE_EXITS="$tmp/exits" FAKE_LOG="$SCORE_LOG" SCORE_K6_COMMAND="bash $fx/fake-k6.sh" bash "$LAB/score/search.sh" \
    --base-url http://server.example:80 --ctl "bash $fx/fake-ctl.sh" --out "$SCORE_OUT" --pause 0 "$@" 2>&1)" || SCORE_RC=$?
}

# score_ran <search.json expression over .runs>: the runs as "kind:users:pass" words, in order.
score_runs() {
  jq -r '[.runs[] | "\(.kind):\(.users):\(.pass)"] | join(" ")' "$SCORE_OUT/search.json"
}

score_check_search() {
  local got
  score_search "0 0 0 99 99 0"
  [ "$SCORE_RC" = 0 ] || { echo "a search that finds 71,000 exits $SCORE_RC: ${SCORE_TEXT//$'\n'/ | }"; return 1; }
  got="$(score_runs)"
  [ "$got" = "warmup:1000:true probe:71000:true probe:75000:true probe:79000:false hold:75000:false hold:71000:true" ] \
    || { echo "the runs of a pass, a pass, a fail, then holds from the highest pass: $got"; return 1; }
  [ "$(jq -r '.end | [.result, .score] | join(" ")' "$SCORE_OUT/search.json")" = "score 71000" ] || { echo "the end is not score 71000: $(jq -c .end "$SCORE_OUT/search.json")"; return 1; }
  [ "$(grep -c '^ctl restart$' "$SCORE_LOG")" = 6 ] || { echo "the server must restart before each of the 6 k6 runs, the warm-up included: $(grep -c '^ctl restart$' "$SCORE_LOG")"; return 1; }
  [ "$(grep -c '^ctl sample-' "$SCORE_LOG")" = 12 ] || { echo "each run needs a sample-start and a sample-stop"; return 1; }
  grep -q '^k6 1000 2m$' "$SCORE_LOG" && grep -q '^k6 71000 2m$' "$SCORE_LOG" && grep -q '^k6 75000 5m$' "$SCORE_LOG" \
    || { echo "durations: the warm-up and the probes run 2 minutes, the holds 5: $(tr '\n' ' ' <"$SCORE_LOG")"; return 1; }
  [ "$(jq '.decisions | length' "$SCORE_OUT/search.json")" -ge 6 ] || { echo "every step has a decision with its reason"; return 1; }
  jq -e '.facts.nproc == 2 and .arguments.base_url == "http://<server>:80" and (.runs | all(.folder != null))' "$SCORE_OUT/search.json" >/dev/null \
    || { echo "search.json has no facts, or keeps the server's address: $(jq -c '.facts, .arguments' "$SCORE_OUT/search.json")"; return 1; }
  [ -f "$SCORE_OUT/06-hold-71000/run.json" ] || { echo "no folder with a run.json per run"; return 1; }
  grep -q '^warmup' <<<"$SCORE_TEXT" && grep -q '^hold     71000' <<<"$SCORE_TEXT" || { echo "the table has no row for the warm-up and the passing hold: ${SCORE_TEXT//$'\n'/ | }"; return 1; }

  score_search "0 99 99 0"
  got="$(score_runs)"
  [ "$got" = "warmup:1000:true probe:71000:false hold:67000:false hold:64000:true" ] \
    || { echo "a first probe that fails starts the holds 5 % under it (67,000), then 64,000 (63,650 rounded): $got"; return 1; }
  [ "$(jq -r '.end.score' "$SCORE_OUT/search.json")" = 64000 ] || { echo "the score of a search that holds at 64,000"; return 1; }

  score_search "0 99 99 99 99 99 99 99"
  got="$(score_runs)"
  [ "$SCORE_RC" = 0 ] && [ "$got" = "warmup:1000:true probe:71000:false hold:67000:false hold:64000:false hold:61000:false hold:58000:false hold:55000:false hold:52000:false" ] \
    || { echo "6 failing holds stop the search (exit $SCORE_RC): $got"; return 1; }
  [ "$(jq -r '.end | [.result, .score, .reason] | map(tostring) | join("|")' "$SCORE_OUT/search.json")" = "no-score|null|no hold passed down to 52000 (6 holds failed)" ] \
    || { echo "the end of 6 failing holds: $(jq -c .end "$SCORE_OUT/search.json")"; return 1; }

  score_search "0 0 0 0" --max-probes 2
  [ "$(score_runs)" = "warmup:1000:true probe:71000:true probe:75000:true hold:75000:true" ] || { echo "--max-probes 2 starts the holds at the second probe: $(score_runs)"; return 1; }

  score_search "0 1"
  [ "$SCORE_RC" = 1 ] && [ "$(score_runs)" = "warmup:1000:true probe:71000:false" ] && [ "$(jq -r ".runs[-1].k6_exit" "$SCORE_OUT/search.json")" = 1 ] && [ "$(jq -r '.end.result' "$SCORE_OUT/search.json")" = harness-error ] \
    || { echo "a k6 exit of 1 is a harness error: the search stops and exits 1 (exit $SCORE_RC): $(score_runs)"; return 1; }
  score_search "99"
  [ "$SCORE_RC" = 1 ] && [ "$(score_runs)" = "warmup:1000:false" ] && grep -q 'warm-up failed' "$SCORE_OUT/search.json" \
    || { echo "a failing warm-up is a harness error, the search stops (exit $SCORE_RC): $(score_runs)"; return 1; }
  # A void probe (k6 may have caused its failure) is neither a pass nor a fail: it ends the climb, and the holds start at the highest passing probe.
  local void="99/lbspike=0.9+lbspikes=5,6,7,8,9"
  score_search "0 0 $void 0"
  [ "$SCORE_RC" = 0 ] && [ "$(score_runs)" = "warmup:1000:true probe:71000:true probe:75000:false hold:71000:true" ] \
    && [ "$(jq -r '.end | [.result, .score, .bound_by_k6] | map(tostring) | join(" ")' "$SCORE_OUT/search.json")" = "score 71000 true" ] \
    || { echo "a void probe ends the climb, the hold at 71000 runs and is the score, the end says k6 bound it (exit $SCORE_RC): $(score_runs) $(jq -c .end "$SCORE_OUT/search.json")"; return 1; }
  score_search "0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0" --max-probes 1
  [ "$(jq -r '.end.bound_by_k6' "$SCORE_OUT/search.json")" = false ] || { echo "a search no void run touched must say bound_by_k6 false: $(jq -c .end "$SCORE_OUT/search.json")"; return 1; }
  # The published run: probes pass up to 135,000, the 142,000 probe is void, the hold at 135,000 passes.
  score_search "0 0 0 $void 0" --start 129000
  [ "$SCORE_RC" = 0 ] && [ "$(score_runs)" = "warmup:1000:true probe:129000:true probe:135000:true probe:142000:false hold:135000:true" ] \
    && [ "$(jq -r '.end.score' "$SCORE_OUT/search.json")" = 135000 ] \
    || { echo "129,000 and 135,000 pass, 142,000 is void: the hold at 135,000 is the score (exit $SCORE_RC): $(score_runs) $(jq -c .end "$SCORE_OUT/search.json")"; return 1; }
  # A void hold runs again once: it passes the second time, or it counts as not passed and the next hold steps down.
  score_search "0 0 99 $void 0"
  [ "$SCORE_RC" = 0 ] && [ "$(score_runs)" = "warmup:1000:true probe:71000:true probe:75000:false hold:71000:false hold:71000:true" ] && [ "$(jq -r '.end.score' "$SCORE_OUT/search.json")" = 71000 ] \
    || { echo "a void hold runs again at the same size, and its pass is the score (exit $SCORE_RC): $(score_runs)"; return 1; }
  score_search "0 0 99 $void $void 0"
  [ "$SCORE_RC" = 0 ] && [ "$(score_runs)" = "warmup:1000:true probe:71000:true probe:75000:false hold:71000:false hold:71000:false hold:67000:true" ] && [ "$(jq -r '.end.score' "$SCORE_OUT/search.json")" = 67000 ] \
    || { echo "a hold void twice counts as not passed: the next hold steps down (exit $SCORE_RC): $(score_runs)"; return 1; }
  score_search "0 0 99 $void $void 99" --max-holds 2
  [ "$SCORE_RC" = 0 ] && [ "$(score_runs)" = "warmup:1000:true probe:71000:true probe:75000:false hold:71000:false hold:71000:false hold:67000:false" ] \
    && [ "$(jq -r '.end | [.result, .score, .bound_by_k6] | map(tostring) | join(" ")' "$SCORE_OUT/search.json")" = "no-score null true" ] && grep -q 'no hold passed' "$SCORE_OUT/search.json" \
    || { echo "a void hold run twice is one failed hold, and a search with no passing hold says so (exit $SCORE_RC): $(score_runs) $(jq -c .end "$SCORE_OUT/search.json")"; return 1; }
  score_search "0 0/lbspike=0.9+lbspikes=5,6,7,8,9 99 0"
  [ "$SCORE_RC" = 0 ] && [ "$(score_runs)" = "warmup:1000:true probe:71000:true probe:75000:false hold:71000:true" ] && [ "$(jq -r '.end.score' "$SCORE_OUT/search.json")" = 71000 ] \
    || { echo "a passing probe with k6 over the line is a valid pass: the search goes on and the hold at 71000 is the score (exit $SCORE_RC): $(score_runs) $(jq -c .end "$SCORE_OUT/search.json")"; return 1; }
}

# A run that is stopped after its server sampler started (Ctrl-C, a harness error) must stop that sampler: it was started with setsid on the
# server box and would keep using the one CPU there for the next run. A run that ends normally stops it once.
score_check_run_k6_cleanup() {
  local fx="$LAB/check/fixtures/score" tmp pid i
  tmp="$(mktemp -d)"
  echo "0" >"$tmp/exits"
  : >"$tmp/log"
  FAKE_K6_SLEEP=4 FAKE_EXITS="$tmp/exits" FAKE_LOG="$tmp/log" SCORE_K6_COMMAND="bash $fx/fake-k6.sh" bash "$LAB/score/run-k6.sh" \
    --base-url http://server.example:80 --ctl "bash $fx/fake-ctl.sh" --out "$tmp/run" --kind probe --users 100 --duration 20s >/dev/null 2>&1 &
  pid=$!
  for i in $(seq 1 50); do grep -q '^k6 ' "$tmp/log" && break; sleep 0.1; done
  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  [ "$(grep -c '^ctl sample-start$' "$tmp/log")" = 1 ] && [ "$(grep -c '^ctl sample-stop$' "$tmp/log")" = 1 ] \
    || { echo "a run stopped by a signal after sample-start must call sample-stop once: $(tr '\n' ' ' <"$tmp/log")"; rm -rf "$tmp"; return 1; }
  rm -rf "$tmp"
}

# The refusals: a load.js with one byte changed, an --out that exists, a controller whose facts fail. Nothing runs, not even a restart.
score_check_refusals() {
  local fx="$LAB/check/fixtures/score" tmp
  tmp="$(mktemp -d)"
  mkdir -p "$tmp/challenge/bench" "$tmp/challenge/seed"
  cp "$REPO/reference/twelve-dollar-server-challenge/bench/load.js" "$tmp/challenge/bench/load.js"
  sed -i.bak 's/const LIKE_PROB = 0.15/const LIKE_PROB = 0.16/' "$tmp/challenge/bench/load.js" && rm -f "$tmp/challenge/bench/load.js.bak"
  score_search "0 0" --challenge "$tmp/challenge"
  [ "$SCORE_RC" = 2 ] && grep -q "not the challenge's script" <<<"$SCORE_TEXT" && [ ! -s "$SCORE_LOG" ] && [ ! -e "$SCORE_OUT" ] \
    || { echo "a load.js with one byte changed must be refused (exit 2, nothing run), got exit $SCORE_RC and log '$(tr '\n' ' ' <"$SCORE_LOG")': ${SCORE_TEXT//$'\n'/ | }"; return 1; }
  cp "$REPO/reference/twelve-dollar-server-challenge/bench/load.js" "$tmp/challenge/bench/load.js"
  score_search "0 0 0" --challenge "$tmp/challenge" --max-probes 1
  [ "$SCORE_RC" != 2 ] || { echo "the unchanged load.js is refused: ${SCORE_TEXT//$'\n'/ | }"; return 1; }
  mkdir -p "$tmp/exists"
  score_search "0 0" --out "$tmp/exists"
  [ "$SCORE_RC" = 2 ] && grep -q 'exists' <<<"$SCORE_TEXT" && [ ! -s "$SCORE_LOG" ] || { echo "an existing --out must be refused with nothing run (exit $SCORE_RC)"; return 1; }
  FAKE_FACTS_FAIL=1 score_search "0 0"
  [ "$SCORE_RC" = 2 ] && grep -q 'facts' <<<"$SCORE_TEXT" || { echo "a controller whose facts fail must be refused (exit $SCORE_RC): ${SCORE_TEXT//$'\n'/ | }"; return 1; }
  [ "$(grep -c '^ctl restart$' "$SCORE_LOG")" = 0 ] || { echo "the server restarted before the facts were known"; return 1; }
}

# The load box's sampler on one half: --cpus reads only those CPUs' counters (a fixture of /proc/stat with four CPUs: 1-2 gives their sums, 3 alone its own,
# nothing given the whole box's line) and --mem-share divides the memory column. In a lab container for bash 5.
score_check_loadbox_sampler_cpus() {
  local dir out total
  docker image inspect "$LAB_IMAGE:8.5" >/dev/null 2>&1 || { echo "image $LAB_IMAGE:8.5 is missing (run lab/build.sh 8.5)"; return 1; }
  dir="$(mktemp -d)"
  printf '%s\n' 'cpu  1000 10 100 8000 40 4 6 2 0 0' 'cpu0 100 1 10 800 4 0 1 0 0 0' 'cpu1 200 2 20 1600 8 1 1 1 0 0' 'cpu2 300 3 30 2400 12 1 2 1 0 0' \
    'cpu3 400 4 40 3200 16 2 2 0 0 0' 'intr 1 2 3' >"$dir/stat"
  total="$(docker run --rm "$LAB_IMAGE:8.5" awk '/MemTotal/ {print $2}' /proc/meminfo)"
  out="$(docker run --rm -v "$LAB:/lab:ro" -v "$dir:/f" -e SCORE_PROC_STAT=/f/stat "$LAB_IMAGE:8.5" bash -c '
    for args in "--cpus 1-2 --mem-share 2" "--cpus 3" "--cpus 0,3" ""; do
      d=$(mktemp -d); touch $d/.nostop
      (sleep 2.5; touch $d/stop) &
      bash /lab/score/loadbox-sample.sh --api 127.0.0.1:1 --cgroup none --dir $d --stop-file $d/stop $args
      echo "[$args] $(sed -n 2p $d/loadbox.csv | cut -d, -f2-9,12)"
    done' 2>&1)" || { echo "the sampler failed: ${out//$'\n'/ | }"; return 1; }
  grep -qxF '[--cpus 1-2 --mem-share 2] 500,5,50,4000,20,2,3,2,'"$((total / 2))" <<<"$out" \
    || { echo "--cpus 1-2 sums those two CPUs (500 5 50 4000 20 2 3 2) and --mem-share 2 halves MemTotal ($((total / 2))): ${out//$'\n'/ | }"; return 1; }
  grep -qxF '[--cpus 3] 400,4,40,3200,16,2,2,0,'"$total" <<<"$out" || { echo "--cpus 3 is CPU 3's line alone: ${out//$'\n'/ | }"; return 1; }
  grep -qxF '[--cpus 0,3] 500,5,50,4000,20,2,3,0,'"$total" <<<"$out" || { echo "--cpus 0,3 sums CPUs 0 and 3: ${out//$'\n'/ | }"; return 1; }
  grep -qxF '[] 1000,10,100,8000,40,4,6,2,'"$total" <<<"$out" || { echo "no --cpus reads the whole box's line: ${out//$'\n'/ | }"; return 1; }
  rm -rf "$dir"
}

# The server's sampler, in a lab container (it needs bash 5 and a Linux /proc): the facts of its start files from a kernel log with a host name
# and a dmesg line (only the message stays), and a real run of 4 seconds beside a sleeping process: the header, 24 columns a row, the open
# files of that process on the first row, and its own CPU under 1 % of a core.
score_check_sampler() {
  local out dir rows
  docker image inspect "$LAB_IMAGE:8.5" >/dev/null 2>&1 || { echo "image $LAB_IMAGE:8.5 is missing (run lab/build.sh 8.5)"; return 1; }
  dir="$(mktemp -d)"
  printf '%s\n' 'Nov 24 10:00:00 some-host kernel: Out of memory: Killed process 4242 (php) total-vm:1kB' \
    '[  123.456789] oom-kill:constraint=CONSTRAINT_MEMCG,task=php' 'Nov 24 10:00:01 some-host kernel: eth0: link up' \
    'Nov 24 10:00:02 some-host kernel: TCP: out of memory -- consider tuning tcp_mem' >"$dir/kernel.log"
  out="$(docker run --rm -v "$LAB:/lab:ro" -v "$dir:/k:ro" -e SCORE_KERNEL_LOG=/k/kernel.log "$LAB_IMAGE:8.5" bash /lab/score/server-sample.sh --facts-only 2>&1)" \
    || { echo "--facts-only failed: ${out//$'\n'/ | }"; return 1; }
  grep -qxF 'oom Out of memory: Killed process 4242 (php) total-vm:1kB' <<<"$out" && grep -qxF 'oom oom-kill:constraint=CONSTRAINT_MEMCG,task=php' <<<"$out" \
    && ! grep -q 'some-host' <<<"$out" && [ "$(grep -c '^oom ' <<<"$out")" = 2 ] \
    || { echo "the OOM lines are not the two messages without a host name or a timestamp: ${out//$'\n'/ | }"; return 1; }
  # Why: the TCP stack's own limit is not the OOM killer's: its line is `tcp-oom`, never `oom` (the memory wall would name it).
  [ "$(grep -c '^tcp-oom ' <<<"$out")" = 1 ] && grep -qxF 'tcp-oom TCP: out of memory -- consider tuning tcp_mem' <<<"$out" \
    || { echo "the TCP out of memory line is not one 'tcp-oom' line without a host name: ${out//$'\n'/ | }"; return 1; }
  grep -q '^nproc [0-9]' <<<"$out" && grep -q '^ena-unread ethtool is not installed' <<<"$out" || { echo "no nproc, or no line saying ethtool is missing: ${out//$'\n'/ | }"; return 1; }
  out="$(docker run --rm -v "$LAB:/lab:ro" "$LAB_IMAGE:8.5" bash -c '
    sleep 30 & sleep 1
    bash /lab/score/server-sample.sh --cgroup /sys/fs/cgroup --pids-of "sleep 30" --out /tmp/s/server.csv >/tmp/stdout.txt 2>&1 &
    mkdir -p /tmp/s; sleep 5; kill -TERM %2; wait %2; cat /tmp/stdout.txt; cat /tmp/s/server.csv' 2>&1)" || { echo "the sampler run failed: ${out//$'\n'/ | }"; return 1; }
  grep -q '^sampler: .* (0\.[0-9][0-9] % of one core)$' <<<"$out" || { echo "the sampler is over 1 % of a core, or prints nothing: ${out//$'\n'/ | }"; return 1; }
  rows="$(grep -c '^[0-9]*\.[0-9][0-9][0-9],' <<<"$out")"
  [ "$rows" -ge 3 ] || { echo "expected 3 rows or more in 5 s, got $rows: ${out//$'\n'/ | }"; return 1; }
  [ "$(grep '^[0-9]*\.[0-9][0-9][0-9],' <<<"$out" | head -n 1 | awk -F, '{ print NF }')" = 24 ] || { echo "a row has not 24 columns"; return 1; }
  grep '^[0-9]*\.[0-9][0-9][0-9],' <<<"$out" | head -n 1 | grep -qE ',[0-9]+:[0-9]+$' || { echo "the first row has no open files of the process: $(grep '^[0-9]*\.' <<<"$out" | head -n 1)"; return 1; }
}

# The sampler goes on when the service's cgroup disappears (a failed unit with Restart=no: systemd removes the folder): the cgroup columns are
# empty from then on, the process is still there at the stop, and server-end.txt is written, because the OOM lines it holds are what names the memory wall.
score_check_sampler_cgroup_gone() {
  local out
  docker image inspect "$LAB_IMAGE:8.5" >/dev/null 2>&1 || { echo "image $LAB_IMAGE:8.5 is missing (run lab/build.sh 8.5)"; return 1; }
  out="$(docker run --rm -v "$LAB:/lab:ro" "$LAB_IMAGE:8.5" bash -c '
    mkdir -p /tmp/cg /tmp/s
    printf "usage_usec 1000\n" >/tmp/cg/cpu.stat; echo 1000 >/tmp/cg/memory.current
    bash /lab/score/server-sample.sh --cgroup /tmp/cg --pids-of "sleep 30" --out /tmp/s/server.csv >/tmp/s/stdout.txt 2>&1 &
    pid=$!
    sleep 4; rm -rf /tmp/cg; sleep 4
    kill -0 $pid 2>/dev/null && echo "alive-after-removal"
    kill -TERM $pid; wait $pid; echo "rc=$?"
    [ -s /tmp/s/server-end.txt ] && echo "end-file"
    awk -F, "NR > 1 && \$10 == \"\" { n++ } END { print \"empty-cgroup-rows \" n + 0 }" /tmp/s/server.csv' 2>&1)" || { echo "the cgroup-gone run failed: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'alive-after-removal' <<<"$out" && grep -qx 'rc=0' <<<"$out" && grep -qx 'end-file' <<<"$out" \
    || { echo "the sampler must outlive the cgroup, stop with exit 0 and write server-end.txt: ${out//$'\n'/ | }"; return 1; }
  [ "$(sed -n 's/^empty-cgroup-rows //p' <<<"$out")" -ge 2 ] || { echo "the rows after the removal must have an empty cgroup column, 2 or more: ${out//$'\n'/ | }"; return 1; }
}

check_score() {
  score_check_steps || return 1
  score_check_numbers || return 1
  score_check_walls || return 1
  score_check_search || return 1
  score_check_refusals || return 1
  score_check_run_k6_cleanup || return 1
  score_check_sampler || return 1
  score_check_sampler_cgroup_gone || return 1
  score_check_loadbox_sampler_cpus || return 1
  score_check_halves || return 1
  score_check_halves_search || return 1
  score_check_finer || return 1
}

# score_run_halves <options of half 1> -- <options of half 2> -- <exit 1> <exit 2> [name=text]...: the run's JSON for two k6 halves of 50 users each, made of
# two sets of load box files (half-1/ and half-2/, make-run.awk with their own options) and the server's files of the first half's options. The run's k6 exit
# is the worse of the two (0 or 99).
score_run_halves() {
  local o1=() o2=() dir c1 c2 kv f
  while [ "$1" != "--" ]; do o1+=("$1"); shift; done
  shift
  while [ "$1" != "--" ]; do o2+=("$1"); shift; done
  shift
  c1="$1" c2="$2"
  shift 2
  dir="$(mktemp -d)"
  mkdir -p "$dir/half-1" "$dir/half-2"
  awk -v "dir=$dir/half-1" -v "opts=users=50 ${o1[*]-}" -f "$LAB/check/fixtures/score/make-run.awk" || return 1
  awk -v "dir=$dir/half-2" -v "opts=users=50 ${o2[*]-}" -f "$LAB/check/fixtures/score/make-run.awk" || return 1
  for f in server.csv server-start.txt server-end.txt; do cp "$dir/half-1/$f" "$dir/$f"; done
  for kv in "$@"; do printf '%s\n' "${kv#*=}" >"$dir/${kv%%=*}"; done
  score_run_json "$dir" hold 100 10 $((c1 > c2 ? c1 : c2)) 4 1699999998 systemd "{\"users\": [50, 50], \"exits\": [$c1, $c2], \"started\": [1699999998, 1699999998.5], \"skew_s\": 0.5}"
  rm -rf "$dir"
}

# Two k6 halves read as one run: the plateau is where both are at their users, the requests are the sums, each half keeps its numbers.
score_check_halves() {
  local j spike="lbspike=0.9 lbspikes=5,6,7,8,9"
  # Half 1 is at 50 users on its rows 5 to 15 (1700000005 to 1700000015, 1,000 requests a second), half 2 starts 3 s later (rows 8 to 18 as the clock goes,
  # 500 a second, p99 450 ms): both at 50 users from 1700000008 to 1700000015, 7 s. By hand: half 1 serves 7 x 1,000, half 2 7 x 500, 10,500 in 7 s = 1,500 a second;
  # the service burns 0.5 core for 7 s = 3,500,000 us over 10,500 requests = 333.3 us.
  j="$(score_run_halves rate=1000 -- shift=3 rate=500 p99=450 -- 0 0)" || { echo "score_run_json failed on two halves: $j"; return 1; }
  score_expect "two halves, both pass" "$j" '[.kind, .users, .k6_exit, .pass, .void, .wall] | join(" ")' "hold 100 0 true false " || return 1
  score_expect "the plateau is the seconds where both halves are at their users" "$j" '.plateau | [.start, .end, .seconds, .http_reqs, .req_per_s] | join(" ")' "1700000008 1700000015 7 10500 1500" || return 1
  score_expect "us per request: the service's CPU over the shared plateau divided by both halves' requests" "$j" '(.server.us_per_req * 10 | round) / 10' "333.3" || return 1
  score_expect "the service share is read over the shared plateau" "$j" '.server.service_share' "0.5" || return 1
  score_expect "p95 and p99: the run's is the worse half's, each half's is kept" "$j" '[.p99_ms, (.halves | map(.p99_ms) | join(",")), (.halves | map(.p95_ms) | join(","))] | join(" ")' "450 300,450 120,120" || return 1
  score_expect "each half's own plateau (10 s each) and users" "$j" '.halves | map("\(.users):\(.plateau.seconds):\(.plateau.http_reqs)") | join(" ")' "50:10:10000 50:10:5000" || return 1
  score_expect "requests over the run and the error rate are the halves' sums" "$j" '[.http_reqs, .error_rate] | join(" ")' "15320 0" || return 1
  score_expect "the start skew and the halves' passes" "$j" '[.half_start_skew_s, (.halves | map(.pass) | join(","))] | join(" ")' "0.5 true,true" || return 1
  # One half fails, the other passes: the run fails (99), neither is hidden.
  j="$(score_run_halves -- -- 0 99)" && score_expect "half 2 crosses a threshold, half 1 does not" "$j" '[.k6_exit, .pass, .void, .wall, (.halves | map(.pass) | join(","))] | join(" ")' "99 false false latency-below-saturation true,false" || return 1
  j="$(score_run_halves -- -- 99 0)" && score_expect "half 1 crosses a threshold, half 2 does not" "$j" '[.k6_exit, .pass, (.halves | map(.pass) | join(","))] | join(" ")' "99 false false,true" || return 1
  # A half over the line (its own CPUs, its own memory share) voids a failing run and not a passing one.
  j="$(score_run_halves -- $spike -- 99 0)" && score_expect "half 2's CPUs over 85 % on 5 seconds in a row and the run fails: void, and it says which half" "$j" \
    '[.void, .wall, (.void_reason | startswith("half 2: the load box")), (.halves | map(.void) | join(",")), (.halves | map(.loadbox.over_line) | join(","))] | join(" ")' "true k6 true false,true false,true" || return 1
  j="$(score_run_halves $spike -- -- 99 0)" && score_expect "the same on half 1" "$j" '[.void, .wall, (.void_reason | startswith("half 1: ")), (.halves | map(.loadbox.over_line) | join(","))] | join(" ")' "true k6 true true,false" || return 1
  j="$(score_run_halves -- $spike -- 0 0)" && score_expect "half 2 over the line but both halves pass: a valid pass, the run still says it was over the line" "$j" \
    '[.pass, .void, (.wall // "none"), .loadbox.over_line, (.halves | map(.void) | join(","))] | join(" ")' "true false none true false,false" || return 1
  j="$(score_run_halves -- k6mib=7100 -- 99 99)" && score_expect "half 2's container over 90 % of its share of the memory and the run fails: void" "$j" '[.void, .wall, (.halves | map(.loadbox.over_line) | join(","))] | join(" ")' "true k6 false,true" || return 1
  j="$(score_run_halves -- -- 99 99)" && score_expect "two quiet halves that fail: latency, not void" "$j" '[.void, .wall, .loadbox.over_line] | join(" ")' "false latency-below-saturation false" || return 1
  j="$(score_run_halves lbspike=0.9 plateau=120 lbspikes=8,9,41,42,75,76 -- plateau=120 -- 99 99)" && score_expect "6 spike seconds in 120 on a half: not over the line (the same rule as one k6)" "$j" '[.void, .halves[0].loadbox.seconds_over_85, .halves[0].loadbox.plateau_seconds] | join(" ")' "false 6 120" || return 1
  # One half alone is the phase-7 run: no halves in its JSON, the numbers read as before.
  j="$(score_run -- 0)" && score_expect "one half: no halves key content, no skew" "$j" '[(.halves | tostring), (.half_start_skew_s | tostring)] | join(" ")' "null null" || return 1
}

# The search and the single run on two halves, with the fake k6 (fake-k6.sh gives each half its folder, its users and the run's exit words).
score_check_halves_search() {
  local got fx="$LAB/check/fixtures/score" tmp spike="lbspike=0.9+lbspikes=5,6,7,8,9" before
  export SCORE_START_LEAD_S=0
  # Half 2 crosses a threshold in the 75,000 probe: the run fails, the hold at 71,000 passes. Each half runs its half of the users, the first one the odd one.
  score_search "0 0 0:99 0" --halves 2
  got="$(score_runs)"
  [ "$SCORE_RC" = 0 ] && [ "$got" = "warmup:1000:true probe:71000:true probe:75000:false hold:71000:true" ] && [ "$(jq -r '.end.score' "$SCORE_OUT/search.json")" = 71000 ] \
    || { echo "two halves, one failing in the 75,000 probe (exit $SCORE_RC): $got $(jq -c .end "$SCORE_OUT/search.json")"; return 1; }
  [ "$(grep -c '^k6 37500 2m$' "$SCORE_LOG")" = 2 ] && [ "$(grep -c '^k6 35500 2m$' "$SCORE_LOG")" = 2 ] && [ "$(grep -c '^k6 500 2m$' "$SCORE_LOG")" = 2 ] \
    || { echo "each half runs half the users (75,000 is 37,500 twice, 71,000 is 35,500 twice, the warm-up's 1,000 is 500 twice): $(tr '\n' ' ' <"$SCORE_LOG")"; return 1; }
  [ "$(jq -r '.runs[2] | [.k6_exit, .pass] | join(" ")' "$SCORE_OUT/search.json")" = "99 false" ] && [ "$(jq -r '.arguments.halves' "$SCORE_OUT/search.json")" = 2 ] \
    && [ -f "$SCORE_OUT/03-probe-75000/half-2/rest.tsv" ] && jq -e '.halves | map(.pass) == [true, false]' "$SCORE_OUT/03-probe-75000/run.json" >/dev/null \
    || { echo "the failing probe has k6 exit 99, both halves' folders and their own pass flags"; return 1; }
  # A void half: in a passing probe it is a valid pass; in a failing one the probe is void and ends the climb.
  score_search "0 0:0/~$spike 99:0/~$spike 0" --halves 2
  got="$(score_runs)"
  [ "$SCORE_RC" = 0 ] && [ "$got" = "warmup:1000:true probe:71000:true probe:75000:false hold:71000:true" ] \
    && [ "$(jq -r '[.runs[1].void, .runs[2].void] | join(" ")' "$SCORE_OUT/search.json")" = "false true" ] && [ "$(jq -r '.end.bound_by_k6' "$SCORE_OUT/search.json")" = true ] \
    || { echo "half 2 over the line: pass in the 71,000 probe (valid), void in the 75,000 one, the hold at 71,000 is the score (exit $SCORE_RC): $got $(jq -c '[.runs[] | .void]' "$SCORE_OUT/search.json")"; return 1; }
  # The run on its own: the halves start at the second the run agreed, not before; the odd user goes to the first half; --halves 2 with one user is refused.
  tmp="$(mktemp -d)"
  echo "0" >"$tmp/exits"
  : >"$tmp/log"
  before="$(date +%s)"
  SCORE_START_LEAD_S=2 FAKE_EXITS="$tmp/exits" FAKE_LOG="$tmp/log" SCORE_K6_COMMAND="bash $fx/fake-k6.sh" bash "$LAB/score/run-k6.sh" \
    --base-url http://server.example:80 --ctl "bash $fx/fake-ctl.sh" --out "$tmp/run" --kind probe --users 101 --duration 20s --halves 2 >/dev/null 2>&1 \
    || { echo "run-k6.sh --halves 2 failed"; return 1; }
  [ "$(cat "$tmp/run/half-1/.hook-started")" = "$(cat "$tmp/run/half-2/.hook-started")" ] && [ "$(cat "$tmp/run/half-1/.hook-started")" -ge $((before + 2)) ] \
    || { echo "both halves must start in the same second, the one the run agreed on (2 s after $before): $(cat "$tmp/run/half-1/.hook-started") and $(cat "$tmp/run/half-2/.hook-started")"; return 1; }
  grep -qx 'k6 51 20s' "$tmp/log" && grep -qx 'k6 50 20s' "$tmp/log" && jq -e '.halves | map(.users) == [51, 50]' "$tmp/run/run.json" >/dev/null \
    || { echo "101 users are 51 for the first half and 50 for the second: $(tr '\n' ' ' <"$tmp/log")"; return 1; }
  [ "$(jq -r '.server.loop' "$tmp/run/run.json")" = epoll ] || { echo "the controller's loop line is in the run's JSON: $(jq -c '.server.loop' "$tmp/run/run.json")"; return 1; }
  echo "0" >"$tmp/exits"
  FAKE_LOOP="" FAKE_EXITS="$tmp/exits" FAKE_LOG="$tmp/log" SCORE_K6_COMMAND="bash $fx/fake-k6.sh" bash "$LAB/score/run-k6.sh" \
    --base-url http://server.example:80 --ctl "bash $fx/fake-ctl.sh" --out "$tmp/run2" --kind probe --users 100 --duration 20s >/dev/null 2>&1 || { echo "run-k6.sh failed"; return 1; }
  [ "$(jq -r '.server.loop | tostring' "$tmp/run2/run.json")" = null ] || { echo "a controller with no loop line: server.loop is null, got $(jq -c '.server.loop' "$tmp/run2/run.json")"; return 1; }
  rc=0
  bash "$LAB/score/run-k6.sh" --base-url http://server.example:80 --ctl "bash $fx/fake-ctl.sh" --out "$tmp/run3" --kind probe --users 1 --duration 20s --halves 2 >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "--halves 2 with 1 user must be refused with exit 2, got $rc"; return 1; }
  unset SCORE_START_LEAD_S
  rm -rf "$tmp"
}

# The finer search (phase 8): probes 5 % apart until one fails, one probe halfway back, holds 2.5 % apart from the highest pass.
score_check_finer() {
  local got
  # 129,000 and 135,000 pass, 142,000 fails, the probe at 139,000 passes: the holds start there (139,000 fails, 136,000 fails, 133,000 passes).
  score_search "0 0 0 99 0 99 99 0" --start 129000 --finer
  got="$(score_runs)"
  [ "$SCORE_RC" = 0 ] && [ "$got" = "warmup:1000:true probe:129000:true probe:135000:true probe:142000:false probe:139000:true hold:139000:false hold:136000:false hold:133000:true" ] \
    && [ "$(jq -r '.end.score' "$SCORE_OUT/search.json")" = 133000 ] \
    || { echo "finer: 135,000 passes, 142,000 fails, the probe at 139,000 passes, holds 139,000, 136,000, 133,000 (exit $SCORE_RC): $got"; return 1; }
  # The halfway probe fails: the holds start at the last pass.
  score_search "0 0 99 99 0" --start 135000 --finer
  got="$(score_runs)"
  [ "$SCORE_RC" = 0 ] && [ "$got" = "warmup:1000:true probe:135000:true probe:142000:false probe:139000:false hold:135000:true" ] \
    || { echo "finer: the probe at 139,000 fails, the hold at 135,000 is the score (exit $SCORE_RC): $got"; return 1; }
  # Nothing between the two (they are one --round apart after the rounding): no extra probe.
  score_search "0 0 99 0" --start 130000 --round 5000 --finer
  got="$(score_runs)"
  [ "$SCORE_RC" = 0 ] && [ "$got" = "warmup:1000:true probe:130000:true probe:135000:false hold:130000:true" ] && grep -q 'no probe between 130000 and 135000' "$SCORE_OUT/search.json" \
    || { echo "finer: 130,000 passes and 135,000 fails with a round of 5,000: no probe between, the hold at 130,000 (exit $SCORE_RC): $got"; return 1; }
  # The first probe fails: the holds start 2.5 % under it, then step down by 2.5 %.
  score_search "0 99 99 0" --start 71000 --finer
  got="$(score_runs)"
  [ "$SCORE_RC" = 0 ] && [ "$got" = "warmup:1000:true probe:71000:false hold:69000:false hold:67000:true" ] \
    || { echo "finer: a first probe that fails starts the holds 2.5 % under it (69,000), then 67,000 (67,275): $got"; return 1; }
  # A void probe is not a fail: no probe halfway back, the holds start at the last pass.
  score_search "0 0 99/lbspike=0.9+lbspikes=5,6,7,8,9 0" --finer
  got="$(score_runs)"
  [ "$SCORE_RC" = 0 ] && [ "$got" = "warmup:1000:true probe:71000:true probe:75000:false hold:71000:true" ] && [ "$(jq -r '.end.bound_by_k6' "$SCORE_OUT/search.json")" = true ] \
    || { echo "finer: a void probe has no probe halfway back: the hold at 71,000 (exit $SCORE_RC): $got"; return 1; }
  # Without --finer the phase-7 arithmetic stands: the same words give 5 % holds and no extra probe.
  score_search "0 0 0 99 99 0" --start 129000
  got="$(score_runs)"
  [ "$SCORE_RC" = 0 ] && [ "$got" = "warmup:1000:true probe:129000:true probe:135000:true probe:142000:false hold:135000:false hold:128000:true" ] \
    || { echo "the default arithmetic: holds from 135,000 then 5 % under it (128,000: 128,250): $got"; return 1; }
}

# The boxes' scripts (lab/score/server-setup.sh, server-ctl.sh, ctl-ssh.sh, k6-setup.sh, php-gcob.service). Their first run was on AWS:
# these checks cover what a laptop can, with the paths the scripts read swapped for fixtures and the system's own
# commands (systemctl, shutdown, curl, ssh) stood in for by stubs on the PATH.

# boxes_stubs <dir> <name>...: a stub for each name in <dir>, to be put first on the PATH. A stub logs its name and arguments to
# <dir>/calls and exits with the code in <dir>/<name>.rc (0 when there is none), after printing <dir>/<name>.out if that exists.
boxes_stubs() {
  local dir="$1" name
  shift
  : >"$dir/calls"
  for name in "$@"; do
    printf '#!/usr/bin/env bash\necho "%s $*" >>"%s/calls"\n[ ! -f "%s/%s.out" ] || cat "%s/%s.out"\nexit "$(cat "%s/%s.rc" 2>/dev/null || echo 0)"\n' \
      "$name" "$dir" "$dir" "$name" "$dir" "$name" "$dir" "$name" >"$dir/$name"
    chmod +x "$dir/$name"
  done
}

# The systemd unit passes `systemd-analyze verify` in a clean Ubuntu container with systemd installed (the image has none): the unit
# as it is, and a copy whose ExecStart program does not exist, which must not pass. The user `deploy` and the unit's paths exist, as on the box.
check_score_unit() {
  local image out
  image="$(lab_base_image)"
  [ -n "$image" ] || { echo "no base image found in lab/images/Dockerfile.src"; return 1; }
  out="$(docker run --rm -i -v "$LAB/score/php-gcob.service:/unit.service:ro" "$image" bash -c '
    apt-get update -qq >/dev/null 2>&1 && apt-get install -y -qq --no-install-recommends systemd >/dev/null 2>&1 || { echo "setup: apt failed"; exit 1; }
    useradd -m deploy; mkdir -p /etc/systemd/system /srv/php-Gcob; touch /srv/php-Gcob/start.sh
    cp /unit.service /etc/systemd/system/good.service
    sed "s#^ExecStart=/usr/bin/bash #ExecStart=/usr/bin/no-such-shell #" /unit.service >/etc/systemd/system/bad.service
    systemd-analyze verify /etc/systemd/system/good.service >/tmp/good.log 2>&1; echo "good rc=$?"; cat /tmp/good.log
    systemd-analyze verify /etc/systemd/system/bad.service >/tmp/bad.log 2>&1; echo "bad rc=$?"' 2>&1)" || { echo "the container failed: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'good rc=0' <<<"$out" || { echo "systemd-analyze verify refuses the unit: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'bad rc=0' <<<"$out" && { echo "systemd-analyze verify passed a unit whose ExecStart program does not exist: the check cannot fail"; return 1; }
  return 0
}

# boxes_fixture <dir>: the droplet's shape and a healthy service, as files: one CPU, 1.9 GiB, no swap, no nf_conntrack module, and a unit
# whose one process (4242, run as root so the user name resolves anywhere) has 65,535 open files and the ambient capability of port 80.
boxes_fixture() {
  local dir="$1"
  mkdir -p "$dir/proc/4242" "$dir/cgroup" "$dir/bin"
  printf 'processor\t: 0\nmodel name\t: Fixture CPU\n\n' >"$dir/cpuinfo"
  printf 'MemTotal:        2031616 kB\nMemFree:         1000000 kB\nSwapTotal:             0 kB\n' >"$dir/meminfo"
  printf 'Filename\t\t\t\tType\t\tSize\t\tUsed\t\tPriority\n' >"$dir/swaps"
  printf 'ext4 1 0\n' >"$dir/modules"
  printf '4242\n' >"$dir/cgroup/cgroup.procs"
  printf 'Name:\tphp\nUid:\t0\t0\t0\t0\nCapAmb:\t0000000000000400\n' >"$dir/proc/4242/status"
  printf 'Limit                     Soft Limit           Hard Limit           Units\nMax open files            65535                65535                files\n' >"$dir/proc/4242/limits"
  boxes_stubs "$dir/bin" systemctl shutdown update-grub reboot useradd cloud-init
}

# boxes_setup_run <dir> [env assignment]... -- <server-setup.sh arguments>...: runs the script on the fixture of <dir>; leaves its output in
# BOXES_OUT and its exit code in BOXES_RC.
boxes_setup_run() {
  local dir="$1" envs=()
  shift
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  BOXES_RC=0
  BOXES_OUT="$(env PATH="$dir/bin:$PATH" SCORE_CPUINFO="$dir/cpuinfo" SCORE_MEMINFO="$dir/meminfo" SCORE_SWAPS="$dir/swaps" SCORE_MODULES="$dir/modules" \
    SCORE_UNIT_CGROUP="$dir/cgroup" SCORE_PROC="$dir/proc" SCORE_SETUP_USER=root SCORE_GRUB_DIR="$dir/grub.d" ${envs[@]+"${envs[@]}"} \
    bash "$LAB/score/server-setup.sh" "$@" 2>&1)" || BOXES_RC=$?
}

# The shape checks and the service checks of server-setup.sh --check, each failing alone on its own fixture: two CPUs, 4 GiB, a swap, the
# unit not active, another user, a low open files limit, no ambient capability, no curl. The droplet's shape passes, and a loaded nf_conntrack is
# printed without failing.
check_score_server_setup_checks() {
  local dir kind line want
  dir="$(mktemp -d)"
  boxes_fixture "$dir"
  boxes_setup_run "$dir" SCORE_CURL=bash -- --check
  [ "$BOXES_RC" = 0 ] || { echo "the droplet's shape and a healthy service fail (exit $BOXES_RC): ${BOXES_OUT//$'\n'/ | }"; return 1; }
  for want in cpus memory swap unit user limits capability curl; do
    grep -q "^ok    $want: " <<<"$BOXES_OUT" || { echo "no 'ok    $want:' line on the good fixture: ${BOXES_OUT//$'\n'/ | }"; return 1; }
  done
  grep -q '^info  conntrack: nf_conntrack is not loaded' <<<"$BOXES_OUT" || { echo "no conntrack line: ${BOXES_OUT//$'\n'/ | }"; return 1; }
  for kind in cpus memory swap unit user limits capability curl; do
    rm -rf "$dir"
    dir="$(mktemp -d)"
    boxes_fixture "$dir"
    case "$kind" in
      cpus) printf 'processor\t: 0\n\nprocessor\t: 1\n\n' >"$dir/cpuinfo" ;;
      memory) printf 'MemTotal:        4046848 kB\n' >"$dir/meminfo" ;;
      swap) printf '/swapfile\t\t\t\tfile\t\t1048572\t\t0\t\t-2\n' >>"$dir/swaps" ;;
      unit) echo 3 >"$dir/bin/systemctl.rc" ;;
      user) printf 'Name:\tphp\nUid:\t0\t0\t0\t0\nCapAmb:\t0000000000000400\n' >"$dir/proc/4242/status" ;;
      limits) printf 'Max open files            1024                 524288               files\n' >"$dir/proc/4242/limits" ;;
      capability) printf 'Name:\tphp\nUid:\t0\t0\t0\t0\nCapAmb:\t0000000000000000\n' >"$dir/proc/4242/status" ;;
      curl) ;;   # the program is swapped for one that does not exist, below
    esac
    # Why: the fixture's process runs as root, so only the 'user' case expects another user.
    boxes_setup_run "$dir" "SCORE_SETUP_USER=$([ "$kind" = user ] && echo deploy || echo root)" "SCORE_CURL=$([ "$kind" = curl ] && echo no-such-curl-here || echo bash)" -- --check
    [ "$BOXES_RC" = 1 ] || { echo "the '$kind' fixture exits $BOXES_RC, not 1: ${BOXES_OUT//$'\n'/ | }"; return 1; }
    line="$(grep "^FAIL  $kind: " <<<"$BOXES_OUT" || true)"
    [ -n "$line" ] || { echo "no 'FAIL  $kind:' line on the '$kind' fixture: ${BOXES_OUT//$'\n'/ | }"; return 1; }
    [ "$(grep -c '^FAIL ' <<<"$BOXES_OUT")" = 1 ] || { echo "the '$kind' fixture fails more than that one check: ${BOXES_OUT//$'\n'/ | }"; return 1; }
  done
  rm -rf "$dir"
  dir="$(mktemp -d)"
  boxes_fixture "$dir"
  printf 'nf_conntrack 180224 1 - Live 0x0000000000000000\next4 1 0\n' >"$dir/modules"
  boxes_setup_run "$dir" SCORE_CURL=bash -- --check
  [ "$BOXES_RC" = 0 ] && grep -q '^info  conntrack: nf_conntrack is loaded' <<<"$BOXES_OUT" || { echo "a loaded nf_conntrack is printed and does not fail (exit $BOXES_RC): ${BOXES_OUT//$'\n'/ | }"; return 1; }
  rm -rf "$dir"
}

# The install mode stops on a bad shape before it installs anything (no user, no copy, no cap armed), and --shape writes the boot line's drop-in
# (it appends mem=2G to what the image set before it, so it must sort last), runs update-grub, then reboots, in that order and nothing else.
check_score_server_setup_modes() {
  local dir out
  dir="$(mktemp -d)"
  boxes_fixture "$dir"
  printf 'processor\t: 0\n\nprocessor\t: 1\n\n' >"$dir/cpuinfo"
  boxes_setup_run "$dir" -- --launch-epoch 1700000000
  [ "$BOXES_RC" = 1 ] && grep -q '^FAIL  cpus: ' <<<"$BOXES_OUT" || { echo "a two-CPU box must exit 1 on the cpus line (exit $BOXES_RC): ${BOXES_OUT//$'\n'/ | }"; return 1; }
  [ ! -s "$dir/bin/calls" ] || { echo "the install mode ran commands before refusing the shape: $(tr '\n' ';' <"$dir/bin/calls")"; return 1; }
  rm -rf "$dir"
  dir="$(mktemp -d)"
  boxes_fixture "$dir"
  mkdir "$dir/grub.d"
  boxes_setup_run "$dir" -- --shape
  [ "$BOXES_RC" = 0 ] || { echo "--shape exits $BOXES_RC: ${BOXES_OUT//$'\n'/ | }"; return 1; }
  [ "$(tr '\n' ';' <"$dir/bin/calls")" = "update-grub ;reboot ;" ] || { echo "--shape runs update-grub then reboot and nothing else: $(tr '\n' ';' <"$dir/bin/calls")"; return 1; }
  [ "$(ls "$dir/grub.d")" = "99-twelve-dollar-mem.cfg" ] || { echo "--shape writes one drop-in that sorts after the image's: $(ls "$dir/grub.d")"; return 1; }
  out="$(GRUB_CMDLINE_LINUX_DEFAULT='console=tty1 console=ttyS0' bash -c '. "$1"; echo "$GRUB_CMDLINE_LINUX_DEFAULT"' _ "$dir/grub.d/99-twelve-dollar-mem.cfg")"
  [ "$out" = "console=tty1 console=ttyS0 mem=2G" ] || { echo "the drop-in must append mem=2G to the image's boot line, got '$out'"; return 1; }
  rm -rf "$dir"
}

# The 240-minute cap, re-armed after the reboot with the time left (its minutes round up; past the cap it arms one minute and fails).
check_score_server_setup_cap() {
  local dir
  dir="$(mktemp -d)"
  boxes_fixture "$dir"
  boxes_setup_run "$dir" SCORE_SETUP_NOW=1700003600 -- --cap-only --launch-epoch 1700000000
  [ "$BOXES_RC" = 0 ] && [ "$(tr '\n' ';' <"$dir/bin/calls")" = "shutdown -h +180;" ] \
    || { echo "an hour after the launch the cap has 180 minutes left (exit $BOXES_RC): $(tr '\n' ';' <"$dir/bin/calls") ${BOXES_OUT//$'\n'/ | }"; return 1; }
  : >"$dir/bin/calls"
  boxes_setup_run "$dir" SCORE_SETUP_NOW=1700014341 -- --cap-only --launch-epoch 1700000000
  [ "$(tr '\n' ';' <"$dir/bin/calls")" = "shutdown -h +1;" ] || { echo "59 seconds left arm 1 minute: $(tr '\n' ';' <"$dir/bin/calls")"; return 1; }
  : >"$dir/bin/calls"
  boxes_setup_run "$dir" SCORE_SETUP_NOW=1700014500 -- --cap-only --launch-epoch 1700000000
  [ "$BOXES_RC" = 1 ] && [ "$(tr '\n' ';' <"$dir/bin/calls")" = "shutdown -h +1;" ] && grep -q '^FAIL  cap: ' <<<"$BOXES_OUT" \
    || { echo "past the cap: arm 1 minute and fail (exit $BOXES_RC): $(tr '\n' ';' <"$dir/bin/calls") ${BOXES_OUT//$'\n'/ | }"; return 1; }
  boxes_setup_run "$dir" -- --cap-only
  [ "$BOXES_RC" = 2 ] || { echo "--cap-only without --launch-epoch must be a usage error (exit $BOXES_RC)"; return 1; }
  rm -rf "$dir"
}

# boxes_ctl_fixture <dir> <curl failures>: what server-ctl.sh reads and runs, in <dir>: a seed, a live copy with its -wal and -shm, and stubs for
# systemctl, chown and a curl that fails that many times before it answers.
boxes_ctl_fixture() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/seed" "$dir/data"
  boxes_stubs "$dir/bin" systemctl chown
  printf 'the seed' >"$dir/seed/feed.db"
  chmod 0444 "$dir/seed/feed.db"   # the real seed is read-only: the live copy must still be writable
  printf 'a live copy with writes' >"$dir/data/feed.db"
  printf 'wal' >"$dir/data/feed.db-wal"
  printf 'shm' >"$dir/data/feed.db-shm"
  printf '#!/usr/bin/env bash\nn=$(cat "%s/curl.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"%s/curl.n"\n[ "$n" -gt %s ]\n' "$dir" "$dir" "$2" >"$dir/bin/curl"
  chmod +x "$dir/bin/curl"
}

# boxes_ctl_run <dir> [env assignment]... -- <server-ctl.sh arguments>...: leaves the output in BOXES_OUT and the exit code in BOXES_RC.
boxes_ctl_run() {
  local dir="$1" envs=()
  shift
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  BOXES_RC=0
  BOXES_OUT="$(env PATH="$dir/bin:$PATH" SCORE_CTL_SEED="$dir/seed/feed.db" SCORE_CTL_DATA="$dir/data/feed.db" SCORE_CPUINFO="$dir/cpuinfo" SCORE_MEMINFO="$dir/meminfo" \
    ${envs[@]+"${envs[@]}"} bash "$LAB/score/server-ctl.sh" "$@" 2>&1)" || BOXES_RC=$?
}

# `restart` on the box's own files: the service stopped, the live copy and its -wal and -shm gone, a fresh copy of the seed owned by deploy, the
# service started, /health polled until it answers, the healthy seconds as the last line (the driver reads it); no answer in time exits 1, a
# missing seed exits 1 before the service is touched. `died` and `facts` are the driver's other questions.
check_score_server_ctl() {
  local dir calls
  dir="$(mktemp -d)"
  boxes_fixture "$dir/shape"
  boxes_ctl_fixture "$dir" 3
  cp "$dir/shape/cpuinfo" "$dir/shape/meminfo" "$dir/"
  boxes_ctl_run "$dir" SCORE_CTL_TIMEOUT=20 -- restart
  [ "$BOXES_RC" = 0 ] || { echo "restart exits $BOXES_RC: ${BOXES_OUT//$'\n'/ | }"; return 1; }
  [[ "$(tail -n 1 <<<"$BOXES_OUT")" =~ ^[0-9]+$ ]] || { echo "restart must end with the healthy seconds as a whole number: ${BOXES_OUT//$'\n'/ | }"; return 1; }
  [ "$(cat "$dir/data/feed.db")" = "the seed" ] || { echo "the live copy is not a fresh copy of the seed"; return 1; }
  [ "$(ls -l "$dir/data/feed.db" | cut -c2-3)" = rw ] || { echo "the live copy is not writable by its owner (a copy of a read-only seed keeps its mode): $(ls -l "$dir/data/feed.db")"; return 1; }
  [ ! -e "$dir/data/feed.db-wal" ] && [ ! -e "$dir/data/feed.db-shm" ] || { echo "the live copy's -wal or -shm survived the restart"; return 1; }
  calls="$(tr '\n' ';' <"$dir/bin/calls")"
  [ "$calls" = "systemctl stop php-gcob;chown deploy:deploy $dir/data/feed.db;systemctl start php-gcob;" ] \
    || { echo "restart stops the unit, hands the copy to deploy, then starts the unit: $calls"; return 1; }
  [ "$(cat "$dir/curl.n")" = 4 ] || { echo "/health is polled until it answers (3 refusals, then ok): $(cat "$dir/curl.n") calls"; return 1; }
  rm -rf "$dir"
  dir="$(mktemp -d)"
  boxes_ctl_fixture "$dir" 1000000
  SECONDS=0
  boxes_ctl_run "$dir" SCORE_CTL_TIMEOUT=1 -- restart
  [ "$BOXES_RC" = 1 ] && grep -q 'did not answer' <<<"$BOXES_OUT" || { echo "a server that never answers /health exits 1 after the timeout (exit $BOXES_RC): ${BOXES_OUT//$'\n'/ | }"; return 1; }
  [ "$SECONDS" -le 5 ] || { echo "a 1 s timeout took $SECONDS s: the poll does not stop at its timeout"; return 1; }
  rm -f "$dir/seed/feed.db"
  : >"$dir/bin/calls"
  boxes_ctl_run "$dir" -- restart
  [ "$BOXES_RC" = 1 ] && ! grep -q 'systemctl' "$dir/bin/calls" || { echo "a missing seed must exit 1 before the service is stopped (exit $BOXES_RC): $(tr '\n' ';' <"$dir/bin/calls")"; return 1; }
  boxes_ctl_run "$dir" -- nonsense
  [ "$BOXES_RC" = 2 ] || { echo "an unknown command is a usage error (exit $BOXES_RC)"; return 1; }
  echo 3 >"$dir/bin/systemctl.rc"
  boxes_ctl_run "$dir" -- died
  [ "$BOXES_RC" = 0 ] || { echo "died exits 0 when the unit is not active (exit $BOXES_RC)"; return 1; }
  echo 0 >"$dir/bin/systemctl.rc"
  boxes_ctl_run "$dir" -- died
  [ "$BOXES_RC" = 1 ] || { echo "died exits 1 when the unit is active (exit $BOXES_RC)"; return 1; }
  rm -rf "$dir"
  dir="$(mktemp -d)"
  boxes_fixture "$dir"
  boxes_ctl_fixture "$dir" 0
  boxes_stubs "$dir/bin" journalctl
  printf 'starting\nloop: epoll\nlistening on 80\nloop: ring, 3 rings\nready\n' >"$dir/bin/journalctl.out"
  boxes_ctl_run "$dir" -- loop
  [ "$BOXES_RC" = 0 ] && [ "$BOXES_OUT" = "ring, 3 rings" ] && grep -q '^journalctl -u php-gcob ' "$dir/bin/calls" \
    || { echo "loop prints the text of the unit's last loop: line (exit $BOXES_RC): ${BOXES_OUT//$'\n'/ | } / $(tr '\n' ';' <"$dir/bin/calls")"; return 1; }
  printf 'starting\nready\n' >"$dir/bin/journalctl.out"
  boxes_ctl_run "$dir" -- loop
  [ "$BOXES_RC" = 0 ] && [ -z "$BOXES_OUT" ] || { echo "a service that printed no loop line: loop prints nothing and exits 0 (exit $BOXES_RC): $BOXES_OUT"; return 1; }
  boxes_ctl_run "$dir" -- facts
  [ "$BOXES_RC" = 0 ] && jq -e 'type == "object" and .nproc == 1 and .mem_total_mib == 1984 and .swap_mib == 0 and (.kernel | type == "string") and .cpu_model == "Fixture CPU"' <<<"$BOXES_OUT" >/dev/null \
    || { echo "facts prints one JSON object (cpu_model, nproc, mem_total_mib, kernel, swap_mib) of the fixture's box (exit $BOXES_RC): ${BOXES_OUT//$'\n'/ | }"; return 1; }
  rm -rf "$dir"
}

# `sample-start` and `sample-stop` in a lab container (the sampler needs bash 5 and a Linux /proc), on the container's own cgroup and a sleeping
# process: 10 rows of 24 columns in the folder, the start and end facts, and no `server-died.txt` while the unit is active (systemctl is a stub that
# says so), the file when it is not.
check_score_server_ctl_sampler() {
  local dir out rows
  docker image inspect "$LAB_IMAGE:8.5" >/dev/null 2>&1 || { echo "image $LAB_IMAGE:8.5 is missing (run lab/build.sh 8.5)"; return 1; }
  dir="$(mktemp -d)"
  mkdir -p "$dir/bin"
  printf '#!/usr/bin/env bash\nexit "$(cat /stubs/systemctl.rc 2>/dev/null || echo 0)"\n' >"$dir/bin/systemctl"
  chmod +x "$dir/bin/systemctl"
  out="$(docker run --rm -v "$LAB:/lab:ro" -v "$dir/bin:/stubs" -e PATH="/stubs:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    -e SCORE_CTL_CGROUP=/sys/fs/cgroup -e SCORE_CTL_PIDS_OF="sleep 300" "$LAB_IMAGE:8.5" bash -c '
      sleep 300 & sleep 1
      s=/lab/score/server-ctl.sh
      bash $s sample-start /tmp/run1 || exit 1
      sleep 11
      bash $s sample-stop /tmp/run1
      echo "--- died: $(ls /tmp/run1 | paste -sd" " -)"
      echo 3 >/stubs/systemctl.rc
      bash $s sample-start /tmp/run2 && sleep 2 && bash $s sample-stop /tmp/run2 >/dev/null
      echo "--- dead: $(ls /tmp/run2 | paste -sd" " -)"
      cat /tmp/run1/server.csv' 2>&1)" || { echo "the controller's sampler run failed: ${out//$'\n'/ | }"; rm -rf "$dir"; return 1; }
  rm -rf "$dir"
  grep -q '^--- died: .*server.csv' <<<"$out" && grep -q '^--- died: .*server-start.txt' <<<"$out" && grep -q '^--- died: .*server-end.txt' <<<"$out" \
    || { echo "sample-stop must leave server.csv, server-start.txt and server-end.txt: ${out//$'\n'/ | }"; return 1; }
  grep '^--- died: ' <<<"$out" | grep -q 'server-died.txt' && { echo "server-died.txt written while the unit is active"; return 1; }
  grep '^--- dead: ' <<<"$out" | grep -q 'server-died.txt' || { echo "no server-died.txt while the unit is not active: ${out//$'\n'/ | }"; return 1; }
  rows="$(grep -c '^[0-9]*\.[0-9][0-9][0-9],' <<<"$out")"
  [ "$rows" -ge 10 ] || { echo "expected 10 rows or more in 11 s, got $rows"; return 1; }
  [ "$(grep '^[0-9]*\.[0-9][0-9][0-9],' <<<"$out" | head -n 1 | awk -F, '{ print NF }')" = 24 ] || { echo "a row has not 24 columns"; return 1; }
}

# ctl-ssh.sh, the controller the driver runs on the load box: each command goes to the server box over ssh (a stub that runs the command
# here), and `sample-stop <dir>` leaves the sampler's files in <dir> on this side, whatever the folder is called on the server box.
check_score_ctl_ssh() {
  local dir remote local_dir out rc
  dir="$(mktemp -d)"
  remote="$dir/remote"
  mkdir -p "$dir/bin" "$remote" "$dir/run"
  # The ssh stub: drops the options and the host, runs the remote command in a local shell (as ssh does with the joined arguments).
  printf '%s\n' '#!/usr/bin/env bash' 'echo "ssh $*" >>"$SSH_LOG"' \
    'while [ "$#" -gt 0 ]; do case "$1" in -n) shift ;; -o|-i|-p) shift 2 ;; *) break ;; esac; done' \
    'shift' 'exec bash -c "$*"' >"$dir/bin/ssh"
  chmod +x "$dir/bin/ssh"
  # The server box's controller, as a stand-in: logs its arguments, leaves files in the folder it is given.
  printf '%s\n' '#!/usr/bin/env bash' 'echo "ctl $*" >>"$SSH_LOG"' 'case "$1" in' \
    '  restart) echo "copying"; echo 7 ;;' \
    '  sample-start) mkdir -p "$2" ;;' \
    '  sample-stop) printf "ts\n1\n" >"$2/server.csv"; echo "nproc 1" >"$2/server-start.txt"; echo "sampler_cpu_ms 3" >"$2/server-end.txt" ;;' \
    '  facts) echo "{\"nproc\":1}" ;;' \
    '  loop) echo "ring, 3 rings" ;;' \
    '  died) exit "${FAKE_DIED:-1}" ;;' 'esac' >"$dir/ctl"
  run_ssh() { env PATH="$dir/bin:$PATH" SSH_LOG="$dir/log" SCORE_REMOTE_CTL="bash $dir/ctl" SCORE_REMOTE_DIR="$remote/sample" "$@"; }
  : >"$dir/log"
  out="$(run_ssh bash "$LAB/score/ctl-ssh.sh" ubuntu@192.0.2.9 restart 2>&1)" || { echo "restart through ssh failed: $out"; return 1; }
  [ "$(tail -n 1 <<<"$out")" = 7 ] || { echo "restart's last line is the healthy seconds: ${out//$'\n'/ | }"; return 1; }
  run_ssh bash "$LAB/score/ctl-ssh.sh" ubuntu@192.0.2.9 sample-start "$dir/run" >/dev/null 2>&1 || { echo "sample-start failed"; return 1; }
  run_ssh bash "$LAB/score/ctl-ssh.sh" ubuntu@192.0.2.9 sample-stop "$dir/run" >/dev/null 2>&1 || { echo "sample-stop failed"; return 1; }
  for local_dir in server.csv server-start.txt server-end.txt; do
    [ -s "$dir/run/$local_dir" ] || { echo "sample-stop did not bring $local_dir into the driver's folder: $(ls "$dir/run")"; return 1; }
  done
  [ "$(cat "$dir/run/server-end.txt")" = "sampler_cpu_ms 3" ] || { echo "a file was changed on the way"; return 1; }
  grep -q "^ctl sample-start $remote/sample\$" "$dir/log" && grep -q "^ctl sample-stop $remote/sample\$" "$dir/log" \
    || { echo "the server box gets its own folder, not the driver's: $(grep '^ctl' "$dir/log" | tr '\n' ';')"; return 1; }
  out="$(run_ssh bash "$LAB/score/ctl-ssh.sh" ubuntu@192.0.2.9 facts 2>&1)"
  [ "$out" = '{"nproc":1}' ] || { echo "facts passes the JSON through: $out"; return 1; }
  out="$(run_ssh bash "$LAB/score/ctl-ssh.sh" ubuntu@192.0.2.9 loop 2>&1)"
  [ "$out" = "ring, 3 rings" ] || { echo "loop passes the server's loop text through: $out"; return 1; }
  FAKE_DIED=0 run_ssh bash "$LAB/score/ctl-ssh.sh" ubuntu@192.0.2.9 died >/dev/null 2>&1 || { echo "died passes the exit code 0 through"; return 1; }
  rc=0
  run_ssh bash "$LAB/score/ctl-ssh.sh" ubuntu@192.0.2.9 died >/dev/null 2>&1 || rc=$?
  [ "$rc" = 1 ] || { echo "died passes the exit code 1 through (got $rc)"; return 1; }
  rm -rf "$remote/sample"
  rc=0
  run_ssh bash "$LAB/score/ctl-ssh.sh" ubuntu@192.0.2.9 sample-stop "$dir/run2" >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || { echo "sample-stop with nothing to bring back must fail"; return 1; }
  printf '#!/usr/bin/env bash\nexit 1\n' >"$dir/ctl"
  rc=0
  run_ssh bash "$LAB/score/ctl-ssh.sh" ubuntu@192.0.2.9 restart >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] || { echo "a failing restart on the server box must fail the controller"; return 1; }
  rc=0
  run_ssh bash "$LAB/score/ctl-ssh.sh" ubuntu@192.0.2.9 nonsense >/dev/null 2>&1 || rc=$?
  [ "$rc" = 2 ] || { echo "an unknown command is a usage error (got $rc)"; return 1; }
  rm -rf "$dir"
}

# boxes_k6_fixture <dir>: what k6-setup.sh reads, in <dir>: the challenge's real bench/load.js and a tokens file, the ephemeral range of a box that
# was set up, no nf_conntrack module, and stubs for the instance metadata (a curl that answers the IMDSv2 paths with a primary and 3 secondary
# addresses), `ip` (the default route and the interface's 4 addresses), ssh, sudo, sysctl, ping and ethtool.
boxes_k6_fixture() {
  local dir="$1"
  mkdir -p "$dir/bin" "$dir/challenge/bench" "$dir/challenge/seed" "$dir/challenge/test"
  cp "$REPO/reference/twelve-dollar-server-challenge/bench/load.js" "$dir/challenge/bench/load.js"
  printf '[]' >"$dir/challenge/seed/tokens.json"
  printf '1024\t65535\n' >"$dir/range"
  printf 'ext4 1 0\n' >"$dir/modules"
  boxes_stubs "$dir/bin" sysctl
  printf '%s\n' '#!/usr/bin/env bash' 'for last; do :; done' 'case "$last" in' \
    '  */latest/api/token) echo TOKEN ;;' '  */macs/) echo "02:aa:bb:cc:dd:ee/" ;;' \
    '  */local-ipv4s) printf "192.0.2.5\n192.0.2.6\n192.0.2.7\n192.0.2.8" ;;' '  */subnet-ipv4-cidr-block) echo 192.0.2.0/24 ;;' '  *) exit 22 ;;' 'esac' >"$dir/bin/curl"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "ip $*" >>"'"$dir"'/bin/calls"' 'case "$*" in' \
    '  "route show default") echo "default via 192.0.2.1 dev ens5 proto dhcp src 192.0.2.5 metric 100" ;;' \
    '  "-4 -o addr show dev ens5") cat "'"$dir"'/addrs" ;;' '  addr\ add*) ;;' '  *) exit 1 ;;' 'esac' >"$dir/bin/ip"
  printf '2: ens5    inet 192.0.2.5/24 brd 192.0.2.255 scope global dynamic ens5\n2: ens5    inet 192.0.2.6/24 scope global secondary ens5\n2: ens5    inet 192.0.2.7/24 scope global secondary ens5\n2: ens5    inet 192.0.2.8/24 scope global secondary ens5\n' >"$dir/addrs"
  printf '%s\n' '#!/usr/bin/env bash' 'exec "$@"' >"$dir/bin/sudo"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "ssh $*" >>"'"$dir"'/bin/calls"' '[ ! -f "'"$dir"'/ssh.rc" ] || exit "$(cat "'"$dir"'/ssh.rc")"' \
    'while [ "$#" -gt 0 ]; do case "$1" in -n|-q) shift ;; -o|-i|-p) shift 2 ;; *) break ;; esac; done' 'shift' 'exec bash -c "$*"' >"$dir/bin/ssh"
  printf '%s\n' '#!/usr/bin/env bash' 'exec shasum -a 256 "$@"' >"$dir/bin/sha256sum"
  chmod +x "$dir/bin/curl" "$dir/bin/ip" "$dir/bin/sudo" "$dir/bin/ssh" "$dir/bin/sha256sum"
}

# boxes_k6_run <dir> [env assignment]... -- <k6-setup.sh arguments>...: leaves the output in BOXES_OUT and the exit code in BOXES_RC.
boxes_k6_run() {
  local dir="$1" envs=()
  shift
  while [ "$1" != -- ]; do envs+=("$1"); shift; done
  shift
  BOXES_RC=0
  BOXES_OUT="$(env PATH="$dir/bin:$PATH" K6_SETUP_CHALLENGE="$dir/challenge" K6_SETUP_PORT_RANGE_FILE="$dir/range" SCORE_MODULES="$dir/modules" K6_SETUP_USER="$(id -un)" \
    ${envs[@]+"${envs[@]}"} bash "$LAB/score/k6-setup.sh" "$@" 2>&1)" || BOXES_RC=$?
}

# k6-setup.sh --check prints one line per check, names them, and exits non-zero when one fails: on a box that is set up, each passes; a load.js
# with one byte changed, a default ephemeral range, a missing address and a server that does not answer ssh each fail alone.
check_score_k6_setup_check() {
  local dir kind want
  docker image inspect "$LAB_K6_IMAGE" >/dev/null 2>&1 || { echo "image $LAB_K6_IMAGE is missing (pull it: the scores' k6)"; return 1; }
  dir="$(mktemp -d)"
  boxes_k6_fixture "$dir"
  boxes_k6_run "$dir" -- --check 192.0.2.9
  [ "$BOXES_RC" = 0 ] || { echo "a box that is set up fails its check (exit $BOXES_RC): ${BOXES_OUT//$'\n'/ | }"; return 1; }
  for want in k6 nofile addresses ports load.js tokens ssh; do
    [ "$(grep -c "^ok    $want: " <<<"$BOXES_OUT")" = 1 ] || { echo "no single 'ok    $want:' line: ${BOXES_OUT//$'\n'/ | }"; return 1; }
  done
  grep -q '^info  conntrack: nf_conntrack is not loaded' <<<"$BOXES_OUT" || { echo "no conntrack line: ${BOXES_OUT//$'\n'/ | }"; return 1; }
  [ "$(grep -c '^\(ok   \|FAIL \|info \)' <<<"$BOXES_OUT")" = 8 ] || { echo "one line per check, 8 of them: ${BOXES_OUT//$'\n'/ | }"; return 1; }
  for kind in load.js ports addresses ssh; do
    rm -rf "$dir"
    dir="$(mktemp -d)"
    boxes_k6_fixture "$dir"
    case "$kind" in
      load.js) sed -i.bak 's/const LIKE_PROB = 0.15/const LIKE_PROB = 0.16/' "$dir/challenge/bench/load.js" && rm -f "$dir/challenge/bench/load.js.bak" ;;
      ports) printf '32768\t60999\n' >"$dir/range" ;;
      addresses) sed -i.bak '$d' "$dir/addrs" && rm -f "$dir/addrs.bak" ;;
      ssh) echo 255 >"$dir/ssh.rc" ;;
    esac
    boxes_k6_run "$dir" -- --check 192.0.2.9
    [ "$BOXES_RC" = 1 ] && [ "$(grep -c '^FAIL  ' <<<"$BOXES_OUT")" = 1 ] && grep -q "^FAIL  $kind: " <<<"$BOXES_OUT" \
      || { echo "the '$kind' fixture must fail that one check and exit 1 (exit $BOXES_RC): ${BOXES_OUT//$'\n'/ | }"; return 1; }
    [ "$kind" != load.js ] || grep -q "not the challenge's" <<<"$BOXES_OUT" || { echo "a changed load.js is refused with the reason: ${BOXES_OUT//$'\n'/ | }"; return 1; }
  done
  rm -rf "$dir"
  dir="$(mktemp -d)"
  boxes_k6_fixture "$dir"
  printf 'nf_conntrack 180224 1 - Live 0x0000000000000000\n' >"$dir/modules"
  boxes_k6_run "$dir" -- --check
  grep -q '^info  conntrack: nf_conntrack is loaded: nf_conntrack_max set to 1048576' <<<"$BOXES_OUT" && grep -q '^sysctl -w net.netfilter.nf_conntrack_max=1048576' "$dir/bin/calls" \
    || { echo "a loaded nf_conntrack gets nf_conntrack_max 1048576 and says so: ${BOXES_OUT//$'\n'/ | } $(cat "$dir/bin/calls")"; return 1; }
  rm -rf "$dir"
}

# The other modes of k6-setup.sh, on stubs: --rtt prints only the numbers (no address), --push-seed sends the seed and compares its sha256 on both sides (a
# copy that differs fails), --check-42 must end `passed=42 failed=0`, --allowance prints the ENA's allowance counters, --print-ips the interface's
# addresses for k6's --local-ips.
check_score_k6_setup_modes() {
  local dir seed
  dir="$(mktemp -d)"
  boxes_k6_fixture "$dir"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "PING 192.0.2.9 (192.0.2.9) 56(84) bytes of data."' 'echo' 'echo "--- 192.0.2.9 ping statistics ---"' \
    'echo "100 packets transmitted, 100 received, 0% packet loss, time 19905ms"' 'echo "rtt min/avg/max/mdev = 0.112/0.156/0.321/0.032 ms"' >"$dir/bin/ping"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "NIC statistics:"' 'echo "     tx_timeout: 0"' 'echo "     bw_in_allowance_exceeded: 0"' \
    'echo "     pps_allowance_exceeded: 2"' 'echo "     conntrack_allowance_available: 4294967295"' >"$dir/bin/ethtool"
  printf '%s\n' '#!/usr/bin/env bash' 'last=""; for a; do prev="$last"; last="$a"; done' 'cp "$prev" "${last#*:}"' >"$dir/bin/scp"
  chmod +x "$dir/bin/ping" "$dir/bin/ethtool" "$dir/bin/scp"
  boxes_k6_run "$dir" -- --rtt 192.0.2.9
  [ "$BOXES_RC" = 0 ] && [ "$BOXES_OUT" = "rtt: min 0.112 ms, avg 0.156 ms, max 0.321 ms (100 packets, 0 % lost)" ] \
    || { echo "--rtt prints the three numbers and nothing that names the box (exit $BOXES_RC): ${BOXES_OUT//$'\n'/ | }"; return 1; }
  boxes_k6_run "$dir" -- --allowance
  [ "$BOXES_RC" = 0 ] && [ "$BOXES_OUT" = "$(printf 'ena bw_in_allowance_exceeded 0\nena pps_allowance_exceeded 2\nena conntrack_allowance_available 4294967295')" ] \
    || { echo "--allowance prints one line per allowance counter, and only those (exit $BOXES_RC): ${BOXES_OUT//$'\n'/ | }"; return 1; }
  boxes_k6_run "$dir" -- --print-ips
  [ "$BOXES_RC" = 0 ] && [ "$BOXES_OUT" = "192.0.2.5,192.0.2.6,192.0.2.7,192.0.2.8" ] || { echo "--print-ips prints the interface's addresses, comma separated (exit $BOXES_RC): ${BOXES_OUT//$'\n'/ | }"; return 1; }
  seed="$dir/seed.db"
  head -c 100000 /dev/urandom >"$seed"
  mkdir -p "$dir/remote"
  boxes_k6_run "$dir" K6_SETUP_SEED="$seed" K6_SETUP_REMOTE_SEED_DIR="$dir/remote" K6_SETUP_REMOTE_SUDO=env -- --push-seed 192.0.2.9
  [ "$BOXES_RC" = 0 ] && cmp -s "$seed" "$dir/remote/feed.db" && grep -q "^ok    seed: sha256 $(shasum -a 256 "$seed" | cut -d' ' -f1) on both boxes" <<<"$BOXES_OUT" \
    || { echo "--push-seed copies the seed and reports one sha256 for both sides (exit $BOXES_RC): ${BOXES_OUT//$'\n'/ | }"; return 1; }
  printf '%s\n' '#!/usr/bin/env bash' 'last=""; for a; do prev="$last"; last="$a"; done' 'cp "$prev" "${last#*:}"; echo x >>"${last#*:}"' >"$dir/bin/scp"
  boxes_k6_run "$dir" K6_SETUP_SEED="$seed" K6_SETUP_REMOTE_SEED_DIR="$dir/remote" K6_SETUP_REMOTE_SUDO=env -- --push-seed 192.0.2.9
  [ "$BOXES_RC" = 1 ] && grep -q '^FAIL  seed: ' <<<"$BOXES_OUT" || { echo "a copy that differs fails --push-seed (exit $BOXES_RC): ${BOXES_OUT//$'\n'/ | }"; return 1; }
  printf '%s\n' '#!/usr/bin/env bash' 'echo "  ok   something"' 'echo "passed=42 failed=0"' >"$dir/challenge/test/test.sh"
  boxes_k6_run "$dir" -- --check-42 192.0.2.9
  [ "$BOXES_RC" = 0 ] && grep -q '^ok    challenge-test: passed=42 failed=0' <<<"$BOXES_OUT" || { echo "--check-42 passes on passed=42 failed=0 (exit $BOXES_RC): ${BOXES_OUT//$'\n'/ | }"; return 1; }
  printf '%s\n' '#!/usr/bin/env bash' 'echo "passed=41 failed=1"' 'exit 1' >"$dir/challenge/test/test.sh"
  boxes_k6_run "$dir" -- --check-42 192.0.2.9
  [ "$BOXES_RC" = 1 ] && grep -q '^FAIL  challenge-test: passed=41 failed=1' <<<"$BOXES_OUT" || { echo "--check-42 fails on passed=41 failed=1 (exit $BOXES_RC): ${BOXES_OUT//$'\n'/ | }"; return 1; }
  rm -rf "$dir"
}

# swoole_co_start <container> <image> [K=V]...: lab/servers/swoole-co.php on a fresh copy of the seed, without Docker's seccomp filter (io_uring needs it
# lifted; epoll does not mind), waited on until it listens or exits. Prints the failure and returns 1 otherwise.
# Why disable SC2034: LAB_COLD, LAB_EXT and LAB_ENV are read by lab_start_app and lab_build_php_flags (lib.sh), which shellcheck does not follow.
# shellcheck disable=SC2034
swoole_co_start() {
  local name="$1" image="$2"
  shift 2
  LAB_COLD=0 LAB_EXT=(swoole) LAB_ENV=("$@")
  lab_build_php_flags
  docker rm -f "$name" >/dev/null 2>&1
  LAB_SERVER_SECCOMP_UNCONFINED=1 lab_start_app "$name" "$image" 18175 /lab/servers/swoole-co.php || { echo "lab_start_app failed"; return 1; }
  for _ in $(seq 1 120); do
    docker logs "$name" 2>&1 | grep -q '^loop: ' && return 0
    [ "$(docker inspect -f '{{.State.Running}}' "$name")" = true ] || { echo "the server exited ($(docker inspect -f '{{.State.ExitCode}}' "$name")): $(docker logs "$name" 2>&1 | tr '\n' ' ')"; return 1; }
    sleep 0.5
  done
  echo "the server did not print its loop line within 60 s"
  return 1
}

# The image with Swoole's io_uring sockets and the server on it. The image: `--ri swoole` names io_uring and uring_socket, liburing is the pinned version
# and the build refuses one under 2.8 (before any download). The server: its boot lines, keep-alive (two requests, one connection), JSON bytes, the
# 401 and 404 of the app, a ring in the process's descriptors once it has served, and a Swoole without io_uring (the 8.5 image's) says `epoll` in the
# same line, so the line is the build's answer and not a constant. APP_GROUP_COMMIT=1 and a stack size under Swoole's minimum are refused at boot.
check_swoole_co() {
  local out want name=lab-check-swoole-co log
  docker image inspect "$LAB_IMAGE:8.5-uring" >/dev/null 2>&1 || { echo "skip: image $LAB_IMAGE:8.5-uring is not built (run lab/build.sh 8.5-uring)"; return 0; }
  out="$(bash "$LAB/run.sh" 8.5-uring php -d extension=swoole --ri swoole 2>&1)" || { echo "php --ri swoole failed: $out"; return 1; }
  grep -qx 'io_uring => enabled' <<<"$out" && grep -qx 'uring_socket => enabled' <<<"$out" || { echo "--ri swoole does not say io_uring and uring_socket are enabled: ${out//$'\n'/ | }"; return 1; }
  want="$(sed -n 's/^LIBURING_PINNED_VERSION=//p' "$LAB/images/install-liburing.sh")"
  [ -n "$want" ] || { echo "no LIBURING_PINNED_VERSION in lab/images/install-liburing.sh"; return 1; }
  out="$(bash "$LAB/run.sh" 8.5-uring pkg-config --modversion liburing 2>&1)"
  [ "$out" = "$want" ] || { echo "the image's liburing is '$out', the pin is $want"; return 1; }
  out="$(LIBURING_VERSION=2.5 bash "$LAB/images/install-liburing.sh" 2>&1)" && { echo "install-liburing.sh accepted liburing 2.5"; return 1; }
  grep -q 'liburing 2.5 is under 2.8' <<<"$out" || { echo "the refusal of liburing 2.5 does not say why: ${out//$'\n'/ | }"; return 1; }
  lab_ensure_tools_image
  swoole_co_start "$name" 8.5-uring || { docker rm -f "$name" >/dev/null 2>&1; return 1; }
  log="$(docker logs "$name" 2>&1)"
  grep -qx 'loop: swoole-co, uring' <<<"$log" || { docker rm -f "$name" >/dev/null 2>&1; echo "the loop line is not 'loop: swoole-co, uring': ${log//$'\n'/ | }"; return 1; }
  out="$(docker run --rm --network host "$LAB_TOOLS_IMAGE" sh -c '
    for _ in 1 2 3 4 5 6 7 8 9 10; do curl -sf -m 2 http://127.0.0.1:18175/health >/dev/null && break; sleep 0.3; done
    curl -s -m 5 -o /dev/null -w "connects %{num_connects} " http://127.0.0.1:18175/health -o /dev/null http://127.0.0.1:18175/feed
    curl -s -m 5 -D - -o /dev/null http://127.0.0.1:18175/health | tr -d "\r" | grep -i "^content-type:"
    curl -s -m 5 -o /dev/null -w "post-no-token %{http_code}\n" -X POST -d "{}" http://127.0.0.1:18175/posts
    curl -s -m 5 -o /dev/null -w "unknown %{http_code}\n" http://127.0.0.1:18175/nope
    curl -s -m 5 http://127.0.0.1:18175/feed | head -c 9; echo' 2>&1)"
  grep -q '^connects 1 connects 0 ' <<<"$out" || { docker rm -f "$name" >/dev/null 2>&1; echo "two requests were not served on one connection: ${out//$'\n'/ | }"; return 1; }
  grep -qi 'content-type: application/json$' <<<"$out" || { docker rm -f "$name" >/dev/null 2>&1; echo "the Content-Type is not application/json: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'post-no-token 401' <<<"$out" && grep -qx 'unknown 404' <<<"$out" && grep -qx '{"posts":' <<<"$out" || { docker rm -f "$name" >/dev/null 2>&1; echo "the app's answers are not the expected ones: ${out//$'\n'/ | }"; return 1; }
  out="$(docker exec "$name" sh -c 'ls -l /proc/1/fd | grep -c "anon_inode:.io_uring."')"
  docker rm -f "$name" >/dev/null 2>&1
  [ "${out:-0}" -ge 1 ] || { echo "the server holds no io_uring ring after serving requests"; return 1; }
  if docker image inspect "$LAB_IMAGE:8.5" >/dev/null 2>&1; then
    swoole_co_start "$name" 8.5 || { docker rm -f "$name" >/dev/null 2>&1; return 1; }
    log="$(docker logs "$name" 2>&1)"
    docker rm -f "$name" >/dev/null 2>&1
    grep -qx 'loop: swoole-co, epoll' <<<"$log" || { echo "on a Swoole without io_uring the loop line is not 'loop: swoole-co, epoll': ${log//$'\n'/ | }"; return 1; }
  fi
  out="$(swoole_co_start "$name" 8.5-uring APP_GROUP_COMMIT=1)" && { docker rm -f "$name" >/dev/null 2>&1; echo "APP_GROUP_COMMIT=1 was accepted"; return 1; }
  docker rm -f "$name" >/dev/null 2>&1
  grep -q 'APP_GROUP_COMMIT=1 is not supported' <<<"$out" || { echo "the refusal of group commit does not say why: $out"; return 1; }
  out="$(swoole_co_start "$name" 8.5-uring SWOOLE_CO_STACK_SIZE=100)" && { docker rm -f "$name" >/dev/null 2>&1; echo "SWOOLE_CO_STACK_SIZE=100 was accepted (Swoole's minimum is 65536)"; return 1; }
  docker rm -f "$name" >/dev/null 2>&1
  grep -q 'SWOOLE_CO_STACK_SIZE must be a whole number of bytes from 65536 to 16777216' <<<"$out" || { echo "the refusal of a stack size under 65536 does not say why: $out"; return 1; }
}

# lab/steplab.sh --expect-loop: a variant whose server printed another `loop:` line than the one asked for stops the comparison (exit 1, with the
# line it got), the right line goes through and lands in the run's JSON, an unknown variant is a usage error, and --seccomp-unconfined is accepted.
check_steplab_expect_loop() {
  local out rc=0 dir
  dir="$(mktemp -d)"
  out="$(bash "$LAB/steplab.sh" --dry-run --image 8.5 --rate 100 --think-scale 0.1 --seconds 5 --pairs 1 --variant a= --expect-loop b=epoll 2>&1)" || rc=$?
  [ "$rc" = 2 ] && grep -q "names 'b', which is not one of the variants" <<<"$out" || { rm -rf "$dir"; echo "an unknown variant in --expect-loop is not a usage error (exit $rc): ${out//$'\n'/ | }"; return 1; }
  out="$(bash "$LAB/steplab.sh" --dry-run --image 8.5 --rate 100 --think-scale 0.1 --seconds 5 --pairs 1 --seccomp-unconfined --variant a= --expect-loop a=epoll 2>&1)" \
    || { rm -rf "$dir"; echo "--dry-run with --seccomp-unconfined and --expect-loop failed: ${out//$'\n'/ | }"; return 1; }
  rc=0
  out="$(bash "$LAB/steplab.sh" --image 8.5 --rate 200 --think-scale 0.1 --seconds 5 --pairs 1 --warmup 20,5 --variant ref= --expect-loop ref=uring --out "$dir/wrong" 2>&1)" || rc=$?
  [ "$rc" = 1 ] && grep -q "the server's loop line is 'epoll', which does not contain 'uring'" <<<"$out" || { rm -rf "$dir"; echo "a wrong loop line did not stop the run (exit $rc): ${out//$'\n'/ | }"; return 1; }
  rc=0
  out="$(bash "$LAB/steplab.sh" --image 8.5 --rate 200 --think-scale 0.1 --seconds 5 --pairs 1 --warmup 20,5 --variant ref= --expect-loop ref=epoll --out "$dir/right" 2>&1)" || rc=$?
  [ "$rc" = 0 ] && [ "$(jq -r '.server.loop' "$dir/right/ref-1.json")" = epoll ] || { echo "the right loop line did not pass, or is not in the JSON (exit $rc): ${out//$'\n'/ | }"; rm -rf "$dir"; return 1; }
  rm -rf "$dir"
}

# ring_start <name> <port> [K=V]...: the challenge app on the ring (APP_RING=1, telemetry on so that its `ring:` lines come out), on a fresh copy of the
# seed, without Docker's seccomp filter (io_uring needs it lifted); waited on until it listens or exits. Prints the failure and returns 1 otherwise.
ring_start() {
  local name="$1" port="$2"
  shift 2
  LAB_SERVER_SECCOMP_UNCONFINED=1 start_app_for_check "$name" "$port" 0 APP_RING=1 APP_TELEMETRY=1 "$@"
}

# ring_sum <container> <field>: the sum of a counter over the `ring:` lines the server printed (each holds one second's counts).
ring_sum() {
  docker logs "$1" 2>&1 | grep '^ring: ' | grep -o " $2=[0-9]*" | cut -d= -f2 | awk '{s += $1} END {print s + 0}'
}

# ring_last <container> <field>: the value of a field on the last `ring:` line (for the values that are not counts: `open`, `slots_in_use`).
ring_last() {
  docker logs "$1" 2>&1 | grep '^ring: ' | tail -n 1 | grep -o " $2=[0-9]*" | cut -d= -f2
}

# ring_client <container> <port> <command> [other port]: lab/check/ring-client.php inside the server's container (its output, one line per case).
ring_client() {
  docker exec "$1" php -d extension=sockets /lab/check/ring-client.php "$2" "$3" ${4:+"$4"} 2>&1
}

# ring_client_ok <container> <port> <command> <lines>: runs a command of the client and wants exactly <lines> `ok` lines and no FAIL. Prints why not.
ring_client_ok() {
  local out ok
  out="$(ring_client "$1" "$2" "$3" ${5:+"$5"})" || { echo "ring-client $3 failed: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok    ' <<<"$out")"
  [ "$ok" = "$4" ] && ! grep -q '^FAIL' <<<"$out" || { echo "ring-client $3: expected $4 ok lines: ${out//$'\n'/ | }"; return 1; }
}

# The ring (APP_RING=1) refuses at boot, with a message that says why and exit code 1, what it replaces or cannot serve: several workers, group
# commit, the checkpointer, the profiler, the loop presets, and a value that is not 0 or 1. Nothing is started before the refusal (no database, no ring).
check_ring_refusals() {
  local out v
  out="$(bash "$LAB/run.sh" 8.5 sh -c '
    for v in APP_WORKERS=2 APP_GROUP_COMMIT=1 APP_CHECKPOINTER=100 APP_PROFILE=/tmp/p APP_LOOP=poll APP_RING=yes; do
      echo "== $v"
      env SQLITE_PATH=/nonexistent JWT_SECRET=x APP_RING=1 "$v" php -d extension=sockets /lab/app/server.php 2>&1
      echo "exit $?"
    done' 2>&1)" || { echo "the run failed: ${out//$'\n'/ | }"; return 1; }
  for v in APP_WORKERS=2 APP_GROUP_COMMIT=1 APP_CHECKPOINTER=100 APP_PROFILE=/tmp/p APP_LOOP=poll; do
    grep -A2 -x "== $v" <<<"$out" | grep -q "^server: APP_RING=1 cannot be set with ${v%%=*}" || { echo "$v is not refused with a reason: ${out//$'\n'/ | }"; return 1; }
    grep -A2 -x "== $v" <<<"$out" | grep -qx 'exit 1' || { echo "$v does not exit with 1: ${out//$'\n'/ | }"; return 1; }
  done
  grep -A2 -x '== APP_RING=yes' <<<"$out" | grep -q "^server: APP_RING must be 1 or 0, got 'yes'" || { echo "APP_RING=yes is not refused: ${out//$'\n'/ | }"; return 1; }
}

# The app on the ring: its boot lines (`loop: ring, 1 ring`, the pools, the socket line), a ring in the process's descriptors and almost nothing else
# after 300 connections held together (the connections are the ring's direct descriptors), the `ring:` line with its requests per turn, and the app's
# own answers (the 404 of a route that is not the bake-off's, a 401).
check_ring_boot() {
  local name=lab-check-ring log out
  ring_start "$name" 18177 || { docker rm -f "$name" >/dev/null 2>&1; return 1; }
  log="$(docker logs "$name" 2>&1)"
  grep -qx 'loop: ring, 1 ring' <<<"$log" || { docker rm -f "$name" >/dev/null 2>&1; echo "the loop line is not 'loop: ring, 1 ring': ${log//$'\n'/ | }"; return 1; }
  grep -q '^ring-settings: table=[0-9]* sq=4096 cq=32768 recv_buffers=4096x2048 send_slots=2048x8192$' <<<"$log" || { docker rm -f "$name" >/dev/null 2>&1; echo "the settings line is missing: ${log//$'\n'/ | }"; return 1; }
  grep -qx 'socket: backlog=4096 tcp_nodelay=1' <<<"$log" || { docker rm -f "$name" >/dev/null 2>&1; echo "the socket line is missing: ${log//$'\n'/ | }"; return 1; }
  out="$(docker exec "$name" php -r '
    $c = []; for ($i = 0; $i < 300; $i++) { $c[] = stream_socket_client("tcp://127.0.0.1:18177"); }
    foreach ($c as $fp) { fwrite($fp, "GET /nope HTTP/1.1\r\n\r\n"); }
    foreach ($c as $fp) { $first = fgets($fp); if ($first !== "HTTP/1.1 404 Not Found\r\n") { echo "bad answer: $first"; } }
    echo "descriptors: " . count(scandir("/proc/self/fd")) . "\n";
    echo "ring descriptors: " . (int) shell_exec("ls -l /proc/1/fd | grep -c anon_inode:.io_uring.") . "\n";
    echo "server descriptors: " . (int) shell_exec("ls /proc/1/fd | wc -l") . "\n";
    $r = stream_socket_client("tcp://127.0.0.1:18177"); fwrite($r, "POST /posts HTTP/1.1\r\nContent-Length: 2\r\n\r\n{}"); echo "post: " . trim(fgets($r)) . "\n";')"
  sleep 2.5
  log="$(docker logs "$name" 2>&1)"
  docker rm -f "$name" >/dev/null 2>&1
  grep -qx 'ring descriptors: 1' <<<"$out" || { echo "the server holds no io_uring ring (or more than one): ${out//$'\n'/ | }"; return 1; }
  grep -q '^bad answer' <<<"$out" && { echo "an unknown route is not a 404: ${out//$'\n'/ | }"; return 1; }
  [ "$(sed -n 's/^server descriptors: //p' <<<"$out")" -lt 20 ] || { echo "the server process holds 20 descriptors or more with 300 connections open: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'post: HTTP/1.1 401 Unauthorized' <<<"$out" || { echo "a POST without a token is not a 401: ${out//$'\n'/ | }"; return 1; }
  grep -q '^ring: turns=[0-9]* requests=[0-9]* .* requests_per_turn=[0-9.]* ' <<<"$log" || { echo "the ring: line is missing: ${log//$'\n'/ | }"; return 1; }
}

# A request cut in two at every byte boundary of its first 64 bytes (a GET, and a POST with a body) is answered as the whole request is, and not before
# its second part comes; 16 requests in one packet, and a mix of statuses, are answered in order. The server's counters agree with the 1,000-odd
# requests made.
check_ring_splits_and_pipelines() {
  local name=lab-check-ring out
  ring_start "$name" 18177 || { docker rm -f "$name" >/dev/null 2>&1; return 1; }
  out="$(ring_client_ok "$name" 18177 split 2)" || { docker rm -f "$name" >/dev/null 2>&1; echo "$out"; return 1; }
  out="$(ring_client_ok "$name" 18177 pipeline 2)" || { docker rm -f "$name" >/dev/null 2>&1; echo "$out"; return 1; }
  docker rm -f "$name" >/dev/null 2>&1
}

# The feed made larger than a send slot (20 posts of 500 two-byte characters, over 20 KB) comes whole, then 8 of them pipelined and read in pieces of
# 1,000 bytes, then 300 of them (6 MB, more than the server keeps waiting for one connection) read slowly: all in order, all the same bytes. A client that
# leaves with 1,000 feeds unread frees what it held (no send slot or connection left in use) and the next client is answered.
check_ring_oversize_responses() {
  local name=lab-check-ring out
  ring_start "$name" 18177 || { docker rm -f "$name" >/dev/null 2>&1; return 1; }
  out="$(ring_client_ok "$name" 18177 big 3)" || { docker rm -f "$name" >/dev/null 2>&1; echo "$out"; return 1; }
  out="$(ring_client_ok "$name" 18177 midclose 1)" || { docker rm -f "$name" >/dev/null 2>&1; echo "$out"; return 1; }
  sleep 2.5
  out="big_sends=$(ring_sum "$name" big_sends) short_sends=$(ring_sum "$name" short_sends) stalls=$(ring_sum "$name" stalls) slots=$(ring_last "$name" slots_in_use) open=$(ring_last "$name" open)"
  docker rm -f "$name" >/dev/null 2>&1
  [[ "$out" =~ big_sends=([0-9]+)\ short_sends=([0-9]+)\ stalls=([0-9]+)\ slots=([0-9]+)\ open=([0-9]+) ]] || { echo "the ring: lines are missing: $out"; return 1; }
  [ "${BASH_REMATCH[1]}" -gt 6 ] || { echo "the oversize responses did not take the sized mappings (big_sends): $out"; return 1; }
  [ "${BASH_REMATCH[2]}" -gt 0 ] || { echo "no send was short, so the resubmission was not exercised (short_sends): $out"; return 1; }
  [ "${BASH_REMATCH[3]}" -gt 0 ] || { echo "no connection reached the write limit, so the stall was not exercised (stalls): $out"; return 1; }
  [ "${BASH_REMATCH[4]}" = 0 ] && [ "${BASH_REMATCH[5]}" = 0 ] || { echo "a slot or a connection is still in use after every client left: $out"; return 1; }
}

# A server with 2 receive buffers and 1 send slot, and 300 connections that each send 3 requests at once: the receive pool runs dry (the kernel ends
# receives with ENOBUFS) and the loop re-arms them, the send pool is full and connections wait for a slot, and every answer still comes, in order.
check_ring_pools_run_dry() {
  local name=lab-check-ring out
  ring_start "$name" 18177 URING_RECV_BUFFERS=2 URING_SEND_SLOTS=1 || { docker rm -f "$name" >/dev/null 2>&1; return 1; }
  out="$(ring_client_ok "$name" 18177 many 1)" || { docker rm -f "$name" >/dev/null 2>&1; echo "$out"; return 1; }
  sleep 2.5
  out="recv_dry=$(ring_sum "$name" recv_dry) send_waits=$(ring_sum "$name" send_waits) slots=$(ring_last "$name" slots_in_use)"
  docker rm -f "$name" >/dev/null 2>&1
  [[ "$out" =~ recv_dry=([0-9]+)\ send_waits=([0-9]+)\ slots=([0-9]+) ]] || { echo "the ring: lines are missing: $out"; return 1; }
  [ "${BASH_REMATCH[1]}" -gt 0 ] || { echo "the receive pool never ran dry: $out"; return 1; }
  [ "${BASH_REMATCH[2]}" -gt 0 ] || { echo "no connection waited for a send slot: $out"; return 1; }
  [ "${BASH_REMATCH[3]}" = 0 ] || { echo "a send slot is still in use after every client left: $out"; return 1; }
}

# The soft connection limit on the ring, as on the DIY loop (check_soft_limit_closes_the_third_connection): with a limit of 2, three keep-alive
# connections opened one after the other: the first two answer as always and stay open, the third answers with Connection: close and is ended.
check_ring_soft_limit() {
  local name=lab-check-ring seq
  ring_start "$name" 18177 APP_SOFT_CONN_LIMIT=2 || { docker rm -f "$name" >/dev/null 2>&1; return 1; }
  seq="$(docker exec "$name" php /lab/check/conn-client.php 18177 seq 3 --keep)"
  docker rm -f "$name" >/dev/null 2>&1
  jq -e '.answered == 3 and .errors == [] and .connections == [{close_header: false, server_closed: false}, {close_header: false, server_closed: false}, {close_header: true, server_closed: true}]' <<<"$seq" >/dev/null \
    || { echo "expected the first two kept and the third closed with the header: $seq"; return 1; }
}

# What the ring answers is what the DIY loop answers, byte for byte: 30 raw requests (valid, refused, malformed, HTTP/1.0, Connection: close,
# pipelined behind a close, a head over 8 KiB) to both servers, each on a fresh copy of the seed: the same bytes back, the same connections closed.
check_ring_answers_like_diy() {
  local ring=lab-check-ring diy=lab-check-ring-diy out
  start_app_for_check "$diy" 18178 0 || { docker rm -f "$diy" >/dev/null 2>&1; return 1; }
  ring_start "$ring" 18177 || { docker rm -f "$ring" "$diy" >/dev/null 2>&1; return 1; }
  out="$(ring_client_ok "$ring" 18177 compare 1 18178)" || { docker rm -f "$ring" "$diy" >/dev/null 2>&1; echo "$out"; return 1; }
  docker rm -f "$ring" "$diy" >/dev/null 2>&1
}

# The ring in the step lab, a pair with the DIY loop's reference and `--seccomp-unconfined` on both sides: the runs' JSON say `epoll` and `ring, 1 ring`
# (`server.loop`), `server.ring` holds what the ring counted (the step lab turns the telemetry off unless the variant sets it), `--expect-loop` lets the right lines through, and a wrong one for the ring (`epoll`, what a
# ring that fell back to the DIY loop would print) stops the comparison with exit 1 and the line it got.
check_ring_loop_line_in_runs() {
  local out rc=0 dir
  dir="$(mktemp -d)"
  out="$(bash "$LAB/steplab.sh" --image 8.5 --rate 200 --think-scale 0.1 --seconds 5 --pairs 1 --warmup 20,5 --seccomp-unconfined --ext sockets --ext event \
    --variant ref= --variant ring=APP_RING=1,APP_TELEMETRY=1 --expect-loop ref=epoll --expect-loop 'ring=ring, 1 ring' --out "$dir/right" 2>&1)" || rc=$?
  [ "$rc" = 0 ] && [ "$(jq -r '.server.loop' "$dir/right/ref-1.json")" = epoll ] && [ "$(jq -r '.server.loop' "$dir/right/ring-1.json")" = 'ring, 1 ring' ] \
    && jq -e '.server.ring.requests > 0 and .server.ring.turns > 0 and .server.ring.requests_per_turn > 0' "$dir/right/ring-1.json" >/dev/null \
    || { rm -rf "$dir"; echo "the right loop lines did not pass, or are not in the JSON (exit $rc): ${out//$'\n'/ | }"; return 1; }
  rc=0
  out="$(bash "$LAB/steplab.sh" --image 8.5 --rate 200 --think-scale 0.1 --seconds 5 --pairs 1 --warmup 20,5 --seccomp-unconfined --ext sockets --ext event \
    --variant ref= --variant ring=APP_RING=1,APP_TELEMETRY=1 --expect-loop ref=epoll --expect-loop ring=epoll --out "$dir/wrong" 2>&1)" || rc=$?
  rm -rf "$dir"
  [ "$rc" = 1 ] && grep -q "the server's loop line is 'ring, 1 ring', which does not contain 'epoll'" <<<"$out" || { echo "a wrong loop line for the ring did not stop the run (exit $rc): ${out//$'\n'/ | }"; return 1; }
}

# lab/stress.sh --path /posts/{id} on the app on the ring: random posts of the seed, one request at a time and pipelined, each response the one of its
# request, in order, 0 lost; and against a server that answers the wrong post it finds the mismatches (exit 1) and removes its containers.
check_ring_stress_posts() {
  local out rc=0 left
  out="$(bash "$LAB/stress.sh" --image 8.5 --server "$LAB/app/server.php" --ext sockets --seccomp-unconfined --app --env APP_RING=1 --env APP_TELEMETRY=1 --path '/posts/{id}' \
    --connections 100 --requests 20000 --procs 2 --pipelines 1,16 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/stress.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  [ "$(grep -c '^ok    pipeline=.*"matched":20000,"mismatches":0,"lost":0' <<<"$out")" = 2 ] || { echo "not two clean runs of 20,000: ${out//$'\n'/ | }"; return 1; }
  grep -q '^last busy second of the server: turns=[0-9]* requests=[0-9]* .*requests_per_turn=[0-9.]*' <<<"$out" || { echo "the server's statistics line is missing: ${out//$'\n'/ | }"; return 1; }
  rc=0
  out="$(bash "$LAB/stress.sh" --image 8.5 --server "$LAB/check/fixtures/wrong-post.php" --path '/posts/{id}' --connections 10 --requests 500 --procs 1 --pipelines 1 2>&1)" || rc=$?
  [ "$rc" = 1 ] || { echo "against the wrong-post server lab/stress.sh exited $rc, expected 1: ${out//$'\n'/ | }"; return 1; }
  grep -q '^FAIL  pipeline=1: .*"mismatches":[1-9]' <<<"$out" || { echo "no mismatch reported against the wrong-post server: ${out//$'\n'/ | }"; return 1; }
  left="$(docker ps -a --format '{{.Names}}' | grep '^lab-stress-' || true)"
  [ -z "$left" ] || { echo "containers left behind: ${left//$'\n'/ }"; return 1; }
}

# ring_max <container> <field>: the largest value of a field over the `ring:` lines (for `ring1_open`: the most connections the ring held in any second).
ring_max() {
  docker logs "$1" 2>&1 | grep '^ring: ' | grep -o " $2=[0-9]*" | cut -d= -f2 | sort -n | tail -n 1
}

# APP_RINGS is a whole number from 1 to 4: 0, 5, text and a negative number are refused with a message that says so and exit code 1, and without
# APP_RING=1 the switch is refused too (it would do nothing, and a run that thinks it measures three rings would measure the DIY loop).
check_rings_refusals() {
  local out v
  out="$(bash "$LAB/run.sh" 8.5 sh -c '
    for v in APP_RINGS=0 APP_RINGS=5 APP_RINGS=two APP_RINGS=-1; do
      echo "== $v"
      env SQLITE_PATH=/nonexistent JWT_SECRET=x APP_RING=1 "$v" php -d extension=sockets /lab/app/server.php 2>&1
      echo "exit $?"
    done
    echo "== no ring"
    env SQLITE_PATH=/nonexistent JWT_SECRET=x APP_RINGS=2 php -d extension=sockets /lab/app/server.php 2>&1
    echo "exit $?"' 2>&1)" || { echo "the run failed: ${out//$'\n'/ | }"; return 1; }
  for v in APP_RINGS=0 APP_RINGS=5 APP_RINGS=two APP_RINGS=-1; do
    grep -A2 -x "== $v" <<<"$out" | grep -q "^ring-server: APP_RINGS must be a whole number from 1 to 4, got '${v#*=}'" || { echo "$v is not refused with a reason: ${out//$'\n'/ | }"; return 1; }
    grep -A2 -x "== $v" <<<"$out" | grep -qx 'exit 1' || { echo "$v does not exit with 1: ${out//$'\n'/ | }"; return 1; }
  done
  grep -A2 -x '== no ring' <<<"$out" | grep -qx 'server: APP_RINGS needs APP_RING=1' || { echo "APP_RINGS without APP_RING is not refused: ${out//$'\n'/ | }"; return 1; }
}

# The soft limit counts every ring's connections together: 2 rings with a table of 80 (each pauses its accept at 64, so 101 connections fill the
# first ring and spill to the second), a limit of 100: the first 100 connections answer as always and stay open, the 101st answers with
# Connection: close and is ended, 0 errors, and the server counted exactly one such close. Without the shared count each ring would see at most
# 64 open and never close. The boot line says `ring, 2 rings`.
check_rings_soft_limit_across_rings() {
  local name=lab-check-rings seq log
  ring_start "$name" 18177 APP_RINGS=2 URING_TABLE_SIZE=80 APP_SOFT_CONN_LIMIT=100 || { docker rm -f "$name" >/dev/null 2>&1; return 1; }
  seq="$(docker exec "$name" php /lab/check/conn-client.php 18177 seq 101 --keep --hold 2.5)"
  log="$(docker logs "$name" 2>&1)"
  docker rm -f "$name" >/dev/null 2>&1
  grep -qx 'loop: ring, 2 rings' <<<"$log" || { echo "the loop line is not 'loop: ring, 2 rings': ${log//$'\n'/ | }"; return 1; }
  jq -e '.answered == 101 and .errors == [] and (.connections | length) == 101
    and ([.connections[:100][] | .close_header or .server_closed] | any | not) and .connections[100] == {close_header: true, server_closed: true}' <<<"$seq" >/dev/null \
    || { echo "expected 100 kept open and the 101st closed with the header, no errors: $(jq -c '{answered, close_header, server_closed, kept_alive, errors}' <<<"$seq")"; return 1; }
  [ "$(grep '^ring: ' <<<"$log" | grep -o ' limit_closes=[0-9]*' | cut -d= -f2 | awk '{s += $1} END {print s + 0}')" = 1 ] || { echo "the ring: lines do not count exactly one limit close: ${log//$'\n'/ | }"; return 1; }
  [ "$(grep '^ring: ' <<<"$log" | grep -o ' ring1_open=[0-9]*' | cut -d= -f2 | sort -n | tail -n 1)" -gt 0 ] || { echo "the connections never reached the second ring, so the limit was not counted across rings: ${log//$'\n'/ | }"; return 1; }
}

# The loop blocks on the ring that had completions in its last turn, not always on the first. 90 idle connections over 2 rings of 80 (the first fills to
# its accept limit of 64) put the last connection on the second ring; 30,000 requests one at a time over it must be answered, each by its own
# post's answer, while the first ring is hardly entered: on any `ring:` line of a second that served 1,000 requests or more on ring 1, ring 0 had
# at most 100 turns (a loop that waits on ring 0 enters it 2,000 times a second, once per 500 µs of its wait).
check_rings_loop_follows_the_active_ring() {
  local name=lab-check-rings out line busy=0 turns0
  ring_start "$name" 18177 APP_RINGS=2 URING_TABLE_SIZE=80 || { docker rm -f "$name" >/dev/null 2>&1; return 1; }
  out="$(docker exec "$name" php -d extension=sockets /lab/check/ring-client.php 18177 follow 90 30000 2>&1)" || { docker rm -f "$name" >/dev/null 2>&1; echo "ring-client follow failed: ${out//$'\n'/ | }"; return 1; }
  while IFS= read -r line; do
    [[ "$line" =~ ring1_requests=([0-9]+) ]] || continue
    [ "${BASH_REMATCH[1]}" -ge 1000 ] || continue
    [[ "$line" =~ ring0_turns=([0-9]+) ]] || continue
    turns0="${BASH_REMATCH[1]}"
    busy=$((busy + 1))
    [ "$turns0" -le 100 ] || { docker rm -f "$name" >/dev/null 2>&1; echo "ring 0 had $turns0 turns in a second that served ring 1: $line"; return 1; }
  done < <(docker logs "$name" 2>&1 | grep '^ring: ')
  [ "$(ring_max "$name" ring0_open)" -gt 0 ] && [ "$(ring_max "$name" ring1_open)" -gt 0 ] && [ "$(ring_sum "$name" ring0_requests)" = 0 ] || { docker rm -f "$name" >/dev/null 2>&1; echo "the idle connections did not span both rings, or ring 0 served requests"; return 1; }
  docker rm -f "$name" >/dev/null 2>&1
  [ "$busy" -gt 0 ] && grep -q '^ok    ' <<<"$out" || { echo "no second of the statistics served 1,000 requests on ring 1 ($busy), or the client failed: ${out//$'\n'/ | }"; return 1; }
}

# A burst at a full table loses no connection. 2 rings with tables of 80; the server is stopped (SIGSTOP from outside the container) while 150
# connections are opened one right after the other and each sends its request, so that the whole burst is in the listen backlog when it runs again.
# Then the two rings hold them between them (80 at most each), every one is answered with its own post's answer within 1 s, and the server never
# prints an accept failure. A ring that accepted past its table lost the connection that found no slot (ENFILE) and left the ones behind it in the
# backlog until another connection came; so does one that arms more accepts than it has free slots.
check_rings_burst_at_a_full_table() {
  local name=lab-check-rings out log r0 r1 file pid rc=0
  ring_start "$name" 18177 APP_RINGS=2 URING_TABLE_SIZE=80 || { docker rm -f "$name" >/dev/null 2>&1; return 1; }
  file="$(mktemp)"
  docker kill --signal=STOP "$name" >/dev/null
  docker exec "$name" php -d extension=sockets /lab/check/ring-client.php 18177 burst 150 >"$file" 2>&1 &
  pid=$!
  sleep 0.5
  docker kill --signal=CONT "$name" >/dev/null
  wait "$pid" || rc=$?
  out="$(cat "$file")"
  rm -f "$file"
  log="$(docker logs "$name" 2>&1)"
  docker rm -f "$name" >/dev/null 2>&1
  [ "$rc" = 0 ] && grep -q '^ok    ' <<<"$out" || { echo "the burst was not answered (exit $rc): ${out//$'\n'/ | }"; return 1; }
  ! grep -q 'accept failed' <<<"$log" || { echo "an accept failed: $(grep 'accept failed' <<<"$log" | head -n 1)"; return 1; }
  r0="$(grep '^ring: ' <<<"$log" | grep -o ' ring0_open=[0-9]*' | cut -d= -f2 | sort -n | tail -n 1)"
  r1="$(grep '^ring: ' <<<"$log" | grep -o ' ring1_open=[0-9]*' | cut -d= -f2 | sort -n | tail -n 1)"
  [ "$r0" -le 80 ] && [ "$r1" -le 80 ] && [ $((r0 + r1)) = 150 ] || { echo "the two rings did not hold the 150 connections between them, 80 at most each: ring 0 $r0, ring 1 $r1"; return 1; }
}

# The fallback. Under Docker's default seccomp filter the kernel refuses io_uring_setup (EPERM): the server prints `loop: epoll (io_uring refused:
# setup 1)` and serves on the DIY loop with 2 worker processes and a soft limit of 64,000 each (what the submission is), and passes the challenge's
# 42 checks there. Then the same fallback for a step after the setup, on the last of 3 rings (a test hook asks the kernel for a buffer ring of 0
# entries, which it refuses with EINVAL; and likewise a table of 0 files): the line names the step and 22, the rings built before are given back
# (no ring left in the process), and it serves.
check_rings_fall_back_to_epoll() {
  local name=lab-check-rings log out step
  CHECK_APP_EXT_EXTRA=pcntl LAB_SERVER_SECCOMP_UNCONFINED="" start_app_for_check "$name" 18177 0 APP_RING=1 APP_RINGS=3 || { docker rm -f "$name" >/dev/null 2>&1; return 1; }
  log="$(docker logs "$name" 2>&1)"
  docker rm -f "$name" >/dev/null 2>&1
  grep -qx 'loop: epoll (io_uring refused: setup 1)' <<<"$log" && grep -q '^workers: 2 ' <<<"$log" && grep -qx 'soft connection limit: 64000 per process' <<<"$log" \
    || { echo "under the default seccomp filter the boot lines are not the fallback's: ${log//$'\n'/ | }"; return 1; }
  out="$(bash "$LAB/challenge-test.sh" --image 8.5 --ext pcntl --ext sockets --ext event --env APP_RING=1 --env APP_RINGS=3 2>&1)" || { echo "the challenge's suite did not pass on the fallback: $(tail -n 5 <<<"$out" | tr '\n' ' ')"; return 1; }
  grep -qx 'passed=42 failed=0' <<<"$out" || { echo "not 42 of 42 on the fallback: $(tail -n 3 <<<"$out" | tr '\n' ' ')"; return 1; }
  for step in buffer_ring files; do
    CHECK_APP_EXT_EXTRA=pcntl LAB_SERVER_SECCOMP_UNCONFINED=1 start_app_for_check "$name" 18177 0 APP_RING=1 APP_RINGS=3 URING_FAIL_STEP=$step || { docker rm -f "$name" >/dev/null 2>&1; return 1; }
    log="$(docker logs "$name" 2>&1)"
    out="ring descriptors: $(docker exec "$name" sh -c 'ls -l /proc/1/fd | grep -c anon_inode:.io_uring.' || true)"
    docker rm -f "$name" >/dev/null 2>&1
    grep -qx "loop: epoll (io_uring refused: $step 22)" <<<"$log" || { echo "a refused $step is not the fallback's line: ${log//$'\n'/ | }"; return 1; }
    [ "$out" = 'ring descriptors: 0' ] || { echo "the rings built before the refused $step are still open in the supervisor: $out"; return 1; }
  done
}

# Several rings in the step lab: a pair of the DIY reference and the app on 2 rings with a smaller `nofile` for that variant only (`--variant-args
# ring='--server-nofile 32768'`): the runs' JSON say `ring, 2 rings`, `server.nofile` 32768 on the ring and 65535 on the reference, and `server.ring.per_ring`
# has the two rings' open connections, turns and requests.
check_rings_in_steplab() {
  local out rc=0 dir
  dir="$(mktemp -d)"
  out="$(bash "$LAB/steplab.sh" --image 8.5 --rate 200 --think-scale 0.1 --seconds 5 --pairs 1 --warmup 20,5 --seccomp-unconfined --ext sockets --ext event \
    --variant ref= --variant ring=APP_RING=1,APP_RINGS=2,APP_TELEMETRY=1 --variant-args 'ring=--server-nofile 32768' \
    --expect-loop ref=epoll --expect-loop 'ring=ring, 2 rings' --out "$dir/pair" 2>&1)" || rc=$?
  [ "$rc" = 0 ] && [ "$(jq -r '.server.loop' "$dir/pair/ring-1.json")" = 'ring, 2 rings' ] && [ "$(jq -r '.server.nofile' "$dir/pair/ring-1.json")" = 32768 ] \
    && [ "$(jq -r '.server.nofile' "$dir/pair/ref-1.json")" = 65535 ] \
    && jq -e '(.server.ring.per_ring | length == 2) and ((.server.ring.per_ring | map(.requests) | add) > 0)' "$dir/pair/ring-1.json" >/dev/null \
    || { echo "the pair's JSON do not show 2 rings and the variant's nofile (exit $rc): ${out//$'\n'/ | }"; rm -rf "$dir"; return 1; }
  rm -rf "$dir"
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
  check_micro_ffi_bench
  check_micro_feed_bench
  check_micro_parse_bench
  check_micro_skips_failed_case
  check_micro_skips_case_failing_in_later_process
  check_micro_refuses_wrong_state
  check_macro_noop_is_valid
  check_macro_marks_invalid_run
  check_macro_cleans_up_after_failure
  check_conformance_bake_swoole
  check_conformance_fails_on_wrong_server
  check_results_hold_no_container_names
  check_macro_bake_swoole_posts_is_valid
  check_conns_holds_steps
  check_conns_finds_ceiling
  check_conns_back_to_back
  check_workerman_caches
  check_conformance_bake_workerman
  check_workerman_server_refuses
  check_macro_bake_workerman_posts_is_valid
  check_diy_parser
  check_diy_partial_write
  check_diy_soft_limit
  check_conformance_bake_diy
  check_macro_bake_diy_posts_is_valid
  check_uring_noop_conformance
  check_uring_noop_stress
  check_stress_fails_on_wrong_echo
  check_uring_noop_holds_connections_without_fds
  check_app_cases
  check_app_variants_cases
  check_challenge_test_passes_on_app
  check_challenge_test_fails_on_wrong_golden
  check_challenge_test_passes_with_soft_limit_zero
  check_challenge_test_passes_each_s6_variant
  check_s6_switches_reach_the_server
  check_app_ffi_cases
  check_app_driver_reaches_the_server
  check_challenge_test_passes_with_exclusive_locking
  check_app_locking_reaches_the_server
  check_app_locking_removes_the_lock_calls
  check_diy_group_commit
  check_diy_loop_presets
  check_challenge_test_passes_with_loop_presets
  check_app_loop_reaches_the_server
  check_app_group_commit_cases
  check_challenge_test_passes_with_group_commit_and_checkpointer
  check_app_workers_cases
  check_challenge_test_passes_with_workers
  check_app_workers_in_a_container
  check_lab_hook_accepts_submissions
  check_submission
  check_submission_catches_violations
  check_submission_cases
  check_submission_install_stops_on_wrong_sha256
  check_submission_passes_challenge_test
  check_submission_both_workers_answer
  check_submission_default_host_and_port
  check_soft_limit_closes_the_third_connection
  check_soft_limit_keeps_idle_connections
  check_soft_limit_serves_churn_at_256_fds
  check_hard_fd_limit_pauses_accepts
  check_aggregate_cases
  check_series_cases
  check_telemetry_cases
  check_realistic_script_is_the_benchs
  check_replay_keeps_up
  check_realistic_staircase_passes
  check_realistic_no_series
  check_realistic_stops_at_a_failing_step
  check_realistic_refuses_vus_above_the_cap
  check_realistic_vu_cap_is_bound_by
  check_realistic_marks_invalid_run
  check_realistic_cleans_up_after_failure
  check_realistic_calibrates
  check_cold_start_evicts_the_copy
  check_app_telemetry
  check_idle_client_hold_mode
  check_realistic_idle_run
  check_realistic_soft_limit_run
  check_realistic_workers_run
  check_realistic_idle_closed_by_the_server_fails
  check_macro_fresh_db_cold_per_second
  check_macro_cold_needs_fresh_db
  check_fold_cases
  check_excimer_calibration
  check_realistic_profile_smoke
  check_macro_profile
  check_steplab_verdicts
  check_steplab_order
  check_steplab_floor
  check_syscalls_table_parse
  check_time_wait_count
  check_cpu_layouts
  check_swoole_entries_are_unchanged
  check_php_ini_flags
  check_steplab_live
  check_steplab_cleans_up_after_failure
  check_host_cpu_share_parse
  check_host_fsync_probe
  check_stages_dry_run
  check_stages_stops_and_refuses
  check_stages_live
  check_syscalls_live
  check_syscalls_cleans_up_after_failure
  check_post_plan
  check_sqlite_tuned
  check_swoole_co
  check_steplab_expect_loop
  check_ring_refusals
  check_ring_boot
  check_ring_splits_and_pipelines
  check_ring_oversize_responses
  check_ring_pools_run_dry
  check_ring_soft_limit
  check_ring_answers_like_diy
  check_ring_loop_line_in_runs
  check_ring_stress_posts
  check_rings_refusals
  check_rings_soft_limit_across_rings
  check_rings_loop_follows_the_active_ring
  check_rings_burst_at_a_full_table
  check_rings_fall_back_to_epoll
  check_rings_in_steplab
  check_score
  check_score_unit
  check_score_server_setup_checks
  check_score_server_setup_modes
  check_score_server_setup_cap
  check_score_server_ctl
  check_score_server_ctl_sampler
  check_score_ctl_ssh
  check_score_k6_setup_check
  check_score_k6_setup_modes
  check_shellcheck
  check_shellcheck_catches_warning
  check_results_check_catches_drift
  check_results_regenerate
  check_public_guard
  check_public_guard_catches_leak
  check_public_guard_catches_aws_traces
  check_public_guard_catches_temp_folder
)

# Names given as arguments: only those checks (`bash lab/check.sh check_replay_keeps_up`).
[ "$#" -eq 0 ] || CHECKS=("$@")

failed=0
for check in "${CHECKS[@]}"; do
  if reason="$("$check")"; then
    # A check that prints `skip: <why>` and returns 0 had nothing to run (a missing image): it is shown as `skip`, not as `ok`.
    case "$reason" in
      "skip: "*) echo "skip  $check: ${reason#skip: }" ;;
      *) echo "ok    $check" ;;
    esac
  else
    echo "FAIL  $check: $reason"
    failed=1
  fi
done
exit "$failed"
