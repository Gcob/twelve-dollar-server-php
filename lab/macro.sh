#!/usr/bin/env bash
# Loads a PHP server running in a lab container with k6 at a fixed request rate, and reports what a request costs the
# server (CPU microseconds), the latency, the errors and the memory.
#
#   bash lab/macro.sh --image 8.4 --server lab/servers/noop-swoole.php --rate 2000 --duration 30
#                     [--warmup 10] [--script lab/macro/k6/fixed-rate.js] [--out <path>] [--port 18080]
#                     [--path /] [--pre-vus <n>] [--max-vus <n>] [--php-ini key=value]... [--ext <name>]... [--env K=V]...
#                     [--label <text>] [--fresh-db] [--cold] [--per-second] [--profile <collapsed stacks file>]
#
# --fresh-db starts the CHALLENGE APP's way of running a server (lab_start_app: a fresh copy of the seed on the container's own disk, SQLITE_PATH
# and JWT_SECRET set, APP_TELEMETRY=1, extensions `sockets event` unless --ext says otherwise) instead of a bake-off server that copies its own
# seed; without it nothing changes. --cold (needs --fresh-db) evicts the copy from the page cache before the server opens it (`cold` in the JSON
# holds what `fincore` found). --per-second adds a per-second series of the measured run: k6 writes its CSV into an aggregator
# (lab/macro/aggregate.php) that keeps a latency histogram per second and endpoint, and one sampler loop in the probe container reads the server
# (CPU, Pss_Anon, memory.current, the WAL, fds, page faults) once a second; with the app the server's telemetry line of each second joins them.
# The CSV costs k6 about 300 us of CPU per request: the server's numbers are not affected, k6's are.
#
# --profile <file> (needs --fresh-db) runs the app with the Excimer profiler on CPU time (see lab/realistic.sh for what it does and prints): the
# collapsed stacks are copied to <file> once the load is over, folded into the steps S1 to S9 and printed with the cgroup's user and system CPU.
# The profiled server's us/request is not a baseline: Excimer costs CPU.
#
# --ext names a PHP extension to load (`-d extension=<name>`, repeatable, default `swoole`); --env K=V is passed to the server
# container (repeatable); --label goes in the JSON and in the default file name after the server's name.
#
# Three containers, all on the host network of Docker's VM (never k6 from macOS: Docker Desktop forwards a port from the
# Mac through a userspace proxy, which would pollute every number):
#   server  php-lab:<image> running the server file, 1 CPU, 2 GiB, pinned to the server CPU (lab/lib.sh);
#   k6      the pinned grafana/k6 image, pinned to the k6 CPUs, no CPU limit;
#   probe   php-lab:<image> sleeping, --cgroupns host --pid host: it reads cpu.stat, memory.peak and /proc from OUTSIDE
#           the server's and k6's cgroups, so a read is never part of the number it reads.
# Just before the measured run it records the other containers running on the VM (`other_containers` in the JSON, a WARNING
# line when there are any): a measurement next to other work is not comparable with one on a quiet VM.
#
# µs CPU per request = (server cgroup usage_usec after the measured run - before) / requests k6 sent in that run.
# Prints a table and writes a JSON file with every number (default: lab/results/macro-<server>[-<label>]-<image>-<rate>rps-<UTC
# date and time>.json). Exit codes: 0 valid run, 3 run printed but INVALID (errors above 0 % or dropped iterations),
# 1 any other failure (bad argument, server did not start, k6 failed), 2 usage. The three containers are removed at the
# end, whatever happens.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$LAB")"
# shellcheck source=lib.sh
source "$LAB/lib.sh"

# shellcheck source=series.sh
source "$LAB/series.sh"
# shellcheck source=profile.sh
source "$LAB/profile.sh"

SERVER=lab-macro-server
K6C=lab-macro-k6
PROBE=lab-macro-probe
AGG=lab-macro-agg
VOLUME=lab-macro-run
# The aggregator falling behind k6 makes the per-second series wrong: a run whose lag passes this is INVALID.
LAG_GATE_S=4

usage() {
  echo "usage: lab/macro.sh --image <variant> --server <php file under lab/> --rate <req/s> --duration <s> [--warmup <s>]" >&2
  echo "                    [--script <k6 js under lab/>] [--out <path>] [--port <n>] [--path </url/path>]" >&2
  echo "                    [--pre-vus <n>] [--max-vus <n>] [--php-ini key=value]... [--ext <name>]... [--env K=V]..." >&2
  echo "                    [--label <text>] [--fresh-db] [--cold] [--per-second] [--profile <collapsed stacks file>]" >&2
  exit 2
}
fail() { echo "macro: $*" >&2; exit 1; }

command_line="lab/macro.sh $*"
command_line="${command_line//$REPO/.}"

image="" server_file="" rate="" duration="" warmup=10 script="$LAB/macro/k6/fixed-rate.js" out="" port=18080 url_path=/
pre_vus="" max_vus="" label="" fresh_db="" cold="" per_second="" profile_out=""
LAB_EXT=() LAB_ENV=() LAB_INI=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --fresh-db) fresh_db=1; shift; continue ;;
    --cold) cold=1; shift; continue ;;
    --per-second) per_second=1; shift; continue ;;
  esac
  [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; usage; }
  case "$1" in
    --image) image="$2" ;;
    --server) server_file="$2" ;;
    --rate) rate="$2" ;;
    --duration) duration="$2" ;;
    --warmup) warmup="$2" ;;
    --script) script="$2" ;;
    --out) out="$2" ;;
    --port) port="$2" ;;
    --path) url_path="$2" ;;
    --pre-vus) pre_vus="$2" ;;
    --max-vus) max_vus="$2" ;;
    --php-ini) LAB_INI+=("$2") ;;
    --ext) LAB_EXT+=("$2") ;;
    --env) LAB_ENV+=("$2") ;;
    --label) label="$2" ;;
    --profile) profile_out="$2" ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
  shift 2
done
[ -n "$image" ] && [ -n "$server_file" ] && [ -n "$rate" ] && [ -n "$duration" ] || usage
for n in rate duration warmup port; do
  [[ "${!n}" =~ ^[0-9]+$ ]] || { echo "--${n//_/-} must be a whole number, got '${!n}'" >&2; usage; }
done
# Why these defaults: k6 hands each iteration to a VU that is idle at that instant, and drops it when none is. A stall of the
# host or the server (tens of ms, about once per 30 s run on this Mac) piles up rate x stall iterations; with VUs to absorb
# them they show as latency, without they are dropped. So VUs = 100 ms worth of requests (at least 50), all started before
# the test (an extra VU started during the run would drop iterations while it initializes). k6 spreads the iterations
# over all of them, so this is also the number of open connections.
if [ -z "$pre_vus" ]; then
  pre_vus=$(( (rate + 9) / 10 ))
  [ "$pre_vus" -ge 50 ] || pre_vus=50
fi
[ -n "$max_vus" ] || max_vus="$pre_vus"
for n in pre_vus max_vus; do
  [[ "${!n}" =~ ^[0-9]+$ ]] || { echo "--${n//_/-} must be a whole number, got '${!n}'" >&2; usage; }
done
[ -z "$cold" ] || [ -n "$fresh_db" ] || { echo "--cold needs --fresh-db (only lab_start_app evicts its copy of the seed)" >&2; usage; }
if [ "${#LAB_EXT[@]}" -eq 0 ]; then
  LAB_EXT=(swoole)
  [ -z "$fresh_db" ] || LAB_EXT=(sockets event)
fi
[ -z "$profile_out" ] || [ -n "$fresh_db" ] || { echo "--profile needs --fresh-db (only the challenge app writes a profile)" >&2; usage; }
# --profile loads Excimer, sets APP_PROFILE and turns the telemetry off unless the caller sets it (lab/profile.sh).
profile_prepare
profile_json=null   # profile_collect (lab/profile.sh) sets it
if [ -n "$fresh_db" ]; then
  # Telemetry is on in every run of the app unless the caller sets it (a later measurement compares on against off).
  telemetry_set=""
  for kv in "${LAB_ENV[@]+"${LAB_ENV[@]}"}"; do [[ "$kv" != APP_TELEMETRY=* ]] || telemetry_set=1; done
  [ -n "$telemetry_set" ] || LAB_ENV+=(APP_TELEMETRY=1)
fi
for kv in "${LAB_ENV[@]+"${LAB_ENV[@]}"}"; do
  [[ "$kv" == ?*=* ]] || { echo "--env must be K=V, got '$kv'" >&2; usage; }
done
# Why: the label becomes part of a file name.
[[ -z "$label" || "$label" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "--label may only hold letters, digits, . _ and -, got '$label'" >&2; usage; }
[ "$rate" -ge 1 ] && [ "$duration" -ge 1 ] || { echo "--rate and --duration must be at least 1" >&2; usage; }
[[ "$url_path" == /* ]] || { echo "--path must start with /" >&2; usage; }

# Everything is checked before the first container starts.
lab_require_variant "$image" || exit 1
docker image inspect "$LAB_IMAGE:$image" >/dev/null 2>&1 || fail "image $LAB_IMAGE:$image is missing (run lab/build.sh $image)"
server_in="$(lab_in_container_path "$server_file")" || exit 1
script_in="$(lab_in_container_path "$script")" || exit 1
if [ -n "$(docker ps -a --format '{{.Names}}' | grep -x -e "$SERVER" -e "$K6C" -e "$PROBE" -e "$AGG" || true)" ]; then
  fail "a lab/macro.sh run is in progress, or one was killed: remove its containers first (docker rm -f $SERVER $K6C $PROBE $AGG; docker volume rm $VOLUME)"
fi
docker image inspect "$LAB_K6_IMAGE" >/dev/null 2>&1 || { echo "pulling $LAB_K6_IMAGE" >&2; docker pull -q "$LAB_K6_IMAGE" >/dev/null || fail "cannot pull $LAB_K6_IMAGE"; }

stamp="$(date -u +%Y%m%d-%H%M%S)"
if [ -z "$out" ]; then
  out="$LAB/results/macro-$(basename "$server_file" .php)${label:+-$label}-$image-${rate}rps-$stamp.json"
fi
mkdir -p "$LAB/results" "$LAB/data" "$(dirname "$out")"

tmp="$(mktemp -d)"
cleanup() {
  local rc=$?
  docker rm -f "$SERVER" "$K6C" "$PROBE" "$AGG" >/dev/null 2>&1 || true
  docker volume rm -f "$VOLUME" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

probe() { docker exec "$PROBE" bash /lab/macro/probe.sh "$@"; }
# json_array <string>...: the arguments as a JSON array (`[]` with none).
json_array() { jq -nc '$ARGS.positional' --args "$@"; }
# `<group> <key> <number>` lines on stdin to {"group": {"key": number}}.
lines_to_json() {
  jq -Rn 'reduce (inputs | split(" ") | select(length == 3)) as $l ({}; .[$l[0]][$l[1]] = ($l[2] | tonumber? // $l[2]))'
}

# --- the probe and the server ---------------------------------------------------------------------------------------
# The volume holds the FIFO k6 writes its CSV into (--per-second): k6, the aggregator and the probe share it.
volume_args=()
if [ -n "$per_second" ]; then
  docker volume create "$VOLUME" >/dev/null
  volume_args=(-v "$VOLUME:/run/rt")
fi
docker run -d --name "$PROBE" --network host --cgroupns host --pid host --cpuset-cpus "$LAB_CPUSET_PROBE" \
  -v "$LAB:/lab:ro" ${volume_args[@]+"${volume_args[@]}"} "$LAB_IMAGE:$image" sleep 86400 >/dev/null

# Why: 8080 and 80 are often taken on the VM's host network by other containers; a server that fails to bind would let
# the wait below succeed against somebody else's server.
if probe port-open "$port"; then
  fail "port $port is already in use on the VM's host network: pick another with --port"
fi
profile_check_image

lab_build_php_flags
# The app copies the seed (and syncs it) before it listens: up to about 30 s on a slow disk.
wait_rounds=100
if [ -n "$fresh_db" ]; then
  # Why disable SC2034: lab_start_app (lib.sh) reads LAB_COLD; shellcheck does not follow lib.sh from the repo root.
  # shellcheck disable=SC2034
  LAB_COLD="${cold:-0}"
  lab_start_app "$SERVER" "$image" "$port" "$server_in"
  wait_rounds=300
else
  lab_start_server "$SERVER" "$image" "$port" "$server_in"
fi

answered=""
for _ in $(seq 1 "$wait_rounds"); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$SERVER")" != true ]; then
    echo "macro: the server container exited:" >&2
    docker logs "$SERVER" >&2 || true
    exit 1
  fi
  if probe http-answers "$port" "$url_path"; then answered=1; break; fi
  sleep 0.2
done
[ -n "$answered" ] || { docker logs "$SERVER" >&2 || true; fail "the server did not answer on port $port within $(( wait_rounds / 5 )) s"; }

server_id="$(docker inspect -f '{{.Id}}' "$SERVER")"
# Why disable SC2034: sampler_start (series.sh) reads server_pid.
# shellcheck disable=SC2034
server_pid="$(docker inspect -f '{{.State.Pid}}' "$SERVER")"
# What the page cache held of the app's database copy just before the server opened it (printed by lab_start_app).
cold_json=null
if [ -n "$fresh_db" ]; then
  fincore_line="$(lab_fincore_line "$SERVER")"
  [ -n "$fincore_line" ] || fail "the server container printed no fincore line"
  cold_json="$(jq -nc --arg line "$fincore_line" --argjson requested "$([ -n "$cold" ] && echo true || echo false)" '
    ($line | split(" ") | map(split("=") | {(.[0]): (.[1] | tonumber)}) | add) as $f
    | {requested: $requested, resident_bytes: $f.resident_bytes, size_bytes: $f.size_bytes,
       resident_pages: $f.resident_pages, pages: $f.pages, resident_share: ($f.resident_bytes / $f.size_bytes * 1000 | round / 1000)}')"
fi
php_version="$(docker exec "$PROBE" php -r 'echo PHP_VERSION;')"
# The ini values the server's flags give, as PHP reads them back (same flags, same image), and whether the JIT is on.
php_ini_json="$(docker exec "$PROBE" php "${LAB_PHP_FLAGS[@]}" -d display_errors=stderr -r '
  $keys = ["opcache.enable_cli", "opcache.jit", "opcache.jit_buffer_size", "opcache.file_update_protection",
           "zend.assertions", "memory_limit"];
  $ini = [];
  foreach ($keys as $k) { $ini[$k] = ini_get($k); }
  $status = function_exists("opcache_get_status") ? opcache_get_status(false) : false;
  $ini["jit_on"] = $status["jit"]["on"] ?? false;
  echo json_encode($ini);' 2>/dev/null || echo '{}')"
swoole_version=""
for e in "${LAB_EXT[@]}"; do
  [ "$e" != swoole ] || swoole_version="$(docker exec "$PROBE" php -d extension=swoole -r 'echo phpversion("swoole") ?: "";' 2>/dev/null || true)"
done
socket_line="$(lab_socket_line "$SERVER")"

# --- k6 --------------------------------------------------------------------------------------------------------------
# Why a long-lived container and `docker exec k6 run`: the container's cgroup has to exist when its cpu.stat is read after
# the measured run, and a container that ran k6 as its command is gone by then. The exec'd k6 runs inside its cgroup.
docker run -d --name "$K6C" --network host --cpuset-cpus "$LAB_CPUSET_K6" -v "$LAB:/lab:ro" ${volume_args[@]+"${volume_args[@]}"} \
  --entrypoint sleep "$LAB_K6_IMAGE" 86400 >/dev/null
[ -z "$per_second" ] || docker exec "$PROBE" mkfifo -m 666 /run/rt/csv
k6_id="$(docker inspect -f '{{.Id}}' "$K6C")"
k6_version="$(docker exec "$K6C" k6 version | head -n 1)"
profile_begin
target_url="http://127.0.0.1:$port$url_path"

# run_k6 <label> <seconds>: the summary stays in the k6 container at /tmp/<label>.json.
run_k6() {
  local label="$1" seconds="$2" env_args=() out_args=()
  # Only the measured run is in the series (the warm-up is not).
  if [ -n "$per_second" ] && [ "$label" = measured ]; then
    env_args=(-e K6_CSV_SAVE_INTERVAL=250ms)
    out_args=(--out csv=/run/rt/csv)
  fi
  docker exec -e K6_NO_USAGE_REPORT=true ${env_args[@]+"${env_args[@]}"} "$K6C" k6 run --quiet --no-color ${out_args[@]+"${out_args[@]}"} \
    -e "RATE=$rate" -e "DURATION=${seconds}s" -e "TARGET_URL=$target_url" -e "PRE_VUS=$pre_vus" -e "MAX_VUS=$max_vus" \
    --summary-trend-stats 'avg,min,med,p(90),p(95),p(99),max' --summary-export "/tmp/$label.json" "$script_in" \
    >"$tmp/$label.log" 2>&1 || { echo "macro: k6 ($label run) failed:" >&2; tail -n 20 "$tmp/$label.log" >&2; exit 1; }
  docker exec "$K6C" cat "/tmp/$label.json" >"$tmp/$label.json"
}

if [ "$warmup" -gt 0 ]; then
  echo "warm-up: ${warmup}s at $rate req/s" >&2
  run_k6 warmup "$warmup"
else
  echo '{}' >"$tmp/warmup.json"
fi

# What the server costs when nothing is asked of it, over 2 s right after the warm-up.
idle_before="$(probe cpu "$server_id" "$k6_id" | lines_to_json)"
sleep 2
idle_after="$(probe cpu "$server_id" "$k6_id" | lines_to_json)"

echo "measured run: ${duration}s at $rate req/s" >&2
# Every running container that is not one of this run's three, whoever started it (another checkout's lab run included).
other_names=()
while IFS= read -r name; do [ -z "$name" ] || other_names+=("$name"); done < <(lab_other_containers "$SERVER" "$K6C" "$PROBE" "$AGG")
other_json="$(jq -nc --argjson names "$(json_array "${other_names[@]+"${other_names[@]}"}")" '{count: ($names | length), names: $names}')"
other_warning=""
if [ "${#other_names[@]}" -gt 0 ]; then
  other_warning="WARNING: ${#other_names[@]} other containers running (${other_names[*]})"
  echo "$other_warning" >&2
fi
if [ -n "$per_second" ]; then
  # The aggregator on k6's CPUs reads the CSV from the FIFO as k6 writes it (no step to judge: the endpoints are the URLs' paths, numbers as :id).
  agg_config="$(jq -nc '{fifo: "/run/rt/csv", status: "/run/rt/status.json", result: "/run/rt/result.json", steps: [], stop_on_fail: false,
    users_per_rps: 1, server_cgroup: null, k6_cgroup: null, normalize_names: true,
    limits: {p95_ms: 500, p99_ms: 1000, error_rate: 0.01, achieved_ratio: 0.97}}')"
  docker run -d --name "$AGG" --cpuset-cpus "$LAB_CPUSET_K6" -v "$LAB:/lab:ro" -v "$VOLUME:/run/rt" -e "AGG_CONFIG=$agg_config" "$LAB_IMAGE:$image" \
    php -d memory_limit=-1 -d opcache.enable_cli=1 -d opcache.jit=tracing -d opcache.jit_buffer_size=32M /lab/macro/aggregate.php >/dev/null
  sampler_start measured "$([ -n "$fresh_db" ] && echo "$LAB_APP_DB" || echo -)"
fi
before="$(probe cpu "$server_id" "$k6_id" | lines_to_json)"
# Why in the background: the connections and the memory are read while k6 runs (the connections close when it ends, and the
# memory at rest is not the memory under load), at 1/4, 1/2 and 3/4 of the run.
run_k6 measured "$duration" &
k6_job=$!
connections='{}'
memory_now='{}'
for quarter in 1 2 3; do
  sleep "$(awk -v d="$duration" 'BEGIN { printf "%.2f", d / 4 }')"
  connections="$(jq -c --argjson n "$(probe connections "$port" | lines_to_json | jq '.connections.established')" --arg q "q$quarter" '. + {($q): $n}' <<<"$connections")"
  memory_now="$(jq -c --argjson m "$(probe memory-now "$server_id" | lines_to_json | jq '.memory_now')" --arg q "q$quarter" '. + {($q): $m}' <<<"$memory_now")"
done
wait "$k6_job" || exit 1
after="$(probe cpu "$server_id" "$k6_id" | lines_to_json)"
memory="$(probe memory "$server_id" | lines_to_json)"
server_running="$(docker inspect -f '{{.State.Running}}' "$SERVER")"
[ "$server_running" = true ] || fail "the server container died during the run"

# The profile: the requests of the profiled window are the warm-up's and the measured run's (k6's counts).
if [ -n "$profile_out" ]; then
  profile_collect "$(jq -s '[.[].metrics.http_reqs.count // 0] | add' "$tmp/warmup.json" "$tmp/measured.json")"
fi

# The per-second series: the sampler's lines, the aggregator's latency rows and the server's telemetry lines, joined by second.
series_json=null
series_note=null
if [ -n "$per_second" ]; then
  sampler_stop measured
  docker exec "$PROBE" sh -c 'printf "#END\n" > /run/rt/csv'
  for _ in $(seq 1 60); do
    docker exec "$PROBE" test -f /run/rt/result.json 2>/dev/null && break
    [ "$(docker inspect -f '{{.State.Running}}' "$AGG" 2>/dev/null)" = true ] || break
    sleep 0.5
  done
  docker exec "$PROBE" cat /run/rt/result.json >"$tmp/agg.json" 2>/dev/null || { echo "macro: the aggregator left no result:" >&2; docker logs "$AGG" >&2 || true; exit 1; }
  series_build measured "$tmp/agg.json"
  series_json="$(cat "$tmp/measured.series.json")"
  series_note="$(jq -c '{max_lag_s: .lag_max_s, rows: .rows, requests: .requests, unparsed: .unparsed, connection_errors: .connection_errors,
    error_codes: (.error_codes | if type == "array" then {} else . end)}' "$tmp/agg.json")"
fi

# --- the numbers -----------------------------------------------------------------------------------------------------
jq -n \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg command "$command_line" \
  --arg docker "$(docker version --format '{{.Server.Platform.Name}}')" \
  --arg engine "$(docker version --format '{{.Server.Version}}')" \
  --arg kernel "$(docker info --format '{{.KernelVersion}}')" \
  --arg arch "$(uname -m)" --arg limits "${LAB_RESOURCE_FLAGS[*]}" \
  --arg variant "$image" --arg image_id "$(docker image inspect -f '{{.Id}}' "$LAB_IMAGE:$image")" \
  --arg php_version "$php_version" --arg swoole_version "$swoole_version" \
  --arg server_file "${server_in#/lab/}" --arg flags "${LAB_PHP_FLAGS[*]}" --argjson php_ini "$php_ini_json" --argjson port "$port" \
  --arg k6_image "$LAB_K6_IMAGE" --arg k6_version "$k6_version" --arg script "${script_in#/lab/}" --arg url "$target_url" \
  --argjson rate "$rate" --argjson duration "$duration" --argjson warmup "$warmup" \
  --argjson pre_vus "$pre_vus" --argjson max_vus "$max_vus" \
  --arg cpuset_server "$LAB_CPUSET_SERVER" --arg cpuset_k6 "$LAB_CPUSET_K6" --arg cpuset_probe "$LAB_CPUSET_PROBE" \
  --argjson before "$before" --argjson after "$after" --argjson idle_before "$idle_before" --argjson idle_after "$idle_after" \
  --argjson ext "$(json_array "${LAB_EXT[@]}")" --argjson env "$(json_array "${LAB_ENV[@]+"${LAB_ENV[@]}"}")" --arg label "$label" \
  --arg socket_line "$socket_line" --argjson other_containers "$other_json" --argjson memory_now "$memory_now" \
  --argjson memory "$memory" --argjson connections "$connections" --argjson cold "$cold_json" --argjson series "$series_json" \
  --argjson series_agg "$series_note" --argjson profile "$profile_json" --argjson lag_gate "$LAG_GATE_S" --slurpfile measured "$tmp/measured.json" --slurpfile warmup_summary "$tmp/warmup.json" '
  def mib: . / 1048576 * 100 | round / 100;
  ($measured[0].metrics) as $m
  | ($m.http_reqs.count // 0) as $requests
  | ($after.server.usage_usec - $before.server.usage_usec) as $server_usec
  | ($after.time.us - $before.time.us) as $window_us
  | ($after.k6.usage_usec - $before.k6.usage_usec) as $k6_usec
  | ($m.http_req_failed.value // 0) as $error_rate
  | ($m.dropped_iterations.count // 0) as $dropped
  | ([ (if $requests == 0 then "no request was sent" else empty end),
       (if $error_rate > 0 then "error rate \($error_rate * 100)% is above 0%" else empty end),
       (if $series_agg != null and $series_agg.max_lag_s > $lag_gate then "the aggregator fell behind k6: lag \($series_agg.max_lag_s) s, above \($lag_gate) s (the per-second series is not trustworthy)" else empty end),
       (if $series_agg != null and $series_agg.unparsed > 0 then "\($series_agg.unparsed) k6 duration rows could not be parsed by the aggregator" else empty end),
       (if $dropped > 0 then "\($dropped) dropped iterations: k6 had no free VU to start them (\($max_vus) VUs absorb a stall of \($max_vus * 1000 / $rate | floor) ms at \($rate) req/s; latency max was \($m.http_req_duration.max // 0 | floor) ms)" else empty end) ]) as $reasons
  | {
    date: $date,
    command: $command,
    label: (if $label == "" then null else $label end),
    other_containers: $other_containers,
    valid: ($reasons | length == 0),
    invalid_reasons: $reasons,
    host: {docker_desktop: $docker, engine: $engine, vm_kernel: $kernel, arch: $arch,
           cpuset_server: $cpuset_server, cpuset_k6: $cpuset_k6, cpuset_probe: $cpuset_probe, limits: $limits},
    server: {variant: $variant, image_id: $image_id, php_version: $php_version, swoole_version: $swoole_version,
             file: $server_file, port: $port, php_flags: $flags, ini: $php_ini, ext: $ext, env: $env,
             socket: (if $socket_line == "" then null
                      else ($socket_line | split(" ") | map(split("=") | {(.[0]): (.[1] | tonumber? // .[1])}) | add) end)},
    k6: {image: $k6_image, version: $k6_version, script: $script, target_url: $url, rate: $rate, duration_s: $duration,
         warmup_s: $warmup, pre_allocated_vus: $pre_vus, max_vus: $max_vus},
    cold: $cold, profile: $profile,
    results: {
      per_second: (if $series == null then null else {aggregator: $series_agg, rows: $series} end),
      requests: $requests,
      requested_req_per_s: $rate,
      achieved_req_per_s: ($m.http_reqs.rate // null),
      server_cpu_usec: $server_usec,
      cpu_usec_per_request: (if $requests > 0 then $server_usec / $requests else null end),
      latency_ms: {avg: $m.http_req_duration.avg, min: $m.http_req_duration.min, p50: $m.http_req_duration.med,
                   p90: $m.http_req_duration["p(90)"], p95: $m.http_req_duration["p(95)"],
                   p99: $m.http_req_duration["p(99)"], max: $m.http_req_duration.max},
      error_rate: $error_rate,
      dropped_iterations: $dropped,
      vus_used: ($m.vus.max // null),
      connections_open: ([$connections[]] | max),
      connections_samples: $connections,
      window_s: ($window_us / 1000000),
      server_cpu_percent_of_one_cpu: ($server_usec / $window_us * 100),
      server_throttled_usec: ($after.server.throttled_usec - $before.server.throttled_usec),
      server_idle_usec_per_s: (($idle_after.server.usage_usec - $idle_before.server.usage_usec) / (($idle_after.time.us - $idle_before.time.us) / 1000000)),
      k6_cpu_percent_of_one_cpu: ($k6_usec / $window_us * 100),
      memory: {
        cgroup_memory_peak_mib: ($memory.memory.peak | mib),
        cgroup_memory_current_mib: ($memory.memory.current | mib),
        vmhwm_mib: ($memory.vmhwm_kb | to_entries | map(.value) | max / 1024 * 100 | round / 100),
        note: "memory.peak counts page cache, VmHWM does not; both cover the whole life of the server, warm-up included",
        under_load: {
          samples: $memory_now,
          max_pss_mib: ([$memory_now[].pss_kb] | max / 1024 * 100 | round / 100),
          max_pss_anon_mib: ([$memory_now[].pss_anon_kb] | max / 1024 * 100 | round / 100),
          max_cgroup_current_mib: ([$memory_now[].cgroup_current] | max | mib),
          note: "read at 1/4, 1/2 and 3/4 of the measured run; Pss and Pss_Anon are sums over the server processes (/proc/<pid>/smaps_rollup), a shared page split between the processes that map it. Pss includes the mapped SQLite database pages (they grow with the rows the requests touched); Pss_Anon does not: compare runtimes on Pss_Anon and cgroup memory.current"
        }
      }
    },
    raw: {
      cpu_stat_before: $before, cpu_stat_after: $after, cpu_stat_idle_before: $idle_before, cpu_stat_idle_after: $idle_after,
      memory: $memory, k6_summary_measured: $measured[0], k6_summary_warmup: $warmup_summary[0]
    }
  }' >"$out"

# The table reads the JSON just written, so what is printed is what is stored.
IFS=$'\t' read -r valid requests achieved usec p50 p95 p99 pmax err dropped vus conns peak hwm k6cpu srvpct idle thr window pss_now anon_now cur_now socket < <(
  jq -r '.results as $r | [.valid, $r.requests, $r.achieved_req_per_s, $r.cpu_usec_per_request, $r.latency_ms.p50,
    $r.latency_ms.p95, $r.latency_ms.p99, $r.latency_ms.max, $r.error_rate, $r.dropped_iterations, $r.vus_used, $r.connections_open,
    $r.memory.cgroup_memory_peak_mib, $r.memory.vmhwm_mib, $r.k6_cpu_percent_of_one_cpu,
    $r.server_cpu_percent_of_one_cpu, $r.server_idle_usec_per_s, $r.server_throttled_usec, $r.window_s,
    $r.memory.under_load.max_pss_mib, $r.memory.under_load.max_pss_anon_mib, $r.memory.under_load.max_cgroup_current_mib,
    (.server.socket // "none printed" | if type == "object" then to_entries | map("\(.key)=\(.value)") | join(" ") else . end)]
    | map(if . == null then "n/a" elif type == "number" then (. * 100 | round / 100) else . end) | @tsv' "$out")
echo
echo "image $image (PHP $php_version${swoole_version:+, Swoole $swoole_version}), $(basename "$server_file"), $k6_version"
echo "requested $rate req/s for ${duration}s (warm-up ${warmup}s), target $target_url"
printf '  %-28s %s\n' \
  "requests" "$requests" \
  "achieved req/s" "$achieved" \
  "CPU us / request" "$usec" \
  "latency ms p50 / p95 / p99" "$p50 / $p95 / $p99" \
  "latency ms max" "$pmax" \
  "error rate" "$(awk -v e="$err" 'BEGIN{printf "%.2f%%", e*100}')" \
  "dropped iterations" "$dropped" \
  "VUs running at once (max)" "$vus (of $max_vus max)" \
  "connections open (max of 3)" "$conns (k6 pre-allocated $pre_vus VUs)" \
  "peak RSS, cgroup memory.peak" "$peak MiB (counts page cache)" \
  "peak RSS, VmHWM" "$hwm MiB" \
  "memory under load (max of 3)" "Pss $pss_now MiB (with the mapped database), Pss_Anon $anon_now MiB, cgroup memory.current $cur_now MiB" \
  "socket settings (server's boot line)" "$socket" \
  "server CPU over the window" "$srvpct % of one CPU ($window s window, idle $idle us/s, throttled $thr us)" \
  "k6 CPU over the window" "$k6cpu % of one CPU (k6 is pinned to $(awk -F- '{print $2-$1+1}' <<<"$LAB_CPUSET_K6") CPUs)"
jq -r 'select(.cold != null) | .cold | "database copy in the page cache when the server opened it (fincore): \(.resident_bytes) of \(.size_bytes) bytes, \(.resident_share * 100 | round) %, --cold \(if .requested then "on" else "off" end)"' "$out"
if [ -n "$per_second" ]; then
  jq -r '.results.per_second.aggregator | "per-second series: \(.requests) requests read by the aggregator (lag at most \(.max_lag_s) s, \(.unparsed) rows unparsed), \(.connection_errors) k6 connection errors"' "$out"
  echo
  jq '.results.per_second.rows' "$out" >"$tmp/series.json"
  series_print "$tmp/series.json"
  echo
fi
profile_print
[ -z "$other_warning" ] || echo "$other_warning"
if [ "$valid" = true ]; then
  echo "VALID"
else
  echo "INVALID: $(jq -r '.invalid_reasons | join("; ")' "$out")"
fi
echo "wrote ${out#"$REPO"/}"
[ "$valid" = true ] || exit 3
