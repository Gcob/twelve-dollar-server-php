#!/usr/bin/env bash
# The step lab: compares server variants by interleaved realistic runs, the median of each variant's runs, and the paired differences
# against the first variant (the reference). Each run is a fresh `lab/realistic.sh --hold` (seed copy, server, idle connections, warm-up),
# without the per-second probes and with the server's telemetry off unless the variant sets it. A round runs every variant once, in the
# order given, and `--pairs` rounds follow each other, so a drift of the machine (heat, a neighbour on the VM) hits every variant alike.
#
#   bash lab/steplab.sh --image 8.5 --rate 24000 --think-scale 0.02 --idle 60000 --seconds 60 --pairs 3 \
#       --variant ref= --variant telemetry-on=APP_TELEMETRY=1 [--server-variant <name>=<php file under lab/>]... \
#       [--warmup <req/s>,<s>] [--floor <us>] [--label <text>] [--out <folder>] [--time-wait-max <n>] [--idle-time-wait-max <n>] [--time-wait-wait <s>]
#                       [--local-ips <range>] [--lag-gate <s>] [--port <n>] [--vu-cap <n>] [--ramp <s>] [--k6-memory <MiB>] [--ext <name>]...
#
# --variant <name>=<K=V,K=V...> sets environment variables on the server (an empty list, `ref=`, is the skeleton as it is);
# --server-variant <name>=<file> runs another server file (the same name in both flags: both apply); --variant-args <name>=<arguments>
# adds arguments to that variant's lab/realistic.sh call, split on spaces, after the common ones (so a later --image or --ext of
# the variant wins or adds: `--variant-args other='--image 8.3-apt --ext swoole --php-ini servers/x/php.ini'`; a path of --php-ini
# is under lab/, relative to the current folder or absolute). The first variant given is the
# reference. The default warm-up is a tenth of the rate for 60 s (the baseline's).
#
# Before each run the TIME_WAIT sockets on every source address the lab's clients use, k6's and the idle client's (127.0.0.2 and up), are
# counted (lab/macro/probe.sh time-wait). A closed connection keeps its port for 60 s, the VM's ephemeral ports are 55000 to 65535 (about
# 10,500 per address).
#  - k6 opens about one connection per VU, a quarter of them per address (1,200 at 24,000 req/s) and dials again when a port is taken, so
#    the run waits for the busiest of its addresses to hold at most --time-wait-max (default 2,500): under it a run has 8,000 free ports per
#    address, six times what it needs, and the sockets a run leaves (1,134 per address at that rate) do not make the next one wait.
#  - The idle client opens its connections once and binds each to a random port of its address. A port whose 4-tuple matches a TIME_WAIT
#    socket fails at connect (`Cannot assign requested address`); the client binds again (another random port) and, after 25 failures in
#    a row, moves to another address, so the sockets of the run before no longer make a run wait: --idle-time-wait-max defaults to 100,000
#    (never). `--idle-time-wait-max 0` waits for the busiest of the idle client's addresses to drain, about a minute after a run that held
#    60,000. The retries a run needed are in its JSON (`idle.bind_retries`).
# A count that does not drop within --time-wait-wait seconds (default 150) is a harness failure: something else is churning connections.
# The counts, before and after each run, are in the run's JSON (`steplab.time_wait`).
#
# The output folder (default lab/results/steplab-...) holds each run's JSON (<variant>-<round>.json, the realistic run's JSON with a
# `steplab` object added), its table (<variant>-<round>.txt), summary.json and summary.txt, which lab/steplab-summary.sh rebuilds from
# the JSON files alone. The verdict needs a floor (--floor <us>, from an A/A calibration): without it nothing is judged.
# Exit codes: 0 every run ran (an invalid run or a failing step is a result), 1 a harness failure, 2 usage.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$LAB")"
# shellcheck source=lib.sh
source "$LAB/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: lab/steplab.sh --image <variant> --rate <req/s> --think-scale <s> --seconds <plateau s> --pairs <n>
                      --variant <name>=<K=V,K=V...> [--variant ...] [--server-variant <name>=<php file under lab/>]...
                      [--variant-args <name>=<arguments>]... [--idle <n>] [--warmup <req/s>,<s>] [--floor <us>] [--label <text>] [--out <folder>]
                      [--time-wait-max <n>] [--idle-time-wait-max <n>] [--time-wait-wait <s>] [--local-ips <range>] [--lag-gate <s>] [--port <n>]
                      [--vu-cap <n>] [--ramp <s>] [--k6-memory <MiB>] [--ext <name>]...
the first variant is the reference; an empty list (`ref=`) is the skeleton as it is
EOF
  exit 2
}
fail() { echo "steplab: $*" >&2; exit 1; }

command_line="lab/steplab.sh $*"
command_line="${command_line//$REPO/.}"

image="" rate="" think_scale="" seconds="" pairs="" idle="" warmup="" floor="" label="" out=""
tw_max=2500 idle_tw_max=100000 tw_wait=150 local_ips="127.0.1.1-127.0.1.4"
# The idle client's source addresses (FIRST_OCTET to LAST_OCTET of lab/conns/client.php): its sockets keep their ports for 60 s too.
idle_ips="127.0.0.2-127.0.0.254"
pass_through=()
# The variants, in the order given: names, their env (one K=V per line), their server file (empty: the skeleton's) and their extra
# arguments for lab/realistic.sh (empty: none).
v_names=() v_env=() v_server=() v_args=()
# variant_index <name>: sets VI to the index of the variant, adding it when it is new (not a $(...): the arrays must change here).
VI=0
variant_index() {
  local i
  for i in "${!v_names[@]}"; do
    [ "${v_names[$i]}" != "$1" ] || { VI="$i"; return; }
  done
  v_names+=("$1") v_env+=("") v_server+=("") v_args+=("")
  VI=$(( ${#v_names[@]} - 1 ))
}
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; usage; }
  case "$1" in
    --image) image="$2" ;;
    --rate) rate="$2" ;;
    --think-scale) think_scale="$2" ;;
    --seconds) seconds="$2" ;;
    --pairs) pairs="$2" ;;
    --idle) idle="$2" ;;
    --warmup) warmup="$2" ;;
    --floor) floor="$2" ;;
    --label) label="$2" ;;
    --out) out="$2" ;;
    --time-wait-max) tw_max="$2" ;;
    --idle-time-wait-max) idle_tw_max="$2" ;;
    --time-wait-wait) tw_wait="$2" ;;
    --local-ips) local_ips="$2"; pass_through+=(--local-ips "$2") ;;
    --lag-gate|--port|--vu-cap|--ramp|--k6-memory|--ext) pass_through+=("$1" "$2") ;;
    --variant)
      [[ "$2" == ?*=* || "$2" == ?*= ]] || { echo "--variant wants <name>=<K=V,K=V...>, got '$2'" >&2; usage; }
      vname="${2%%=*}" vspec="${2#*=}"
      [[ "$vname" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "a variant's name may only hold letters, digits, . _ and -, got '$vname'" >&2; usage; }
      variant_index "$vname"
      vi="$VI"
      if [ -n "$vspec" ]; then
        IFS=, read -r -a vpairs <<<"$vspec"
        for kv in "${vpairs[@]}"; do
          [[ "$kv" == ?*=* ]] || { echo "variant '$vname': '$kv' is not K=V (a comma separates variables, so a value cannot hold one)" >&2; usage; }
          v_env[vi]="${v_env[$vi]}${v_env[$vi]:+$'\n'}$kv"
        done
      fi
      ;;
    --server-variant)
      [[ "$2" == ?*=?* ]] || { echo "--server-variant wants <name>=<php file under lab/>, got '$2'" >&2; usage; }
      vname="${2%%=*}" vfile="${2#*=}"
      [[ "$vname" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "a variant's name may only hold letters, digits, . _ and -, got '$vname'" >&2; usage; }
      [ -f "$vfile" ] || { [ ! -f "$LAB/$vfile" ] || vfile="$LAB/$vfile"; }
      [ -f "$vfile" ] || { echo "--server-variant '$vname': no file $vfile (give a path under lab/)" >&2; usage; }
      variant_index "$vname"
      vi="$VI"
      v_server[vi]="$vfile"
      ;;
    --variant-args)
      [[ "$2" == ?*=?* ]] || { echo "--variant-args wants <name>=<arguments of lab/realistic.sh>, got '$2'" >&2; usage; }
      vname="${2%%=*}"
      [[ "$vname" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "a variant's name may only hold letters, digits, . _ and -, got '$vname'" >&2; usage; }
      variant_index "$vname"
      v_args[VI]="${2#*=}"
      ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
  shift 2
done

for n in image rate think_scale seconds pairs; do
  [ -n "${!n}" ] || { echo "--${n//_/-} is required" >&2; usage; }
done
lab_require_variant "$image" || exit 2
[ "${#v_names[@]}" -ge 1 ] || { echo "give at least one --variant (the first is the reference)" >&2; usage; }
[[ "$idle_tw_max" =~ ^[0-9]+$ ]] || { echo "--idle-time-wait-max must be a whole number from 0, got '$idle_tw_max'" >&2; usage; }
for n in rate seconds pairs tw_max tw_wait; do
  [[ "${!n}" =~ ^[1-9][0-9]*$ ]] || { echo "--${n//_/-} must be a whole number from 1, got '${!n}'" >&2; usage; }
done
[[ "$think_scale" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "--think-scale must be a number, got '$think_scale'" >&2; usage; }
[ -z "$idle" ] || [[ "$idle" =~ ^[1-9][0-9]*$ ]] || { echo "--idle must be a whole number above 0, got '$idle'" >&2; usage; }
[ -z "$floor" ] || [[ "$floor" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "--floor must be a number of microseconds, got '$floor'" >&2; usage; }
[[ -z "$label" || "$label" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "--label may only hold letters, digits, . _ and -, got '$label'" >&2; usage; }
if [ -z "$warmup" ]; then
  warmup="$(( rate / 10 > 0 ? rate / 10 : 1 )),60"
fi
[[ "$warmup" =~ ^[0-9]+,[0-9]+$ ]] || { echo "--warmup wants <req/s>,<s>, got '$warmup'" >&2; usage; }
# Why a /24: lab/macro/probe.sh time-wait counts the addresses first to last of one block.
ips_ok='^[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+-[0-9]+[.][0-9]+[.][0-9]+[.][0-9]+$'
first_ip="${local_ips%-*}" last_ip="${local_ips#*-}"
{ [[ "$local_ips" =~ $ips_ok ]] && [ "${first_ip%.*}" = "${last_ip%.*}" ]; } || { echo "--local-ips must be a range of one /24 (127.0.1.1-127.0.1.4) for the TIME_WAIT count, got '$local_ips'" >&2; usage; }

docker image inspect "$LAB_IMAGE:$image" >/dev/null 2>&1 || fail "image $LAB_IMAGE:$image is missing (run lab/build.sh $image)"

stamp="$(date -u +%Y%m%d-%H%M%S)"
[ -n "$out" ] || out="$LAB/results/steplab-${label:+$label-}$image-$stamp"
mkdir -p "$out"
tmp="$(mktemp -d)"
run_pid=""
cleanup() {
  local rc=$?
  # The realistic run removes its own containers when it is told to stop.
  if [ -n "$run_pid" ] && kill -0 "$run_pid" 2>/dev/null; then
    kill -TERM "$run_pid" 2>/dev/null || true
    wait "$run_pid" 2>/dev/null || true
  fi
  rm -rf "$tmp"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# time_wait_json: the TIME_WAIT sockets of every address the lab's clients use now, as one JSON object, from a short-lived container on the
# VM's host network. per_address lists the addresses that hold at least one, max is the busiest of all of them, k6_max and idle_max the
# busiest of each client's, in_range and all the sockets on the clients' addresses and on the VM.
time_wait_json() {
  docker run --rm --network host -v "$LAB:/lab:ro" "$LAB_IMAGE:$image" bash -c '
    bash /lab/macro/probe.sh time-wait "$0" | sed "s/^/k6 /"
    bash /lab/macro/probe.sh time-wait "$1" | sed "s/^/idle /"' "$local_ips" "$idle_ips" |
    jq -Rn '[inputs | split(" ")] as $l
      | def summary($g; $k): $l | map(select(.[0] == $g and .[1] == "time_wait_summary" and .[2] == $k) | .[3] | tonumber) | first;
        {per_address: ($l | map(select(.[1] == "time_wait" and (.[3] | tonumber) > 0) | {(.[2]): (.[3] | tonumber)}) | add // {}),
         max: ([summary("k6"; "max"), summary("idle"; "max")] | max),
         k6_max: summary("k6"; "max"), idle_max: summary("idle"; "max"),
         in_range: (summary("k6"; "in_range") + summary("idle"; "in_range")),
         all: summary("k6"; "all")}'
}

# wait_for_time_wait: counts, waits for k6's busiest address to drain under --time-wait-max and, with --idle, the idle client's under
# --idle-time-wait-max, leaves the last count in TW_BEFORE (JSON) with the seconds waited and the limits.
TW_BEFORE=""
wait_for_time_wait() {
  local start now k6_max idle_max waited=0 over
  start="$(date +%s)"
  while :; do
    TW_BEFORE="$(time_wait_json)" || fail "cannot count the TIME_WAIT sockets"
    k6_max="$(jq '.k6_max' <<<"$TW_BEFORE")" idle_max="$(jq '.idle_max' <<<"$TW_BEFORE")"
    over=""
    [ "$k6_max" -le "$tw_max" ] || over="$k6_max on the busiest of k6's addresses, above $tw_max"
    [ -z "$idle" ] || [ "$idle_max" -le "$idle_tw_max" ] || over="${over:+$over, }$idle_max on the busiest of the idle client's addresses, above $idle_tw_max"
    [ -n "$over" ] || break
    now="$(date +%s)"
    waited=$(( now - start ))
    [ "$waited" -lt "$tw_wait" ] || fail "TIME_WAIT sockets after $waited s: $over: something else on the VM opens connections"
    echo "  TIME_WAIT: $over: waiting for them to drain (60 s a socket)" >&2
    sleep 5
  done
  TW_BEFORE="$(jq --argjson w "$waited" --argjson lim "$tw_max" --argjson idle_lim "$idle_tw_max" '. + {waited_s: $w, limit_per_address: $lim, idle_limit_per_address: $idle_lim}' <<<"$TW_BEFORE")"
}

echo "steplab: ${#v_names[@]} variant(s) x $pairs round(s), $rate req/s for ${seconds}s (think scale $think_scale${idle:+, $idle idle connections}), warm-up $warmup, into ${out#"$REPO"/}"
total=$(( ${#v_names[@]} * pairs ))
done_runs=0
for round in $(seq 1 "$pairs"); do
  for i in "${!v_names[@]}"; do
    name="${v_names[$i]}"
    id="$name-$round"
    done_runs=$(( done_runs + 1 ))
    echo "[$done_runs/$total] round $round, $name"
    wait_for_time_wait
    echo "  TIME_WAIT before: $(jq -r '"\(.max) on the busiest address, \(.in_range) in all on the clients'"'"' addresses, \(.all) on the VM, waited \(.waited_s) s"' <<<"$TW_BEFORE")"

    run_args=(--image "$image" --think-scale "$think_scale" --hold "$rate,$seconds" --no-series --warmup "$warmup" --out "$tmp/$id.json"
      --label "${label:+$label-}$name")
    [ -z "$idle" ] || run_args+=(--idle "$idle")
    [ -z "${v_server[$i]}" ] || run_args+=(--server "${v_server[$i]}")
    telemetry_set=""
    while IFS= read -r kv; do
      [ -n "$kv" ] || continue
      run_args+=(--env "$kv")
      [[ "$kv" != APP_TELEMETRY=* ]] || telemetry_set=1
    done <<<"${v_env[$i]}"
    [ -n "$telemetry_set" ] || run_args+=(--env APP_TELEMETRY=0)

    variant_args=()
    [ -z "${v_args[$i]}" ] || read -r -a variant_args <<<"${v_args[$i]}"
    run_rc=0
    bash "$LAB/realistic.sh" "${run_args[@]}" "${pass_through[@]+"${pass_through[@]}"}" "${variant_args[@]+"${variant_args[@]}"}" >"$tmp/$id.stdout" 2>"$tmp/$id.stderr" &
    run_pid=$!
    wait "$run_pid" || run_rc=$?
    run_pid=""
    case "$run_rc" in
      0|3) ;;
      2) cat "$tmp/$id.stderr" >&2; exit 2 ;;
      *) echo "steplab: the run $id failed (exit $run_rc):" >&2; tail -n 20 "$tmp/$id.stderr" >&2; exit 1 ;;
    esac
    [ -s "$tmp/$id.json" ] || fail "the run $id left no JSON"
    tw_after="$(time_wait_json)" || fail "cannot count the TIME_WAIT sockets"

    # The run's own JSON stays as it is; the runner adds one object.
    jq --arg variant "$name" --argjson index "$i" --argjson round "$round" --argjson rounds "$pairs" --arg reference "${v_names[0]}" \
      --argjson env "$(jq -Rnc '[inputs | select(length > 0)]' <<<"${v_env[$i]}")" --arg server "${v_server[$i]:+${v_server[$i]#"$LAB"/}}" \
      --argjson rate "$rate" --arg warmup "$warmup" --argjson before "$TW_BEFORE" --argjson after "$tw_after" --arg command "$command_line" '
      . + {steplab: {variant: $variant, variant_index: $index, round: $round, rounds: $rounds, reference: $reference, variant_env: $env,
                     variant_server_file: (if $server == "" then null else $server end), rate: $rate, warmup: $warmup,
                     time_wait: {before: $before, after: $after}, command: $command}}' "$tmp/$id.json" >"$out/$id.json"
    cp "$tmp/$id.stdout" "$out/$id.txt"
    echo "  $(jq -r '.results.steps[0] as $s | if .valid then "valid, \($s.achieved_rps | . * 10 | round / 10) req/s, \($s.cpu_usec_per_request | . * 10 | round / 10) us/req, p99 \($s.latency_ms.overall.p99) ms, \(if $s.pass then "pass" else "FAIL: " + ($s.reasons | join("; ")) end)" else "INVALID: " + (.invalid_reasons | join("; ")) end' "$out/$id.json"), TIME_WAIT after: $(jq -r '.max' <<<"$tw_after") on the busiest address"
  done
done

echo
summary_args=("$out")
[ -z "$floor" ] || summary_args+=(--floor "$floor")
bash "$LAB/steplab-summary.sh" "${summary_args[@]}" --json "$out/summary.json" | tee "$out/summary.txt"
