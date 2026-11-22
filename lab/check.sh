#!/usr/bin/env bash
# The lab's smoke suite: one line per check, `ok` or `FAIL: <reason>`, exit non-zero if any check fails.
#
#   bash lab/check.sh
#
# To add a check: write a function `check_<name>` that returns 0 or prints a reason on stdout and returns 1,
# then add its name to CHECKS.
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

# check_source_extras <variant>: pcntl, sockets and Workerman 5.2.4 (both trees) are in the image; ext-event is there, or
# `not built` when lab/lib.sh says this variant is built without it. The phase-2 lines are checked by check_source_image.
check_source_extras() {
  local v="$1" with_event info
  read -r _ _ _ with_event <<<"$(lab_source_release "$v")"
  info="$(bash "$LAB/run.sh" "$v" php-info 2>&1)" || { echo "php-info failed: $info"; return 1; }
  grep -qx 'pcntl: present' <<<"$info" || { echo "pcntl is not present: ${info//$'\n'/ | }"; return 1; }
  grep -qx 'sockets: present' <<<"$info" || { echo "sockets is not present: ${info//$'\n'/ | }"; return 1; }
  if [ "$with_event" = 1 ]; then
    grep -qx 'event: 3.2.0' <<<"$info" || { echo "php-info does not report 'event: 3.2.0': ${info//$'\n'/ | }"; return 1; }
  else
    grep -qx 'event: not built' <<<"$info" || { echo "php-info does not report 'event: not built': ${info//$'\n'/ | }"; return 1; }
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

# The bake-off server under k6 on /posts/<id>, with --env, --label and the default file name: the run is valid, the JSON holds
# what the options said (extension, env, label, the server's socket line), the other containers and the memory under load.
check_macro_bake_swoole_posts_is_valid() {
  local out rc=0 json holds="" detail=""
  out="$(bash "$LAB/macro.sh" --image 8.5 --server "$LAB/servers/bake-swoole.php" --rate 500 --duration 5 --warmup 2 \
    --script "$LAB/macro/k6/posts.js" --path /posts/1 --env FOO=bar --label test 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "lab/macro.sh exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -qx 'VALID' <<<"$out" || { echo "the run is not marked VALID: ${out//$'\n'/ | }"; return 1; }
  json="$REPO/$(sed -n 's/^wrote //p' <<<"$out")"
  [ -f "$json" ] || { echo "no JSON file at $json: ${out//$'\n'/ | }"; return 1; }
  jq -e '.valid == true and .results.requests > 2000 and .results.error_rate == 0
         and .label == "test" and .server.ext == ["swoole"] and .server.env == ["FOO=bar"]
         and .server.socket == {backlog: 4096, tcp_nodelay: 1}
         and (.other_containers.count == (.other_containers.names | length))
         and (.other_containers.names | map(startswith("lab-macro-")) | any | not)
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
  [ "$ok" = 57 ] || { echo "expected 57 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
  grep -q 'FAIL' <<<"$out" && { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
  return 0
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

# The aggregator's library on rows copied from a real k6 run: the histogram error, the percentiles of a known set, the rows it keeps,
# a plateau found from k6's `vus` rows, a step's numbers and verdict (the 97 % rule included).
check_aggregate_cases() {
  local out ok rc=0
  out="$(bash "$LAB/run.sh" 8.5 php /lab/check/aggregate-test.php 2>&1)" || rc=$?
  [ "$rc" = 0 ] || { echo "aggregate-test.php exited $rc: ${out//$'\n'/ | }"; return 1; }
  grep -q '^FAIL' <<<"$out" && { echo "a case failed: ${out//$'\n'/ | }"; return 1; }
  ok="$(grep -c '^ok  ' <<<"$out")"
  [ "$ok" -ge 45 ] || { echo "expected at least 45 ok cases, got $ok: ${out//$'\n'/ | }"; return 1; }
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
  local out rc=0 json detail left
  json="$(mktemp -d)/realistic.json"
  out="$(bash "$LAB/realistic.sh" --image 8.5 --think-scale 0.1 --staircase 50,50,150,8 --label test --out "$json" 2>&1)" || rc=$?
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
         and (.other_containers.count == (.other_containers.names | length))
         and (.other_containers.names | map(startswith("lab-realistic-")) | any | not)
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

# A step above the capacity of the server fails on the 97 % rule, and the staircase stops there: against a server that spends 4 ms per
# request (about 190 req/s at most), 60 req/s passes and 300 req/s does not.
check_realistic_stops_at_a_failing_step() {
  local out rc=0 json detail
  json="$(mktemp -d)/realistic.json"
  out="$(bash "$LAB/realistic.sh" --image 8.5 --server "$LAB/check/fixtures/slow-app.php" --think-scale 0.1 --staircase 60,240,300,8 --out "$json" 2>&1)" || rc=$?
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
  check_conformance_bake_swoole
  check_conformance_fails_on_wrong_server
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
  check_conformance_bake_diy
  check_macro_bake_diy_posts_is_valid
  check_app_cases
  check_challenge_test_passes_on_app
  check_challenge_test_fails_on_wrong_golden
  check_aggregate_cases
  check_realistic_script_is_the_benchs
  check_replay_keeps_up
  check_realistic_staircase_passes
  check_realistic_stops_at_a_failing_step
  check_realistic_refuses_vus_above_the_cap
  check_realistic_marks_invalid_run
  check_realistic_cleans_up_after_failure
  check_realistic_calibrates
  check_shellcheck
  check_shellcheck_catches_warning
)

# Names given as arguments: only those checks (`bash lab/check.sh check_replay_keeps_up`).
[ "$#" -eq 0 ] || CHECKS=("$@")

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
