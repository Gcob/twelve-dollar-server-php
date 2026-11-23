#!/usr/bin/env bash
# Prints the Markdown tables of README.md from the JSON files next to this script (and the collapsed stacks of the profiled run).
# A run counts when its JSON says valid: true and other_containers.count 0; every other run is listed under "Runs that do not count".
# Runs that were stopped or failed on their way keep their files in invalid/ and are not read here.
set -euo pipefail
cd "$(dirname "$0")"

PRELUDE='
def med: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
def r1: if . == null then "-" else . * 10 | round / 10 end;
def r2: if . == null then "-" else . * 100 | round / 100 end;
def r0: if . == null then "-" else round end;
def counted: .valid and .other_containers.count == 0;
# The seconds of the series that lie in the plateau of the first (only) step of a hold.
def plateau: (.results.steps[0].window) as $w | .results.series | map(select(.second >= $w[0] and .second < $w[1]));
def maxms: [.endpoints[]?.max] | max // 0;
def stalls: map(select(maxms > 100));
def frames: map(.server.wal_frames) | map(select(. != null));
def drops: [range(1; length) as $i | select(.[$i] < .[$i - 1])] | length;
'

echo "### Calibration (quiet VM, stream on, think scale 0.0286)"
echo
echo "| Run | VUs | k6 memory MiB | achieved / offered | k6 CPU (% of one CPU, µs/req) | aggregator max lag s |"
echo "|---|---|---|---|---|---|"
for f in calibration-low calibration-top; do
  jq -r "$PRELUDE"'.calibration as $c | .other_containers.count as $o
    | range(0; 2) as $i
    | "| \($f)\(if $i == 0 then "" else "" end) | \($c.vus[$i]) | \($c.k6_memory_mib[$i]) | \($c.achieved_over_offered[$i]) | \($c.k6_cpu_percent_of_one_cpu[$i]) %, \($c.k6_cpu_usec_per_request[$i]) | \($c.aggregator_max_lag_s[$i]) |"' \
    --arg f "$f" "$f.json"
done
echo
echo "| Calibration | MiB per VU | MiB at rest | VU cap (bound by) | scale for 20,000 req/s | lag gate to use s | valid | other containers |"
echo "|---|---|---|---|---|---|---|---|"
for f in calibration-low calibration-top; do
  jq -r "$PRELUDE"'.calibration as $c
    | "| \($f) | \($c.mib_per_vu) | \($c.base_mib) | \($c.vu_cap) (\($c.cap_bound_by)) | \($c.scale_for_20000_rps) | \($c.lag_gate_to_use_s) | \(.valid) | \(.other_containers.count) |"' --arg f "$f" "$f.json"
done

staircase_table() { # file
  jq -r "$PRELUDE"'
    "Run `\($f).json`: think scale \(.load.think_scale), VU cap \(.load.vu_cap), warm-up \(.load.warmup // "none"), \(.load.plateau_s) s plateaus, lag gate \(.aggregator.lag_gate_s) s; valid \(.valid), other containers \(.other_containers.count), idle held \(.idle.held_at_start) at the start and \(.idle.held_at_end) at the end, aggregator max lag \(.aggregator.max_lag_s) s, k6 connection errors \(.k6_connection_errors).",
    "",
    "| Step | VUs | offered req/s | achieved req/s | users | µs CPU/req | p95 ms | p99 ms | errors | k6 CPU % of one | result |",
    "|---|---|---|---|---|---|---|---|---|---|---|",
    (.results.steps[] | "| \(.step) | \(.vus) | \(.offered_rps | r1) | \(.achieved_rps | r1) | \(.users | r0) | \(.cpu_usec_per_request | r1) | \(.latency_ms.overall.p95 | r2) | \(.latency_ms.overall.p99 | r2) | \(.error_rate * 100 | r2) % | \(.k6_cpu_percent_of_one_cpu // "-") | \(if .pass then "pass" else "FAIL: " + (.reasons | join("; ")) end) |"),
    "",
    (if .results.stopped_at_step then "Stopped at step \(.results.stopped_at_step): \(.results.stop_reasons | join("; "))." else "No step failed." end)' --arg f "$1" "$1.json"
}
for json in staircase-coarse-?.json staircase-fine*.json; do
  [ -f "$json" ] || continue
  f="${json%.json}"
  echo
  echo "### $f"
  echo
  staircase_table "$f"
done

# ---------------------------------------------------------------------------------------------------------------------------------
# The holds: one step each (the plateau), judged by the same rule as a staircase step.
HOLDS="$(ls hold-[0-9].json 2>/dev/null || true)"
if [ -n "$HOLDS" ]; then
  echo
  echo "### The holds (5 minutes each, a fresh run each)"
  echo
  echo "| Run | valid | other containers | offered req/s | achieved req/s | users at 9.45 per req/s | µs CPU/req | p95 ms | p99 ms | errors | k6 CPU % of one | idle held (start / end) | aggregator max lag s | result |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
  for f in $HOLDS hold-above.json; do
    [ -f "$f" ] || continue
    jq -r "$PRELUDE"'.results.steps[0] as $s
      | "| \($f | sub("\\.json$"; "")) | \(.valid) | \(.other_containers.count) | \($s.offered_rps | r1) | \($s.achieved_rps | r1) | \($s.users | r0) | \($s.cpu_usec_per_request | r2)"
        + " | \($s.latency_ms.overall.p95 | r2) | \($s.latency_ms.overall.p99 | r2) | \($s.error_rate * 100 | r2) % | \($s.k6_cpu_percent_of_one_cpu) | \(.idle.held_at_start) / \(.idle.held_at_end)"
        + " | \(.aggregator.max_lag_s) | \(if $s.pass then "pass" else "FAIL: " + ($s.reasons | join("; ")) end) |"' --arg f "$f" "$f"
  done
  # shellcheck disable=SC2086
  jq -nr "$PRELUDE"'[inputs | select(counted) | .results.steps[0] | select(.pass)] as $h
    | "| **median of the \($h | length) counted holds** | | | \($h | map(.offered_rps) | med | r1) | **\($h | map(.achieved_rps) | med | r1)** | **\($h | map(.users) | med | r0)** | **\($h | map(.cpu_usec_per_request) | med | r2)**"
      + " | **\($h | map(.latency_ms.overall.p95) | med | r2)** | **\($h | map(.latency_ms.overall.p99) | med | r2)** | \($h | map(.error_rate) | max * 100 | r2) % (max) | \($h | map(.k6_cpu_percent_of_one_cpu) | med) | | | |"' $HOLDS </dev/null
  echo
  echo "Per endpoint, p95 / p99 in ms over the plateau (requests in brackets):"
  echo
  EPS="GET /feed|GET /posts/:id|POST /posts/:id/like|POST /posts"
  echo "| Run | GET /feed | GET /posts/:id | POST /posts/:id/like | POST /posts |"
  echo "|---|---|---|---|---|"
  for f in $HOLDS hold-above.json; do
    [ -f "$f" ] || continue
    jq -r "$PRELUDE"'.results.steps[0].latency_ms.endpoints as $e
      | "| \($f | sub("\\.json$"; "")) | " + ([$eps | split("|")[] | . as $k | "\($e[$k].p95 | r2) / \($e[$k].p99 | r2) (\($e[$k].count))"] | join(" | ")) + " |"' --arg f "$f" --arg eps "$EPS" "$f"
  done
  # shellcheck disable=SC2086
  jq -nr "$PRELUDE"'[inputs | select(counted) | .results.steps[0] | select(.pass)] as $h
    | "| **median of the counted holds** | " + ([$eps | split("|")[] | . as $k | "\($h | map(.latency_ms.endpoints[$k].p95) | med | r2) / \($h | map(.latency_ms.endpoints[$k].p99) | med | r2)"] | join(" | ")) + " |"' --arg eps "$EPS" $HOLDS </dev/null

  echo
  echo "### Per-second latency over each hold's plateau (stall: a second whose max latency, over any endpoint, is above 100 ms)"
  echo
  echo "| Run | plateau seconds | stalled seconds | largest per-second max ms | median per-second p99 ms (GET /feed) | GC runs (telemetry) | GC runs in stalled seconds | longest callback ms | major faults |"
  echo "|---|---|---|---|---|---|---|---|---|"
  for f in $HOLDS hold-above.json; do
    [ -f "$f" ] || continue
    jq -r "$PRELUDE"'plateau as $p | ($p | stalls) as $st
      | "| \($f | sub("\\.json$"; "")) | \($p | length) | \($st | length) | \($p | map(maxms) | max | r1) | \($p | map(.endpoints["GET /feed"].p99) | map(select(. != null)) | med | r2)"
        + " | \($p | map(.telemetry.gc_runs // 0) | add) | \($st | map(.telemetry.gc_runs // 0) | add // 0) | \($p | map(.telemetry.longest_callback_ms // 0) | max) | \($p | map(.server.majflt // 0) | add) |"' --arg f "$f" "$f"
  done
  echo
  echo "Excerpt of the first hold: ten seconds from the middle of the plateau (per endpoint: requests, then p50 / p99 / max latency in ms; the full series are in the JSON):"
  echo
  jq -r "$PRELUDE"'plateau as $p | ($p | length / 2 | floor) as $m | ($p[$m:$m + 10]) as $rows
    | "| second | req | GET /feed | GET /posts/:id | POST /posts/:id/like | POST /posts | server CPU ms |", "|---|---|---|---|---|---|---|",
      ($rows[] | . as $r | "| +\($r.second - $p[0].second) | \($r.requests) | " + ([$eps | split("|")[] | . as $k | $r.endpoints[$k] | if . == null then "-" else "\(.count): \(.p50) / \(.p99) / \(.max)" end] | join(" | ")) + " | \($r.server.cpu_usec / 1000 | r0) |")' \
    --arg eps "$EPS" hold-1.json

  echo
  echo "### Memory and the WAL over each hold's plateau"
  echo
  echo "| Run | Pss_Anon MiB (min .. max) | memory.current MiB (min .. max) | peak over the whole run: Pss_Anon / memory.current MiB | WAL frames (min .. max, median) | seconds above 2,000 frames | checkpoints seen (drops of the frame count) | WAL file KiB (start .. end, max) |"
  echo "|---|---|---|---|---|---|---|---|"
  for f in $HOLDS hold-above.json; do
    [ -f "$f" ] || continue
    jq -r "$PRELUDE"'plateau as $p | ($p | frames) as $fr | ($p | map(.server.pss_anon_kb) | map(select(. != null)) | map(. / 1024)) as $pss
      | ($p | map(.server.memory_current) | map(select(. != null)) | map(. / 1048576)) as $cur | ($p | map(.server.wal_bytes) | map(select(. != null))) as $wal
      | "| \($f | sub("\\.json$"; "")) | \($pss | min | r1) .. \($pss | max | r1) | \($cur | min | r1) .. \($cur | max | r1) | \(.server_memory.pss_anon_peak_mib) / \(.server_memory.memory_current_peak_mib)"
        + " | \($fr | min) .. \($fr | max), \($fr | med) | \($fr | map(select(. > 2000)) | length) | \($fr | drops) | \($wal[0] / 1024 | r0) .. \($wal[-1] / 1024 | r0), \($wal | max / 1024 | r0) |"' --arg f "$f" "$f"
  done
  echo
  echo "Excerpt of the first hold, every 30 seconds of the plateau:"
  echo
  jq -r "$PRELUDE"'plateau as $p
    | "| second | Pss_Anon MiB | memory.current MiB | WAL frames | WAL file KiB | fds | server CPU % of one |", "|---|---|---|---|---|---|---|",
      ($p | to_entries | map(select(.key % 30 == 0)) | .[] | .value as $r | "| +\($r.second - $p[0].second) | \($r.server.pss_anon_kb / 1024 | r1) | \($r.server.memory_current / 1048576 | r1) | \($r.server.wal_frames) | \($r.server.wal_bytes / 1024 | r0) | \($r.server.fds) | \($r.server.cpu_usec / 10000 | r1) |")' hold-1.json
fi

# ---------------------------------------------------------------------------------------------------------------------------------
# One row per 60 s run of a pair (profile, telemetry): the plateau's cost per request.
cost_row() { # file
  jq -r "$PRELUDE"'.results.steps[0] as $s
    | "| \($f | sub("\\.json$"; "")) | \(.valid) | \(.other_containers.count) | \(.server.env | join(" ")) | \($s.offered_rps | r1) | \($s.achieved_rps | r1) | \($s.cpu_usec_per_request | r2) | \($s.latency_ms.overall.p95 | r2) | \($s.latency_ms.overall.p99 | r2) | \(if $s.pass then "pass" else "FAIL: " + ($s.reasons | join("; ")) end) |"' --arg f "$1" "$1"
}
COST_HEAD='| Run | valid | other containers | server env | offered req/s | achieved req/s | µs CPU/req (plateau) | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|'

if [ -f profile-on.json ]; then
  echo
  echo "### Excimer's cost: the same 60 s run unprofiled, profiled, unprofiled (telemetry off in all three)"
  echo
  echo "$COST_HEAD"
  for f in profile-off-1.json profile-on.json profile-off-2.json; do [ -f "$f" ] && cost_row "$f"; done
  jq -nr "$PRELUDE"'[inputs | select(counted) | {n: input_filename, us: .results.steps[0].cpu_usec_per_request}] as $r
    | ([$r[] | select(.n | startswith("profile-off")) | .us]) as $off | ([$r[] | select(.n == "profile-on.json") | .us]) as $on
    | "", "Unprofiled mean \($off | add / length | r2) µs/req (\($off | map(r2) | join(" and "))), profiled \($on | add / length | r2): Excimer at 1 ms costs **\((($on | add / length) / ($off | add / length) - 1) * 100 | r2) %** (against each unprofiled run: \($off | map((($on | add / length) / . - 1) * 100 | r2) | join(" % and ")) %) of the CPU per request."' \
    profile-off-1.json profile-on.json profile-off-2.json </dev/null
  echo
  jq -r '.profile | "Profiled window (the server'"'"'s whole life after its first answer: warm-up, ramps and plateau): \(.samples) samples at \(.period_s * 1000) ms, the cgroup'"'"'s user CPU \(.cgroup.user_usec / 1000 | round) ms and system CPU \(.cgroup.system_usec / 1000 | round) ms (**\(.cgroup.system_share * 100 | round) % in the kernel**), the samples cover \(.samples_over_cgroup_cpu * 100 | round) % of that CPU, unclassified \(.unclassified_share * 100 | . * 10 | round / 10) %."' profile-on.json 2>/dev/null || true
  us="$(jq -nr "$PRELUDE"'[inputs | select(counted) | .results.steps[0].cpu_usec_per_request] | add / length' profile-off-1.json profile-off-2.json </dev/null)"
  echo
  echo "Fold of \`profile.collapsed\` with \`--us-per-req $us\` (the unprofiled runs' mean). Each cell is a share of all the samples and the microseconds it adds to the average request:"
  echo
  echo '```text'
  bash ../../run.sh 8.5 php /lab/profile/fold.php /lab/results/2026-11-22-realistic-baseline/profile.collapsed --us-per-req "$us"
  echo '```'
fi

if [ -f telemetry-1-on.json ]; then
  echo
  echo "### Telemetry's cost: two pairs of 60 s runs, \`APP_TELEMETRY=1\` against \`0\`, interleaved"
  echo
  echo "$COST_HEAD"
  for f in telemetry-1-on.json telemetry-1-off.json telemetry-2-off.json telemetry-2-on.json; do [ -f "$f" ] && cost_row "$f"; done
  jq -nr "$PRELUDE"'[inputs | select(counted) | {n: input_filename, us: .results.steps[0].cpu_usec_per_request}] as $r
    | def us($n): [$r[] | select(.n == $n) | .us] | .[0];
      (us("telemetry-1-on.json")) as $a1 | (us("telemetry-1-off.json")) as $b1 | (us("telemetry-2-on.json")) as $a2 | (us("telemetry-2-off.json")) as $b2
    | "", "Pair 1: \((($a1 / $b1) - 1) * 100 | r2) %, pair 2: \((($a2 / $b2) - 1) * 100 | r2) %; on against off over both pairs: **\((((($a1 + $a2) / ($b1 + $b2))) - 1) * 100 | r2) %** of the CPU per request."' \
    telemetry-1-on.json telemetry-1-off.json telemetry-2-off.json telemetry-2-on.json </dev/null
fi

# ---------------------------------------------------------------------------------------------------------------------------------
# Q10: are the latency stalls the server's? A stalled second is a row whose largest per-endpoint max is above 100 ms. The server's longest
# callback of that second (the telemetry's own line) says where it was: a callback at least as long as the stall is the server working that
# long (inside the server); a longest callback under 20 ms means the server's loop never ran for long, so the time was lost outside it (the
# host, k6, the network stack); in between is mixed.
STALL_DEFS='
def pmax: [.endpoints[]?.p99] | max // 0;
def klass: maxms as $m | (.telemetry.longest_callback_ms // null) as $c
  | if $c == null then "no telemetry" elif $c >= $m then "inside" elif $c < 20 then "outside" else "mixed" end;
def kcount($k): map(select(klass == $k)) | length;
def majf: map(.server.majflt // 0) | add;
'

echo
echo "### What the stalls of each hold were (seconds of the plateau whose max latency is above 100 ms)"
echo
echo "| Run | stalled seconds | callback at least as long as the stall (inside the server) | longest callback under 20 ms (outside the server) | in between | longest callback in a stalled second ms (median) | CFS throttling of the server's cgroup over the run (periods, ms) |"
echo "|---|---|---|---|---|---|---|"
for f in $HOLDS hold-above.json; do
  [ -f "$f" ] || continue
  jq -r "$PRELUDE$STALL_DEFS"'. as $run | (plateau | stalls) as $st
    | "| \($f | sub("\\.json$"; "")) | \($st | length) | \($st | kcount("inside")) | \($st | kcount("outside")) | \($st | kcount("mixed")) | \($st | map(.telemetry.longest_callback_ms // 0) | med | r1) | \($run.raw.cpu_stat_after.server.nr_throttled - $run.raw.cpu_stat_before.server.nr_throttled), \(($run.raw.cpu_stat_after.server.throttled_usec - $run.raw.cpu_stat_before.server.throttled_usec) / 1000 | r1) |"' --arg f "$f" "$f"
done

if ls q10-*.json >/dev/null 2>&1; then
  echo
  echo "### Q10: \`posts.js\` at 7,000 req/s with 700 VUs, 30 s (warm: after a 10 s warm-up; cold: the copy evicted from the page cache, no warm-up), per-second series"
  echo
  echo "| Run | valid | other containers | achieved req/s | µs CPU/req | p99 ms | max ms | dropped iterations | seconds | stalled seconds | inside / outside / mixed | major faults (seconds 0-9 / 10-19 / 20-29) | median per-second p99 ms (0-9 / 10-19 / 20-29) | CFS throttled ms |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
  for f in q10-warm-1 q10-cold-1 q10-warm-2 q10-cold-2 q10-warm-3 q10-cold-3; do
    [ -f "$f.json" ] || continue
    jq -r "$PRELUDE$STALL_DEFS"'.results.per_second.rows as $r | ($r | map(select(.requests > 0))) as $rows
      | def span($a; $b): $rows | to_entries | map(select(.key >= $a and .key < $b) | .value);
      ($rows | stalls) as $st
      | "| \($f) | \(.valid) | \(.other_containers.count) | \(.results.achieved_req_per_s | r1) | \(.results.cpu_usec_per_request | r2) | \(.results.latency_ms.p99 | r2) | \(.results.latency_ms.max | r1) | \(.results.dropped_iterations)"
        + " | \($rows | length) | \($st | length) | \($st | kcount("inside")) / \($st | kcount("outside")) / \($st | kcount("mixed"))"
        + " | \(span(0; 10) | majf) / \(span(10; 20) | majf) / \(span(20; 30) | majf)"
        + " | \(span(0; 10) | map(pmax) | med | r1) / \(span(10; 20) | map(pmax) | med | r1) / \(span(20; 30) | map(pmax) | med | r1) | \(.results.server_throttled_usec / 1000 | r1) |"' --arg f "$f" "$f.json"
  done
fi

if ls cold-60s-*.json warm-60s-*.json >/dev/null 2>&1; then
  echo
  echo "### Q10: the first 60 s of a realistic run, cold against warm (no warm-up, 60,000 idle, the baseline's rate; the 60 s counted from the first second that has requests, ramp included)"
  echo
  echo "| Run | valid | other containers | achieved req/s | µs CPU/req | stalled seconds | inside / outside / mixed | major faults (seconds 0-9 / 10-29 / 30-59) | median per-second p99 ms (0-9 / 10-29 / 30-59) | page cache resident at start | CFS throttled ms |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|"
  for f in cold-60s-1 warm-60s-1 cold-60s-2 warm-60s-2; do
    [ -f "$f.json" ] || continue
    jq -r "$PRELUDE$STALL_DEFS"'(.results.series | map(select(.requests > 0))) as $all | ($all | map(select(.second < $all[0].second + 60))) as $rows
      | def span($a; $b): $rows | to_entries | map(select(.key >= $a and .key < $b) | .value);
      ($rows | stalls) as $st
      | "| \($f) | \(.valid) | \(.other_containers.count) | \(.results.steps[0].achieved_rps | r1) | \(.results.steps[0].cpu_usec_per_request | r2) | \($st | length) | \($st | kcount("inside")) / \($st | kcount("outside")) / \($st | kcount("mixed"))"
        + " | \(span(0; 10) | majf) / \(span(10; 30) | majf) / \(span(30; 60) | majf)"
        + " | \(span(0; 10) | map(pmax) | med | r1) / \(span(10; 30) | map(pmax) | med | r1) / \(span(30; 60) | map(pmax) | med | r1) | \(.cold.resident_share * 100 | r1) % | \((.raw.cpu_stat_after.server.throttled_usec - .raw.cpu_stat_before.server.throttled_usec) / 1000 | r1) |"' --arg f "$f" "$f.json"
  done
fi

echo
echo "### Every stalled second (max latency above 100 ms) of the Q10 runs and of the cold and warm realistic runs"
echo
echo "| Run | second of the run | max latency ms | server's longest callback ms | requests | server CPU ms | major faults |"
echo "|---|---|---|---|---|---|---|"
for f in q10-warm-1 q10-cold-1 q10-warm-2 q10-cold-2 q10-warm-3 q10-cold-3; do
  [ -f "$f.json" ] || continue
  jq -r "$PRELUDE$STALL_DEFS"'.results.per_second.rows | map(select(.requests > 0)) | to_entries[] | select(.value | maxms > 100)
    | "| \($f) | \(.key) | \(.value | maxms | r1) | \(.value.telemetry.longest_callback_ms // "-") | \(.value.requests) | \(.value.server.cpu_usec / 1000 | r0) | \(.value.server.majflt) |"' --arg f "$f" "$f.json"
done
for f in cold-60s-1 warm-60s-1 cold-60s-2 warm-60s-2; do
  [ -f "$f.json" ] || continue
  jq -r "$PRELUDE$STALL_DEFS"'(.results.series | map(select(.requests > 0))) as $all | ($all | map(select(.second < $all[0].second + 60))) | to_entries[] | select(.value | maxms > 100)
    | "| \($f) | \(.key) | \(.value | maxms | r1) | \(.value.telemetry.longest_callback_ms // "-") | \(.value.requests) | \(.value.server.cpu_usec / 1000 | r0) | \(.value.server.majflt) |"' --arg f "$f" "$f.json"
done

# ---------------------------------------------------------------------------------------------------------------------------------
# Runs that do not count: their files are in invalid/ (a run stopped by hand or that failed before its JSON has only its .txt there).
# Any run next to this script that is not valid or saw another container is listed here too.
echo
echo "### Runs that do not count"
echo
echo "| File | valid | reason | other containers |"
echo "|---|---|---|---|"
for json in *.json invalid/*.json; do
  [ -f "$json" ] || continue
  jq -r "$PRELUDE"'select(counted | not) | "| \($f) | \(.valid) | \(if (.invalid_reasons | length) > 0 then (.invalid_reasons | join("; ")) else "-" end) | \(.other_containers.count) |"' --arg f "$json" "$json"
done
for json in invalid/*.json; do
  [ -f "$json" ] || continue
  echo
  echo "Steps of \`$json\` (shown, not counted):"
  echo
  staircase_table "${json%.json}"
done
