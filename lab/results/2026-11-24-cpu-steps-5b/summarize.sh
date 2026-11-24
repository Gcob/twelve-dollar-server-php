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

# --------------------------------------------------------------------------------------------------------------------------------
# S1-b (two processes on one port) against S1-a (one process) at 12,000 req/s on the Mac.
S1AA="$LAB/results/2026-11-23-s1-fd-wall/aa-12000"
echo
echo "### S1-b on the Mac: the series, as the driver recorded it (\`stages-s1b.json\`)"
echo
jq -r '"The lab'"'"'s commit when the file started: `\(.commit[0:7])`, tracked files changed since: \(.dirty). Gap between series: \(.gap_s) s; `--allow-busy`: \(.allow_busy)."' stages-s1b.json
echo
echo "| Series | start (UTC) | end (UTC) | exit code | other containers at the quiet check | busy | refused |"
echo "|---|---|---|---|---|---|---|"
jq -r '.series[] | "| \(.name) | \(.start) | \(.end) | \(.exit_code) | \(.other_containers) | \(.busy) | \(.refused) |"' stages-s1b.json

echo
echo "### S1-b on the Mac: S1-b against S1-a at 12,000 req/s (\`APP_WORKERS=2\` against one process, \`APP_PRAGMAS=mmap-off\`, telemetry on, \`s = 0.02\`, 60,000 idle, 3 pairs)"
echo
runs_table s1b-12000
echo
host_table s1b-12000
echo
runs_of s1b-12000 | jq -r "$PRELUDE"'map(select(counted)) as $c | [$c[] | .host.plateau.load1] as $l | [$c[] | .host.plateau.cpu_busy_pct] as $b | [$c[] | .host.fsync_ms] as $f | [$c[] | .host.plateau.steal_pct] as $s
  | "Over the \($c | length) runs: load on the plateau \($l | min) to \($l | max), the VM'"'"'s CPU busy \($b | min) to \($b | max) %, steal \($s | min) to \($s | max) %, `fsync` \($f | min) to \($f | max) ms."'
echo
echo "The pairs (S1-b minus S1-a, the order alternates: round 1 runs S1-b first, round 2 S1-a first, round 3 S1-b first):"
echo
echo "| Round | order | S1-a µs/req | S1-b µs/req | S1-b minus S1-a µs | as a share of S1-a |"
echo "|---|---|---|---|---|---|"
runs_of s1b-12000 | jq -r "$PRELUDE"'map(select(counted)) | group_by(.steplab.round)[] | select(length == 2) | (.[] | select(.steplab.variant == "s1a")) as $a | (.[] | select(.steplab.variant == "s1b")) as $b
  | "| \($a.steplab.round) | \(if $a.steplab.position == 0 then "s1a then s1b" else "s1b then s1a" end) | \($a | us | r2) | \($b | us | r2) | \(($b | us) - ($a | us) | sgn) | \((($b | us) / ($a | us) - 1) * 100 | sgn) % |"'
echo
runs_of s1b-12000 | jq -r "$PRELUDE"'map(select(counted)) as $c | ([$c[] | select(.steplab.variant == "s1a") | us] | med) as $ma | ([$c[] | select(.steplab.variant == "s1b") | us] | med) as $mb
  | ($c | group_by(.steplab.round) | map(select(length == 2) | ((.[] | select(.steplab.variant == "s1b") | us) - (.[] | select(.steplab.variant == "s1a") | us)))) as $d
  | "Medians: S1-a \($ma | r2) µs/req, S1-b \($mb | r2) µs/req. Paired differences \($d | map(sgn) | join(", ")), **median \($d | med | sgn) µs/req, \(($d | med) / $ma * 100 | sgn) % of the median S1-a**. Achieved over offered: \([$c[] | ratio] | min | r1) % to \([$c[] | ratio] | max | r1) %; runs under the 97 % rule: \([$c[] | select(.results.steps[0].pass | not)] | length) of \($c | length)."'
echo
echo "Both processes served, from the server's own log (the telemetry line each process prints every second, \`requests\` summed over the run's whole life: the warm-up, the plateau and one request per idle connection):"
echo
echo "| Run | processes | requests counted by each process | seconds in which each counted a request | share of the first |"
echo "|---|---|---|---|---|"
jq -r '.[] | if (.processes | length) == 0 then "| \(.run) | not followed | - | - | - |"
  else "| \(.run) | \(.processes | length) | \(.processes | map(.requests) | join(" and ")) | \(.processes | map(.seconds_with_requests) | join(" and ")) | \(.processes[0].requests / (.processes | map(.requests) | add) * 100 * 10 | round / 10) % |" end' s1b-12000/served.json
echo
echo "Memory of one run of each variant, with the sampler on (\`--no-series\` off; 12,000 req/s for 60 s after the warm-up, 60,000 idle; not a pair, not counted):"
echo
echo "| Variant | valid | achieved req/s | µs CPU/req | memory.current peak MiB | Pss_Anon peak MiB | file descriptors peak | processes |"
echo "|---|---|---|---|---|---|---|---|"
for v in s1a s1b; do
  jq -r "$PRELUDE"'"| \(input_filename | sub("^.*/"; "") | sub("\\.json$"; "")) | \(.valid) | \(.results.steps[0].achieved_rps | r1) | \(us | r2) | \(.results.server_memory_current_peak_mib | r1) | \(.results.server_pss_anon_peak_mib | r1) | \(.server_connections.fds_peak) | \(.server_connections.telemetry.processes // 1) |"' "s1b-12000/memory/$v.json"
done
echo
summary_block s1b-12000 --floor-from "$S1AA"
echo
echo "The same series against this folder's own floor (the A/A at 24,000 req/s above), the more cautious reading:"
echo
summary_block s1b-12000 --floor-from "$AA"

echo
echo "### S1-b on the Mac: what S1-b and S1-d add at the bench's sizes (soft limit 64,000; share of requests that reconnect = 1 - 64,000 / N)"
echo
MAC_RECON12="$(jq '.variants[] | select(.variant == "s1d") | .median_difference_us' "$S1/s1-12000/summary.json")"
RECON7500="$(runs_of reconnect-7500 | jq "$PRELUDE"'map(select(counted)) | ((map(select(.steplab.variant == "s1d-every") | us)[0]) - (map(select(.steplab.variant == "skeleton") | us)[0]))')"
S1B_ADD="$(runs_of s1b-12000 | jq "$PRELUDE"'map(select(counted)) | group_by(.steplab.round) | map(select(length == 2) | ((.[] | select(.steplab.variant == "s1b") | us) - (.[] | select(.steplab.variant == "s1a") | us))) | med')"
S1A_US="$(runs_of s1b-12000 | jq "$PRELUDE"'map(select(counted and .steplab.variant == "s1a") | us) | med')"
echo "| Users N | share that reconnect | S1-d at 7,500 req/s's reconnect ($(jq -n "$PRELUDE $RECON7500 | r2") µs) adds | S1-d at 12,000 req/s's reconnect ($(jq -n "$PRELUDE $MAC_RECON12 | r2") µs) adds | S1-b adds (any N) | S1-b over S1-d (12,000 figure) |"
echo "|---|---|---|---|---|---|"
for n in 100000 150000; do
  jq -rn "$PRELUDE"'(1 - 64000 / $n) as $share | "| \($n) | \($share * 100 | r1) % | \($share * $r75 | sgn) µs (\($share * $r75 / $a * 100 | r1) % of S1-a) | \($share * $r12 | sgn) µs (\($share * $r12 / $a * 100 | r1) % of S1-a) | \($b | sgn) µs (\($b / $a * 100 | r1) % of S1-a) | \(if $b < $share * $r12 then "cheaper by \($share * $r12 - $b | r2) µs" else "dearer by \($b - $share * $r12 | r2) µs" end) |"' \
    --argjson n "$n" --argjson r75 "$RECON7500" --argjson r12 "$MAC_RECON12" --argjson b "$S1B_ADD" --argjson a "$S1A_US"
done
echo
jq -rn "$PRELUDE"'"S1-b and S1-d add the same at a share of \($b / $r12 * 100 | r1) % of requests reconnecting (S1-d at the 12,000 req/s figure), that is N = \(64000 / (1 - $b / $r12) | round) users; with the 7,500 req/s figure, \($b / $r75 * 100 | r1) % and N = \(64000 / (1 - $b / $r75) | round). Below that size S1-d is cheaper, above it S1-b is."' \
  --argjson r75 "$RECON7500" --argjson r12 "$MAC_RECON12" --argjson b "$S1B_ADD"

# --------------------------------------------------------------------------------------------------------------------------------
# The CPU variants of 5b: the screens that ran (one pair each, the A/A's floor), then the profile of the chosen combination.
echo
echo "### The CPU variants of 5b: the series, as the driver recorded them (\`stages-screens.json\`)"
echo
jq -r '"The lab'"'"'s commit when the file started: `\(.commit[0:7])`, tracked files changed since: \(.dirty). Gap between series: \(.gap_s) s; `--allow-busy`: \(.allow_busy)."' stages-screens.json
echo
echo "| Series | start (UTC) | end (UTC) | exit code | other containers at the quiet check | busy | refused |"
echo "|---|---|---|---|---|---|---|"
jq -r '.series[] | "| \(.name) | \(.start) | \(.end) | \(.exit_code) | \(.other_containers) | \(.busy) | \(.refused) |"' stages-screens.json
screen_section json-sqlite "\`APP_JSON=sqlite\` against \`encode\` at 24,000 req/s (\`APP_PRAGMAS=mmap-off\` on both, the A/A's floor, one pair)" json-sqlite

# --------------------------------------------------------------------------------------------------------------------------------
# The profile: one profiled run of the chosen combination (here the reference alone), folded into the steps, beside 5a's.
PROFILE=profile/profile.json
if [ -f "$PROFILE" ]; then
  TOGETHER=../2026-11-23-step-lab-together
  STEPS=../2026-11-23-cpu-steps
  # The reference's runs at 24,000 req/s (the A/A's ten, and the reference of every screen): the fold's microseconds per request.
  REF_RUNS="$(jq -s 'map(select(type == "object" and has("steplab")))' aa-24000/*.json php-8.6/*.json php-8.4/*.json json-sqlite/*.json)"
  REF_US="$(jq -r "$PRELUDE"'map(select(counted and (.steplab.variant | IN("a", "b", "ref"))) | us) | med' <<<"$REF_RUNS")"
  REF_N="$(jq -r 'map(select(.valid and .other_containers.count == 0 and (.steplab.variant | IN("a", "b", "ref")))) | length' <<<"$REF_RUNS")"
  echo
  echo "### The profile of the chosen combination (the reference alone: \`APP_PRAGMAS=mmap-off\`), beside 5a's (Excimer, 1 ms CPU time, one run: 24,000 req/s, \`s = 0.02\`, 60,000 idle, telemetry off)"
  echo
  jq -r "$PRELUDE"'"The profiled run is valid \(.valid), other containers \(.other_containers.count), idle held \(.idle.held_at_start) / \(.idle.held_at_end). Profiled window (the server'"'"'s whole life after its first answer: warm-up, ramps and plateau): \(.profile.samples) samples at \(.profile.period_s * 1000) ms, the cgroup'"'"'s user CPU \(.profile.cgroup.user_usec / 1000 | round) ms and system CPU \(.profile.cgroup.system_usec / 1000 | round) ms (**\(.profile.cgroup.system_share * 100 | round) % in the kernel**), the samples cover \(.profile.samples_over_cgroup_cpu * 100 | round) % of that CPU, unclassified \(.profile.unclassified_share * 100 | . * 10 | round / 10) %. The profiled run itself read \(.results.steps[0].cpu_usec_per_request | r2) µs/req (the sampler costs CPU)."' "$PROFILE"
  echo
  echo "Each cell is a share of all the samples of its profile and the microseconds it is on the average request of that profile (the fold's \`--us-per-req\`: 5a's together 27.58 (the median of its 3 holds at 22,000 req/s, telemetry on, S1-d on, no \`mmap-off\`), 5a's skeleton 26.71 (the CPU steps' three references' median at 24,000 req/s, no pragma), and this run's $(jq -rn "$PRELUDE"'$u | r2' --argjson u "$REF_US") (the median of the $REF_N reference runs of this folder at 24,000 req/s, telemetry off)). The kernel's share is the cgroup's system CPU."
  echo
  echo "| Step | in this profile | 5a together: share, µs | 5a skeleton: share, µs | 5b reference: share, µs | 5b minus 5a together, µs | 5b minus 5a skeleton, µs |"
  echo "|---|---|---|---|---|---|---|"
  jq -rn "$PRELUDE"'def rows: .profile.fold | split("\n") | map(capture("^(?<step>(S[1-9] |event loop|unclassified).*?)\\s+[0-9.]+% [0-9.]+us\\s+[0-9.]+% [0-9.]+us\\s+[0-9.]+% [0-9.]+us\\s+[0-9.]+% [0-9.]+us\\s+[0-9.]+% [0-9.]+us\\s+[0-9.]+% [0-9.]+us\\s+(?<pct>[0-9.]+)% [0-9.]+us$"));
    {"S1 accept connections": "no soft limit (5a together ran S1-d, which never fired)",
     "S6 query SQLite": "`APP_PRAGMAS=mmap-off` (the reference; `APP_JSON=sqlite` screened, not better)"} as $variant
    | (input | rows) as $t | (input | rows) as $s | (input | rows) as $r
    | [range(0; $r | length)] | map(. as $i | $r[$i].step as $step
      | (($t[$i].pct | tonumber) / 100 * 27.58) as $ut | (($s[$i].pct | tonumber) / 100 * 26.71) as $us | (($r[$i].pct | tonumber) / 100 * $u) as $ur
      | "| \($step) | \($variant[$step | rtrimstr(" ")] // $variant[$step] // "unchanged") | \($t[$i].pct) %, \($ut | r1) µs | \($s[$i].pct) %, \($us | r1) µs | \($r[$i].pct) %, \($ur | r1) µs | \($ur - $ut | sgn) | \($ur - $us | sgn) |") | .[]' \
    --argjson u "$REF_US" "$TOGETHER/profile/profile.json" "$STEPS/profile/skeleton.json" "$PROFILE"
  echo
  echo "The fold of \`profile/profile.collapsed\` with \`--us-per-req\` set to the reference runs' median:"
  echo
  echo '```text'
  bash "$LAB/run.sh" 8.5 php /lab/profile/fold.php "/lab/results/$(basename "$PWD")/profile/profile.collapsed" --us-per-req "$REF_US"
  echo '```'
fi
