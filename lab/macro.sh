#!/usr/bin/env bash
# Loads a PHP server running in a lab container with k6 at a fixed request rate, and reports what a request costs the
# server (CPU microseconds), the latency, the errors and the memory.
#
#   bash lab/macro.sh --image 8.4 --server lab/servers/noop-swoole.php --rate 2000 --duration 30
#                     [--warmup 10] [--script lab/macro/k6/fixed-rate.js] [--out <path>] [--port 18080]
#                     [--path /] [--pre-vus <n>] [--max-vus <n>] [--php-ini key=value]...
#
# Three containers, all on the host network of Docker's VM (never k6 from macOS: Docker Desktop forwards a port from the
# Mac through a userspace proxy, which would pollute every number):
#   server  php-lab:<image> running the server file, 1 CPU, 2 GiB, pinned to the server CPU (lab/lib.sh);
#   k6      the pinned grafana/k6 image, pinned to the k6 CPUs, no CPU limit;
#   probe   php-lab:<image> sleeping, --cgroupns host --pid host: it reads cpu.stat, memory.peak and /proc from OUTSIDE
#           the server's and k6's cgroups, so a read is never part of the number it reads.
#
# µs CPU per request = (server cgroup usage_usec after the measured run - before) / requests k6 sent in that run.
# Prints a table and writes a JSON file with every number (default: lab/results/macro-<server>-<image>-<rate>rps-<UTC
# date and time>.json). Exit codes: 0 valid run, 3 run printed but INVALID (errors above 0 % or dropped iterations),
# 1 any other failure (bad argument, server did not start, k6 failed), 2 usage. The three containers are removed at the
# end, whatever happens.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$LAB")"
# shellcheck source=lib.sh
source "$LAB/lib.sh"

SERVER=lab-macro-server
K6C=lab-macro-k6
PROBE=lab-macro-probe

usage() {
  echo "usage: lab/macro.sh --image <variant> --server <php file under lab/> --rate <req/s> --duration <s> [--warmup <s>]" >&2
  echo "                    [--script <k6 js under lab/>] [--out <path>] [--port <n>] [--path </url/path>]" >&2
  echo "                    [--pre-vus <n>] [--max-vus <n>] [--php-ini key=value]..." >&2
  exit 2
}
fail() { echo "macro: $*" >&2; exit 1; }

command_line="lab/macro.sh $*"
command_line="${command_line//$REPO/.}"

image="" server_file="" rate="" duration="" warmup=10 script="$LAB/macro/k6/fixed-rate.js" out="" port=18080 url_path=/
pre_vus= max_vus= php_ini=()
while [ "$#" -gt 0 ]; do
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
    --php-ini) php_ini+=("$2") ;;
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
[ "$rate" -ge 1 ] && [ "$duration" -ge 1 ] || { echo "--rate and --duration must be at least 1" >&2; usage; }
[[ "$url_path" == /* ]] || { echo "--path must start with /" >&2; usage; }

# Everything is checked before the first container starts.
lab_require_variant "$image" || exit 1
docker image inspect "$LAB_IMAGE:$image" >/dev/null 2>&1 || fail "image $LAB_IMAGE:$image is missing (run lab/build.sh $image)"
in_container_path() { # <file under lab/>: prints its path in the containers, where lab/ is mounted at /lab
  local abs
  [ -f "$1" ] || fail "file not found: $1"
  abs="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  case "$abs" in
    "$LAB"/*) echo "/lab/${abs#"$LAB"/}" ;;
    *) fail "the file must be under lab/ (it is mounted in the containers): $1" ;;
  esac
}
server_in="$(in_container_path "$server_file")"
script_in="$(in_container_path "$script")"
if [ -n "$(docker ps -a --format '{{.Names}}' | grep -x -e "$SERVER" -e "$K6C" -e "$PROBE" || true)" ]; then
  fail "a lab/macro.sh run is in progress, or one was killed: remove its containers first (docker rm -f $SERVER $K6C $PROBE)"
fi
docker image inspect "$LAB_K6_IMAGE" >/dev/null 2>&1 || { echo "pulling $LAB_K6_IMAGE" >&2; docker pull -q "$LAB_K6_IMAGE" >/dev/null || fail "cannot pull $LAB_K6_IMAGE"; }

stamp="$(date -u +%Y%m%d-%H%M%S)"
if [ -z "$out" ]; then
  out="$LAB/results/macro-$(basename "$server_file" .php)-$image-${rate}rps-$stamp.json"
fi
mkdir -p "$LAB/results" "$LAB/data" "$(dirname "$out")"

tmp="$(mktemp -d)"
cleanup() {
  local rc=$?
  docker rm -f "$SERVER" "$K6C" "$PROBE" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

probe() { docker exec "$PROBE" bash /lab/macro/probe.sh "$@"; }
# `<group> <key> <number>` lines on stdin to {"group": {"key": number}}.
lines_to_json() {
  jq -Rn 'reduce (inputs | split(" ") | select(length == 3)) as $l ({}; .[$l[0]][$l[1]] = ($l[2] | tonumber? // $l[2]))'
}

# --- the probe and the server ---------------------------------------------------------------------------------------
docker run -d --name "$PROBE" --network host --cgroupns host --pid host --cpuset-cpus "$LAB_CPUSET_PROBE" \
  -v "$LAB:/lab:ro" "$LAB_IMAGE:$image" sleep 86400 >/dev/null

# Why: 8080 and 80 are often taken on the VM's host network by other containers; a server that fails to bind would let
# the wait below succeed against somebody else's server.
if probe port-open "$port"; then
  fail "port $port is already in use on the VM's host network: pick another with --port"
fi

php_flags=("${LAB_SERVER_PHP_FLAGS[@]}")
for kv in "${php_ini[@]+"${php_ini[@]}"}"; do php_flags+=(-d "$kv"); done
docker run -d --name "$SERVER" "${LAB_RESOURCE_FLAGS[@]}" --network host --cpuset-cpus "$LAB_CPUSET_SERVER" \
  -v "$LAB:/lab:ro" -v "$LAB/data:/lab/data" -e "PORT=$port" \
  "$LAB_IMAGE:$image" php "${php_flags[@]}" "$server_in" >/dev/null

answered=""
for _ in $(seq 1 100); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$SERVER")" != true ]; then
    echo "macro: the server container exited:" >&2
    docker logs "$SERVER" >&2 || true
    exit 1
  fi
  if probe http-answers "$port" "$url_path"; then answered=1; break; fi
  sleep 0.2
done
[ -n "$answered" ] || { docker logs "$SERVER" >&2 || true; fail "the server did not answer on port $port within 20 s"; }

server_id="$(docker inspect -f '{{.Id}}' "$SERVER")"
php_version="$(docker exec "$PROBE" php -r 'echo PHP_VERSION;')"
swoole_version="$(docker exec "$PROBE" php -d extension=swoole -r 'echo phpversion("swoole") ?: "";' 2>/dev/null || true)"

# --- k6 --------------------------------------------------------------------------------------------------------------
# Why a long-lived container and `docker exec k6 run`: the container's cgroup has to exist when its cpu.stat is read after
# the measured run, and a container that ran k6 as its command is gone by then. The exec'd k6 runs inside its cgroup.
docker run -d --name "$K6C" --network host --cpuset-cpus "$LAB_CPUSET_K6" -v "$LAB:/lab:ro" \
  --entrypoint sleep "$LAB_K6_IMAGE" 86400 >/dev/null
k6_id="$(docker inspect -f '{{.Id}}' "$K6C")"
k6_version="$(docker exec "$K6C" k6 version | head -n 1)"
target_url="http://127.0.0.1:$port$url_path"

# run_k6 <label> <seconds>: the summary stays in the k6 container at /tmp/<label>.json.
run_k6() {
  local label="$1" seconds="$2"
  docker exec -e K6_NO_USAGE_REPORT=true "$K6C" k6 run --quiet --no-color \
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
before="$(probe cpu "$server_id" "$k6_id" | lines_to_json)"
# Why in the background: the connections are counted while k6 runs (they close when it ends), at 1/4, 1/2 and 3/4 of the run.
run_k6 measured "$duration" &
k6_job=$!
connections='{}'
for quarter in 1 2 3; do
  sleep "$(awk -v d="$duration" 'BEGIN { printf "%.2f", d / 4 }')"
  connections="$(jq -c --argjson n "$(probe connections "$port" | lines_to_json | jq '.connections.established')" --arg q "q$quarter" '. + {($q): $n}' <<<"$connections")"
done
wait "$k6_job" || exit 1
after="$(probe cpu "$server_id" "$k6_id" | lines_to_json)"
memory="$(probe memory "$server_id" | lines_to_json)"
server_running="$(docker inspect -f '{{.State.Running}}' "$SERVER")"
[ "$server_running" = true ] || fail "the server container died during the run"

# --- the numbers -----------------------------------------------------------------------------------------------------
jq -n \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg command "$command_line" \
  --arg docker "$(docker version --format '{{.Server.Platform.Name}}')" \
  --arg engine "$(docker version --format '{{.Server.Version}}')" \
  --arg kernel "$(docker info --format '{{.KernelVersion}}')" \
  --arg arch "$(uname -m)" --arg limits "${LAB_RESOURCE_FLAGS[*]}" \
  --arg variant "$image" --arg image_id "$(docker image inspect -f '{{.Id}}' "$LAB_IMAGE:$image")" \
  --arg php_version "$php_version" --arg swoole_version "$swoole_version" \
  --arg server_file "${server_in#/lab/}" --arg flags "${php_flags[*]}" --argjson port "$port" \
  --arg k6_image "$LAB_K6_IMAGE" --arg k6_version "$k6_version" --arg script "${script_in#/lab/}" --arg url "$target_url" \
  --argjson rate "$rate" --argjson duration "$duration" --argjson warmup "$warmup" \
  --argjson pre_vus "$pre_vus" --argjson max_vus "$max_vus" \
  --arg cpuset_server "$LAB_CPUSET_SERVER" --arg cpuset_k6 "$LAB_CPUSET_K6" --arg cpuset_probe "$LAB_CPUSET_PROBE" \
  --argjson before "$before" --argjson after "$after" --argjson idle_before "$idle_before" --argjson idle_after "$idle_after" \
  --argjson memory "$memory" --argjson connections "$connections" --slurpfile measured "$tmp/measured.json" --slurpfile warmup_summary "$tmp/warmup.json" '
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
       (if $dropped > 0 then "\($dropped) dropped iterations: k6 had no free VU to start them (\($max_vus) VUs absorb a stall of \($max_vus * 1000 / $rate | floor) ms at \($rate) req/s; latency max was \($m.http_req_duration.max // 0 | floor) ms)" else empty end) ]) as $reasons
  | {
    date: $date,
    command: $command,
    valid: ($reasons | length == 0),
    invalid_reasons: $reasons,
    host: {docker_desktop: $docker, engine: $engine, vm_kernel: $kernel, arch: $arch,
           cpuset_server: $cpuset_server, cpuset_k6: $cpuset_k6, cpuset_probe: $cpuset_probe, limits: $limits},
    server: {variant: $variant, image_id: $image_id, php_version: $php_version, swoole_version: $swoole_version,
             file: $server_file, port: $port, php_flags: $flags},
    k6: {image: $k6_image, version: $k6_version, script: $script, target_url: $url, rate: $rate, duration_s: $duration,
         warmup_s: $warmup, pre_allocated_vus: $pre_vus, max_vus: $max_vus},
    results: {
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
        note: "memory.peak counts page cache, VmHWM does not; both cover the whole life of the server, warm-up included"
      }
    },
    raw: {
      cpu_stat_before: $before, cpu_stat_after: $after, cpu_stat_idle_before: $idle_before, cpu_stat_idle_after: $idle_after,
      memory: $memory, k6_summary_measured: $measured[0], k6_summary_warmup: $warmup_summary[0]
    }
  }' >"$out"

# The table reads the JSON just written, so what is printed is what is stored.
IFS=$'\t' read -r valid requests achieved usec p50 p95 p99 pmax err dropped vus conns peak hwm k6cpu srvpct idle thr window < <(
  jq -r '.results as $r | [.valid, $r.requests, $r.achieved_req_per_s, $r.cpu_usec_per_request, $r.latency_ms.p50,
    $r.latency_ms.p95, $r.latency_ms.p99, $r.latency_ms.max, $r.error_rate, $r.dropped_iterations, $r.vus_used, $r.connections_open,
    $r.memory.cgroup_memory_peak_mib, $r.memory.vmhwm_mib, $r.k6_cpu_percent_of_one_cpu,
    $r.server_cpu_percent_of_one_cpu, $r.server_idle_usec_per_s, $r.server_throttled_usec, $r.window_s]
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
  "server CPU over the window" "$srvpct % of one CPU ($window s window, idle $idle us/s, throttled $thr us)" \
  "k6 CPU over the window" "$k6cpu % of one CPU (k6 is pinned to $(awk -F- '{print $2-$1+1}' <<<"$LAB_CPUSET_K6") CPUs)"
if [ "$valid" = true ]; then
  echo "VALID"
else
  echo "INVALID: $(jq -r '.invalid_reasons | join("; ")' "$out")"
fi
echo "wrote ${out#"$REPO"/}"
[ "$valid" = true ] || exit 3
