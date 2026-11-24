#!/usr/bin/env bash
# Prints the Markdown tables of README.md from the JSON files next to this script (its subfolders and stages.json) and from the 5a folders it is
# read against (the Xeon's reconnect pair and the S1 series' reconnect at 12,000 req/s). A run counts when its JSON says valid: true and
# other_containers.count 0; every other run is listed in its table with its result and counted nowhere.
set -euo pipefail
cd "$(dirname "$0")"
LAB="$(cd ../.. && pwd)"
AA="$LAB/results/$(basename "$PWD")/aa-24000"
XEON=../2026-11-23-x86-calibration
S1=../2026-11-23-s1-fd-wall

PRELUDE='
def med: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
def r1: if . == null then "-" else . * 10 | round / 10 end;
def r2: if . == null then "-" else . * 100 | round / 100 end;
def r3: if . == null then "-" else . * 1000 | round / 1000 end;
def sgn: if . == null then "-" elif . > 0 then "+\(. * 1000 | round / 1000)" else "\(. * 1000 | round / 1000)" end;
def counted: .valid and .other_containers.count == 0;
def us: .results.steps[0].cpu_usec_per_request;
def ratio: .results.steps[0] | .achieved_rps / .offered_rps * 100;
'
runs_of() { jq -s 'map(select(type == "object" and has("steplab")))' "$1"/*.json; }

# --------------------------------------------------------------------------------------------------------------------------------
echo "### The series, as the driver recorded them (\`stages.json\`)"
echo
jq -r '"The lab'"'"'s commit when the file started: `\(.commit[0:7])`, tracked files changed since: \(.dirty). Gap between series: \(.gap_s) s; `--allow-busy`: \(.allow_busy)."' stages.json
echo
echo "| Series | start (UTC) | end (UTC) | exit code | other containers at the quiet check | busy | refused |"
echo "|---|---|---|---|---|---|---|"
jq -r '.series[] | "| \(.name) | \(.start) | \(.end) | \(.exit_code) | \(.other_containers) | \(.busy) | \(.refused) |"' stages.json

# One series: the runs in the order they ran, the host's state around each, then the step lab's own summary.
runs_table() { # folder
  echo "| Run | position in its round | valid | other containers | idle held at the end | closed by the server | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|"
  runs_of "$1" | jq -r "$PRELUDE"'sort_by(.steplab.round, .steplab.position)[] | .results.steps[0] as $s
    | "| \(.steplab.variant)-\(.steplab.round) | \(.steplab.position + 1) | \(.valid) | \(.other_containers.count) | \(.idle.held_at_end) | \(.idle.closed_by_server_at_end) | \($s.achieved_rps | r1) | \(ratio | r1) % | \($s.cpu_usec_per_request | r2) | \($s.latency_ms.overall.p95 | r2) | \($s.latency_ms.overall.p99 | r2) | \(if $s.pass then "pass" else "FAIL: " + ($s.reasons | join("; ")) end) |"'
}
host_table() { # folder
  echo "| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |"
  echo "|---|---|---|---|---|---|---|---|"
  runs_of "$1" | jq -r "$PRELUDE"'sort_by(.steplab.round, .steplab.position)[]
    | "| \(.steplab.variant)-\(.steplab.round) | \(.host.before.load1) | \(.host.plateau.load1) | \(.host.plateau.cpu_busy_pct) % | \(.host.plateau.steal_pct) % | \(.host.fsync_ms) | \(.steplab.time_wait.before.max) | \(.steplab.time_wait.before.waited_s) |"'
}
summary_block() { # folder [steplab-summary.sh arguments]
  local dir="$1"
  shift
  echo '```text'
  bash "$LAB/steplab-summary.sh" "$dir" "$@"
  echo '```'
}

# --------------------------------------------------------------------------------------------------------------------------------
echo
echo "### A/A at 24,000 req/s in alternating order (\`APP_PRAGMAS=mmap-off\` against itself, \`s = 0.02\`, 60,000 idle, telemetry off, 5 pairs)"
echo
runs_table aa-24000
echo
host_table aa-24000
echo
echo "The pairs (b minus a, the order alternates: round 1 runs b first, round 2 a first, and so on):"
echo
echo "| Round | order | a µs/req | b µs/req | b minus a µs |"
echo "|---|---|---|---|---|"
runs_of aa-24000 | jq -r "$PRELUDE"'map(select(counted)) | group_by(.steplab.round)[] | select(length == 2) | (.[] | select(.steplab.variant == "a")) as $a | (.[] | select(.steplab.variant == "b")) as $b
  | "| \($a.steplab.round) | \($a.steplab.order): \(if $a.steplab.position == 0 then "a then b" else "b then a" end) | \($a | us | r2) | \($b | us | r2) | \(($b | us) - ($a | us) | sgn) |"'
echo
bash "$LAB/steplab-floor.sh" "$AA" | jq -r "$PRELUDE"'"**Floor: |median| + interquartile range = \(.median_difference_us | fabs | r3) + \(.iqr_us | r3) = \(.floor_us | r3) µs/req.** Differences \(.differences_us | map(sgn) | join(", ")); median \(.median_difference_us | sgn), q1 \(.q1_us | sgn), q3 \(.q3_us | sgn), interquartile range \(.iqr_us | r3)."'
runs_of aa-24000 | jq -r "$PRELUDE"'map(select(counted)) as $c | ([$c[] | select(.steplab.variant == "a") | us] | med) as $ma | ([$c[] | select(.steplab.variant == "b") | us] | med) as $mb
  | "Medians: a \($ma | r2) µs/req, b \($mb | r2) µs/req; the median of the \($c | length) runs is \([$c[] | us] | med | r2). Achieved over offered: \([$c[] | ratio] | min | r1) % to \([$c[] | ratio] | max | r1) %; runs under the 97 % rule: \([$c[] | select(.results.steps[0].pass | not)] | length) of \($c | length)."'
echo
summary_block aa-24000

# --------------------------------------------------------------------------------------------------------------------------------
echo
echo "### The Mac's reconnect at 7,500 req/s (the skeleton against S1-d with every request reconnecting, \`APP_SOFT_CONN_LIMIT=60000\`, telemetry on, one round)"
echo
runs_table reconnect-7500
echo
host_table reconnect-7500
echo
runs_of reconnect-7500 | jq -r "$PRELUDE"'map(select(.steplab.variant == "s1d-every"))[0] | .results.k6_summary.metrics.http_reqs.count as $k6 | (.steplab.warmup | split(",") | (.[0] | tonumber) * ((.[1] | tonumber) + 5)) as $warm | .server_connections.telemetry.close_responses as $closes
  | "S1-d with every request reconnecting: the server sent \($closes) `Connection: close` responses; k6 made \($k6) requests, plus the warm-up'"'"'s nominal \($warm | round) (its rate times its plateau plus half its 10 s ramp; the server counts its whole life): a difference of \($closes - $k6 - $warm | round), \((($closes - $k6 - $warm) / $closes * 100 | fabs) | r2) % of the closes, so every request reconnected."'
echo
summary_block reconnect-7500
echo
MAC_RECON="$(jq '.variants[] | select(.variant == "s1d") | {cost: .median_difference_us, pairs: (.pairs | length)}' "$S1/s1-12000/summary.json")"
XEON_RECON="$(runs_of "$XEON/reconnect" | jq "$PRELUDE"'map(select(counted)) | ((map(select(.steplab.variant == "skeleton") | us)[0]) as $a | (map(select(.steplab.variant == "s1d-every") | us)[0]) as $b | {skeleton: $a, every: $b, cost: ($b - $a)})')"
runs_of reconnect-7500 | jq -r "$PRELUDE"'map(select(counted)) | (map(select(.steplab.variant == "skeleton") | us)[0]) as $a | (map(select(.steplab.variant == "s1d-every") | us)[0]) as $b | ($b - $a) as $cost
  | "One pair: the skeleton \($a | r2), S1-d with every request reconnecting \($b | r2) µs/req: **one reconnect costs \($cost | r2) µs on the Mac at 7,500 req/s** (\($cost / $a * 100 | r1) % of the skeleton). At 12,000 req/s the Mac'"'"'s was \($mac.cost | r2) µs (median of \($mac.pairs) pairs, S1 series), so the cost is \($cost / $mac.cost | r2) times that. The Xeon'"'"'s reconnect at 7,500 req/s was \($xeon.cost | r2) µs (one pair: skeleton \($xeon.skeleton | r2), every-request \($xeon.every | r2)): **the Xeon over the Mac for a reconnect is \($xeon.cost / $cost | r2)** (\($xeon.cost / $mac.cost | r2) against the Mac'"'"'s 12,000 req/s figure)."' \
  --argjson mac "$MAC_RECON" --argjson xeon "$XEON_RECON"

# --------------------------------------------------------------------------------------------------------------------------------
screen_section() { # folder title variant
  local dir="$1" title="$2" variant="$3"
  echo
  echo "### $title"
  echo
  runs_table "$dir"
  echo
  host_table "$dir"
  echo
  runs_of "$dir" | jq -r --arg v "$variant" "$PRELUDE"'map(select(counted)) | (map(select(.steplab.variant == "ref") | us)[0]) as $a | (map(select(.steplab.variant == $v) | us)[0]) as $b
    | "One pair: ref \($a | r2), \($v) \($b | r2) µs/req: **\(($b - $a) | sgn) µs, \(($b / $a - 1) * 100 | sgn) %** of the reference."'
  echo
  summary_block "$dir" --floor-from "$AA"
}
screen_section php-8.6 "PHP 8.6 against 8.5 at 24,000 req/s (\`APP_PRAGMAS=mmap-off\` on both, 8.6 through \`--variant-args\`, the A/A's floor, one pair)" php86
screen_section php-8.4 "PHP 8.4 against 8.5 at 24,000 req/s (\`APP_PRAGMAS=mmap-off\` on both, 8.4 through \`--variant-args\`, the A/A's floor, one pair)" php84
