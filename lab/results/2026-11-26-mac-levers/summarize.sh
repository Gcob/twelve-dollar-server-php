#!/usr/bin/env bash
# Prints the Markdown tables of README.md from the JSON files next to this script: the A/A floor (aa-7500/), the feed micro (feed-micro/feed.json),
# the tuned SQLite's pairs (sqlite-7500/), the ring's pairs (ring-7500/) and the winners together (together-7500/, when it exists). A run counts when its JSON says
# valid: true and other_containers.count 0; every other run is listed in its table with its result and counted nowhere. Every pair is read against the
# floor of aa-7500/ by lab/steplab-summary.sh's own rule.
set -euo pipefail
cd "$(dirname "$0")"
LAB="$(cd ../.. && pwd)"
AA="$PWD/aa-7500"
# Two numbers no file of this folder holds: the users the reference holds on the bench (the figure the phase's plan carries) and the feeds a request
# costs (a bench loop makes one feed in about 2.17 requests: D109's bar).
REF_USERS=86800
FEEDS_PER_REQUEST=0.46

PRELUDE='
def med: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
def r1: if . == null then "-" else . * 10 | round / 10 end;
def r2: if . == null then "-" else . * 100 | round / 100 end;
def r3: if . == null then "-" else . * 1000 | round / 1000 end;
def sgn: if . == null then "-" elif . > 0 then "+\(. * 100 | round / 100)" else "\(. * 100 | round / 100)" end;
def counted: .valid and .other_containers.count == 0;
def us: .results.steps[0].cpu_usec_per_request;
def ratio: .results.steps[0] | .achieved_rps / .offered_rps * 100;
'
runs_of() { jq -s 'map(select(type == "object" and has("steplab")))' "$1"/*.json; }

runs_table() { # folder
  echo "| Run | position in its round | valid | other containers | idle held at the end | loop line | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|"
  runs_of "$1" | jq -r "$PRELUDE"'sort_by(.steplab.round, .steplab.position)[] | .results.steps[0] as $s
    | "| \(.steplab.variant)-\(.steplab.round) | \(.steplab.position + 1) | \(.valid) | \(.other_containers.count) | \(.idle.held_at_end) | \(.server.loop) | \($s.achieved_rps | r1) | \(ratio | r1) % | \($s.cpu_usec_per_request | r2) | \($s.latency_ms.overall.p95 | r2) | \($s.latency_ms.overall.p99 | r2) | \(if $s.pass then "pass" else "FAIL: " + ($s.reasons | join("; ")) end) |"'
}
host_table() { # folder
  echo "| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before |"
  echo "|---|---|---|---|---|---|---|"
  runs_of "$1" | jq -r "$PRELUDE"'sort_by(.steplab.round, .steplab.position)[]
    | "| \(.steplab.variant)-\(.steplab.round) | \(.host.before.load1) | \(.host.plateau.load1) | \(.host.plateau.cpu_busy_pct) % | \(.host.plateau.steal_pct) % | \(.host.fsync_ms) | \(.steplab.time_wait.before.max) |"'
}
summary_block() { # folder [steplab-summary.sh arguments]
  local dir="$1"
  shift
  echo '```text'
  bash "$LAB/steplab-summary.sh" "$dir" "$@"
  echo '```'
}

# lever_line <folder> <variant> <label>: the paired differences (variant minus ref), their median, the reference's and the variant's medians, and the
# Mac estimate REF_USERS x ref / variant.
lever_line() {
  local folder="$1" variant="$2" label="$3" floor
  floor="$(bash "$LAB/steplab-floor.sh" "$AA" | jq .floor_us)"
  runs_of "$folder" | jq -r "$PRELUDE"'map(select(counted)) as $c
    | ($c | group_by(.steplab.round) | map(select(length == 2) | ((.[] | select(.steplab.variant == $v) | us) - (.[] | select(.steplab.variant == "ref") | us)))) as $d
    | ([$c[] | select(.steplab.variant == "ref") | us] | med) as $r | ([$c[] | select(.steplab.variant == $v) | us] | med) as $x
    | ($d | med) as $m
    | (if ($d | length) >= 2 then (if (($d | all(. < 0)) or ($d | all(. > 0))) and ($m | fabs) >= $floor then "beyond the floor" else "within the floor" end)
       elif ($d | length) == 1 then (if ($m | fabs) >= $floor then "one pair: a screen that \(if $m < 0 then "beats" else "loses to" end) the floor, no verdict" else "one pair: within the floor" end)
       else "no pair" end) as $verdict
    | "- **\($label):** reference \($r | r2) µs/req, \($label) \($x | r2) µs/req over \($d | length) pair(s); paired differences \($d | map(sgn) | join(", ")), **median \($m | sgn) µs/req** (\($m / $r * 100 | sgn) %) against the floor \($floor | r3): **\($verdict)**. Mac estimate, arm64, not the bench: \($users) x \($r | r2) / \($x | r2) = **\($users * $r / $x | round) users**."' \
    --arg v "$variant" --arg label "$label" --argjson floor "$floor" --argjson users "$REF_USERS"
}

# --------------------------------------------------------------------------------------------------------------------------------
echo "### The Mac's A/A floor (the reference against itself, \`ref\` and \`ref2\`, 5 pairs, 7,500 req/s)"
echo
runs_table aa-7500
echo
host_table aa-7500
echo
summary_block aa-7500
echo
bash "$LAB/steplab-floor.sh" aa-7500 | jq -r "$PRELUDE"'"Floor: **\(.floor_us | r3) µs/req** (|median \(.median_difference_us | r3)| + interquartile range \(.iqr_us | r3), 5 paired differences \(.differences_us | map(sgn) | join(", ")))."'
echo
runs_of aa-7500 | jq -r "$PRELUDE"'map(select(counted)) as $c | "Valid runs: \($c | length) of \(length). Reference (both sides) median \([$c[] | us] | med | r2) µs/req."'

# --------------------------------------------------------------------------------------------------------------------------------
echo
echo "### The feed micro (\`lab/micro.sh lab/micro/benches/feed.php --images 8.5,8.5-sqlite --jit on --jit-buffer-size 32M\`, the JIT as the submission runs it, 5 processes a case)"
echo
echo "| Case | Ubuntu's 3.45.1 (\`8.5\`) ns/op | tuned 3.54.1 (\`8.5-sqlite\`) ns/op | saving ns | saving % |"
echo "|---|---|---|---|---|"
jq -r "$PRELUDE"'
  (.runs | map({key: .image, value: (.cases | map({key: .case, value: .median_ns}) | from_entries)}) | from_entries) as $m
  | ["feed/reference/assoc, APP_PRAGMAS=mmap-off", "feed/reference/assoc", "post/reference/assoc"][] as $c
  | ($m["8.5"][$c]) as $a | ($m["8.5-sqlite"][$c]) as $b
  | "| `\($c)` | \($a | round) | \($b | round) | \($a - $b | round) | \(($a - $b) / $a * 100 | r1) % |"' feed-micro/feed.json
echo
jq -r "$PRELUDE"'
  (.runs | map({key: .image, value: (.cases | map({key: .case, value: .median_ns}) | from_entries)}) | from_entries) as $m
  | "feed/reference/assoc, APP_PRAGMAS=mmap-off" as $c
  | ($m["8.5"][$c] - $m["8.5-sqlite"][$c]) as $save
  | "The submission opens its connections with `cache_size = -65536` and `mmap_size = 0`, which is the `APP_PRAGMAS=mmap-off` case: that row is the one the bar reads.",
    "",
    "**The bar:** the saving per feed, \($save | round) ns = \($save / 1000 | r2) µs, times \($f) feeds a request = **\($save / 1000 * $f | r2) µs/req**, against the floor \($floor | r3) µs/req: \(if $save / 1000 * $f >= $floor then "it reaches the floor, so the pair is run" else "it does not reach the floor, so the pair is skipped" end). (With the default pragmas row the saving is \($m["8.5"]["feed/reference/assoc"] - $m["8.5-sqlite"]["feed/reference/assoc"] | round) ns, \(($m["8.5"]["feed/reference/assoc"] - $m["8.5-sqlite"]["feed/reference/assoc"]) / 1000 * $f | r2) µs/req.)"' \
  feed-micro/feed.json --argjson f "$FEEDS_PER_REQUEST" --argjson floor "$(bash "$LAB/steplab-floor.sh" "$AA" | jq .floor_us)"

# --------------------------------------------------------------------------------------------------------------------------------
for step in sqlite ring; do
  case "$step" in
    sqlite) title="The tuned SQLite's pairs (\`sqlite\`: the submission's server on \`8.5-sqlite\`, against \`ref\`)" ;;
    ring) title="The ring's pairs (\`ring\`: the lab app on 3 rings, \`APP_PRAGMAS=mmap-off\`, soft limit 192,000, server nofile 32,768, against \`ref\`)" ;;
  esac
  echo
  echo "### $title"
  echo
  runs_table "$step-7500"
  echo
  host_table "$step-7500"
  echo
  summary_block "$step-7500" --floor-from "$AA"
done

if [ -d together-7500 ]; then
  echo
  echo "### The winners together (\`ring-sqlite\`: the ring on \`8.5-sqlite\`, against \`ref\`)"
  echo
  runs_table together-7500
  echo
  host_table together-7500
  echo
  summary_block together-7500 --floor-from "$AA"
fi

# --------------------------------------------------------------------------------------------------------------------------------
echo
echo "### One line per lever"
echo
lever_line sqlite-7500 sqlite "tuned SQLite"
lever_line ring-7500 ring "ring"
if [ -d together-7500 ]; then
  lever_line together-7500 ring-sqlite "ring on the tuned SQLite"
fi
