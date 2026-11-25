#!/usr/bin/env bash
# Prints the Markdown tables of README.md from the JSON files next to this script (parity-24000/, stages.json for round 1 and stages-more.json for
# rounds 2 and 3) and from the A/A folder of phase 5b it is read against. A run counts when its JSON says valid: true and other_containers.count 0. The step lab's verdict for one pair is one-sided
# ("not better"); parity needs both sides, so the paired differences are also read in absolute value against the floor. The rule (the step lab's
# own, for three pairs): outside the floor when every paired difference has the same sign and the median is at least the floor in absolute value;
# otherwise within it (parity).
set -euo pipefail
cd "$(dirname "$0")"
LAB="$(cd ../.. && pwd)"
AA="$LAB/results/2026-11-24-cpu-steps-5b/aa-24000"

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

for f in stages.json stages-more.json; do
  echo "### The series, as the driver recorded it (\`$f\`)"
  echo
  jq -r '"The lab'"'"'s commit when the file started: `\(.commit[0:7])`, tracked files changed since: \(.dirty). `--allow-busy`: \(.allow_busy)."' "$f"
  echo
  echo "| Series | start (UTC) | end (UTC) | exit code | other containers at the quiet check | busy | refused |"
  echo "|---|---|---|---|---|---|---|"
  jq -r '.series[] | "| \(.name) | \(.start) | \(.end) | \(.exit_code) | \(.other_containers) | \(.busy) | \(.refused) |"' "$f"
  echo
done

echo "### The pair at 24,000 req/s (\`lab\`: the lab's server with the submission's configuration; \`sub\`: the submission's copy; \`s = 0.02\`, 60,000 idle, telemetry off, three pairs)"
echo
echo "| Run | position in its round | valid | other containers | idle held at the end | closed by the server | achieved req/s | achieved / offered | at or over 97 % | µs CPU/req | p95 ms | p99 ms | result |"
echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|"
runs_of parity-24000 | jq -r "$PRELUDE"'sort_by(.steplab.round, .steplab.position)[] | .results.steps[0] as $s
  | "| \(.steplab.variant)-\(.steplab.round) | \(.steplab.position + 1) | \(.valid) | \(.other_containers.count) | \(.idle.held_at_end) | \(.idle.closed_by_server_at_end) | \($s.achieved_rps | r1) | \(ratio | r1) % | \(if ratio >= 97 then "yes" else "no" end) | \($s.cpu_usec_per_request | r2) | \($s.latency_ms.overall.p95 | r2) | \($s.latency_ms.overall.p99 | r2) | \(if $s.pass then "pass" else "FAIL: " + ($s.reasons | join("; ")) end) |"'
echo
echo "| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |"
echo "|---|---|---|---|---|---|---|---|"
runs_of parity-24000 | jq -r "$PRELUDE"'sort_by(.steplab.round, .steplab.position)[]
  | "| \(.steplab.variant)-\(.steplab.round) | \(.host.before.load1) | \(.host.plateau.load1) | \(.host.plateau.cpu_busy_pct) % | \(.host.plateau.steal_pct) % | \(.host.fsync_ms) | \(.steplab.time_wait.before.max) | \(.steplab.time_wait.before.waited_s) |"'
echo
echo "What each JSON says about the harness's side of the soft limit (\`sub\` was given \`APP_SOFT_CONN_LIMIT=64000\` as a hint only: the copy reads no environment variable):"
echo
echo "| Run | environment given to the server | soft limit in the JSON | VU cap | VU cap bound by | server file |"
echo "|---|---|---|---|---|---|"
runs_of parity-24000 | jq -r "$PRELUDE"'sort_by(.steplab.round, .steplab.position)[]
  | "| \(.steplab.variant)-\(.steplab.round) | \(.server.env | join(" ")) | \(.server_connections.soft_limit) | \(.load.vu_cap) | \(.load.vu_cap_bound_by) | \(.server.file) |"'
echo
echo "The pairs, in the order they ran (the order alternates: round 1 runs the reference last, so \`sub\` ran first; round 2 runs it first; round 3 like round 1):"
echo
echo "| Round | order | lab µs/req | sub µs/req | sub minus lab µs | absolute value µs |"
echo "|---|---|---|---|---|---|"
runs_of parity-24000 | jq -r "$PRELUDE"'map(select(counted)) | group_by(.steplab.round)[] | select(length == 2) | (.[] | select(.steplab.variant == "lab")) as $a | (.[] | select(.steplab.variant == "sub")) as $b
  | (($b | us) - ($a | us)) as $d
  | "| \($a.steplab.round) | \(if $a.steplab.position == 0 then "lab then sub" else "sub then lab" end) | \($a | us | r2) | \($b | us | r2) | \($d | sgn) | \($d | fabs | r3) |"'
echo
FLOOR="$(bash "$LAB/steplab-floor.sh" "$AA" | jq '.floor_us')"
runs_of parity-24000 | jq -r --argjson floor "$FLOOR" "$PRELUDE"'map(select(counted)) as $c
  | ($c | group_by(.steplab.round) | map(select(length == 2) | ((.[] | select(.steplab.variant == "sub") | us) - (.[] | select(.steplab.variant == "lab") | us)))) as $d
  | ($d | med) as $m | ($d | all(. > 0) or all(. < 0)) as $same
  | ([$c[] | select(.steplab.variant == "lab") | us] | med) as $ml | ([$c[] | select(.steplab.variant == "sub") | us] | med) as $ms
  | ([$c[] | ratio] | min) as $lo | ([$c[] | ratio] | max) as $hi
  | "Medians over \($c | length) valid runs: lab \($ml | r2) µs/req, sub \($ms | r2) µs/req. Paired differences (sub minus lab) \($d | map(sgn) | join(", ")); **median \($m | sgn) µs/req, absolute value \($m | fabs | r3) against the floor \($floor | r3)**. The \($d | length) signs \(if $same then "are the same" else "differ" end). **\(if $same and ($m | fabs) >= $floor then "Outside the floor: every difference has one sign and the median is at or over it." else "Within the floor: " + (if $same then "the median is under it" else "the signs differ" end) + ", parity by the step lab'"'"'s rule." end)** Achieved over offered: \($lo | r1) % to \($hi | r1) %; runs under the 97 % rule: \([$c[] | select(.results.steps[0].pass | not)] | length) of \($c | length). Largest spread between two paired differences: \(($d | max) - ($d | min) | r2) µs."'
echo
echo '```text'
bash "$LAB/steplab-summary.sh" parity-24000 --floor-from "$AA"
echo '```'
