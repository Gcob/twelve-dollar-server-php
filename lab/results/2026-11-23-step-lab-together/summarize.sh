#!/usr/bin/env bash
# Prints the Markdown tables of README.md from the JSON files in this folder's subfolders (screen/, staircase/, holds/, profile/), from the
# baseline's holds and profile (../2026-11-22-realistic-baseline), from the CPU steps' skeleton profile (../2026-11-23-cpu-steps/profile) and
# from the S1 series' A/A floor and reconnect cost (../2026-11-23-s1-fd-wall). A run counts when its JSON says valid: true and
# other_containers.count 0. The 6.62 µs a reconnect and the model of the bench's sizes are the S1 series' (its README, "The reading").
set -euo pipefail
cd "$(dirname "$0")"
LAB="$(cd ../.. && pwd)"
BASE=../2026-11-22-realistic-baseline
STEPS=../2026-11-23-cpu-steps
# The A/A floor of 24,000 req/s: the largest paired difference of the S1 series' five pairs (also printed by its own summarize.sh).
FLOOR=2.57
# One reconnect's cost (median of the S1 series' 5 pairs), the soft limit of that series' model, and the users the leaderboard's formula
# maps one µs of a request to (about 8.0 million over the µs per request, on the Mac, not a score).
RECONNECT_US=6.62
MODEL_LIMIT=64000
USERS_NUMERATOR=8000000
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PRELUDE='
def med: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
def r0: if . == null then "-" else round end;
def r1: if . == null then "-" else . * 10 | round / 10 end;
def r2: if . == null then "-" else . * 100 | round / 100 end;
def sgn: if . == null then "-" else (. * 100 | round / 100) as $x | if $x > 0 then "+\($x)" elif $x == 0 then "0" else "\($x)" end end;
def counted: .valid and .other_containers.count == 0;
def us: .results.steps[0].cpu_usec_per_request;
'

echo "### The combined screen: the skeleton against \`APP_PRAGMAS=cache-256m\` with \`APP_LOCKING=exclusive\` (24,000 req/s, \`s = 0.02\`, 60,000 idle, 60 s plateau, telemetry off, floor $FLOOR µs/req)"
echo
echo '```text'
bash "$LAB/steplab-summary.sh" screen --floor "$FLOOR" --json "$TMP/screen.json"
echo '```'
echo
jq -r "$PRELUDE"'.runs as $r | .variants[] | select(.reference | not) as $v
  | "The pair is **\($v.median_difference_us | sgn) µs/req** (reference \($r | map(select(.index == 0 and .counted) | .us_per_request) | med | r2), combination \($v.median_us | r2)), the floor is \($floor): \($v.verdict)."' \
  --argjson floor "$FLOOR" "$TMP/screen.json"

echo
echo "### The staircase (the combination is S1-d alone: no switch of the screen was confirmed), one run per file"
staircase_table() { # path of the run's JSON, without .json
  jq -r "$PRELUDE"'
    "Run `\($f).json`: think scale \(.load.think_scale), VU cap \(.load.vu_cap), warm-up \(.load.warmup // "none"), \(.load.plateau_s) s plateaus, lag gate \(.aggregator.lag_gate_s) s, server environment `\(.server.env | join(" "))`; valid \(.valid), other containers \(.other_containers.count), idle held \(.idle.held_at_start) at the start and \(.idle.held_at_end) at the end, aggregator max lag \(.aggregator.max_lag_s) s, k6 connection errors \(.k6_connection_errors), limit closes \(.server_connections.telemetry.close_responses), accept pauses \(.server_connections.telemetry.accept_pauses), most connections open \(.server_connections.telemetry.open_peak).",
    "",
    "| Step | VUs | offered req/s | achieved req/s | users | µs CPU/req | p95 ms | p99 ms | errors | k6 CPU % of one | result |",
    "|---|---|---|---|---|---|---|---|---|---|---|",
    (.results.steps[] | "| \(.step) | \(.vus) | \(.offered_rps | r1) | \(.achieved_rps | r1) | \(.users | r0) | \(.cpu_usec_per_request | r1) | \(.latency_ms.overall.p95 | r2) | \(.latency_ms.overall.p99 | r2) | \(.error_rate * 100 | r2) % | \(.k6_cpu_percent_of_one_cpu // "-") | \(if .pass then "pass" else "FAIL: " + (.reasons | join("; ")) end) |"),
    "",
    (if .results.stopped_at_step then "Stopped at step \(.results.stopped_at_step): \(.results.stop_reasons | join("; "))." else "No step failed." end)' --arg f "$1" "$1.json"
}
for json in staircase/staircase-coarse-?.json staircase/staircase-fine*.json; do
  [ -f "$json" ] || continue
  f="$(basename "${json%.json}")"
  echo
  echo "**$f**"
  echo
  staircase_table "staircase/$f"
done

HOLDS="$(ls holds/hold-[0-9].json 2>/dev/null || true)"
if [ -n "$HOLDS" ]; then
  echo
  echo "### The holds (5 minutes each, a fresh run each), beside the baseline's three"
  echo
  echo "| Run | valid | other containers | offered req/s | achieved req/s | users at 9.45 per req/s | µs CPU/req | p95 ms | p99 ms | errors | idle held (start / end) | limit closes | accept pauses | most connections open | fds peak | aggregator max lag s | result |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
  for f in $HOLDS; do
    jq -r "$PRELUDE"'.results.steps[0] as $s | .server_connections as $c
      | "| \($f | sub("^holds/"; "") | sub("\\.json$"; "")) | \(.valid) | \(.other_containers.count) | \($s.offered_rps | r1) | \($s.achieved_rps | r1) | \($s.users | r0) | \($s.cpu_usec_per_request | r2)"
        + " | \($s.latency_ms.overall.p95 | r2) | \($s.latency_ms.overall.p99 | r2) | \($s.error_rate * 100 | r2) % | \(.idle.held_at_start) / \(.idle.held_at_end)"
        + " | \($c.telemetry.close_responses) | \($c.telemetry.accept_pauses) | \($c.telemetry.open_peak) | \($c.fds_peak // "-") | \(.aggregator.max_lag_s) | \(if $s.pass then "pass" else "FAIL: " + ($s.reasons | join("; ")) end) |"' --arg f "$f" "$f"
  done
  # shellcheck disable=SC2086
  jq -nr "$PRELUDE"'[inputs | select(counted) | .results.steps[0] | select(.pass)] as $h
    | "| **median of the \($h | length) counted holds** | | | \($h | map(.offered_rps) | med | r1) | **\($h | map(.achieved_rps) | med | r1)** | **\($h | map(.users) | med | r0)** | **\($h | map(.cpu_usec_per_request) | med | r2)**"
      + " | **\($h | map(.latency_ms.overall.p95) | med | r2)** | **\($h | map(.latency_ms.overall.p99) | med | r2)** | \($h | map(.error_rate) | max * 100 | r2) % (max) | | | | | | |"' $HOLDS </dev/null
  echo "| baseline: median of its 3 holds (the skeleton before the CPU steps, telemetry on) | | | 24002.3 | 23386.4 | 221002 | 27.15 | 11.93 | 28.29 | | | | | | | | |"
  echo
  jq -nr "$PRELUDE"'[inputs | select(counted) | .results.steps[0] | select(.pass) | .cpu_usec_per_request] as $h
    | "The median of the 3 holds is **\($h | med | r2) µs/req**, \(($h | med) - 27.15 | sgn) µs from the baseline'"'"'s 27.15 (\((($h | med) - 27.15) / 27.15 * 100 | sgn) %). The holds run, in µs/req: \($h | map(r2) | join(", ")) (the baseline'"'"'s: 27.71, 27.15, 27.06)."' $HOLDS </dev/null
fi

if [ -f control/staircase.json ]; then
  echo
  echo "### The control: the skeleton alone, with none of S1-d's accounting (no \`APP_SOFT_CONN_LIMIT\`), the same flags as the staircase above"
  echo
  staircase_table control/staircase
  if [ -f control/hold.json ]; then
    echo
    echo "| Run | valid | other containers | offered req/s | achieved req/s | µs CPU/req | p95 ms | p99 ms | errors | idle held (start / end) | result |"
    echo "|---|---|---|---|---|---|---|---|---|---|---|"
    jq -r "$PRELUDE"'.results.steps[0] as $s
      | "| control/hold | \(.valid) | \(.other_containers.count) | \($s.offered_rps | r1) | \($s.achieved_rps | r1) | \($s.cpu_usec_per_request | r2) | \($s.latency_ms.overall.p95 | r2) | \($s.latency_ms.overall.p99 | r2) | \($s.error_rate * 100 | r2) % | \(.idle.held_at_start) / \(.idle.held_at_end) | \(if $s.pass then "pass" else "FAIL: " + ($s.reasons | join("; ")) end) |"' control/hold.json
  fi
fi

if [ -f held-rate-interleaved/skeleton-1.json ]; then
  echo
  echo "### The held rate, interleaved: one 24,000 req/s step each, the skeleton, S1-d (\`APP_SOFT_CONN_LIMIT=65450\`), the skeleton again, in that order, a minute apart"
  for run in skeleton-1 s1d-1 skeleton-2; do
    echo
    echo "**$run**"
    echo
    staircase_table "held-rate-interleaved/$run"
  done
  echo
  echo "| Order | run | achieved / offered | µs CPU/req | p99 ms |"
  echo "|---|---|---|---|---|"
  n=0
  for run in skeleton-1 s1d-1 skeleton-2; do
    n=$((n + 1))
    jq -r "$PRELUDE"'.results.steps[0] as $s | "| \($n) | \($run) | \($s.achieved_rps / $s.offered_rps * 100 | r2) % | \($s.cpu_usec_per_request | r2) | \($s.latency_ms.overall.p99 | r2) |"' --arg run "$run" --argjson n "$n" "held-rate-interleaved/$run.json"
  done
fi

PROFILE=profile/profile.json
if [ -f "$PROFILE" ] && [ -n "$HOLDS" ]; then
  # shellcheck disable=SC2086
  HELD="$(jq -nr "$PRELUDE"'[inputs | select(counted) | .results.steps[0] | select(.pass) | .cpu_usec_per_request] | med' $HOLDS </dev/null)"
  echo
  echo "### The profile (Excimer, 1 ms CPU time, one run: the held rate, \`s = 0.02\`, 60,000 idle, telemetry off), beside the baseline's and today's skeleton's"
  echo
  jq -r '"The profiled run is valid \(.valid), other containers \(.other_containers.count), limit closes \(.server_connections.telemetry.close_responses // "n/a (telemetry off)"), idle held \(.idle.held_at_start) / \(.idle.held_at_end). Profiled window (the server'"'"'s whole life after its first answer: warm-up, ramps and plateau): \(.profile.samples) samples at \(.profile.period_s * 1000) ms, the cgroup'"'"'s user CPU \(.profile.cgroup.user_usec / 1000 | round) ms and system CPU \(.profile.cgroup.system_usec / 1000 | round) ms (**\(.profile.cgroup.system_share * 100 | round) % in the kernel**), the samples cover \(.profile.samples_over_cgroup_cpu * 100 | round) % of that CPU, unclassified \(.profile.unclassified_share * 100 | . * 10 | round / 10) %."' "$PROFILE"
  echo
  echo "Each cell is a share of all the samples of its profile and the microseconds it is on the average request of that profile (the fold's \`--us-per-req\`: the baseline's 27.59 (its unprofiled runs' mean), the skeleton's 26.71 (the CPU steps' three references' median), and this run's $(jq -rn "$PRELUDE"'$u | r2' --argjson u "$HELD") (the median of the 3 holds, telemetry on)). The kernel's share is the cgroup's system CPU."
  echo
  echo "| Step | variant in this configuration | baseline: share, µs | skeleton today: share, µs | together: share, µs | together minus baseline, µs |"
  echo "|---|---|---|---|---|---|"
  jq -rn "$PRELUDE"'def rows: .profile.fold | split("\n") | map(capture("^(?<step>(S[1-9] |event loop|unclassified).*?)\\s+[0-9.]+% [0-9.]+us\\s+[0-9.]+% [0-9.]+us\\s+[0-9.]+% [0-9.]+us\\s+[0-9.]+% [0-9.]+us\\s+[0-9.]+% [0-9.]+us\\s+[0-9.]+% [0-9.]+us\\s+(?<pct>[0-9.]+)% [0-9.]+us$"));
    {"S1 accept connections": "S1-d, `APP_SOFT_CONN_LIMIT=65450`: it never fires here (a reconnect costs 6.62 µs, priced below)",
     "S6 query SQLite": "the skeleton'"'"'s query and pragmas (no S6 variant beat the floor, alone or together)",
     "S8 write the response": "the skeleton'"'"'s locking (`exclusive` did not beat the floor, alone or in the screen)",
     "S9 durability": "the skeleton'"'"'s write per request (group commit did not beat the floor; the checkpointer failed its bound)"} as $variant
    | (input | rows) as $b | (input | rows) as $s | (input | rows) as $t
    | [range(0; $t | length)] | map(. as $i | $t[$i].step as $step
      | "| \($step) | \($variant[$step | rtrimstr(" ")] // $variant[$step] // "unchanged") | \($b[$i].pct) %, \(($b[$i].pct | tonumber) / 100 * 27.59 | r1) µs | \($s[$i].pct) %, \(($s[$i].pct | tonumber) / 100 * 26.71 | r1) µs | \($t[$i].pct) %, \(($t[$i].pct | tonumber) / 100 * $u | r1) µs | \((($t[$i].pct | tonumber) / 100 * $u) - (($b[$i].pct | tonumber) / 100 * 27.59) | sgn) |") | .[]' \
    --argjson u "$HELD" "$BASE/profile-on.json" "$STEPS/profile/skeleton.json" "$PROFILE"
  echo
  echo "The fold of \`profile/profile.collapsed\` with \`--us-per-req\` set to the holds' median:"
  echo
  echo '```text'
  bash "$LAB/run.sh" 8.5 php /lab/profile/fold.php /lab/results/2026-11-23-step-lab-together/profile/profile.collapsed --us-per-req "$HELD"
  echo '```'
fi

if [ -n "$HOLDS" ]; then
  echo
  echo "### Users: what the held µs maps to, next to what S1-d adds at the bench's sizes"
  echo
  echo "Users from the leaderboard's formula (about $(awk -v n="$USERS_NUMERATOR" 'BEGIN { printf "%.1f", n / 1000000 }') million over the µs per request, arm64 Mac, not a score) are the CPU's capacity if the load had no harness floor; users at the held rate (9.45 per req/s) are what the harness offered at \`s = 0.02\`. S1-d adds a reconnect ($RECONNECT_US µs, the S1 series) to the share of requests that open a new connection: \`1 - $MODEL_LIMIT / N\` at N users (the first $MODEL_LIMIT keep theirs), so its cost per request is \`$RECONNECT_US * (1 - $MODEL_LIMIT / N)\`."
  echo
  echo "| Configuration | µs/req | users (leaderboard formula) | users at the held rate |"
  echo "|---|---|---|---|"
  # shellcheck disable=SC2086
  jq -nr "$PRELUDE"'[inputs | select(counted) | .results.steps[0] | select(.pass)] as $h
    | ($h | map(.cpu_usec_per_request) | med) as $u | ($h | map(.users) | med) as $users
    | "| baseline (phase 4, 3 holds, S1-a) | 27.15 | \(($n / 27.15) | r0) | 221002 |",
      "| **together, S1-d never firing (median of 3 holds)** | **\($u | r2)** | **\(($n / $u) | r0)** | **\($users | r0)** |",
      ([100000, 150000, 200000][] | . as $N | ($rc * (1 - $limit / $N)) as $add
        | "| together + S1-d at \($N) users (+\($add | r2) µs) | \($u + $add | r2) | \(($n / ($u + $add)) | r0) | |")' \
    --argjson n "$USERS_NUMERATOR" --argjson rc "$RECONNECT_US" --argjson limit "$MODEL_LIMIT" $HOLDS </dev/null
fi
