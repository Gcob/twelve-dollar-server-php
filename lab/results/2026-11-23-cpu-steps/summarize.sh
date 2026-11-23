#!/usr/bin/env bash
# Prints the Markdown tables of README.md from the JSON files in this folder's subfolders and from the S1 series' A/A files in
# ../2026-11-23-s1-fd-wall/aa-24000 (the floor of 24,000 req/s). A run counts when its JSON says valid: true and other_containers.count 0.
# The syscall counts carry no other_containers field (the script that writes them does not record it): the README says how the VM was
# checked for them. The micro numbers are read from lab/micro/feed-run/feed-8.5-jit-on.json (one developer's run on the Mac's VM).
set -euo pipefail
cd "$(dirname "$0")"
LAB="$(cd ../.. && pwd)"
S1=../2026-11-23-s1-fd-wall
SERIES="s6-mmap-off s6-cache-256m s8-exclusive s9-group-commit"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PRELUDE='
def med: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
def r1: if . == null then "-" else . * 10 | round / 10 end;
def r2: if . == null then "-" else . * 100 | round / 100 end;
def r3: if . == null then "-" else . * 1000 | round / 1000 end;
def sgn: if . == null then "-" elif . > 0 then "+\(. * 100 | round / 100)" else "\(. * 100 | round / 100)" end;
def counted: .valid and .other_containers.count == 0;
def us: .results.steps[0].cpu_usec_per_request;
def ratio: .results.steps[0] | .achieved_rps / .offered_rps * 100;
# The seconds of the plateau whose largest latency, over any endpoint, is above 100 ms.
def plateau_seconds: (.results.steps[0].window) as $w | .results.per_second | map(select(.second >= $w[0] and .second < $w[1]));
def stalls: plateau_seconds | map(select(([.endpoints[].max] | max) > 100));
'
runs_of() { jq -s 'map(select(type == "object" and has("steplab")))' "$1"/*.json; }

# The A/A floor at 24,000 req/s (telemetry off): the largest absolute paired difference of the S1 series' pairs, to two decimals as the step lab was told.
FLOOR="$(runs_of "$S1/aa-24000" | jq -r "$PRELUDE"'map(select(counted)) | group_by(.steplab.round) | map(select(length == 2) | ((.[] | select(.steplab.variant == "b") | us) - (.[] | select(.steplab.variant == "a") | us)) | fabs) | max | r2')"
AA_MEDIAN="$(runs_of "$S1/aa-24000" | jq -r "$PRELUDE"'map(select(counted) | us) | med | r2')"

# Every run file of the series, as one array.
all_runs() { for s in $SERIES; do [ -d "$s" ] && runs_of "$s"; done | jq -s 'add'; }

echo "### The floor and the reference"
echo
runs_of "$S1/aa-24000" | jq -r "$PRELUDE"'"The A/A floor at 24,000 req/s (the S1 series, `2026-11-23-s1-fd-wall/aa-24000`): **\($floor) µs/req**, the largest absolute paired difference of its \(map(select(counted)) | group_by(.steplab.round) | map(select(length == 2)) | length) pairs; the median of its \(map(select(counted)) | length) runs is \($m) µs/req."' --argjson floor "$FLOOR" --arg m "$AA_MEDIAN"
echo
all_runs | jq -r "$PRELUDE"'map(select(counted and .steplab.variant_index == 0 and (.server.env | index("APP_TELEMETRY=0") != null)) | us) as $off
  | map(select(counted and .steplab.variant_index == 0 and (.server.env | index("APP_TELEMETRY=1") != null)) | us) as $on
  | "Today'"'"'s skeleton, the reference of every pair: telemetry off (S6 and S8) \($off | map(r2) | join(", ")) µs/req, median **\($off | med | r2)**; telemetry on (S9) \($on | map(r2) | join(", ")) µs/req. The baseline'"'"'s was 27.15 (phase 4, probes on), before the `respond()` split and the `instanceof Closure` test of a request."'

echo
echo "### Every run of the series"
echo
echo "| Series | Run | valid | other containers | idle held at the end | closed by the server | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |"
echo "|---|---|---|---|---|---|---|---|---|---|---|"
for s in $SERIES; do
  [ -d "$s" ] || continue
  runs_of "$s" | jq -r "$PRELUDE"'sort_by(.steplab.round, .steplab.variant_index)[] | .results.steps[0] as $s
    | "| \($dir) | \(.steplab.variant)-\(.steplab.round) | \(.valid) | \(.other_containers.count) | \(.idle.held_at_end) | \(.idle.closed_by_server_at_end) | \(ratio | r1) % | \($s.cpu_usec_per_request | r2) | \($s.latency_ms.overall.p95 | r2) | \($s.latency_ms.overall.p99 | r2) | \(if $s.pass then "pass" else "FAIL: " + ($s.reasons | join("; ")) end) |"' --arg dir "$s"
done

echo
echo "### The step lab's tables, one series at a time (the reference first in each pair; the floor is $FLOOR µs/req)"
for s in $SERIES; do
  [ -d "$s" ] || continue
  echo
  echo "**$s**"
  echo
  echo '```text'
  bash "$LAB/steplab-summary.sh" "$s" --floor "$FLOOR" --json "$TMP/$s.json"
  echo '```'
done

echo
echo "### Each variant against the reference"
echo
echo "| Series | Variant | pairs | reference µs/req | variant µs/req | paired difference µs | floor µs | reference p99 ms | variant p99 ms | verdict |"
echo "|---|---|---|---|---|---|---|---|---|---|"
for s in $SERIES; do
  [ -f "$TMP/$s.json" ] || continue
  jq -r "$PRELUDE"'.runs as $r | .variants[] | select(.reference | not) | . as $v
    | ($r | map(select(.index == 0 and .counted))) as $ref
    | "| \($dir) | \($v.variant) | \($v.pairs | length) | \($ref | map(.us_per_request) | med | r2) | \($v.median_us | r2) | \($v.median_difference_us | sgn) | \($floor) | \($ref | map(.p99_ms) | med | r2) | \($v.median_p99_ms | r2) | \($v.verdict) |"' --arg dir "$s" --argjson floor "$FLOOR" "$TMP/$s.json"
done

if [ -d s9-group-commit ]; then
  echo
  echo "### S9: group commit, judged on its latency first (telemetry on for both sides)"
  echo
  echo "| Run | µs CPU/req | p99 ms | median per-second p99 ms | largest per-second max ms | stalled seconds of the plateau (max latency above 100 ms) | longest callback ms (the most of any second) | commits | mean batch | largest batch |"
  echo "|---|---|---|---|---|---|---|---|---|---|"
  runs_of s9-group-commit | jq -r "$PRELUDE"'sort_by(.steplab.round, .steplab.variant_index)[] | .server_connections.telemetry as $t | plateau_seconds as $p
    | "| \(.steplab.variant)-\(.steplab.round) | \(us | r2) | \(.results.steps[0].latency_ms.overall.p99 | r2) | \($p | map(.p99) | med | r2) | \($p | map([.endpoints[].max] | max) | max | r1) | \(stalls | length) of \($p | length) | \($t.longest_callback_ms_max | r2) | \($t.group_commit.commits // "-") | \($t.group_commit.batch_mean // "-") | \($t.group_commit.batch_max // "-") |"'
fi

echo
echo "### The micro bench of the S6 variants beside the macro pairs (ns per feed: query and JSON, 5 processes, JIT on; one developer's run on the Mac's VM)"
echo
echo "| Variant | micro: median ns per feed | micro: against the reference | macro: paired difference µs/req (one pair) | macro: against the reference's µs/req |"
echo "|---|---|---|---|---|"
for pair in "mmap-off s6-mmap-off" "cache-256m s6-cache-256m"; do
  read -r variant dir <<<"$pair"
  jq -rn "$PRELUDE"'input.runs[0].cases as $m | input as $sum
    | ($m | map(select(.case == "feed/reference/assoc"))[0].median_ns) as $ref | ($m | map(select(.case == "feed/reference/assoc, APP_PRAGMAS=" + $name))[0].median_ns) as $v
    | ($sum.variants[] | select(.variant == $name)) as $x | ($sum.runs | map(select(.index == 0 and .counted)) | map(.us_per_request) | med) as $mr
    | "| `APP_PRAGMAS=\($name)` | \($v | round) | \((($v / $ref) - 1) * 100 | r1) % | \($x.median_difference_us | sgn) | \(($x.median_difference_us / $mr) * 100 | r1) % |"' \
    --arg name "$variant" "$LAB/micro/feed-run/feed-8.5-jit-on.json" "$TMP/$dir.json"
done

if [ -f syscalls-skeleton.json ] && [ -f syscalls-exclusive.json ]; then
  echo
  echo "### Syscalls per request (strace -c, 2,000 req/s, 20 s of the plateau; counts only), the skeleton and \`APP_LOCKING=exclusive\`"
  echo
  echo "| syscall | skeleton: calls per request | exclusive: calls per request | difference |"
  echo "|---|---|---|---|"
  jq -rn "$PRELUDE"'[inputs] as $f | ($f[0].syscalls | map({(.name): .calls_per_request}) | add) as $a | ($f[1].syscalls | map({(.name): .calls_per_request}) | add) as $b
    | ($f[0].syscalls + $f[1].syscalls | map(.name) | unique) as $names
    | ($names | map(select(($b[.] // 0) >= 0.01 or ($a[.] // 0) >= 0.01)))[]
    | . as $n | "| `\($n)` | \($a[$n] // 0) | \($b[$n] // 0) | \((($b[$n] // 0) - ($a[$n] // 0)) * 1000 | round / 1000 | sgn) |"' syscalls-skeleton.json syscalls-exclusive.json
  jq -rn '[inputs] as $f | "| **total** | **\($f[0].total.calls_per_request)** | **\($f[1].total.calls_per_request)** | **\((($f[1].total.calls_per_request - $f[0].total.calls_per_request) * 1000 | round) / 1000)** |",
    "| requests counted in the window | \($f[0].requests) | \($f[1].requests) | |"' syscalls-skeleton.json syscalls-exclusive.json
fi

if [ -d idle-retry-proof ]; then
  echo
  echo "### Step 0: three real-shape runs back to back with no wait (the idle client retries a busy port): 24,000 req/s, \`s = 0.02\`, 60,000 idle, telemetry off"
  echo
  echo "| Run | valid | other containers | waited before the run (s) | TIME_WAIT on the busiest idle address when it started | idle held at the end | closed by the server | source addresses used | connects retried | µs CPU/req |"
  echo "|---|---|---|---|---|---|---|---|---|---|"
  runs_of idle-retry-proof | jq -r "$PRELUDE"'sort_by(.steplab.variant_index)[]
    | "| \(.steplab.variant)-\(.steplab.round) | \(.valid) | \(.other_containers.count) | \(.steplab.time_wait.before.waited_s) | \(.steplab.time_wait.before.idle_max) | \(.idle.held_at_end) | \(.idle.closed_by_server_at_end) | \(.idle.source_addresses | length) | \(.idle.bind_retries) | \(us | r2) |"'
fi

if [ -f profile/skeleton.json ]; then
  echo
  echo "### The profile of today's skeleton (Excimer, 1 ms CPU time, one run: 24,000 req/s, \`s = 0.02\`, 60,000 idle, telemetry off), beside the baseline's"
  echo
  jq -r '.profile | "Profiled window (the server'"'"'s whole life after its first answer: warm-up, ramps and plateau): \(.samples) samples at \(.period_s * 1000) ms, the cgroup'"'"'s user CPU \(.cgroup.user_usec / 1000 | round) ms and system CPU \(.cgroup.system_usec / 1000 | round) ms (**\(.cgroup.system_share * 100 | round) % in the kernel**), the samples cover \(.samples_over_cgroup_cpu * 100 | round) % of that CPU, unclassified \(.unclassified_share * 100 | . * 10 | round / 10) %. The run is valid: \(.valid_note // "see the run table")."' profile/skeleton.json 2>/dev/null | sed 's/ The run is valid: see the run table\.//'
  us="$(all_runs | jq -r "$PRELUDE"'map(select(counted and .steplab.variant_index == 0 and (.server.env | index("APP_TELEMETRY=0") != null)) | us) | med')"
  echo
  echo "Share of all the samples per step, the baseline's profile (phase 4, probes on) and today's (the all column of the fold):"
  echo
  echo "| Step | baseline: share of the samples | today: share of the samples | today: µs on the average request (reference median $(jq -rn "$PRELUDE"'$u | r2' --argjson u "$us") µs/req) |"
  echo "|---|---|---|---|"
  jq -rn "$PRELUDE"'def rows: .profile.fold | split("\n") | map(capture("^(?<step>(S[1-9] |event loop|unclassified).*?)\\s+[0-9.]+% [0-9.]+us\\s+[0-9.]+% [0-9.]+us\\s+[0-9.]+% [0-9.]+us\\s+[0-9.]+% [0-9.]+us\\s+[0-9.]+% [0-9.]+us\\s+[0-9.]+% [0-9.]+us\\s+(?<pct>[0-9.]+)% [0-9.]+us$"));
    (input | rows) as $b | (input | rows) as $t
    | [range(0; $t | length)] | map(. as $i | "| \($t[$i].step) | \($b[$i].pct) % | \($t[$i].pct) % | \((($t[$i].pct | tonumber) / 100 * $u) | r1) |") | .[]' \
    --argjson u "$us" ../2026-11-22-realistic-baseline/profile-on.json profile/skeleton.json
  echo
  echo "The fold of \`profile/skeleton.collapsed\` with \`--us-per-req\` set to the reference runs' median (an unprofiled number):"
  echo
  echo '```text'
  bash "$LAB/run.sh" 8.5 php /lab/profile/fold.php /lab/results/2026-11-23-cpu-steps/profile/skeleton.collapsed --us-per-req "$us"
  echo '```'
fi
