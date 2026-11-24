#!/usr/bin/env bash
# Prints the Markdown tables of README.md from the JSON files next to this script (reconnect/, s1b-7500/, s1b-7500/served.json) and from the
# folders it is read against: 5a's x86 calibration (its first reconnect pair, its skeleton against S1-d that never fired: the only x86
# near-A/A, so the floor) and the Mac's A/A at 24,000 req/s of 5b (the cautious floor). A run counts when its JSON says valid: true and
# other_containers.count 0; every other run is listed in its table with its result and counted nowhere.
set -euo pipefail
cd "$(dirname "$0")"
LAB="$(cd ../.. && pwd)"
XEON="$LAB/results/2026-11-23-x86-calibration"
MACAA="$LAB/results/2026-11-24-cpu-steps-5b/aa-24000"
# Four numbers no file of this folder holds: the soft limit of the S1 series' model (its README states it as text), the bytes a connection costs
# on x86 (5a's S1 series: the DIY server's 1.48 KiB of Pss plus 5.19 KiB of kernel memory a connection, 6.67 KiB), the Xeon-to-bench factor of
# 5a (its Swoole pairs: the leaderboard's 94 and 101 µs/req over the Xeon's two entries, mean 1.57) and 5a's bench estimate of the skeleton
# (the Xeon's skeleton median 53.57 times that factor, 83.9, in ../2026-11-23-x86-calibration/README.md).
SOFT_LIMIT=64000
KIB_PER_CONNECTION=6.67
XEON_TO_BENCH=1.57
FIVE_A_BENCH_ESTIMATE=83.9
BOX_MIB=2048

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
echo "### The second reconnect pair (S1-a against S1-d with every request reconnecting, \`APP_SOFT_CONN_LIMIT=60000\`, \`APP_PRAGMAS=mmap-off\`, telemetry on, 7,500 req/s, one round)"
echo
runs_table reconnect
echo
host_table reconnect
echo
runs_of reconnect | jq -r "$PRELUDE"'map(select(.steplab.variant == "s1d-every"))[0] | .results.k6_summary.metrics.http_reqs.count as $k6 | (.steplab.warmup | split(",") | (.[0] | tonumber) * ((.[1] | tonumber) + 5)) as $warm | .server_connections.telemetry.close_responses as $closes
  | "S1-d with every request reconnecting: the server sent \($closes) `Connection: close` responses; k6 made \($k6) requests, plus the warm-up'"'"'s nominal \($warm | round) (its rate times its plateau plus half its 10 s ramp; the server counts its whole life): a difference of \($closes - $k6 - $warm | round), \((($closes - $k6 - $warm) / $closes * 100 | fabs) | r2) % of the closes, so every request reconnected."'
echo
summary_block reconnect --floor-from "$XEON/pairs"

FIRST="$(runs_of "$XEON/reconnect" | jq "$PRELUDE"'map(select(counted)) | ((map(select(.steplab.variant == "skeleton") | us)[0]) as $a | (map(select(.steplab.variant == "s1d-every") | us)[0]) as $b | {skeleton: $a, every: $b, cost: ($b - $a)})')"
SECOND="$(runs_of reconnect | jq "$PRELUDE"'map(select(counted)) | ((map(select(.steplab.variant == "s1a") | us)[0]) as $a | (map(select(.steplab.variant == "s1d-every") | us)[0]) as $b | {s1a: $a, every: $b, cost: ($b - $a)})')"
echo
echo "### The reconnect's price on the Xeon: this pair against 5a's"
echo
jq -rn "$PRELUDE"'
  "| Pair | reference µs/req | every request reconnecting µs/req | one reconnect costs µs | against 5a'"'"'s |",
  "|---|---|---|---|---|",
  "| 5a, the skeleton (no `mmap-off`) | \($first.skeleton | r2) | \($first.every | r2) | \($first.cost | r2) | - |",
  "| this folder, S1-a (`mmap-off`) | \($second.s1a | r2) | \($second.every | r2) | \($second.cost | r2) | \(($second.cost / $first.cost - 1) * 100 | sgn) % (\(if (($second.cost / $first.cost - 1) | fabs) <= 0.1 then "within" else "outside" end) 10 %) |",
  "",
  "Mean of the two pairs: **\((($first.cost + $second.cost) / 2) | r2) µs a reconnect** (the price the S1 rule below uses). The two pairs are one pair each: a screen apiece (floor \($floor | r3) µs/req), their gap is \(($second.cost - $first.cost) | sgn) µs."' \
  --argjson first "$FIRST" --argjson second "$SECOND" --argjson floor "$(bash "$LAB/steplab-floor.sh" "$XEON/pairs" | jq .floor_us)"

# --------------------------------------------------------------------------------------------------------------------------------
echo
echo "### S1-b against S1-a at 7,500 req/s (\`APP_WORKERS=2\` against one process, \`APP_PRAGMAS=mmap-off\`, telemetry on, \`s = 0.02\`, 60,000 idle, 3 pairs)"
echo
runs_table s1b-7500
echo
host_table s1b-7500
echo
runs_of s1b-7500 | jq -r "$PRELUDE"'map(select(counted)) as $c | [$c[] | .host.plateau.load1] as $l | [$c[] | .host.plateau.cpu_busy_pct] as $b | [$c[] | .host.fsync_ms] as $f | [$c[] | .host.plateau.steal_pct] as $s
  | "Over the \($c | length) runs: load on the plateau \($l | min) to \($l | max), the VM'"'"'s CPU busy \($b | min) to \($b | max) %, steal \($s | min) to \($s | max) %, `fsync` \($f | min) to \($f | max) ms."'
echo
echo "The pairs (S1-b minus S1-a, the order alternates: round 1 runs S1-b first, round 2 S1-a first, round 3 S1-b first):"
echo
echo "| Round | order | S1-a µs/req | S1-b µs/req | S1-b minus S1-a µs | as a share of S1-a |"
echo "|---|---|---|---|---|---|"
runs_of s1b-7500 | jq -r "$PRELUDE"'map(select(counted)) | group_by(.steplab.round)[] | select(length == 2) | (.[] | select(.steplab.variant == "s1a")) as $a | (.[] | select(.steplab.variant == "s1b")) as $b
  | "| \($a.steplab.round) | \(if $a.steplab.position == 0 then "s1a then s1b" else "s1b then s1a" end) | \($a | us | r2) | \($b | us | r2) | \(($b | us) - ($a | us) | sgn) | \((($b | us) / ($a | us) - 1) * 100 | sgn) % |"'
echo
runs_of s1b-7500 | jq -r "$PRELUDE"'map(select(counted)) as $c | ([$c[] | select(.steplab.variant == "s1a") | us] | med) as $ma | ([$c[] | select(.steplab.variant == "s1b") | us] | med) as $mb
  | ($c | group_by(.steplab.round) | map(select(length == 2) | ((.[] | select(.steplab.variant == "s1b") | us) - (.[] | select(.steplab.variant == "s1a") | us)))) as $d
  | "Medians: S1-a \($ma | r2) µs/req, S1-b \($mb | r2) µs/req. Paired differences \($d | map(sgn) | join(", ")), **median \($d | med | sgn) µs/req, \(($d | med) / $ma * 100 | sgn) % of the median S1-a**. Achieved over offered: \([$c[] | ratio] | min | r1) % to \([$c[] | ratio] | max | r1) %; runs under the 97 % rule: \([$c[] | select(.results.steps[0].pass | not)] | length) of \($c | length)."'
echo
echo "Both processes served, from the server's own log (the telemetry line each process prints every second, \`requests\` summed over the run's whole life: the warm-up, the plateau and one request per idle connection):"
echo
echo "| Run | processes | requests counted by each process | seconds in which each counted a request | share of the first |"
echo "|---|---|---|---|---|"
jq -r '.[] | if (.processes | length) == 0 then "| \(.run) | not followed | - | - | - |"
  else "| \(.run) | \(.processes | length) | \(.processes | map(.requests) | join(" and ")) | \(.processes | map(.seconds_with_requests) | join(" and ")) | \(.processes[0].requests / (.processes | map(.requests) | add) * 100 * 10 | round / 10) % |" end' s1b-7500/served.json
echo
echo "Memory of one run of each variant, with the sampler on (\`--no-series\` off; 7,500 req/s for 60 s after the warm-up, 60,000 idle; not a pair, not counted):"
echo
echo "| Variant | valid | achieved req/s | µs CPU/req | memory.current peak MiB | Pss_Anon peak MiB | file descriptors peak | processes |"
echo "|---|---|---|---|---|---|---|---|"
for v in s1a s1b; do
  jq -r "$PRELUDE"'"| \(input_filename | sub("^.*/"; "") | sub("\\.json$"; "")) | \(.valid) | \(.results.steps[0].achieved_rps | r1) | \(us | r2) | \(.results.server_memory_current_peak_mib | r1) | \(.results.server_pss_anon_peak_mib | r1) | \(.server_connections.fds_peak) | \(.server_connections.telemetry.processes // 1) |"' "s1b-7500/memory/$v.json"
done
echo
echo "The same series against the Xeon's floor (5a's skeleton against S1-d that never fired, the only x86 near-A/A):"
echo
summary_block s1b-7500 --floor-from "$XEON/pairs"
echo
echo "And against the Mac's floor (the A/A at 24,000 req/s of 5b), the cautious reading:"
echo
summary_block s1b-7500 --floor-from "$MACAA"

# --------------------------------------------------------------------------------------------------------------------------------
echo
echo "### The S1 rule at the bench's sizes (soft limit $SOFT_LIMIT a process; a share 1 - $SOFT_LIMIT / N of the requests reconnect when a process holds N users)"
echo
S1B_ADD="$(runs_of s1b-7500 | jq "$PRELUDE"'map(select(counted)) | group_by(.steplab.round) | map(select(length == 2) | ((.[] | select(.steplab.variant == "s1b") | us) - (.[] | select(.steplab.variant == "s1a") | us))) | med | . * 100 | round / 100')"
PAIR_DIFFS="$(runs_of s1b-7500 | jq "$PRELUDE"'map(select(counted)) | group_by(.steplab.round) | map(select(length == 2) | ((.[] | select(.steplab.variant == "s1b") | us) - (.[] | select(.steplab.variant == "s1a") | us)))')"
S1A_US="$(runs_of s1b-7500 | jq "$PRELUDE"'map(select(counted and .steplab.variant == "s1a") | us) | med')"
RECON="$(jq -n '($first.cost + $second.cost) / 2' --argjson first "$FIRST" --argjson second "$SECOND")"
jq -rn "$PRELUDE"'
  def share($per): if $per > $limit then 1 - $limit / $per else 0 end;
  "The reconnect price is \($r | r2) µs (the mean of the two Xeon pairs), S1-a costs \($a | r2) µs/req (the median of the series'"'"' S1-a runs), S1-b with 2 processes adds \($b | sgn) µs/req measured (\($b / $a * 100 | r1) % of S1-a).",
  "",
  "- **S1-d:** one process holds all N users, so it adds `share(N) × price`.",
  "- **S1-b, 2 processes:** the kernel splits the users about in half, so each holds N / 2; it adds the measured \($b | r2) µs, and a share `1 - \($limit) / (N / 2)` of the requests reconnect when N / 2 is over \($limit) (S1-d in each process).",
  "- **S1-b, 3 processes (a projection, not measured):** each extra process adds the measured \($b | r2) µs, so 3 processes add \($b * 2 | r2) µs; N / 3 stays under \($limit) up to \(3 * $limit) users, so no reconnect.",
  "",
  "| Users N | S1-d adds | S1-b with 2 processes adds | S1-b with 3 processes adds (projection) |",
  "|---|---|---|---|",
  ([100000, 150000][] | . as $n
    | ($n | share(.) * $r) as $d | ($b + share($n / 2) * $r) as $b2 | ($b * 2 + share($n / 3) * $r) as $b3
    | "| \($n) | \($d | r2) µs (\($d / $a * 100 | r1) % of S1-a) | \($b2 | r2) µs (\($b2 / $a * 100 | r1) % of S1-a) | \($b3 | r2) µs (\($b3 / $a * 100 | r1) % of S1-a) |"),
  "",
  ([100000, 150000][] | . as $n | ($n | share(.) * $r) as $d | ($b + share($n / 2) * $r) as $b2
    | "At \($n) users S1-b with 2 processes is \(if $b2 < $d then "cheaper than S1-d by \($d - $b2 | r2)" else "dearer than S1-d by \($b2 - $d | r2)" end) µs."),
  "",
  (150000 | share(.) * $r) as $d150
    | "S1-d adds \($d150 / $a * 100 | r1) % at 150,000 users: \(if $d150 / $a <= 0.15 then "15 % or less, so **S1-d stays**" else "over the 15 % line" end).",
  "",
  ($ds | map($limit / (1 - . / $r)) | [min, max]) as $lo
    | "S1-b against S1-d: they add the same at about \($limit / (1 - $b / $r) | . / 1000 | round * 1000) users (a share of \($b / $r * 100 | r1) % of requests reconnecting); over the three pairs (S1-b'"'"'s cost \($ds | map(r2) | join(", ")) µs) anywhere from \($lo[0] | . / 100 | round * 100) to \($lo[1] | . / 100 | round * 100) users. S1-d is cheaper below, S1-b above, up to about \($limit * $r / $b | . / 1000 | round * 1000) users: past 2 × \($limit) a process of S1-b passes its own limit and S1-d is cheaper again."' \
  --argjson r "$RECON" --argjson a "$S1A_US" --argjson b "$S1B_ADD" --argjson limit "$SOFT_LIMIT" --argjson ds "$PAIR_DIFFS"

echo
echo "### Memory at 150,000 users on a $BOX_MIB MiB box (from the memory runs above and a connection's $KIB_PER_CONNECTION KiB, the connections held capped by the soft limit)"
echo
MEM_A="$(jq '.results.server_memory_current_peak_mib' s1b-7500/memory/s1a.json)"
MEM_B="$(jq '.results.server_memory_current_peak_mib' s1b-7500/memory/s1b.json)"
PSS_A="$(jq '.results.server_pss_anon_peak_mib' s1b-7500/memory/s1a.json)"
PSS_B="$(jq '.results.server_pss_anon_peak_mib' s1b-7500/memory/s1b.json)"
jq -rn "$PRELUDE"'
  def more($held): ($held - 60000) * $kib / 1024;
  def row($label; $base; $held): "| \($label) | \($held) | \($base + more($held) | r1) | \(($base + more($held)) / $box * 100 | r1) % |";
  "Each variant'"'"'s `memory.current` peak with 60,000 idle: S1-a \($ma | r1) MiB (Pss_Anon \($pa | r1)), S1-b \($mb | r1) MiB (Pss_Anon \($pb | r1)); S1-b minus S1-a \($mb - $ma | sgn) MiB (one run each, not a pair). Each connection above the 60,000 adds \($kib) KiB. A process holds at most about \($limit) connections (its soft limit, under the 65,535 fds), so S1-d holds \([$n, $limit] | min) at \($n) users and S1-b with 2 processes holds 2 × \([$n / 2, $limit] | min) (the connections held are counted at the limit, a few hundred more in practice).",
  "",
  "| At \($n) users | connections held | memory.current MiB | of the \($box) MiB box |",
  "|---|---|---|---|",
  row("S1-d, 1 process"; $ma; [$n, $limit] | min),
  row("S1-b, 2 processes"; $mb; 2 * ([$n / 2, $limit] | min)),
  row("S1-b, 3 processes (a projection: no soft limit reached, \($n / 3 | round) each; a process is counted as the extra memory S1-b measured over S1-a when that is positive, \([$mb - $ma, 0] | max | r1) MiB here)"; $mb + ([$mb - $ma, 0] | max); $n)' \
  --argjson limit "$SOFT_LIMIT" --argjson n 150000 --argjson kib "$KIB_PER_CONNECTION" --argjson box "$BOX_MIB" --argjson ma "$MEM_A" --argjson mb "$MEM_B" --argjson pa "$PSS_A" --argjson pb "$PSS_B"

echo
echo "### The bench estimate (S1-a's Xeon µs/req times $XEON_TO_BENCH, 5a's Xeon-to-bench factor)"
echo
ALL_S1A="$(jq -s "$PRELUDE"'[.[][] | select(counted and .steplab.variant == "s1a") | us] | med' <(runs_of s1b-7500) <(runs_of reconnect))"
jq -rn "$PRELUDE"'
  def share($per): if $per > $limit then 1 - $limit / $per else 0 end;
  ($b + share(150000 / 2) * $r) as $b150
  | "S1-a on the Xeon: \($a | r2) µs/req (median of the S1-a runs of the S1-b series; \($all | r2) over the \($n) S1-a runs of this folder). Times \($f): **\($a * $f | r1) µs/req on the bench** (\($all * $f | r1) with every S1-a run), against 5a'"'"'s \($old) for the skeleton (no `mmap-off`).",
  "",
  "With the chosen S1 (S1-b, 2 processes, the soft limit in each) on top of S1-a, through the same factor: \(($a + $b + share(100000 / 2) * $r) * $f | r1) µs/req at 100,000 users (\($b + share(100000 / 2) * $r | sgn) µs added) and \(($a + $b150) * $f | r1) µs/req at 150,000 users (\($b150 | sgn) µs added)."' \
  --argjson a "$S1A_US" --argjson all "$ALL_S1A" --argjson f "$XEON_TO_BENCH" --argjson n "$(jq -s "$PRELUDE"'[.[][] | select(counted and .steplab.variant == "s1a")] | length' <(runs_of s1b-7500) <(runs_of reconnect))" --argjson old "$FIVE_A_BENCH_ESTIMATE" \
  --argjson b "$S1B_ADD" --argjson r "$RECON" --argjson limit "$SOFT_LIMIT"
