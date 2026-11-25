#!/usr/bin/env bash
# Counts the syscalls the server makes per request: a realistic hold at a low rate (lab/realistic.sh, no idle connections, no per-second
# probes) and, during its plateau, a sidecar container in the server's pid namespace runs `strace -c -f` on the server for a fixed number
# of seconds. Each syscall's count is divided by the requests of the same seconds.
#
#   bash lab/syscalls.sh --image 8.5                                  # the skeleton, 2,000 req/s, 20 s of strace
#   bash lab/syscalls.sh --image 8.5 --env APP_SOMETHING=1 --out /tmp/count.json
#                        [--rate 2000] [--think-scale 0.1] [--seconds 20] [--server <php file under lab/ or submissions/>] [--env K=V]...
#
# Only counts are kept. strace stops the server at every syscall, so it slows it down and its times mean nothing; its time columns are
# dropped (lab/syscalls-table.awk). The requests are the aggregator's (lab/macro/aggregate.php, one row per second of k6's own samples),
# summed over the whole seconds the strace ran: the server serves fewer requests than the nominal rate while it is traced, so the
# division uses what it served. The window starts on a whole second of the VM's clock, where the aggregator's seconds start.
#
# strace comes from lab/images/Dockerfile.strace (a pinned Ubuntu and a pinned strace version). Its raw output stays in a temporary
# folder: only the table of counts is written to the JSON, never paths or process ids. The telemetry of the server is off unless --env
# sets it (the lab's runs compare servers on CPU per request with it off). If strace cannot attach (Docker Desktop's VM may refuse
# ptrace), the script prints strace's own message and exits 1.
# Exit codes: 0 counted, 1 harness failure (strace included), 2 usage, 3 the realistic run was INVALID (its requests cannot be trusted).
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$LAB")"
# shellcheck source=lib.sh
source "$LAB/lib.sh"

# The names of lab/realistic.sh's containers and the aggregator's status file: the sidecar joins the server's pid namespace, and the
# plateau is found in the status the aggregator writes once a second.
SERVER=lab-realistic-server
PROBE=lab-realistic-probe
SIDECAR=lab-syscalls-strace
STATUS_FILE=/run/rt/status.json
# Seconds of the plateau before the trace starts (the ramp's last VUs have arrived and the server is warm), and after it ends.
LEAD_S=3
TAIL_S=5
# The writes of one response: a server answering with one of these per request is at about 1 per request.
WRITE_FAMILY='["write", "sendto", "writev"]'

usage() {
  cat >&2 <<'EOF'
usage: lab/syscalls.sh --image <variant> [--rate <req/s>] [--think-scale <s>] [--seconds <s>] [--server <php file under lab/ or submissions/>]
                       [--env K=V]... [--out <path>]
defaults: --rate 2000, --think-scale 0.1, --seconds 20
EOF
  exit 2
}
fail() { echo "syscalls: $*" >&2; exit 1; }

command_line="lab/syscalls.sh $*"
command_line="${command_line//$REPO/.}"

image="" rate=2000 think_scale=0.1 seconds=20 server_file="$LAB/app/server.php" out=""
ENVS=()
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; usage; }
  case "$1" in
    --image) image="$2" ;;
    --rate) rate="$2" ;;
    --think-scale) think_scale="$2" ;;
    --seconds) seconds="$2" ;;
    --server) server_file="$2" ;;
    --env) ENVS+=("$2") ;;
    --out) out="$2" ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
  shift 2
done
[ -n "$image" ] || { echo "--image is required" >&2; usage; }
lab_require_variant "$image" || exit 2
for n in rate seconds; do
  [[ "${!n}" =~ ^[1-9][0-9]*$ ]] || { echo "--$n must be a whole number from 1, got '${!n}'" >&2; usage; }
done
[ "$seconds" -ge 5 ] || { echo "--seconds must be at least 5 (a shorter trace is mostly the attach)" >&2; usage; }
[[ "$think_scale" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "--think-scale must be a number, got '$think_scale'" >&2; usage; }
for kv in "${ENVS[@]+"${ENVS[@]}"}"; do
  [[ "$kv" == ?*=* ]] || { echo "--env must be K=V, got '$kv'" >&2; usage; }
done

docker image inspect "$LAB_IMAGE:$image" >/dev/null 2>&1 || fail "image $LAB_IMAGE:$image is missing (run lab/build.sh $image)"
lab_in_container_path "$server_file" >/dev/null || exit 1
docker ps -a --format '{{.Names}}' | grep -x "$SIDECAR" >/dev/null && fail "a sidecar of an earlier run is still there: docker rm -f $SIDECAR"
lab_ensure_strace_image || fail "cannot build $LAB_STRACE_IMAGE"

# The VUs that offer the rate (the same arithmetic as lab/realistic.sh), to know when the plateau has started.
vus="$(awk -v r="$rate" -v s="$think_scale" 'BEGIN { v = r * 20.5 * s / 2.17; printf "%d", (v == int(v)) ? v : int(v) + 1 }')"
plateau=$(( seconds + LEAD_S + TAIL_S ))
warm_rate=$(( rate / 10 > 0 ? rate / 10 : 1 ))

stamp="$(date -u +%Y%m%d-%H%M%S)"
[ -n "$out" ] || out="$LAB/results/syscalls-$(basename "$server_file" .php)-$image-$stamp.json"
mkdir -p "$(dirname "$out")"

tmp="$(mktemp -d)"
run_pid=""
cleanup() {
  local rc=$?
  # The realistic run removes its own containers when it is told to stop.
  if [ -n "$run_pid" ] && kill -0 "$run_pid" 2>/dev/null; then
    kill -TERM "$run_pid" 2>/dev/null || true
    wait "$run_pid" 2>/dev/null || true
  fi
  docker rm -f "$SIDECAR" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

env_args=()
telemetry_set=""
for kv in "${ENVS[@]+"${ENVS[@]}"}"; do
  env_args+=(--env "$kv")
  [[ "$kv" != APP_TELEMETRY=* ]] || telemetry_set=1
done
[ -n "$telemetry_set" ] || env_args+=(--env APP_TELEMETRY=0)

echo "syscalls: a realistic hold of $rate req/s (think scale $think_scale, $vus VUs, plateau ${plateau}s), strace for ${seconds}s from ${LEAD_S}s into the plateau" >&2
bash "$LAB/realistic.sh" --image "$image" --think-scale "$think_scale" --hold "$rate,$plateau" --no-series --warmup "$warm_rate,10" \
  --server "$server_file" "${env_args[@]}" --out "$tmp/run.json" >"$tmp/realistic.out" 2>"$tmp/realistic.err" &
run_pid=$!

# The plateau has started when the aggregator sees the step's VUs.
started=""
for _ in $(seq 1 1200); do
  kill -0 "$run_pid" 2>/dev/null || break
  status="$(docker exec "$PROBE" cat "$STATUS_FILE" 2>/dev/null || true)"
  if [ -n "$status" ] && [ "$(jq -r --argjson v "$vus" '(.vus_now // 0) >= $v' <<<"$status" 2>/dev/null || echo false)" = true ]; then
    started=1
    break
  fi
  sleep 0.5
done
if [ -z "$started" ]; then
  run_rc=0
  wait "$run_pid" || run_rc=$?
  run_pid=""
  echo "syscalls: the realistic run ended (exit $run_rc) before its plateau:" >&2
  tail -n 15 "$tmp/realistic.err" "$tmp/realistic.out" >&2 || true
  exit 1
fi
sleep "$LEAD_S"

# The sidecar: the server's PID is the first `php` of the shared pid namespace. It starts the trace on a whole second of the clock the
# aggregator's rows use, prints that second, then strace's table (its own table goes to a file: -o).
docker run --rm --name "$SIDECAR" --pid "container:$SERVER" --cap-add SYS_PTRACE --cpuset-cpus "$LAB_CPUSET_PROBE" "$LAB_STRACE_IMAGE" sh -c '
  seconds="$1"
  pid=""
  for p in /proc/[0-9]*; do
    if [ "$(cat "$p/comm" 2>/dev/null)" = php ]; then pid="${p#/proc/}"; break; fi
  done
  [ -n "$pid" ] || { echo "sidecar: no php process in the server container" >&2; exit 1; }
  ns="$(date +%s%N)"
  frac=$(( 1000000000 - ns % 1000000000 ))
  sleep "$(printf "0.%09d" "$(( frac % 1000000000 ))")"
  echo "window_start $(date +%s)"
  timeout -s INT "$seconds" strace -c -f -o /tmp/strace.txt -p "$pid" 2>/tmp/strace.err
  if [ ! -s /tmp/strace.txt ]; then cat /tmp/strace.err >&2; exit 1; fi
  echo "window_end $(date +%s)"
  cat /tmp/strace.txt' sidecar "$seconds" >"$tmp/strace.out" 2>"$tmp/strace.err" || {
  echo "syscalls: strace could not trace the server (Docker Desktop's VM may refuse ptrace from a sidecar):" >&2
  cat "$tmp/strace.err" >&2
  exit 1
}
grep -q '^window_start ' "$tmp/strace.out" && grep -q ' total$' "$tmp/strace.out" || {
  echo "syscalls: strace printed no table:" >&2
  cat "$tmp/strace.out" "$tmp/strace.err" >&2
  exit 1
}

run_rc=0
wait "$run_pid" || run_rc=$?
run_pid=""
if [ "$run_rc" = 3 ]; then
  echo "syscalls: the realistic run is INVALID, its requests cannot be trusted: $(jq -r '.invalid_reasons | join("; ")' "$tmp/run.json" 2>/dev/null)" >&2
  exit 3
fi
[ "$run_rc" = 0 ] || { echo "syscalls: the realistic run failed (exit $run_rc):" >&2; tail -n 15 "$tmp/realistic.err" >&2; exit 1; }

start_s="$(sed -n 's/^window_start //p' "$tmp/strace.out")"
end_s="$(sed -n 's/^window_end //p' "$tmp/strace.out")"
# The requests of the whole seconds of the window; every one of them must have a row (a second with no request has none).
read -r requests rows < <(jq -r --argjson s "$start_s" --argjson n "$seconds" \
  '[.results.per_second[] | select(.second >= $s and .second < $s + $n)] | "\(map(.requests) | add // 0) \(length)"' "$tmp/run.json")
[ "$rows" -eq "$seconds" ] || fail "the aggregator has $rows rows for the $seconds seconds of the window starting at $start_s (ended at $end_s): the trace is not inside the plateau"
[ "$requests" -gt 0 ] || fail "no request in the window"

awk -f "$LAB/syscalls-table.awk" "$tmp/strace.out" >"$tmp/counts.txt"
strace_version="$(docker run --rm "$LAB_STRACE_IMAGE" strace -V | head -n 1)"

jq -Rn --argjson requests "$requests" --argjson seconds "$seconds" --argjson start "$start_s" --argjson end "$end_s" --argjson rate "$rate" \
  --argjson think "$think_scale" --arg image "$image" --arg server "${server_file#"$LAB"/}" --arg command "$command_line" --arg strace "$strace_version" \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --argjson env "$(jq -nc '$ARGS.positional' --args "${ENVS[@]+"${ENVS[@]}"}")" --argjson family "$WRITE_FAMILY" '
  [inputs | split(" ") | {name: .[0], calls: (.[1] | tonumber), errors: (.[2] | tonumber)}] as $rows
  | ($rows | map(select(.name != "total")) | sort_by(-.calls, .name)
     | map(. + {calls_per_request: (.calls / $requests * 1000 | round / 1000)})) as $calls
  | ($rows | map(select(.name == "total"))[0]) as $total
  | {date: $date, command: $command, image: $image, server: $server, env: $env, strace: $strace,
     counted_with: "the aggregator'"'"'s request count over the same whole seconds (time columns dropped: strace slows the server)",
     offered_rps: $rate, think_scale: $think,
     window: {start_epoch_s: $start, end_epoch_s: $end, seconds: $seconds}, requests: $requests,
     syscalls: $calls,
     total: {calls: $total.calls, errors: $total.errors, calls_per_request: ($total.calls / $requests * 1000 | round / 1000)},
     write_family: {names: $family, calls_per_request: (([$calls[] | select(.name as $n | $family | index($n)) | .calls] | add // 0) / $requests * 1000 | round / 1000)}}' \
  <"$tmp/counts.txt" >"$out"

echo
echo "image $image, $(basename "$server_file"), strace ${strace_version#strace -- version }: $seconds s of strace -c -f, requests counted by the aggregator over the same seconds"
echo "$(jq -r '.requests' "$out") requests in the window (offered $rate req/s; the server serves fewer while it is traced)"
printf '%-22s %10s %14s %8s\n' syscall calls "calls/request" errors
jq -r '.syscalls[] | [.name, .calls, .calls_per_request, .errors] | map(tostring) | join("\t")' "$out" |
  while IFS=$'\t' read -r name calls per errors; do
    printf '%-22s %10s %14s %8s\n' "$name" "$calls" "$per" "$errors"
  done
jq -r '.total | "\(.calls) \(.calls_per_request) \(.errors)"' "$out" |
  while read -r calls per errors; do
    printf '%-22s %10s %14s %8s\n' total "$calls" "$per" "$errors"
  done
jq -r '"write family (write, sendto, writev): \(.write_family.calls_per_request) per request"' "$out"
echo "wrote ${out#"$REPO"/}"
