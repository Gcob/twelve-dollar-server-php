#!/usr/bin/env bash
# Measures how many idle keep-alive connections one server process holds, and what each one costs in memory.
#
#   bash lab/conns.sh --image 8.5 --server lab/servers/bake-swoole.php [--ext <name>]... [--env K=V]... [--label <text>]
#                     [--steps 1000,5000,...] [--max <n>] [--server-nofile <n>] [--port 18100] [--out <path>]
#
# --ext names a PHP extension to load (`-d extension=<name>`, repeatable, default `swoole`); --env K=V is passed to the server
# container (repeatable); --label goes in the JSON and in the default file name after the server's name; --max drops every
# step above it; --server-nofile replaces the server container's `nofile` limit (65535 in the lab), a test hook.
#
# Three containers, all on the host network of Docker's VM, like lab/macro.sh:
#   server  php-lab:<image> running the server file, 1 CPU, 2 GiB, pinned to the server CPU (lab/lib.sh);
#   client  php-lab:<image> running lab/conns/client.php, pinned to the load CPUs, `nofile` far above 66 000, no CPU or memory
#           limit: it opens the connections one at a time and holds them (see that file for why);
#   probe   php-lab:<image> sleeping, --cgroupns host --pid host: it reads the server's cgroup and /proc from outside.
# For each step the client opens connections up to the step's total, then waits while the probe reads what the server holds:
# summed Pss, memory.current, oom_kill, the established connections to the server port in /proc/net/tcp, and a fresh request
# from 127.0.0.1 that must answer within 1 s.
#
# Max connections: what the client got an answer on and still holds, at the last fully held step. The ceiling is the first step
# where a connect or a request times out (2 s), a connection is reset, a held connection is closed by the server (EOF), a
# connect is refused, an answer is wrong, the fresh request fails, or the server died or was OOM-killed. A client that fails
# itself (bind, no fd left, no free port) is a harness failure, never a ceiling.
# Memory per connection: least-squares slope of Pss (and of memory.current) against the connections held, over the held steps.
#
# Prints a table and writes a JSON file with every reading and the exact command (default: lab/results/conns-<server>[-<label>]-
# <image>-<UTC date and time>.json). Exit codes: 0 a ceiling was found or --max was reached (both are results), 1 the harness
# failed (client error, server never answered, probe failure), 2 usage. The containers are removed at the end, whatever happens.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$LAB")"
# shellcheck source=lib.sh
source "$LAB/lib.sh"

SERVER=lab-conns-server
CLIENT=lab-conns-client
PROBE=lab-conns-probe

# Far above the 66 000 sockets of the last default step, so a client that runs out of fds is a harness failure and not a result.
CLIENT_NOFILE=200000
DEFAULT_STEPS=1000,5000,10000,20000,30000,40000,50000,60000,65000,66000
# Time given to the server to settle after a step before its memory is read.
SETTLE_S=1

usage() {
  echo "usage: lab/conns.sh --image <variant> --server <php file under lab/> [--ext <name>]... [--env K=V]... [--label <text>]" >&2
  echo "                    [--steps a,b,...] [--max <n>] [--server-nofile <n>] [--port <n>] [--out <path>]" >&2
  exit 2
}
fail() { echo "conns: $*" >&2; exit 1; }

command_line="lab/conns.sh $*"
command_line="${command_line//$REPO/.}"

image="" server_file="" out="" port=18100 label="" steps_arg="$DEFAULT_STEPS" max="" server_nofile=""
LAB_EXT=() LAB_ENV=()
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; usage; }
  case "$1" in
    --image) image="$2" ;;
    --server) server_file="$2" ;;
    --ext) LAB_EXT+=("$2") ;;
    --env) LAB_ENV+=("$2") ;;
    --label) label="$2" ;;
    --steps) steps_arg="$2" ;;
    --max) max="$2" ;;
    --server-nofile) server_nofile="$2" ;;
    --port) port="$2" ;;
    --out) out="$2" ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
  shift 2
done
[ -n "$image" ] && [ -n "$server_file" ] || usage
[[ "$port" =~ ^[0-9]+$ ]] || { echo "--port must be a whole number, got '$port'" >&2; usage; }
for n in max server_nofile; do
  [ -z "${!n}" ] || [[ "${!n}" =~ ^[1-9][0-9]*$ ]] || { echo "--${n//_/-} must be a whole number above 0, got '${!n}'" >&2; usage; }
done
[ "${#LAB_EXT[@]}" -gt 0 ] || LAB_EXT=(swoole)
for kv in "${LAB_ENV[@]+"${LAB_ENV[@]}"}"; do
  [[ "$kv" == ?*=* ]] || { echo "--env must be K=V, got '$kv'" >&2; usage; }
done
# Why: the label becomes part of a file name.
[[ -z "$label" || "$label" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "--label may only hold letters, digits, . _ and -, got '$label'" >&2; usage; }

# The steps: whole numbers, strictly increasing; the ones above --max are not run.
steps=()
previous=0
IFS=, read -r -a all_steps <<<"$steps_arg"
for s in "${all_steps[@]}"; do
  [[ "$s" =~ ^[1-9][0-9]*$ ]] || { echo "--steps must be whole numbers above 0 separated by commas, got '$steps_arg'" >&2; usage; }
  [ "$s" -gt "$previous" ] || { echo "--steps must increase, got '$steps_arg'" >&2; usage; }
  previous="$s"
  if [ -z "$max" ] || [ "$s" -le "$max" ]; then steps+=("$s"); fi
done
[ "${#steps[@]}" -gt 0 ] || { echo "no step is at or below --max $max" >&2; usage; }

# Everything is checked before the first container starts.
lab_require_variant "$image" || exit 1
docker image inspect "$LAB_IMAGE:$image" >/dev/null 2>&1 || fail "image $LAB_IMAGE:$image is missing (run lab/build.sh $image)"
server_in="$(lab_in_container_path "$server_file")" || exit 1
if [ -n "$(docker ps -a --format '{{.Names}}' | grep -x -e "$SERVER" -e "$CLIENT" -e "$PROBE" || true)" ]; then
  fail "a lab/conns.sh run is in progress, or one was killed: remove its containers first (docker rm -f $SERVER $CLIENT $PROBE)"
fi
command -v jq >/dev/null || fail "jq is needed (it builds the JSON and the table)"

stamp="$(date -u +%Y%m%d-%H%M%S)"
if [ -z "$out" ]; then
  out="$LAB/results/conns-$(basename "$server_file" .php)${label:+-$label}-$image-$stamp.json"
fi
mkdir -p "$LAB/results" "$LAB/data" "$(dirname "$out")"

tmp="$(mktemp -d)"
client_pid=""
cleanup() {
  local rc=$?
  exec 7>&-
  [ -z "$client_pid" ] || kill "$client_pid" 2>/dev/null || true
  docker rm -f "$SERVER" "$CLIENT" "$PROBE" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
# Why: a write to the client's FIFO after the client died must fail with a message, not kill this script in silence.
trap '' PIPE

probe() { docker exec "$PROBE" bash /lab/macro/probe.sh "$@"; }
# json_array <string>...: the arguments as a JSON array (`[]` with none).
json_array() { jq -nc '$ARGS.positional' --args "$@"; }
# `<group> <key> <number>` lines on stdin to {"group": {"key": number}}.
lines_to_json() {
  jq -Rn 'reduce (inputs | split(" ") | select(length == 3)) as $l ({}; .[$l[0]][$l[1]] = ($l[2] | tonumber? // $l[2]))'
}

# --- the probe and the server ---------------------------------------------------------------------------------------
docker run -d --name "$PROBE" --network host --cgroupns host --pid host --cpuset-cpus "$LAB_CPUSET_PROBE" \
  -v "$LAB:/lab:ro" "$LAB_IMAGE:$image" sleep 86400 >/dev/null

# Why: a server that fails to bind would let the wait below succeed against somebody else's server.
if probe port-open "$port"; then
  fail "port $port is already in use on the VM's host network: pick another with --port"
fi

lab_build_php_flags
# Read by lab_start_server.
export LAB_SERVER_NOFILE="$server_nofile"
lab_start_server "$SERVER" "$image" "$port" "$server_in"

# The server copies the seed (250 MB) before it listens: up to 30 s, and it must still be running while we wait.
answered=""
for _ in $(seq 1 150); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$SERVER")" != true ]; then
    echo "conns: the server container exited:" >&2
    docker logs "$SERVER" >&2 || true
    exit 1
  fi
  if probe http-answers "$port" /noop; then answered=1; break; fi
  sleep 0.2
done
[ -n "$answered" ] || { docker logs "$SERVER" >&2 || true; fail "the server did not answer on port $port within 30 s"; }

server_id="$(docker inspect -f '{{.Id}}' "$SERVER")"
php_version="$(docker exec "$PROBE" php -r 'echo PHP_VERSION;')"
swoole_version=""
for e in "${LAB_EXT[@]}"; do
  [ "$e" != swoole ] || swoole_version="$(docker exec "$PROBE" php -d extension=swoole -r 'echo phpversion("swoole") ?: "";' 2>/dev/null || true)"
done
socket_line="$(lab_socket_line "$SERVER")"
server_pid="$(docker inspect -f '{{.State.Pid}}' "$SERVER")"
# The soft limit the server runs under, read from outside (the probe sees every process).
server_limit="$(docker exec "$PROBE" awk '/^Max open files/ {print $4}' "/proc/$server_pid/limits")"

# --- the client ------------------------------------------------------------------------------------------------------
# Why no CPU or memory limit: the client must not be what stops the count. Its CPUs are the load generator's.
docker run -d --name "$CLIENT" --network host --cpuset-cpus "$LAB_CPUSET_K6" --ulimit "nofile=$CLIENT_NOFILE:$CLIENT_NOFILE" \
  -v "$LAB:/lab:ro" "$LAB_IMAGE:$image" sleep 86400 >/dev/null

# The client reads its commands on a FIFO and writes its events to a file: a docker exec in the background, so that this script
# can read the server between two steps.
mkfifo "$tmp/commands"
: >"$tmp/events"
# Why display_errors=stderr: a PHP fatal error must not land in the events file.
docker exec -i "$CLIENT" php -d memory_limit=-1 -d display_errors=stderr -d log_errors=0 /lab/conns/client.php "$port" <"$tmp/commands" >"$tmp/events" 2>"$tmp/client.err" &
client_pid=$!
exec 7>"$tmp/commands"

consumed=0
EVENT=""
# next_event [<seconds>]: waits for the client's next event into EVENT, printing its log lines; a client that fails or exits
# without answering fails the run.
next_event() {
  local deadline total dead kind
  deadline=$(( $(date +%s) + ${1:-900} ))
  while :; do
    dead=0
    kill -0 "$client_pid" 2>/dev/null || dead=1
    total="$(wc -l <"$tmp/events" | tr -d ' ')"
    if [ "$total" -gt "$consumed" ]; then
      consumed=$((consumed + 1))
      EVENT="$(sed -n "${consumed}p" "$tmp/events")"
      kind="$(jq -r '.event' <<<"$EVENT" 2>/dev/null)" || fail "the client printed something that is not an event: '$EVENT' $(tr '\n' ' ' <"$tmp/client.err")"
      case "$kind" in
        log) echo "conns: $(jq -r '.message' <<<"$EVENT")" >&2 ;;
        harness_error) fail "the client failed: $(jq -r '.message' <<<"$EVENT")" ;;
        *) return 0 ;;
      esac
      continue
    fi
    [ "$dead" = 0 ] || fail "the client exited without answering: $(tr '\n' ' ' <"$tmp/client.err")"
    [ "$(date +%s)" -lt "$deadline" ] || fail "the client did not answer within ${1:-900} s"
    sleep 0.2
  done
}

# read_probe: what the server holds right now, as one JSON object. The established connections are counted before the fresh
# request, which would add one.
read_probe() {
  local mem events tcp fresh
  mem="$(probe memory-now "$server_id" | lines_to_json)" || return 1
  events="$(probe memory-events "$server_id" | lines_to_json)" || return 1
  tcp="$(probe connections "$port" | lines_to_json)" || return 1
  fresh="$(probe fresh-request "$port" /noop | lines_to_json)" || return 1
  jq -nc --argjson mem "$mem" --argjson events "$events" --argjson tcp "$tcp" --argjson fresh "$fresh" '{
    pss_kb: $mem.memory_now.pss_kb, cgroup_current: $mem.memory_now.cgroup_current, oom_kill: $events.memory_events.oom_kill,
    tcp_established: $tcp.connections.established, fresh_http_code: $fresh.fresh.http_code, fresh_ms: $fresh.fresh.ms}'
}

next_event
[ "$(jq -r '.event' <<<"$EVENT")" = baseline_ready ] || fail "the client's first event is not baseline_ready: $EVENT"
sleep "$SETTLE_S"
baseline="$(read_probe)" || fail "the probe could not read the server before the first step"

echo "conns: the baseline is read, steps: ${steps[*]}" >&2
# Every running container that is not one of this run's three, whoever started it (another checkout's lab run included).
other_names=()
while IFS= read -r name; do [ -z "$name" ] || other_names+=("$name"); done < <(lab_other_containers "$SERVER" "$CLIENT" "$PROBE")
other_json="$(jq -nc --argjson names "$(json_array "${other_names[@]+"${other_names[@]}"}")" '{count: ($names | length), names: $names}')"
other_warning=""
if [ "${#other_names[@]}" -gt 0 ]; then
  other_warning="WARNING: ${#other_names[@]} other containers running (${other_names[*]})"
  echo "$other_warning" >&2
fi

# --- the steps -------------------------------------------------------------------------------------------------------
: >"$tmp/steps.jsonl"
for target in "${steps[@]}"; do
  echo "step $target" >&7 || fail "the client is gone, it does not read its commands"
  next_event
  [ "$(jq -r '.event' <<<"$EVENT")" = step ] || fail "expected a step event, got: $EVENT"
  client_event="$EVENT"
  sleep "$SETTLE_S"

  # What stopped the step, if anything. A dead server comes first: the client's failure is then only the symptom.
  reason=""
  probe_json=null
  if [ "$(docker inspect -f '{{.State.Running}}' "$SERVER")" != true ]; then
    if [ "$(docker inspect -f '{{.State.OOMKilled}}' "$SERVER")" = true ]; then
      reason="server OOM-killed"
    else
      reason="server died (exit code $(docker inspect -f '{{.State.ExitCode}}' "$SERVER"))"
    fi
  else
    if ! probe_json="$(read_probe)"; then
      probe_json=null
      [ "$(docker inspect -f '{{.State.Running}}' "$SERVER")" = true ] && fail "the probe could not read the server at step $target"
      reason="server died during the probe's reading"
    fi
  fi
  if [ -z "$reason" ] && [ "$probe_json" != null ]; then
    reason="$(jq -r --argjson c "$client_event" '
      if .oom_kill > 0 then "server OOM-killed (oom_kill \(.oom_kill))"
      elif $c.failure != null then $c.failure
      elif $c.closed_by_server > 0 then "held connection closed by the server (EOF)"
      elif .fresh_http_code != 200 or .fresh_ms >= 1000 then "fresh request failed (HTTP \(.fresh_http_code), \(.fresh_ms) ms)"
      else "" end' <<<"$probe_json")"
  fi

  jq -nc --argjson c "$client_event" --argjson p "$probe_json" --arg reason "$reason" \
    '{target: $c.target, held: $c.held, client: $c, probe: $p, ceiling_reason: (if $reason == "" then null else $reason end)}' >>"$tmp/steps.jsonl"
  echo "conns: step $target: held $(jq -r '.held' <<<"$client_event")${reason:+, stopped: $reason}" >&2
  [ -z "$reason" ] || break
done

echo quit >&7
exec 7>&-
wait "$client_pid" 2>/dev/null || true
client_pid=""

# --- the numbers -----------------------------------------------------------------------------------------------------
jq -n \
  --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg command "$command_line" \
  --arg docker "$(docker version --format '{{.Server.Platform.Name}}')" \
  --arg engine "$(docker version --format '{{.Server.Version}}')" \
  --arg kernel "$(docker info --format '{{.KernelVersion}}')" \
  --arg arch "$(uname -m)" --arg limits "${LAB_RESOURCE_FLAGS[*]}" \
  --arg variant "$image" --arg image_id "$(docker image inspect -f '{{.Id}}' "$LAB_IMAGE:$image")" \
  --arg php_version "$php_version" --arg swoole_version "$swoole_version" \
  --arg server_file "${server_in#/lab/}" --arg flags "${LAB_PHP_FLAGS[*]}" --argjson port "$port" \
  --arg server_limit "$server_limit" --arg cpuset_server "$LAB_CPUSET_SERVER" --arg cpuset_client "$LAB_CPUSET_K6" \
  --arg cpuset_probe "$LAB_CPUSET_PROBE" --argjson client_nofile "$CLIENT_NOFILE" \
  --argjson ext "$(json_array "${LAB_EXT[@]}")" --argjson env "$(json_array "${LAB_ENV[@]+"${LAB_ENV[@]}"}")" --arg label "$label" \
  --argjson steps_planned "$(json_array "${steps[@]}")" --arg max "$max" \
  --arg socket_line "$socket_line" --argjson other_containers "$other_json" --argjson baseline "$baseline" \
  --slurpfile steps "$tmp/steps.jsonl" '
  def kib_mib: . / 1024 * 100 | round / 100;
  def bytes_mib: . / 1048576 * 100 | round / 100;
  # Least-squares slope of y against x, null with fewer than two points.
  def slope(x; y):
    length as $n
    | if $n < 2 then null else
        (map(x) | add) as $sx | (map(y) | add) as $sy | (map(x * y) | add) as $sxy | (map(x * x) | add) as $sxx
        | if ($n * $sxx - $sx * $sx) == 0 then null else ($n * $sxy - $sx * $sy) / ($n * $sxx - $sx * $sx) end
      end;
  ($steps | map(select(.ceiling_reason == null))) as $held
  | ($steps | last) as $last
  | {
    date: $date,
    command: $command,
    label: (if $label == "" then null else $label end),
    other_containers: $other_containers,
    host: {docker_desktop: $docker, engine: $engine, vm_kernel: $kernel, arch: $arch, cpuset_server: $cpuset_server,
           cpuset_client: $cpuset_client, cpuset_probe: $cpuset_probe, limits: $limits},
    server: {variant: $variant, image_id: $image_id, php_version: $php_version, swoole_version: $swoole_version,
             file: $server_file, port: $port, php_flags: $flags, ext: $ext, env: $env, nofile: ($server_limit | tonumber? // $server_limit),
             socket: (if $socket_line == "" then null
                      else ($socket_line | split(" ") | map(split("=") | {(.[0]): (.[1] | tonumber? // .[1])}) | add) end)},
    client: {nofile: $client_nofile, port_range: ($last.client.port_range), ports_per_address: ($last.client.ports_per_address),
             source_addresses: ($last.client.source_addresses)},
    max_option: (if $max == "" then null else ($max | tonumber) end),
    steps_planned: ($steps_planned | map(tonumber)),
    results: {
      max_connections: (($held | last | .held) // 0),
      max_connections_step: (($held | last | .target) // null),
      held_at_stop: $last.held,
      ceiling: (if $last.ceiling_reason == null then null
                else {step: $last.target, reason: $last.ceiling_reason, held_at_stop: $last.held,
                      client_failure: $last.client.failure, client_detail: $last.client.detail} end),
      reason_stopped: ($last.ceiling_reason
                       // (if $max == "" then "no ceiling: every planned step held" else "no ceiling: every planned step up to --max held" end)),
      baseline: {pss_kb: $baseline.pss_kb, cgroup_current_bytes: $baseline.cgroup_current},
      memory_per_connection: {
        held_steps_used: ($held | length),
        pss_kib_per_connection: ($held | slope(.held; .probe.pss_kb)),
        cgroup_current_kib_per_connection: ($held | slope(.held; .probe.cgroup_current / 1024))
      }
    },
    steps: $steps,
    raw: {baseline: $baseline}
  }' >"$out"

# The table reads the JSON just written, so what is printed is what is stored.
echo
echo "image $image (PHP $php_version${swoole_version:+, Swoole $swoole_version}), $(basename "$server_file"), server nofile $server_limit"
printf '  %8s %8s %10s %12s %10s %9s  %s\n' target held "Pss MiB" "mem.cur MiB" "/proc tcp" "fresh ms" status
jq -r '.steps[] | [.target, .held, ((.probe.pss_kb // null) | if . == null then null else . / 1024 * 100 | round / 100 end),
    ((.probe.cgroup_current // null) | if . == null then null else . / 1048576 * 100 | round / 100 end),
    (.probe.tcp_established // null), (.probe.fresh_ms // null), (.ceiling_reason // "ok")]
  | map(if . == null then "n/a" else . end) | @tsv' "$out" \
  | while IFS=$'\t' read -r t h pss cur tcp fresh status; do
      printf '  %8s %8s %10s %12s %10s %9s  %s\n' "$t" "$h" "$pss" "$cur" "$tcp" "$fresh" "$status"
    done
IFS=$'\t' read -r maxc maxstep stopped reason pss_slope cur_slope used base_pss base_cur socket < <(
  jq -r '.results as $r | [$r.max_connections, ($r.max_connections_step // "none"), $r.held_at_stop, $r.reason_stopped,
    ($r.memory_per_connection.pss_kib_per_connection | if . == null then "n/a" else "\(. * 100 | round / 100) KiB" end),
    ($r.memory_per_connection.cgroup_current_kib_per_connection | if . == null then "n/a" else "\(. * 100 | round / 100) KiB" end),
    $r.memory_per_connection.held_steps_used, ($r.baseline.pss_kb / 1024), ($r.baseline.cgroup_current_bytes / 1048576),
    (.server.socket // "none printed" | if type == "object" then to_entries | map("\(.key)=\(.value)") | join(" ") else . end)]
    | map(if type == "number" then (. * 100 | round / 100) else . end) | @tsv' "$out")
echo
printf '  %-38s %s\n' \
  "max connections (held, answered)" "$maxc (at step $maxstep)" \
  "held when it stopped" "$stopped" \
  "stopped because" "$reason" \
  "memory per connection, Pss" "$pss_slope (slope over $used held steps)" \
  "memory per connection, memory.current" "$cur_slope (slope over $used held steps)" \
  "baseline (one request, no connection)" "Pss $base_pss MiB, memory.current $base_cur MiB" \
  "socket settings (server's boot line)" "$socket" \
  "other containers on the VM" "$(jq -r '.other_containers.count' "$out")"
[ -z "$other_warning" ] || echo "$other_warning"
echo "wrote ${out#"$REPO"/}"
