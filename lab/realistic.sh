#!/usr/bin/env bash
# Loads the challenge app the way the challenge's bench does: k6 runs the bench's own journey (lab/macro/k6/realistic.js, a copy of
# its bench/load.js: the feed, a post from it, 15 % like, 2 % new post, think time between) with the think times scaled down, so that
# a few thousand VUs make the request rate the bench's many more make. A staircase of load steps or one hold, each step judged the
# way the bench would (latency and errors) plus one rule the scaled think time needs: the achieved rate must reach 97 % of the offered.
#
#   bash lab/realistic.sh --image 8.5 --think-scale 0.1 --staircase 100,100,400,20     # req/s: from, step, to, seconds per plateau
#   bash lab/realistic.sh --image 8.5 --think-scale 0.1 --hold 200,300                  # req/s, seconds of the plateau
#   bash lab/realistic.sh --image 8.5 --think-scale 0.1 --calibrate                     # k6's memory per VU, the VU cap, the scale
#   bash lab/realistic.sh --image 8.5 --think-scale 0.0286 --idle 60000 --cold --staircase 100,100,400,20
#                         [--server <php file under lab/>] [--ext <name>]... [--env K=V]... [--label <text>]
#                         [--warmup <req/s>,<seconds>] [--vu-cap <n>] [--ramp <s>] [--out <path>] [--port <n>]
#                         [--local-ips <range>] [--lag-gate <s>] [--k6-memory <MiB>] [--calibrate-vus <a>,<b>] [--calibrate-seconds <s>]
#                         [--profile <collapsed stacks file>]
#
# The numbers of the journey: 2.17 requests per loop (1 + 1 + 0.15 + 0.02), 20.5 s of mean think time per loop (5 + 5.5 + 10), so one
# VU offers 2.17 / (20.5 * scale) req/s, and a steady load is 9.45 users per req/s (20.5 / 2.17). Users are always mapped from the
# achieved rate, never from the VUs.
#
# --idle <n> holds <n> idle keep-alive connections from before the first request to the end (the bench's thousands of users who sit on a
# connection): one client opens them one at a time, each with one GET /health, and at the end sweeps them for a close by the server. The
# count held at the start and at the end is in the table and the JSON; a connection the server closed makes the run INVALID. --cold starts
# the server on a copy of the seed whose pages were evicted from the page cache (what the page cache holds of it is read before the
# server opens it: `cold` in the JSON). The server runs with APP_TELEMETRY=1 unless --env sets it, and every run has its per-second series.
#
# --profile <file> runs the server with the Excimer profiler (CPU time, one sample every APP_PROFILE_PERIOD seconds, default 0.001: pass
# `--env APP_PROFILE_PERIOD=<s>` to change it; telemetry off unless --env sets it), copies the collapsed stacks to <file> when the load is over
# and prints the fold of lab/profile/fold.php (the table of steps S1 to S9 per endpoint) with the cgroup's user and system CPU of the same
# window. The window is the whole life of the server after its first answer: warm-up, ramps and plateaus. A profiled run is for the shape
# of the cost, never for a baseline: Excimer costs CPU, so the us/req printed is the profiled server's.
#
# Containers (all on the host network of Docker's VM, removed at the end whatever happens), started on a fresh copy of the seed:
#   server  php-lab:<image> running the app, 1 CPU, 2 GiB, the server CPU (lab/lib.sh);
#   idle    only with --idle: php-lab:<image> running lab/conns/client.php in its hold mode on the load CPUs;
#   k6      the pinned k6 image on the k6 CPUs, with a memory limit (the budget of the cap), writes its CSV into a FIFO;
#   agg     lab/macro/aggregate.php on the k6 CPUs: reads the FIFO, keeps per-second histograms, judges each step, reads the server's
#           and k6's cgroups on every whole second;
#   probe   on CPUs 0-1: reads memory and /proc from outside, and the aggregator's status file, once a second; one sampler loop
#           (lab/macro/sampler.php) takes the server's per-second readings (CPU, Pss_Anon, memory.current, WAL size and frames, fds,
#           page faults) for the series.
# Exit codes: 0 a valid run (a failing step is a result, not an error), 3 printed but INVALID (the aggregator fell behind, k6 reached
# its memory budget, a row could not be parsed), 2 usage (a VU count above the cap included), 1 any other failure.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$LAB")"
# shellcheck source=lib.sh
source "$LAB/lib.sh"
# shellcheck source=series.sh
source "$LAB/series.sh"
# shellcheck source=profile.sh
source "$LAB/profile.sh"

SERVER=lab-realistic-server
K6C=lab-realistic-k6
PROBE=lab-realistic-probe
AGG=lab-realistic-agg
IDLEC=lab-realistic-idle
VOLUME=lab-realistic-run

# The journey of lab/macro/k6/realistic.js (the bench's).
LOOP_REQUESTS=2.17
LOOP_THINK_S=20.5
USERS_PER_RPS=9.45
# What the idle connections of the next measurement leave of the server's file descriptors: 65,535 (the lab's nofile) minus 60,000 idle
# connections minus a margin for the server's own descriptors (about 13 at boot).
LAB_VU_CAP_FDS=5400
# The memory the idle client may take in the budget of k6's memory (MiB), and the file it ends on (the client holds until it exists).
LAB_IDLE_CLIENT_MIB=512
IDLE_END_FILE=/tmp/idle-end
# The pass rule of a step.
LIMIT_P95_MS=500
LIMIT_P99_MS=1000
LIMIT_ERROR_RATE=0.01
LIMIT_ACHIEVED_RATIO=0.97

usage() {
  cat >&2 <<'EOF'
usage: lab/realistic.sh --image <variant> (--staircase <from>,<step>,<to>,<s> | --hold <rate>,<s> | --calibrate) [--think-scale <s>]
                        [--server <php file under lab/>] [--ext <name>]... [--env K=V]... [--label <text>] [--warmup <rate>,<s>]
                        [--vu-cap <n>] [--ramp <s>] [--out <path>] [--port <n>] [--local-ips <range>] [--lag-gate <s>] [--k6-memory <MiB>]
                        [--calibrate-vus <a>,<b>] [--calibrate-seconds <s>] [--idle <n>] [--cold] [--profile <collapsed stacks file>]
rates are in req/s, <s> is the seconds of one plateau; --think-scale is the share of the bench's think time (default 1)
EOF
  exit 2
}
fail() { echo "realistic: $*" >&2; exit 1; }

command_line="lab/realistic.sh $*"
command_line="${command_line//$REPO/.}"

image=8.5 server_file="$LAB/app/server.php" label="" think_scale=1 warmup="" staircase="" hold="" calibrate="" vu_cap=""
profile_out=""
ramp="" out="" port=18120 local_ips="127.0.1.1-127.0.1.4" lag_gate=4 k6_memory="" calibrate_vus="50,300" calibrate_seconds=60 idle="" cold=""
LAB_EXT=() LAB_ENV=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --calibrate ]; then calibrate=1; shift; continue; fi
  if [ "$1" = --cold ]; then cold=1; shift; continue; fi
  [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; usage; }
  case "$1" in
    --image) image="$2" ;;
    --server) server_file="$2" ;;
    --ext) LAB_EXT+=("$2") ;;
    --env) LAB_ENV+=("$2") ;;
    --label) label="$2" ;;
    --think-scale) think_scale="$2" ;;
    --warmup) warmup="$2" ;;
    --staircase) staircase="$2" ;;
    --hold) hold="$2" ;;
    --vu-cap) vu_cap="$2" ;;
    --ramp) ramp="$2" ;;
    --out) out="$2" ;;
    --port) port="$2" ;;
    --local-ips) local_ips="$2" ;;
    --lag-gate) lag_gate="$2" ;;
    --k6-memory) k6_memory="$2" ;;
    --calibrate-vus) calibrate_vus="$2" ;;
    --calibrate-seconds) calibrate_seconds="$2" ;;
    --idle) idle="$2" ;;
    --profile) profile_out="$2" ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
  shift 2
done

modes=0
for m in "$staircase" "$hold" "$calibrate"; do [ -z "$m" ] || modes=$(( modes + 1 )); done
[ "$modes" -eq 1 ] || { echo "give exactly one of --staircase, --hold, --calibrate" >&2; usage; }
[ "${#LAB_EXT[@]}" -gt 0 ] || LAB_EXT=(sockets event)
for kv in "${LAB_ENV[@]+"${LAB_ENV[@]}"}"; do
  [[ "$kv" == ?*=* ]] || { echo "--env must be K=V, got '$kv'" >&2; usage; }
done
[[ -z "$label" || "$label" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "--label may only hold letters, digits, . _ and -, got '$label'" >&2; usage; }
number='^[0-9]+([.][0-9]+)?$'
[[ "$think_scale" =~ $number ]] && awk -v s="$think_scale" 'BEGIN { exit !(s > 0 && s <= 1) }' || { echo "--think-scale must be above 0 and at most 1, got '$think_scale'" >&2; usage; }
[[ "$lag_gate" =~ $number ]] || { echo "--lag-gate must be a number of seconds, got '$lag_gate'" >&2; usage; }
for n in port calibrate_seconds; do
  [[ "${!n}" =~ ^[0-9]+$ ]] || { echo "--${n//_/-} must be a whole number, got '${!n}'" >&2; usage; }
done
[ -z "$vu_cap" ] || [[ "$vu_cap" =~ ^[0-9]+$ ]] || { echo "--vu-cap must be a whole number, got '$vu_cap'" >&2; usage; }
[ -z "$ramp" ] || [[ "$ramp" =~ ^[0-9]+$ ]] || { echo "--ramp must be a whole number of seconds, got '$ramp'" >&2; usage; }
[ -z "$k6_memory" ] || [[ "$k6_memory" =~ ^[0-9]+$ ]] || { echo "--k6-memory must be a whole number of MiB, got '$k6_memory'" >&2; usage; }
[ -n "$vu_cap" ] || vu_cap="$LAB_VU_CAP_FDS"
[ -z "$idle" ] || [[ "$idle" =~ ^[1-9][0-9]*$ ]] || { echo "--idle must be a whole number above 0, got '$idle'" >&2; usage; }
[ -z "$idle" ] || [ -z "$calibrate" ] || { echo "--idle does not go with --calibrate (the calibration prices k6's VUs alone)" >&2; usage; }
[ -z "$profile_out" ] || [ -z "$calibrate" ] || { echo "--profile does not go with --calibrate" >&2; usage; }
# --profile loads Excimer, sets APP_PROFILE and turns the telemetry off unless the caller sets it (lab/profile.sh).
profile_prepare
profile_json=null   # profile_collect (lab/profile.sh) sets it
# Telemetry is on in every run unless the caller sets it (a later measurement compares on against off).
telemetry_set=""
for kv in "${LAB_ENV[@]+"${LAB_ENV[@]}"}"; do [[ "$kv" != APP_TELEMETRY=* ]] || telemetry_set=1; done
[ -n "$telemetry_set" ] || LAB_ENV+=(APP_TELEMETRY=1)

# vus_for <req/s>: the VUs that offer at least that rate: rate * 20.5 * scale / 2.17, rounded up.
vus_for() { awk -v r="$1" -v s="$think_scale" -v t="$LOOP_THINK_S" -v n="$LOOP_REQUESTS" 'BEGIN { v = r * t * s / n; printf "%d", (v == int(v)) ? v : int(v) + 1 }'; }
per_vu_rate="$(awk -v s="$think_scale" -v t="$LOOP_THINK_S" -v n="$LOOP_REQUESTS" 'BEGIN { printf "%.6f", n / (t * s) }')"
offered_for() { awk -v v="$1" -v p="$per_vu_rate" 'BEGIN { printf "%.3f", v * p }'; }

# steps_vus: the VU count of each step, one per line; plateau: seconds of one plateau.
steps_vus=()
plateau=""
if [ -n "$staircase" ]; then
  IFS=, read -r from step to plateau <<<"$staircase"
  for n in from step to plateau; do
    [[ "${!n:-}" =~ ^[0-9]+$ ]] && [ "${!n}" -ge 1 ] || { echo "--staircase wants <from>,<step>,<to>,<s>, whole numbers from 1, got '$staircase'" >&2; usage; }
  done
  [ "$to" -ge "$from" ] || { echo "--staircase: <to> is below <from>" >&2; usage; }
  rate="$from"
  while [ "$rate" -le "$to" ]; do
    steps_vus+=("$(vus_for "$rate")")
    rate=$(( rate + step ))
  done
elif [ -n "$hold" ]; then
  IFS=, read -r rate plateau <<<"$hold"
  for n in rate plateau; do
    [[ "${!n:-}" =~ ^[0-9]+$ ]] && [ "${!n}" -ge 1 ] || { echo "--hold wants <rate>,<s>, whole numbers from 1, got '$hold'" >&2; usage; }
  done
  steps_vus+=("$(vus_for "$rate")")
else
  IFS=, read -r cal_a cal_b <<<"$calibrate_vus"
  for n in cal_a cal_b; do
    [[ "${!n:-}" =~ ^[0-9]+$ ]] && [ "${!n}" -ge 1 ] || { echo "--calibrate-vus wants <a>,<b>, whole numbers from 1, got '$calibrate_vus'" >&2; usage; }
  done
  [ "$cal_b" -gt "$cal_a" ] || { echo "--calibrate-vus: <b> must be above <a>" >&2; usage; }
  [ "$calibrate_seconds" -ge 10 ] || { echo "--calibrate-seconds must be at least 10" >&2; usage; }
  plateau="$calibrate_seconds"
  steps_vus=("$cal_a" "$cal_b")
fi
if [ -z "$ramp" ]; then
  ramp=$(( (plateau + 3) / 4 ))
  [ "$ramp" -ge 2 ] || ramp=2
  [ "$ramp" -le 10 ] || ramp=10
fi
if [ -n "$warmup" ]; then
  IFS=, read -r warm_rate warm_seconds <<<"$warmup"
  for n in warm_rate warm_seconds; do
    [[ "${warm_rate:-}" =~ ^[0-9]+$ && "${warm_seconds:-}" =~ ^[0-9]+$ ]] || { echo "--warmup wants <rate>,<s>, got '$warmup'" >&2; usage; }
  done
fi
max_vus=0
for v in "${steps_vus[@]}"; do [ "$v" -le "$max_vus" ] || max_vus="$v"; done
if [ -z "$calibrate" ] && [ "$max_vus" -gt "$vu_cap" ]; then
  echo "realistic: $max_vus VUs are above the VU cap of $vu_cap (--vu-cap; lab/realistic.sh --calibrate prints the cap): refusing to start" >&2
  exit 2
fi

# Everything is checked before the first container starts.
lab_require_variant "$image" || exit 1
docker image inspect "$LAB_IMAGE:$image" >/dev/null 2>&1 || fail "image $LAB_IMAGE:$image is missing (run lab/build.sh $image)"
server_in="$(lab_in_container_path "$server_file")" || exit 1
[ -f "$LAB/data/feed.db" ] && [ -f "$LAB/data/tokens.json" ] || fail "lab/data/feed.db or tokens.json is missing (run lab/seed.sh)"
for c in "$SERVER" "$K6C" "$PROBE" "$AGG" "$IDLEC"; do
  if docker ps -a --format '{{.Names}}' | grep -x "$c" >/dev/null; then
    fail "a lab/realistic.sh run is in progress, or one was killed: remove its containers first (docker rm -f $SERVER $K6C $PROBE $AGG $IDLEC; docker volume rm $VOLUME)"
  fi
done
docker image inspect "$LAB_K6_IMAGE" >/dev/null 2>&1 || { echo "pulling $LAB_K6_IMAGE" >&2; docker pull -q "$LAB_K6_IMAGE" >/dev/null || fail "cannot pull $LAB_K6_IMAGE"; }

# The memory k6 may use: the VM's, minus 2 GiB for the server, what the client that holds the idle connections may take (LAB_IDLE_CLIENT_MIB,
# reserved whether or not --idle is given, so that runs with and without share one budget) and 1 GiB of margin. --k6-memory sets it by
# hand (a test hook: a budget k6 cannot live in).
vm_bytes="$(docker info --format '{{.MemTotal}}')"
k6_budget_mib=$(( vm_bytes / 1048576 - 2048 - LAB_IDLE_CLIENT_MIB - 1024 ))
[ -z "$k6_memory" ] || k6_budget_mib="$k6_memory"
[ "$k6_budget_mib" -gt 16 ] || fail "the VM has $(( vm_bytes / 1048576 )) MiB: not enough for a server (2 GiB), an idle client ($LAB_IDLE_CLIENT_MIB MiB), a margin (1 GiB) and k6"

stamp="$(date -u +%Y%m%d-%H%M%S)"
mode=staircase
[ -z "$hold" ] || mode=hold
[ -z "$calibrate" ] || mode=calibrate
if [ -z "$out" ]; then
  out="$LAB/results/realistic-$mode-$(basename "$server_file" .php)${label:+-$label}-$image-$stamp.json"
fi
mkdir -p "$LAB/results" "$(dirname "$out")"

tmp="$(mktemp -d)"
idle_pid=""
cleanup() {
  local rc=$?
  [ -z "$idle_pid" ] || kill "$idle_pid" 2>/dev/null || true
  docker rm -f "$SERVER" "$K6C" "$PROBE" "$AGG" "$IDLEC" >/dev/null 2>&1 || true
  docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

probe() { docker exec "$PROBE" bash /lab/macro/probe.sh "$@"; }
json_array() { jq -nc '$ARGS.positional' --args "$@"; }
lines_to_json() {
  jq -Rn 'reduce (inputs | split(" ") | select(length == 3)) as $l ({}; .[$l[0]][$l[1]] = ($l[2] | tonumber? // $l[2]))'
}

# --- the containers ---------------------------------------------------------------------------------------------------------
docker volume create "$VOLUME" >/dev/null
docker run -d --name "$PROBE" --network host --cgroupns host --pid host --cpuset-cpus "$LAB_CPUSET_PROBE" \
  -v "$LAB:/lab:ro" -v "$VOLUME:/run/rt" "$LAB_IMAGE:$image" sleep 86400 >/dev/null
if probe port-open "$port"; then
  fail "port $port is already in use on the VM's host network: pick another with --port"
fi
profile_check_image

lab_build_php_flags
# Why disable SC2034: lab_start_app (lib.sh) reads LAB_COLD; shellcheck does not follow lib.sh from the repo root.
# shellcheck disable=SC2034
LAB_COLD="${cold:-0}"
lab_start_app "$SERVER" "$image" "$port" "$server_in"
answered=""
for _ in $(seq 1 240); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$SERVER")" != true ]; then
    echo "realistic: the server container exited:" >&2
    docker logs "$SERVER" >&2 || true
    exit 1
  fi
  if probe http-answers "$port" /health; then answered=1; break; fi
  sleep 0.5
done
[ -n "$answered" ] || { docker logs "$SERVER" >&2 || true; fail "the server did not answer GET /health on port $port within 120 s"; }
server_id="$(docker inspect -f '{{.Id}}' "$SERVER")"
php_version="$(docker exec "$PROBE" php -r 'echo PHP_VERSION;')"
socket_line="$(lab_socket_line "$SERVER")"
server_fds="$(probe fds "$server_id" | lines_to_json | jq '.fds.open')"
# Why disable SC2034: sampler_start (series.sh) reads server_pid.
# shellcheck disable=SC2034
server_pid="$(docker inspect -f '{{.State.Pid}}' "$SERVER")"

# What the page cache held of the database copy just before the server opened it (printed by lab_start_app).
fincore_line="$(lab_fincore_line "$SERVER")"
[ -n "$fincore_line" ] || fail "the server container printed no fincore line"
cold_json="$(jq -nc --arg line "$fincore_line" --argjson requested "$([ -n "$cold" ] && echo true || echo false)" '
  ($line | split(" ") | map(split("=") | {(.[0]): (.[1] | tonumber)}) | add) as $f
  | {requested: $requested, resident_bytes: $f.resident_bytes, size_bytes: $f.size_bytes,
     resident_pages: $f.resident_pages, pages: $f.pages, resident_share: ($f.resident_bytes / $f.size_bytes * 1000 | round / 1000)}')"
extra_invalid=""
add_invalid() { extra_invalid="${extra_invalid:+$extra_invalid; }$1"; }
if [ -n "$cold" ] && [ "$(jq '.resident_share > 0.05' <<<"$cold_json")" = true ]; then
  add_invalid "--cold: $(jq -r '.resident_share * 100 | round' <<<"$cold_json") % of the database copy was still in the page cache when the server opened it"
fi

# Why --memory: k6 does not slow down when its reader falls behind, it buffers samples in memory; a run that needs more than the
# budget is killed by Docker, not by the VM's OOM killer next to the server.
docker run -d --name "$K6C" --network host --cpuset-cpus "$LAB_CPUSET_K6" --memory "${k6_budget_mib}m" --memory-swap "${k6_budget_mib}m" \
  -v "$LAB:/lab:ro" -v "$VOLUME:/run/rt" --entrypoint sleep "$LAB_K6_IMAGE" 86400 >/dev/null
k6_id="$(docker inspect -f '{{.Id}}' "$K6C")"
k6_version="$(docker exec "$K6C" k6 version | head -n 1)"
docker exec "$PROBE" mkfifo -m 666 /run/rt/csv
profile_begin

# --- the idle connections ----------------------------------------------------------------------------------------------------------
# One client, in its own container on the load CPUs, opens <n> keep-alive connections one at a time (see lab/conns/client.php for why),
# before the warm-up, and holds them until the run is over. The body of GET /health is checked with a pattern (it carries the uptime).
idle_json="null"
IDLE_EVENT=""
# idle_wait <kind> <seconds>: waits for the client's next event of that kind into IDLE_EVENT, printing its log lines.
idle_wait() {
  local deadline line printed=0
  deadline=$(( $(date +%s) + $2 ))
  while :; do
    line="$(grep "\"event\":\"$1\"" "$tmp/idle-events" | head -n 1 || true)"
    if [ -n "$line" ]; then IDLE_EVENT="$line"; return 0; fi
    line="$(grep '"event":"harness_error"' "$tmp/idle-events" | head -n 1 || true)"
    [ -z "$line" ] || fail "the idle client failed: $(jq -r '.message' <<<"$line")"
    if [ "$(grep -c '"event":"log"' "$tmp/idle-events" || true)" -gt "$printed" ]; then
      printed=$(( printed + 1 ))
      echo "realistic: idle client: $(grep '"event":"log"' "$tmp/idle-events" | sed -n "${printed}p" | jq -r '.message')" >&2
      continue
    fi
    kill -0 "$idle_pid" 2>/dev/null || fail "the idle client exited without answering: $(tr '\n' ' ' <"$tmp/idle.err")"
    [ "$(date +%s)" -lt "$deadline" ] || fail "the idle client did not answer within $2 s"
    sleep 0.2
  done
}
if [ -n "$idle" ]; then
  echo "idle: opening $idle connections" >&2
  docker run -d --name "$IDLEC" --network host --cpuset-cpus "$LAB_CPUSET_K6" --ulimit nofile=200000:200000 \
    -v "$LAB:/lab:ro" "$LAB_IMAGE:$image" sleep 86400 >/dev/null
  idle_id="$(docker inspect -f '{{.Id}}' "$IDLEC")"
  : >"$tmp/idle-events"
  # Why display_errors=stderr: a PHP fatal error must not land in the events file.
  docker exec "$IDLEC" php -d memory_limit=-1 -d display_errors=stderr -d log_errors=0 /lab/conns/client.php "$port" --hold "$idle" \
    --path /health --body-regex '^\{"status":"ok",.*\}$' --end-file "$IDLE_END_FILE" >"$tmp/idle-events" 2>"$tmp/idle.err" &
  idle_pid=$!
  idle_wait held 3600
  idle_start="$IDLE_EVENT"
  [ "$(docker inspect -f '{{.State.Running}}' "$SERVER")" = true ] || fail "the server container died while the idle connections were opened"
  [ "$(jq -r '.failure' <<<"$idle_start")" = null ] || fail "the idle client held only $(jq -r '.held' <<<"$idle_start") of $idle connections: $(jq -r '.failure + ": " + .detail' <<<"$idle_start")"
  [ "$(jq -r '.closed_by_server' <<<"$idle_start")" -eq 0 ] || add_invalid "the server closed $(jq -r '.closed_by_server' <<<"$idle_start") of the $idle idle connections before the load started"
  idle_established_start="$(probe connections "$port" | lines_to_json | jq '.connections.established')"
  idle_memory_start="$(probe cgroup-memory "$idle_id" | lines_to_json | jq -c '.cgroup')"
  idle_fds_start="$(probe fds "$server_id" | lines_to_json | jq '.fds.open')"
  echo "idle: $(jq -r '.held' <<<"$idle_start") held in $(jq -r '.seconds' <<<"$idle_start") s, the server has $idle_established_start established and $idle_fds_start file descriptors open" >&2
fi

# options_for <vus>...: the k6 options (JSON) of one ramping-vus scenario: for each VU count a ramp and a plateau, then a 1 s ramp down.
# The bench's thresholds stay; the submetrics per endpoint are always met: they are there so that k6's own summary holds the
# percentiles of each endpoint.
options_for() {
  jq -nc --argjson ramp "$ramp" --argjson plateau "$plateau" '
    ($ARGS.positional | map(tonumber)) as $vus
    | {scenarios: {users: {executor: "ramping-vus", startVUs: 0, gracefulRampDown: "1s", gracefulStop: "1s",
         stages: (($vus | map([{duration: "\($ramp)s", target: .}, {duration: "\($plateau)s", target: .}]) | add) + [{duration: "1s", target: 0}])}},
       thresholds: ({"http_req_duration": ["p(95)<500", "p(99)<1000"], "http_req_failed": ["rate<0.01"]}
         + (["GET /feed", "GET /posts/:id", "POST /posts/:id/like", "POST /posts"] | map({key: "http_req_duration{name:\(.)}", value: ["p(95)<3600000"]}) | from_entries)),
       summaryTrendStats: ["avg", "min", "med", "p(90)", "p(95)", "p(99)", "max"]}' --args "$@"
}

k6_job=""
# k6_run <name> <options json> [csv]: the k6 run is a `docker exec` in the long-lived container (its cgroup outlives it). The summary
# stays in the container at /tmp/<name>.json.
k6_run() {
  local name="$1" options="$2" csv="${3:-}" args=()
  [ -z "$csv" ] || args+=(--out csv=/run/rt/csv)
  docker exec -e K6_NO_USAGE_REPORT=true -e K6_CSV_SAVE_INTERVAL=250ms "$K6C" k6 run --quiet --no-color --local-ips "$local_ips" \
    -e "BASE_URL=http://127.0.0.1:$port" -e TOKENS=/lab/data/tokens.json -e "THINK_SCALE=$think_scale" -e "REALISTIC_OPTIONS=$options" \
    ${args[@]+"${args[@]}"} --summary-export "/tmp/$name.json" /lab/macro/k6/realistic.js >"$tmp/$name.log" 2>&1
}

if [ -n "$warmup" ]; then
  echo "warm-up: ${warm_seconds}s at $warm_rate req/s (not scored)" >&2
  warm_options="$(plateau="$warm_seconds" options_for "$(vus_for "$warm_rate")")"
  k6_run warmup "$warm_options" || { echo "realistic: k6 (warm-up) failed:" >&2; tail -n 20 "$tmp/warmup.log" >&2; exit 1; }
fi

# run_measured <name> <stop on first failing step: true|false> <vus>...: one k6 run of those steps with the aggregator reading its CSV.
# Leaves, in $tmp: <name>.agg.json (the aggregator's result), <name>.k6.json (k6's summary, when it wrote one), <name>.polls (one line
# per poll: vus_now k6_memory_current server_pss_anon_kb server_memory_current) and <name>.meta.json: invalid (the reason, or ""),
# stopped_by_harness (k6 was stopped at a failing step), k6_exit, k6_peak_bytes, server_pss_anon_peak_kb, server_memory_peak_bytes,
# clients (the client addresses the server saw, read mid-run), <name>.samples (the sampler's lines), <name>.series.json (the per-second rows:
# the aggregator's latency, the sampler's readings and the server's telemetry lines of the same second).
run_measured() {
  local name="$1" stop_on_fail="$2" steps_json config options
  shift 2
  steps_json="$(jq -nc --argjson p "$per_vu_rate" '$ARGS.positional | map(tonumber) | map({vus: ., offered: (. * $p)})' --args "$@")"
  config="$(jq -nc --argjson steps "$steps_json" --argjson stop "$stop_on_fail" --arg server "/sys/fs/cgroup/docker/$server_id" \
    --arg k6 "/sys/fs/cgroup/docker/$k6_id" --argjson users "$USERS_PER_RPS" --argjson p95 "$LIMIT_P95_MS" --argjson p99 "$LIMIT_P99_MS" \
    --argjson err "$LIMIT_ERROR_RATE" --argjson ratio "$LIMIT_ACHIEVED_RATIO" '
    {fifo: "/run/rt/csv", status: "/run/rt/status.json", result: "/run/rt/result.json", steps: $steps, stop_on_fail: $stop,
     users_per_rps: $users, server_cgroup: $server, k6_cgroup: $k6,
     limits: {p95_ms: $p95, p99_ms: $p99, error_rate: $err, achieved_ratio: $ratio}}')"
  options="$(options_for "$@")"

  docker exec "$PROBE" rm -f /run/rt/status.json /run/rt/result.json
  docker rm -f "$AGG" >/dev/null 2>&1 || true
  docker run -d --name "$AGG" --cpuset-cpus "$LAB_CPUSET_K6" --cgroupns host -v "$LAB:/lab:ro" -v "$VOLUME:/run/rt" \
    -e "AGG_CONFIG=$config" "$LAB_IMAGE:$image" php -d memory_limit=-1 -d opcache.enable_cli=1 -d opcache.jit=tracing -d opcache.jit_buffer_size=32M \
    /lab/macro/aggregate.php >/dev/null

  local run_invalid="" run_stopped=0 run_k6_rc=0 run_k6_peak=0 run_pss_peak_kb=0 run_cur_peak=0 run_clients='{}' polls=0
  : >"$tmp/$name.polls"
  local limit_bytes=$(( k6_budget_mib * 1048576 ))
  sampler_start "$name" "$LAB_APP_DB"
  k6_run "$name" "$options" csv &
  k6_job=$!
  local poll line g k v k6_cur k6_peak k6_oom pss cur status_json failed_step failed_why lag_max vus_now unparsed
  while kill -0 "$k6_job" 2>/dev/null; do
    sleep 1
    poll="$(probe poll "$server_id" "$k6_id" /run/rt/status.json 2>/dev/null || true)"
    k6_cur=0 k6_peak=0 k6_oom=0 pss=0 cur=0 status_json='{}'
    while IFS= read -r line; do
      g="${line%% *}"
      [ "$g" != status ] || { status_json="${line#status }"; continue; }
      read -r g k v <<<"$line"
      case "$g $k" in
        "k6 memory_current") k6_cur="$v" ;;
        "k6 memory_peak") k6_peak="$v" ;;
        "k6 oom_kill") k6_oom="${v:-0}" ;;
        "server pss_anon_kb") pss="$v" ;;
        "server cgroup_current") cur="$v" ;;
      esac
    done <<<"$poll"
    [ "$k6_peak" -le "$run_k6_peak" ] || run_k6_peak="$k6_peak"
    [ "$pss" -le "$run_pss_peak_kb" ] || run_pss_peak_kb="$pss"
    [ "$cur" -le "$run_cur_peak" ] || run_cur_peak="$cur"
    IFS=$'\t' read -r failed_step failed_why lag_max vus_now unparsed < <(jq -r '[(.failed.step // 0), ((.failed.reasons // ["-"]) | join("; ")), (.lag_max_s // 0), (.vus_now // 0), (.unparsed // 0)] | @tsv' <<<"${status_json:-{\}}" 2>/dev/null || echo "")
    echo "${vus_now:-0} $k6_cur $pss $cur" >>"$tmp/$name.polls"
    polls=$(( polls + 1 ))
    if [ "$polls" -ge 4 ] && [ "${vus_now:-0}" -gt 0 ]; then
      run_clients="$(probe client-ips "$port" | lines_to_json | jq -c --argjson old "$run_clients" '(.clients // {}) as $now | if ($now | length) >= ($old | length) then $now else $old end')"
    fi
    if [ "$(docker inspect -f '{{.State.Running}}' "$SERVER" 2>/dev/null)" != true ]; then
      stop_k6
      fail "the server container died during the run"
    fi
    if [ "${k6_oom:-0}" -gt 0 ] || [ "$k6_peak" -ge $(( limit_bytes * 95 / 100 )) ]; then
      run_invalid="k6 reached its memory budget ($(( k6_peak / 1048576 )) MiB of $k6_budget_mib MiB)"
      stop_k6
      break
    fi
    if awk -v l="${lag_max:-0}" -v g="$lag_gate" 'BEGIN { exit !(l > g) }'; then
      run_invalid="the aggregator fell behind k6: lag ${lag_max} s, above the gate of $lag_gate s"
      stop_k6
      break
    fi
    if [ "${unparsed:-0}" -gt 0 ]; then
      run_invalid="${unparsed} k6 duration rows could not be parsed by the aggregator"
      stop_k6
      break
    fi
    if [ "${failed_step:-0}" -gt 0 ] && [ "$stop_on_fail" = true ]; then
      echo "step $failed_step failed ($failed_why): stopping k6" >&2
      run_stopped=1
      stop_k6
      break
    fi
  done
  wait "$k6_job" || run_k6_rc=$?
  k6_job=""
  sampler_stop "$name"
  # 99: k6's thresholds failed (a result). 105: k6 stopped by a signal, which the harness sent on purpose.
  # A k6 killed for its memory before the poll saw it reach the budget is the same finding.
  if [ "$run_k6_rc" -ne 0 ] && [ -z "$run_invalid" ] && [ "$(probe memory-events "$k6_id" | awk '$2 == "oom_kill" {print $3}')" -gt 0 ]; then
    run_invalid="k6 was killed for reaching its memory budget ($k6_budget_mib MiB)"
  fi
  if [ "$run_k6_rc" -ne 0 ] && [ "$run_k6_rc" -ne 99 ] && [ "$run_stopped" -eq 0 ] && [ -z "$run_invalid" ]; then
    echo "realistic: k6 failed (exit $run_k6_rc):" >&2
    tail -n 20 "$tmp/$name.log" >&2
    exit 1
  fi
  docker exec "$PROBE" sh -c 'printf "#END\n" > /run/rt/csv'
  for _ in $(seq 1 60); do
    docker exec "$PROBE" test -f /run/rt/result.json 2>/dev/null && break
    [ "$(docker inspect -f '{{.State.Running}}' "$AGG" 2>/dev/null)" = true ] || break
    sleep 0.5
  done
  docker exec "$PROBE" cat /run/rt/result.json >"$tmp/$name.agg.json" 2>/dev/null || {
    echo "realistic: the aggregator left no result:" >&2
    docker logs "$AGG" >&2 || true
    exit 1
  }
  docker exec "$K6C" cat "/tmp/$name.json" >"$tmp/$name.k6.json" 2>/dev/null || echo 'null' >"$tmp/$name.k6.json"
  jq -nc --arg invalid "$run_invalid" --argjson stopped "$run_stopped" --argjson rc "$run_k6_rc" --argjson peak "$run_k6_peak" \
    --argjson pss "$run_pss_peak_kb" --argjson cur "$run_cur_peak" --argjson clients "$run_clients" \
    '{invalid: $invalid, stopped_by_harness: ($stopped == 1), k6_exit: $rc, k6_peak_bytes: $peak, server_pss_anon_peak_kb: $pss,
      server_memory_peak_bytes: $cur, clients: $clients}' >"$tmp/$name.meta.json"
  series_build "$name" "$tmp/$name.agg.json"
}

# Stops k6 the way ctrl-C does: it wraps up and writes its summary.
stop_k6() { docker exec "$K6C" sh -c 'kill -INT $(pidof k6)' >/dev/null 2>&1 || true; }

other_names=()
while IFS= read -r name; do [ -z "$name" ] || other_names+=("$name"); done < <(lab_other_containers "$SERVER" "$K6C" "$PROBE" "$AGG" "$IDLEC")
other_json="$(jq -nc --argjson names "$(json_array "${other_names[@]+"${other_names[@]}"}")" '{count: ($names | length), names: $names}')"
other_warning=""
if [ "${#other_names[@]}" -gt 0 ]; then
  other_warning="WARNING: ${#other_names[@]} other containers running (${other_names[*]})"
  echo "$other_warning" >&2
fi
cpu_before="$(probe cpu "$server_id" "$k6_id" | lines_to_json)"

if [ -n "$calibrate" ]; then
  echo "calibration: ${steps_vus[0]} VUs for ${plateau}s, then ${steps_vus[1]} VUs for ${plateau}s (think scale $think_scale)" >&2
  run_measured cal-a false "${steps_vus[0]}"
  run_measured cal-b false "${steps_vus[1]}"
else
  echo "measured: ${#steps_vus[@]} step(s) of ${plateau}s (ramp ${ramp}s), think scale $think_scale, VUs ${steps_vus[*]}" >&2
  run_measured main true "${steps_vus[@]}"
fi
cpu_after="$(probe cpu "$server_id" "$k6_id" | lines_to_json)"
[ "$(docker inspect -f '{{.State.Running}}' "$SERVER")" = true ] || fail "the server container died during the run"

# The profile: the requests of the profiled window are the warm-up's, the measured run's and one GET /health per idle connection.
if [ -n "$profile_out" ]; then
  warm_requests=0
  [ -z "$warmup" ] || warm_requests="$(docker exec "$K6C" cat /tmp/warmup.json | jq '.metrics.http_reqs.count // 0')"
  profile_collect "$(( warm_requests + $(jq '.requests' "$tmp/main.agg.json") + ${idle:-0} ))"
fi

# The idle connections at the end of the run: what the server counts, then the client's own sweep (it ends the hold).
if [ -n "$idle" ]; then
  idle_established_end="$(probe connections "$port" | lines_to_json | jq '.connections.established')"
  idle_memory_end="$(probe cgroup-memory "$idle_id" | lines_to_json | jq -c '.cgroup')"
  docker exec "$IDLEC" touch "$IDLE_END_FILE"
  idle_wait ended 600
  idle_end="$IDLE_EVENT"
  if [ "$(jq -r '.closed_by_server' <<<"$idle_end")" -gt 0 ] || [ "$(jq -r '.held' <<<"$idle_end")" -ne "$idle" ]; then
    add_invalid "the server closed $(jq -r '.closed_by_server' <<<"$idle_end") of the $idle idle connections during the run: $(jq -r '.held' <<<"$idle_end") held at the end"
  fi
  idle_json="$(jq -nc --argjson requested "$idle" --argjson start "$idle_start" --argjson end "$idle_end" --argjson est_start "$idle_established_start" \
    --argjson est_end "$idle_established_end" --argjson fds_start "$idle_fds_start" --argjson mem_start "$idle_memory_start" --argjson mem_end "$idle_memory_end" \
    --argjson budget "$LAB_IDLE_CLIENT_MIB" '
    def mib: . / 1048576 * 100 | round / 100;
    {requested: $requested, path: "/health", held_at_start: $start.held, held_at_end: $end.held,
     closed_by_server_at_start: $start.closed_by_server, closed_by_server_at_end: $end.closed_by_server,
     server_established_at_start: $est_start, server_established_at_end: $est_end, server_fds_open_with_idle: $fds_start,
     seconds_to_open: $start.seconds, source_addresses: $start.source_addresses, ports_per_address: $start.ports_per_address,
     client: {nofile: $start.nofile, rss_mib: ($start.rss_kb / 1024 * 100 | round / 100), hwm_mib: ($end.hwm_kb / 1024 * 100 | round / 100),
              memory_current_mib_after_opening: ($mem_start.current | mib), memory_current_mib_at_end: ($mem_end.current | mib),
              memory_peak_mib: ($mem_end.peak | mib), anon_mib: ($mem_end.anon | mib), socket_buffers_mib: ($mem_end.sock | mib), kernel_mib: ($mem_end.kernel | mib),
              budget_mib: $budget}}')"
  echo "idle: $(jq -r '.held_at_end' <<<"$idle_json") held at the end ($idle_established_end established on the server)" >&2
fi

# --- the numbers ------------------------------------------------------------------------------------------------------------
runs_for_json=(main)
[ -z "$calibrate" ] || runs_for_json=(cal-a cal-b)

# The k6 memory of a run on its plateau: the median of the polls where k6's gauge read the step's VUs (MiB), or the peak when none did.
plateau_memory_mib() {
  local name="$1" vus="$2" m
  m="$(awk -v v="$vus" '$1 == v { print $2 }' "$tmp/$name.polls" | sort -n | awk '{ a[NR] = $1 } END { if (NR) printf "%.2f", a[int((NR + 1) / 2)] / 1048576 }')"
  if [ -z "$m" ]; then m="$(jq -r '.k6_peak_bytes / 1048576 * 100 | round / 100' "$tmp/$name.meta.json")"; fi
  echo "$m"
}

# run_json <name>: everything one k6 run produced, as one JSON object.
run_json() {
  local name="$1"
  jq -n --slurpfile agg "$tmp/$name.agg.json" --slurpfile k6 "$tmp/$name.k6.json" --slurpfile meta "$tmp/$name.meta.json" --slurpfile series "$tmp/$name.series.json" '
    def mib: . / 1048576 * 100 | round / 100;
    $agg[0] as $a | $meta[0] as $m
    | {steps: $a.steps, stopped_at_step: ($a.failed.step // null), stop_reasons: ($a.failed.reasons // []),
       invalid: (if $m.invalid != "" then $m.invalid
                 elif ($a.steps | length) == 0 then "no step reached its plateau"
                 else "" end),
       stopped_by_harness: $m.stopped_by_harness, k6_exit: $m.k6_exit,
       k6_peak_memory_mib: ($m.k6_peak_bytes | mib), client_ips_seen: $m.clients,
       server_pss_anon_peak_mib: ($m.server_pss_anon_peak_kb / 1024 * 100 | round / 100),
       server_memory_current_peak_mib: ($m.server_memory_peak_bytes | mib),
       aggregator: {max_lag_s: $a.lag_max_s, rows: $a.rows, requests: $a.requests, unparsed: $a.unparsed, bytes: $a.bytes,
                    connection_errors: $a.connection_errors, error_codes: ($a.error_codes | if type == "array" then {} else . end)},
       per_second: $a.per_second, series: $series[0], run_total: $a.run_total, k6_summary: $k6[0]}'
}

# Calibration: the memory a VU costs, the VU cap and the scale (see the README).
calibration_json='null'
if [ -n "$calibrate" ]; then
  mem_a="$(plateau_memory_mib cal-a "${steps_vus[0]}")"
  mem_b="$(plateau_memory_mib cal-b "${steps_vus[1]}")"
  calibration_json="$(jq -n --argjson va "${steps_vus[0]}" --argjson vb "${steps_vus[1]}" --argjson ma "$mem_a" --argjson mb "$mem_b" \
    --argjson vm "$(( vm_bytes / 1048576 ))" --argjson fd_cap "$LAB_VU_CAP_FDS" --argjson idle_mib "$LAB_IDLE_CLIENT_MIB" --argjson per_vu "$per_vu_rate" --argjson s "$think_scale" \
    --argjson loop_n "$LOOP_REQUESTS" --argjson loop_t "$LOOP_THINK_S" --slurpfile a "$tmp/cal-a.agg.json" --slurpfile b "$tmp/cal-b.agg.json" '
    (($mb - $ma) / ($vb - $va)) as $per
    | ($ma - $per * $va) as $base
    # A per-VU cost under the noise of two readings (zero or negative) bounds nothing: the cap is then the file descriptors.
    | (if $per > 0 then (($vm - 2048 - $idle_mib - 1024) / $per | floor) else null end) as $mem_cap
    | ([$mem_cap, $fd_cap] | map(select(. != null)) | min) as $cap
    # The scale that puts 20,000 req/s under the cap: VUs = rate * loop_t * scale / loop_n.
    | ($cap * $loop_n / (20000 * $loop_t)) as $raw
    | (($raw * 100000 | floor) / 100000) as $scale
    | ($a[0].steps[0]) as $sa | ($b[0].steps[0]) as $sb
    | {vus: [$va, $vb], k6_memory_mib: [$ma, $mb], mib_per_vu: ($per * 1000 | round / 1000), base_mib: ($base * 100 | round / 100),
       vm_memory_mib: $vm, memory_cap: $mem_cap, fd_cap: $fd_cap, vu_cap: $cap,
       cap_bound_by: (if $mem_cap != null and $mem_cap < $fd_cap then "memory" else "file descriptors" end),
       scale_for_20000_rps: $scale,
       vus_at_20000_rps_with_that_scale: (20000 * $loop_t * $scale / $loop_n | ceil),
       latency_margin_ms_per_request_at_that_scale: ((1 - 0.97) * $loop_t * $scale / (0.97 * $loop_n) * 1000 * 100 | round / 100),
       achieved_over_offered: [($sa.achieved_rps / $sa.offered_rps * 1000 | round / 1000), ($sb.achieved_rps / $sb.offered_rps * 1000 | round / 1000)],
       k6_cpu_percent_of_one_cpu: [$sa.k6_cpu_percent_of_one_cpu, $sb.k6_cpu_percent_of_one_cpu],
       k6_cpu_usec_per_request: [($sa.k6_cpu_percent_of_one_cpu * 10000 / $sa.achieved_rps | round), ($sb.k6_cpu_percent_of_one_cpu * 10000 / $sb.achieved_rps | round)],
       aggregator_max_lag_s: [$a[0].lag_max_s, $b[0].lag_max_s],
       lag_gate_to_use_s: ([$a[0].lag_max_s, $b[0].lag_max_s] | max | . + 2 | . * 100 | round / 100)}')"
fi

# Why files and not --argjson: a run of several minutes holds thousands of per-second rows, and one argument over the OS limit (1 MiB on
# macOS, for all the arguments together) made jq fail with "Argument list too long" after a 25 minute staircase.
echo '[]' >"$tmp/runs.json"
for r in "${runs_for_json[@]}"; do
  run_json "$r" >"$tmp/$r.run.json"
  jq -c --slurpfile run "$tmp/$r.run.json" '. + [$run[0]]' "$tmp/runs.json" >"$tmp/runs.next.json"
  mv "$tmp/runs.next.json" "$tmp/runs.json"
done
invalid_all="$(jq -r --arg extra "$extra_invalid" '(map(select(.invalid != "") | .invalid) + (if $extra == "" then [] else [$extra] end)) | join("; ")' "$tmp/runs.json")"

jq -n \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg command "$command_line" --arg mode "$mode" \
  --arg docker "$(docker version --format '{{.Server.Platform.Name}}')" --arg engine "$(docker version --format '{{.Server.Version}}')" \
  --arg kernel "$(docker info --format '{{.KernelVersion}}')" --arg arch "$(uname -m)" --arg limits "${LAB_RESOURCE_FLAGS[*]}" \
  --arg variant "$image" --arg image_id "$(docker image inspect -f '{{.Id}}' "$LAB_IMAGE:$image")" --arg php_version "$php_version" \
  --arg server_file "${server_in#/lab/}" --arg flags "${LAB_PHP_FLAGS[*]}" --argjson port "$port" --arg label "$label" \
  --argjson ext "$(json_array "${LAB_EXT[@]}")" --argjson env "$(json_array "${LAB_ENV[@]+"${LAB_ENV[@]}"}")" \
  --arg socket_line "$socket_line" --argjson server_fds "$server_fds" --argjson other_containers "$other_json" \
  --argjson think_scale "$think_scale" --argjson per_vu_rate "$per_vu_rate" --argjson users_per_rps "$USERS_PER_RPS" \
  --argjson ramp "$ramp" --argjson plateau "$plateau" --argjson vu_cap "$vu_cap" --arg warmup "$warmup" \
  --argjson steps_vus "$(jq -nc '$ARGS.positional | map(tonumber)' --args "${steps_vus[@]}")" \
  --arg k6_image "$LAB_K6_IMAGE" --arg k6_version "$k6_version" --arg local_ips "$local_ips" --argjson k6_budget "$k6_budget_mib" \
  --argjson lag_gate "$lag_gate" --argjson before "$cpu_before" --argjson after "$cpu_after" --argjson idle "$idle_json" --argjson cold "$cold_json" \
  --slurpfile runs_file "$tmp/runs.json" --argjson calibration "$calibration_json" --argjson profile "$profile_json" --arg invalid "$invalid_all" '
  def mib: . / 1048576 * 100 | round / 100;
  ($after.time.us - $before.time.us) as $window_us
  | ($runs_file[0]) as $runs
  | ($runs[-1]) as $last
  | {
    date: $date, command: $command, mode: $mode, label: (if $label == "" then null else $label end),
    other_containers: $other_containers,
    valid: ($invalid == ""), invalid_reasons: (if $invalid == "" then [] else [$invalid] end),
    idle: $idle, cold: $cold, profile: $profile,
    host: {docker_desktop: $docker, engine: $engine, vm_kernel: $kernel, arch: $arch, limits: $limits},
    server: {variant: $variant, image_id: $image_id, php_version: $php_version, file: $server_file, port: $port, php_flags: $flags,
             ext: $ext, env: $env, fds_open_at_boot: $server_fds,
             socket: (if $socket_line == "" then null else $socket_line end)},
    load: {think_scale: $think_scale, per_vu_rate_rps: $per_vu_rate, users_per_rps: $users_per_rps, ramp_s: $ramp, plateau_s: $plateau,
           vus: $steps_vus, vu_cap: $vu_cap, warmup: (if $warmup == "" then null else $warmup end),
           pass_rule: "p95 < 500 ms, p99 < 1000 ms, errors < 1 %, achieved >= 97 % of offered"},
    k6: {image: $k6_image, version: $k6_version, script: "macro/k6/realistic.js", local_ips: $local_ips,
         client_ips_seen: $last.client_ips_seen, memory_budget_mib: $k6_budget,
         peak_memory_mib: ([$runs[].k6_peak_memory_mib] | max),
         cpu_percent_of_one_cpu: (($after.k6.usage_usec - $before.k6.usage_usec) / $window_us * 100 * 100 | round / 100),
         exit_codes: [$runs[].k6_exit]},
    aggregator: {lag_gate_s: $lag_gate, max_lag_s: ([$runs[].aggregator.max_lag_s] | max),
                 rows: ([$runs[].aggregator.rows] | add), unparsed: ([$runs[].aggregator.unparsed] | add)},
    k6_connection_errors: ([$runs[].aggregator.connection_errors] | add),
    k6_error_codes: ($runs | map(.aggregator.error_codes | to_entries) | add | group_by(.key) | map({key: .[0].key, value: (map(.value) | add)}) | from_entries),
    server_memory: {pss_anon_peak_mib: ([$runs[].server_pss_anon_peak_mib] | max),
                    memory_current_peak_mib: ([$runs[].server_memory_current_peak_mib] | max)},
    server_cpu_usec_over_the_runs: ($after.server.usage_usec - $before.server.usage_usec),
    results: $last,
    calibration: $calibration,
    runs: (if $mode == "calibrate" then $runs else null end),
    raw: {cpu_stat_before: $before, cpu_stat_after: $after}
  }' >"$out"

# The table reads the JSON just written, so what is printed is what is stored.
echo
echo "image $image (PHP $php_version), $(basename "$server_file"), $k6_version, k6 from $local_ips"
jq -r '"think scale \(.load.think_scale): one VU offers \(.load.per_vu_rate_rps) req/s, \(.load.users_per_rps) users per req/s, ramp \(.load.ramp_s) s, plateau \(.load.plateau_s) s, VU cap \(.load.vu_cap)"' "$out"
if [ -z "$calibrate" ]; then
  printf '%4s %6s %9s %9s %7s %9s %8s %8s %7s  %s\n' step VUs offered achieved users us/req "p95 ms" "p99 ms" errors result
  jq -r '.results.steps[] | [.step, .vus, (.offered_rps | . * 10 | round / 10), (.achieved_rps | . * 10 | round / 10), (.users | round),
      (.cpu_usec_per_request // "n/a" | if type == "number" then (. * 10 | round / 10) else . end),
      .latency_ms.overall.p95, .latency_ms.overall.p99, (.error_rate * 100 | . * 100 | round / 100 | tostring + "%"),
      (if .pass then "pass" else "FAIL: " + (.reasons | join("; ")) end)] | @tsv' "$out" |
    while IFS=$'\t' read -r st vus off ach users usec p95 p99 err res; do
      printf '%4s %6s %9s %9s %7s %9s %8s %8s %7s  %s\n' "$st" "$vus" "$off" "$ach" "$users" "$usec" "$p95" "$p99" "$err" "$res"
    done
  jq -r '.results.steps[] | "  step \(.step) per endpoint (p95 / p99 ms, requests): " + ([.latency_ms.endpoints | to_entries[] | "\(.key) \(.value.p95) / \(.value.p99) (\(.value.count))"] | join(", "))' "$out"
  jq -r 'if .results.stopped_at_step then "STOPPED at step \(.results.stopped_at_step): \(.results.stop_reasons | join("; "))"
         elif (.results.steps | length) == 0 then "no step reached its plateau" else "no step failed" end' "$out"
else
  jq -r '.calibration as $c | .runs as $r | "VUs \($c.vus[0]) / \($c.vus[1]): k6 memory \($c.k6_memory_mib[0]) / \($c.k6_memory_mib[1]) MiB, achieved over offered \($c.achieved_over_offered[0]) / \($c.achieved_over_offered[1]), k6 CPU \($c.k6_cpu_percent_of_one_cpu[0]) / \($c.k6_cpu_percent_of_one_cpu[1]) % of one CPU (\($c.k6_cpu_usec_per_request[0]) / \($c.k6_cpu_usec_per_request[1]) us per request), aggregator lag \($c.aggregator_max_lag_s[0]) / \($c.aggregator_max_lag_s[1]) s",
    "k6 memory per VU: \($c.mib_per_vu) MiB (and \($c.base_mib) MiB at rest)",
    "VU cap: \($c.vu_cap) (memory \($c.memory_cap // "not bound: the cost per VU is under the noise") of the VM'"'"'s \($c.vm_memory_mib) MiB less the server, the idle client and a margin, file descriptors \($c.fd_cap); bound by \($c.cap_bound_by))",
    "scale for 20,000 req/s under the cap: \($c.scale_for_20000_rps) (\($c.vus_at_20000_rps_with_that_scale) VUs; the 97 % rule leaves \($c.latency_margin_ms_per_request_at_that_scale) ms of mean latency per request)",
    "lag gate to use: \($c.lag_gate_to_use_s) s (the lag at low load plus 2 s)"' "$out"
fi
jq -r '"k6 connection errors: \(.k6_connection_errors)" + (if (.k6_error_codes | length) > 0 then " (k6 error codes: \(.k6_error_codes | to_entries | map("\(.key) x \(.value)") | join(", ")))" else "" end)' "$out"
jq -r '.cold | "database copy in the page cache when the server opened it (fincore): \(.resident_bytes) of \(.size_bytes) bytes, \(.resident_share * 100 | round) %, --cold \(if .requested then "on" else "off" end)"' "$out"
jq -r 'select(.idle != null) | .idle | "idle connections: \(.requested) requested, \(.held_at_start) held at the start and \(.held_at_end) at the end, \(.closed_by_server_at_end) closed by the server; the server counted \(.server_established_at_start) and \(.server_established_at_end) established, \(.server_fds_open_with_idle) file descriptors open with them",
  "idle client memory: \(.client.memory_current_mib_at_end) MiB memory.current at the end (peak \(.client.memory_peak_mib), anon \(.client.anon_mib), kernel \(.client.kernel_mib), socket buffers \(.client.socket_buffers_mib)), the process RSS \(.client.rss_mib) MiB after opening them, opened in \(.seconds_to_open) s from \(.source_addresses | length) source addresses"' "$out"
jq -r '"k6 peak memory \(.k6.peak_memory_mib) MiB of its \(.k6.memory_budget_mib) MiB budget, k6 CPU \(.k6.cpu_percent_of_one_cpu) % of one CPU, aggregator max lag \(.aggregator.max_lag_s) s (gate \(.aggregator.lag_gate_s) s), server Pss_Anon peak \(.server_memory.pss_anon_peak_mib) MiB, memory.current peak \(.server_memory.memory_current_peak_mib) MiB"' "$out"
[ -z "$other_warning" ] || echo "$other_warning"
if [ -z "$calibrate" ]; then
  echo
  jq '.results.series' "$out" >"$tmp/series.json"
  series_print "$tmp/series.json"
  echo
fi
profile_print
if [ -z "$invalid_all" ]; then
  echo "VALID"
else
  echo "INVALID: $invalid_all"
fi
echo "wrote ${out#"$REPO"/}"
[ -z "$invalid_all" ] || exit 3
