#!/usr/bin/env bash
# Prints the Markdown tables of README.md from the JSON files next to this script (and in its subfolders).
# A run counts when its JSON says valid: true and other_containers.count 0; every other run is listed under "Runs that do not count".
# A series that was started again after a harness failure keeps the first attempt's files in aborted-first-attempt/ (not read as a series).
# The syscall counts carry no other_containers field (the script that writes them does not record it): the README says how the VM was
# checked for them.
set -euo pipefail
cd "$(dirname "$0")"
LAB="$(cd ../.. && pwd)"

PRELUDE='
def med: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
def r1: if . == null then "-" else . * 10 | round / 10 end;
def r2: if . == null then "-" else . * 100 | round / 100 end;
def r0: if . == null then "-" else round end;
def sgn: if . == null then "-" elif . > 0 then "+\(. * 100 | round / 100)" else "\(. * 100 | round / 100)" end;
def counted: .valid and .other_containers.count == 0;
def us: .results.steps[0].cpu_usec_per_request;
def ratio: .results.steps[0] | .achieved_rps / .offered_rps * 100;
'

# ---------------------------------------------------------------------------------------------------------------------------------
echo "### Syscalls per request (strace -c on the skeleton, 2,000 req/s, 20 s of the plateau; counts only)"
echo
echo "| syscall | skeleton: calls per request | \`APP_SOFT_CONN_LIMIT=0\` (every request reconnects): calls per request | difference |"
echo "|---|---|---|---|"
jq -rn "$PRELUDE"'[inputs] as $f | ($f[0].syscalls | map({(.name): .calls_per_request}) | add) as $a | ($f[1].syscalls | map({(.name): .calls_per_request}) | add) as $b
  | ($f[1].syscalls | map(.name)) as $names
  | ($names | map(select(($b[.] // 0) >= 0.01 or ($a[.] // 0) >= 0.01)))[]
  | . as $n | "| `\($n)` | \($a[$n] // 0) | \($b[$n] // 0) | \((($b[$n] // 0) - ($a[$n] // 0)) * 1000 | round / 1000 | sgn) |"' syscalls-skeleton.json syscalls-soft-limit-0.json
jq -rn '[inputs] as $f | "| **total** | **\($f[0].total.calls_per_request)** | **\($f[1].total.calls_per_request)** | **+\((($f[1].total.calls_per_request - $f[0].total.calls_per_request) * 1000 | round) / 1000)** |",
  "| requests counted in the window | \($f[0].requests) | \($f[1].requests) | |",
  "| write family (`write`, `sendto`, `writev`) per request | \($f[0].write_family.calls_per_request) | \($f[1].write_family.calls_per_request) | |"' syscalls-skeleton.json syscalls-soft-limit-0.json
echo
echo "Errors in the two tables: $(jq -s '[.[].syscalls[].errors] | add' syscalls-skeleton.json syscalls-soft-limit-0.json) in all."

# ---------------------------------------------------------------------------------------------------------------------------------
# A/A calibration: one folder per rate, two identical skeleton variants (a and b), the rounds one after the other.
# The run files of a folder, as one array (the folder also holds summary.json, which is not a run).
runs_of() { jq -s 'map(select(type == "object" and has("steplab")))' "$1"/*.json; }
runs_table() { # folder
  echo "| Run | valid | other containers | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |"
  echo "|---|---|---|---|---|---|---|---|---|"
  runs_of "$1" | jq -r "$PRELUDE"'sort_by(.steplab.round, .steplab.variant_index)[] | .results.steps[0] as $s
    | "| \(.steplab.variant)-\(.steplab.round) | \(.valid) | \(.other_containers.count) | \($s.achieved_rps | r1) | \(ratio | r1) % | \($s.cpu_usec_per_request | r2) | \($s.latency_ms.overall.p95 | r2) | \($s.latency_ms.overall.p99 | r2) | \(if $s.pass then "pass" else "FAIL: " + ($s.reasons | join("; ")) end) |"'
}
aa_pairs() { # folder
  echo "| Round | a µs/req | b µs/req | b minus a µs | a p99 ms | b p99 ms |"
  echo "|---|---|---|---|---|---|"
  runs_of "$1" | jq -r "$PRELUDE"'map(select(counted)) | group_by(.steplab.round)[] | select(length == 2) | (.[] | select(.steplab.variant == "a")) as $a | (.[] | select(.steplab.variant == "b")) as $b
    | "| \($a.steplab.round) | \($a | us | r2) | \($b | us | r2) | \(($b | us) - ($a | us) | sgn) | \($a.results.steps[0].latency_ms.overall.p99 | r2) | \($b.results.steps[0].latency_ms.overall.p99 | r2) |"'
  runs_of "$1" | jq -r "$PRELUDE"'map(select(counted)) as $c | ($c | group_by(.steplab.round) | map(select(length == 2) | ((.[] | select(.steplab.variant == "b") | us) - (.[] | select(.steplab.variant == "a") | us)))) as $d
    | ([$c[] | select(.steplab.variant == "a") | us] | med) as $ma | ([$c[] | select(.steplab.variant == "b") | us] | med) as $mb
    | "", "Medians: a \($ma | r2) µs/req, b \($mb | r2) µs/req. Paired differences (b minus a): \($d | map(sgn) | join(", ")), median \($d | med | sgn). **Floor (the largest absolute paired difference of the \($d | length) pairs): \($d | map(fabs) | max | r2) µs/req** (\(($d | map(fabs) | max) / (($ma + $mb) / 2) * 100 | r1) % of the median run). Achieved over offered: \([$c[] | ratio] | min | r1) % to \([$c[] | ratio] | max | r1) % (median \([$c[] | ratio] | med | r1) %); runs under the 97 % rule: \([$c[] | select(.results.steps[0].pass | not)] | length) of \($c | length)."'
}
for aa in aa-24000 aa-12000; do
  [ -d "$aa" ] || continue
  echo
  if [ "$aa" = aa-24000 ]; then
    echo "### A/A calibration at 24,000 req/s (the skeleton against itself, \`s = 0.02\`, 60,000 idle, telemetry off, 5 pairs)"
  else
    echo "### A/A calibration at 12,000 req/s (the skeleton against itself, \`s = 0.02\`, 60,000 idle, telemetry on, 5 pairs)"
  fi
  echo
  runs_table "$aa"
  echo
  aa_pairs "$aa"
done

# ---------------------------------------------------------------------------------------------------------------------------------
# S1 at 12,000 req/s: the skeleton (s1a) against S1-d with a soft limit equal to the idle count (s1d: every request of k6 reconnects).
# The floor is the A/A calibration's at the same rate.
FLOOR_12000=""
if [ -d aa-12000 ]; then
  FLOOR_12000="$(runs_of aa-12000 | jq -r "$PRELUDE"'map(select(counted)) | group_by(.steplab.round) | map(select(length == 2) | ((.[] | select(.steplab.variant == "b") | us) - (.[] | select(.steplab.variant == "a") | us)) | fabs) | max | . * 1000 | round / 1000')"
fi
if [ -d s1-12000 ]; then
  echo
  echo "### S1 at 12,000 req/s: the skeleton (s1a) against S1-d (s1d: \`APP_SOFT_CONN_LIMIT=60000\`, the 60,000 idle fill the limit, every request of k6 reconnects), \`s = 0.02\`, 60,000 idle, telemetry on in both, 5 pairs"
  echo
  runs_table s1-12000
  echo
  echo "The server's close count against k6's requests (the telemetry counts the server's whole life: the warm-up's requests reconnect too, and their count is not in the run's JSON, so the nominal one is used: the warm-up rate times its plateau plus half its 10 s ramp):"
  echo
  echo "| Round | s1a µs/req | s1d µs/req | s1d minus s1a µs | \`Connection: close\` responses (telemetry) | k6 requests (run, warm-up not included) | nominal warm-up requests (rate x (plateau + ramp / 2)) | closes minus both | as a share of the closes |"
  echo "|---|---|---|---|---|---|---|---|---|"
  runs_of s1-12000 | jq -r "$PRELUDE"'map(select(counted)) | group_by(.steplab.round)[] | select(length == 2) | (.[] | select(.steplab.variant == "s1a")) as $a | (.[] | select(.steplab.variant == "s1d")) as $d
    | ($d.results.run_total | map(.count) | add) as $k6 | ($d.server_connections.telemetry.close_responses) as $c | ($d.steplab.warmup | split(",") | map(tonumber) | .[0] * (.[1] + $d.load.ramp_s / 2)) as $w
    | "| \($a.steplab.round) | \($a | us | r2) | \($d | us | r2) | \(($d | us) - ($a | us) | sgn) | \($c) | \($k6) | \($w) | \($c - $k6 - $w | sgn) | \(($c - $k6 - $w) / $c * 100 | r2) % |"'
  echo
  runs_of s1-12000 | jq -r "$PRELUDE"'map(select(counted)) as $c | ($c | group_by(.steplab.round) | map(select(length == 2) | ((.[] | select(.steplab.variant == "s1d") | us) - (.[] | select(.steplab.variant == "s1a") | us)))) as $d
    | ([$c[] | select(.steplab.variant == "s1a") | us] | med) as $ma | ([$c[] | select(.steplab.variant == "s1d") | us] | med) as $md
    | "S1-a median \($ma | r2) µs/req, S1-d median \($md | r2). Paired differences (s1d minus s1a): \($d | map(sgn) | join(", ")), **median \($d | med | r2) µs: the cost of one reconnect** (\(($d | med) / $ma * 100 | r1) % of the skeleton'"'"'s µs/req). Floor of the A/A at 12,000: \($floor) µs/req."' --argjson floor "${FLOOR_12000:-null}"
  echo
  echo "The step lab's own summary of these runs (its rule: beyond the noise when every pair has the same sign and the median paired difference passes the floor):"
  echo
  echo '```text'
  bash "$LAB/steplab-summary.sh" s1-12000 ${FLOOR_12000:+--floor "$FLOOR_12000"}
  echo '```'
fi

# ---------------------------------------------------------------------------------------------------------------------------------
# What S1-d costs at the bench's sizes. The model: each user holds one connection; the server never closes an idle one, so the first L users
# to connect keep theirs and every request of the other N - L users reconnects (the same share as a least-recently-used set of L connections
# under requests spread evenly over the users); a user makes one request per 9.45 s of think time.
if [ -d s1-12000 ]; then
  echo
  echo "### What S1-d adds at the bench's sizes (soft limit L = 64,000; share of requests that reconnect = 1 - L / N)"
  echo
  echo "| Users N | requests per second (N / 9.45) | share that reconnect | µs added per request (share x the cost of one reconnect) | as a share of the skeleton's µs/req | above 15 %? |"
  echo "|---|---|---|---|---|---|"
  runs_of s1-12000 | jq -r "$PRELUDE"'map(select(counted)) as $c | ($c | group_by(.steplab.round) | map(select(length == 2) | ((.[] | select(.steplab.variant == "s1d") | us) - (.[] | select(.steplab.variant == "s1a") | us))) | med) as $cost
    | ([$c[] | select(.steplab.variant == "s1a") | us] | med) as $sk
    | (100000, 150000, 200000) as $n | (if $n > 64000 then 1 - 64000 / $n else 0 end) as $share
    | "| \($n) | \($n / 9.45 | r0) | \($share * 100 | r1) % | \($share * $cost | r2) | \($share * $cost / $sk * 100 | r1) % | \(if $share * $cost / $sk > 0.15 then "**yes**" else "no" end) |"'
  echo
  echo "Inputs: cost of one reconnect and the skeleton's µs/req are S1's medians above (12,000 req/s, telemetry on, probes off)."
fi

# ---------------------------------------------------------------------------------------------------------------------------------
# The fd wall: 5-minute realistic holds at 12,000 req/s, s = 0.04 (about 4,535 VUs), 64,000 idle, probes on.
if ls fd-wall/*.json >/dev/null 2>&1; then
  echo
  echo "### The fd wall: two 5-minute holds at 12,000 req/s, \`s = 0.04\`, 64,000 idle connections, k6's VUs on top, the sampler on (the file descriptors the process holds are 65,535 at most)"
  echo
  echo "| Run | valid | other containers | VUs | idle held (start / end) | users at once (idle + VUs) | fds peak (sampler) | open connections peak (telemetry) | accept pauses (telemetry) | \`Connection: close\` responses | k6 connection errors | errors | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
  for f in fd-wall/skeleton.json fd-wall/s1d.json; do
    [ -f "$f" ] || continue
    jq -r "$PRELUDE"'.results.steps[0] as $s | .server_connections as $c
      | "| \($f | sub("^fd-wall/"; "") | sub("\\.json$"; "")) | \(.valid) | \(.other_containers.count) | \(.load.vus[0]) | \(.idle.held_at_start) / \(.idle.held_at_end) | \(.idle.held_at_end + .load.vus[0])"
        + " | \($c.fds_peak // "-") | \($c.telemetry.open_peak // "-") | \($c.telemetry.accept_pauses // "-") | \($c.telemetry.close_responses // "-") | \(.k6_connection_errors) | \($s.errors) (\($s.error_rate * 100 | r2) %) | \(ratio | r1) % | \($s.cpu_usec_per_request | r2) | \($s.latency_ms.overall.p95 | r2) | \($s.latency_ms.overall.p99 | r2)"
        + " | \(if $s.pass then "pass" else "FAIL: " + ($s.reasons | join("; ")) end) |"' --arg f "$f" "$f"
  done
  echo
  echo "| Run | k6 error codes | per-second max latency over the plateau (ms) | stalled seconds (max latency above 100 ms) | server memory.current peak MiB | Pss_Anon peak MiB | k6 memory peak MiB | VU cap bound by | aggregator max lag s |"
  echo "|---|---|---|---|---|---|---|---|---|"
  for f in fd-wall/skeleton.json fd-wall/s1d.json; do
    [ -f "$f" ] || continue
    jq -r "$PRELUDE"'def maxms: [.endpoints[]?.max] | max // 0;
      (.results.steps[0].window) as $w | (.results.series | map(select(.second >= $w[0] and .second < $w[1]))) as $p
      | "| \($f | sub("^fd-wall/"; "") | sub("\\.json$"; "")) | \(.k6_error_codes | tojson) | \($p | map(maxms) | max | r1) | \($p | map(select(maxms > 100)) | length) | \(.server_memory.memory_current_peak_mib) | \(.server_memory.pss_anon_peak_mib) | \(.k6.peak_memory_mib) | \(.load.vu_cap_bound_by) | \(.aggregator.max_lag_s) |"' --arg f "$f" "$f"
  done
  if [ -f fd-wall/s1d.json ]; then
    echo
    jq -r "$PRELUDE"'(.results.run_total | map(.count) | add) as $k6 | (.load as $l | $l.warmup | split(",") | map(tonumber) | .[0] * (.[1] + $l.ramp_s / 2)) as $w | .server_connections.telemetry.close_responses as $c
      | "S1-d at the fd wall: \($c) `Connection: close` responses against \($k6) k6 requests plus about \($w) of the warm-up: \($c - $k6 - $w | sgn) (\(($c - $k6 - $w) / $c * 100 | r2) % of the closes), so every request of k6 reconnected."' fd-wall/s1d.json
  fi
  echo
  echo "TIME_WAIT sockets on k6's addresses are not counted by these two runs (the runner that counts them is the step lab's); the VM's ephemeral ports are 55000 to 65535."
fi

# ---------------------------------------------------------------------------------------------------------------------------------
# Runs that do not count: a run whose JSON says valid: false, or that saw another container, and the first attempt of a series that was
# started again after a harness failure (it ended before its second run, and is shown, not counted).
echo
echo "### Runs that do not count"
echo
echo "| File | valid | reason | other containers |"
echo "|---|---|---|---|"
shown=0
for json in aa-*/*.json s1-*/*.json fd-wall/*.json macro/*.json aborted-first-attempt/*.json; do
  [ -f "$json" ] || continue
  line="$(jq -r "$PRELUDE"'select(has("valid")) | select((counted | not) or ($f | startswith("aborted"))) | "| \($f) | \(.valid) | \(if $f | startswith("aborted") then "its series stopped before the second run (a harness failure, see what differed); the run itself was valid" elif (.invalid_reasons | length) > 0 then (.invalid_reasons | join("; ")) else "-" end) | \(.other_containers.count) |"' --arg f "$json" "$json")"
  [ -z "$line" ] || { echo "$line"; shown=$((shown + 1)); }
done
[ "$shown" -gt 0 ] || echo "| none | | | |"

# ---------------------------------------------------------------------------------------------------------------------------------
# The FFI micro bench on 8.5, the JIT off and on: median ns per operation over 5 processes (spread: the fastest and the slowest process).
if [ -f micro/ffi.json ]; then
  MICRO='def c($jit; $n): [.runs[] | select(.jit == $jit) | .cases[] | select(.case == $n) | .median_ns][0];'
  echo
  echo "### The FFI micro bench (\`micro.sh lab/micro/benches/ffi.php --images 8.5 --jit both\`, 5 processes per case, median ns per operation)"
  echo
  echo "| Case | JIT off ns | JIT off, fastest .. slowest process | JIT on ns | JIT on, fastest .. slowest process | on / off | status |"
  echo "|---|---|---|---|---|---|---|"
  jq -r "$PRELUDE$MICRO"'. as $f | [$f.runs[] | select(.jit == "off") | .cases[]] as $off | $off[] | .case as $n
    | ([$f.runs[] | select(.jit == "on") | .cases[] | select(.case == $n)][0]) as $on
    | "| \($n) | \(.median_ns | r1) | \(.min_ns | r1) .. \(.max_ns | r1) | \($on.median_ns | r1) | \($on.min_ns | r1) .. \($on.max_ns | r1) | \($on.median_ns / .median_ns | . * 100 | round / 100) | \(if .status == "ok" and $on.status == "ok" and (.unstable | not) and ($on.unstable | not) then "ok" else "\(.status) \($on.status)\(if .unstable or $on.unstable then " UNSTABLE" else "" end)" end) |"' micro/ffi.json
  echo
  echo "Machine: $(jq -r '.host | "\(.docker), \(.arch), cpuset \(.cpuset), \(.limits)"' micro/ffi.json); PHP $(jq -r '.runs[0].php_version' micro/ffi.json), \`ffi.enable\` $(jq -r '.runs[0].ini["ffi.enable"] // "preload"' micro/ffi.json)."

  echo
  echo "### The micro numbers against prediction 7, and the JIT's effect"
  echo
  echo "| Quantity | JIT off | JIT on | predicted |"
  echo "|---|---|---|---|"
  jq -r "$PRELUDE$MICRO"'def d($j): c($j; "syscall/FFI syscall(getpid), 1 argument") - c($j; "syscall/getmypid() native");
    "| FFI `syscall(getpid)` minus `getmypid()`, ns | \(d("off") | r1) | \(d("on") | r1) | 150 to 500 |",
    "| write one CData field, ns | \(c("off"; "cdata/write one u64 field of an SQE") | r1) | \(c("on"; "cdata/write one u64 field of an SQE") | r1) | 20 to 80 |",
    "| `FFI::memcpy` 200 B, ns | \(c("off"; "memcpy/200 B (a post)") | r1) | \(c("on"; "memcpy/200 B (a post)") | r1) | 50 to 200 |",
    "| `FFI::string` 200 B, ns | \(c("off"; "string/200 B (a request)") | r1) | \(c("on"; "string/200 B (a request)") | r1) | 50 to 200 |",
    "| `FFI::memcpy` 5 KB, ns | \(c("off"; "memcpy/5 KB (a feed)") | r1) | \(c("on"; "memcpy/5 KB (a feed)") | r1) | 150 to 600 |",
    "| `FFI::string` 5 KB, ns | \(c("off"; "string/5 KB") | r1) | \(c("on"; "string/5 KB") | r1) | 150 to 600 |",
    "| `pack()` of a 64-byte SQE, ns | \(c("off"; "pack/one 64-byte SQE") | r1) | \(c("on"; "pack/one 64-byte SQE") | r1) | 100 to 300 |",
    "| `fwrite` + `fread` 200 B, TCP loopback, ns | \(c("off"; "socket/fwrite + fread 200 B, tcp loopback") | r0) | \(c("on"; "socket/fwrite + fread 200 B, tcp loopback") | r0) | 1,000 to 3,000 |",
    "| `fwrite` + `fread` 200 B, unix socket pair, ns | \(c("off"; "socket/fwrite + fread 200 B, unix pair") | r0) | \(c("on"; "socket/fwrite + fread 200 B, unix pair") | r0) | 1,000 to 3,000 |",
    . as $f | ([["cdata/write one u64 field of an SQE", "memcpy/200 B (a post)", "string/200 B (a request)", "memcpy/5 KB (a feed)", "string/5 KB", "pack/one 64-byte SQE"][] | . as $n | ($f | c("on"; $n) / c("off"; $n) - 1) * 100] | map(fabs) | max) as $m
    | "| largest change the JIT makes among the cases above, % | | \($m | r1) | under 20 |"' micro/ffi.json

  echo
  echo "### The stop rule at the record: the ring's FFI budget per request against what the ring removes (ns per request, post of 200 B)"
  echo
  echo "Budget = one \`io_uring_enter\` (priced as the 6-argument FFI \`syscall(getpid)\`) shared by the requests of a turn + one SQE written in place (14 fields) + 1.5 CQEs (the send's and the receive's) + \`FFI::string\` of the request + \`FFI::memcpy\` of the response. Removed = a \`fwrite\` + \`fread\` of 200 B plus the skeleton's \`fcntl\` and \`epoll_pwait\` calls per request (counted above) priced as a read that finds nothing. The prudent floor prices each of the \`recvfrom\`, \`sendto\`, \`fcntl\` and \`epoll_pwait\` calls of a request as a bare \`getmypid()\`."
  echo
  echo "| Requests per turn | JIT | budget | removed (unix pair) | removed (TCP loopback) | prudent floor | passes against the unix pair? |"
  echo "|---|---|---|---|---|---|---|"
  jq -rn "$PRELUDE$MICRO"'input as $f | (input | .syscalls | map({(.name): .calls_per_request}) | add) as $s | ($s.recvfrom + $s.sendto + $s.fcntl + $s.epoll_pwait) as $tot
    | ($s.fcntl + $s.epoll_pwait) as $extra
    | ("off", "on") as $j | (1, 8, 32) as $r | ($f | [c($j; "syscall/FFI syscall(getpid), 6 arguments") / $r, c($j; "cdata/write all 14 fields of an SQE in the ring (sqes[i])"),
        (if $r == 1 then 1.5 * (c($j; "string/16 B (one CQE)") + c($j; "unpack/one 16-byte CQE")) else 1.5 * c($j; "batch/32 CQEs: one FFI::string, one unpack()") / 32 end),
        c($j; "string/200 B (a request)"), c($j; "memcpy/200 B (a post)")] | add) as $b
    | ($f | c($j; "socket/fwrite + fread 200 B, unix pair") + $extra * c($j; "socket/fread with nothing to read (EAGAIN), unix pair")) as $ru
    | ($f | c($j; "socket/fwrite + fread 200 B, tcp loopback") + $extra * c($j; "socket/fread with nothing to read (EAGAIN), tcp loopback")) as $rt
    | ($f | $tot * c($j; "syscall/getmypid() native")) as $floor
    | "| \($r) | \($j) | \($b | r0) | \($ru | r0) | \($rt | r0) | \($floor | r0) | \(if $b < $ru then "yes, \($ru / $b | . * 10 | round / 10)x" else "**no**" end) (\(if $b < $floor then "under" else "over" end) the floor) |"' micro/ffi.json syscalls-skeleton.json syscalls-skeleton.json
fi

# ---------------------------------------------------------------------------------------------------------------------------------
# The ring's no-op server against DIY's on /noop (macro.sh, 30 s after a 10 s warm-up, 1 CPU). The ring's turns per request come from the
# server's own `ring:` lines (counts per second, kept in ring-lines/); DIY prints none.
if ls macro/*.json >/dev/null 2>&1; then
  echo
  echo "### The ring's no-op server against DIY's, \`GET /noop\` (\`macro.sh\`, 30 s after a 10 s warm-up, 1 CPU, \`--pre-vus\` = \`--max-vus\` = rate / 5)"
  echo
  echo "| Run | valid | other containers | offered req/s | achieved req/s | µs CPU/req | p95 ms | p99 ms | dropped iterations | requests per turn (the server's own count, busy seconds) |"
  echo "|---|---|---|---|---|---|---|---|---|---|"
  for f in diy-7000-1 ring-7000-1 diy-7000-2 ring-7000-2 diy-7000-3 ring-7000-3 diy-24000 ring-24000 ring-24000-minwait; do
    [ -f "macro/$f.json" ] || continue
    rpt="-"
    if [ -f "ring-lines/$f.json" ]; then
      rpt="$(jq -r --argjson rate "$(jq '.results.requested_req_per_s' "macro/$f.json")" '[.seconds[] | select(.requests >= $rate / 2)] as $b | if ($b | length) == 0 then "-" else "\(($b | map(.requests) | add) / ($b | map(.turns) | add) * 100 | round / 100) (\($b | length) busy seconds)" end' "ring-lines/$f.json")"
    fi
    jq -r "$PRELUDE"'.results as $r
      | "| \($f) | \(.valid) | \(.other_containers.count) | \($r.requested_req_per_s) | \($r.achieved_req_per_s | r1) | \($r.cpu_usec_per_request | r2) | \($r.latency_ms.p95 | r2) | \($r.latency_ms.p99 | r2) | \($r.dropped_iterations) | \($rpt) |"' --arg f "$f" --arg rpt "$rpt" "macro/$f.json"
  done
  echo
  jq -nr "$PRELUDE"'[inputs | {n: input_filename, v: .valid, o: .other_containers.count, us: .results.cpu_usec_per_request, p99: .results.latency_ms.p99}] as $r
    | def of($k): [$r[] | select(.v and .o == 0 and (.n | test("^macro/\($k)-7000-[0-9]\\.json$"))) | .us];
      (of("diy")) as $d | (of("ring")) as $g
    | if ($d | length) > 0 and ($g | length) > 0 then
        "At 7,000 req/s: DIY \($d | map(r2) | join(", ")) µs/req (median \($d | med | r2)), ring \($g | map(r2) | join(", ")) (median \($g | med | r2)): the ring minus DIY is \((($g | med) - ($d | med)) | sgn) µs/req (\((($g | med) / ($d | med) - 1) * 100 | r1) %). DIY'"'"'s own spread over its \($d | length) runs is \(($d | max) - ($d | min) | r2) µs/req: no A/A floor was measured at this shape (the step lab'"'"'s floors are for the realistic mode)."
      else "" end' macro/*.json </dev/null
fi
if ls turns/*.json >/dev/null 2>&1; then
  echo
  echo "### Turns of each loop at 7,000 req/s, two ways (extra runs, not counted: another container reads the server from outside)"
  echo
  echo "The ring's turn count is its own (the \`ring:\` lines of the counted runs above): about one request per turn. DIY prints no turn count, so its turns are bounded from outside: (a) the voluntary context switches of the server process (a loop that blocks in its wait is one switch per turn, a wait that finds events ready does not block, so the switches are at most the turns and the requests per turn are at most the requests per switch), read every 3 s without tracing; (b) \`strace -c -f\` on the loop's wait for 12 s (\`epoll_pwait\` for DIY, \`io_uring_enter\` for the ring): a true count, but strace stops the server at every syscall, so the traced loop is slower and batches more (the traced run's µs/req is higher): also an upper bound."
  echo
  echo "| Server | (a) voluntary switches per second (median of the busy intervals) | (a) requests per switch (an upper bound of the requests per turn) | (b) traced waits per second | (b) requests per turn while traced | the server's own count, untraced (requests per turn) |"
  echo "|---|---|---|---|---|---|"
  for kind in diy ring; do
    [ -f "turns/switches-$kind-7000.json" ] || continue
    own="-"
    if [ "$kind" = ring ]; then
      own="$(jq -rs '[.[].seconds[] | select(.requests >= 3500)] | (map(.requests) | add) / (map(.turns) | add) * 100 | round / 100' ring-lines/ring-7000-1.json ring-lines/ring-7000-2.json ring-lines/ring-7000-3.json)"
    fi
    sw="$(jq -r "$PRELUDE"'.samples as $s | [range(1; $s | length) | {dt: ($s[.].t - $s[. - 1].t), dv: ($s[.].voluntary - $s[. - 1].voluntary)} | select(.dt > 0) | .dv / .dt] as $v
      | ($v | max) as $m | ([$v[] | select(. > $m / 2)] | med) as $busy | "\($busy | r0) | \(.rate / $busy | r2)"' "turns/switches-$kind-7000.json")"
    st="$(jq -r "$PRELUDE"'"\(.calls / .window_s | r0) | \(.rate / (.calls / .window_s) | r2)"' "turns/strace-$kind-7000.json")"
    echo "| $kind | $sw | $st | $own |"
  done
fi

# ---------------------------------------------------------------------------------------------------------------------------------
# Connections held by the ring server: one ring (a descriptor table of 65,535 at most) and two rings (80,000), the process's own descriptors
# and memory per connection, next to the bake-off's DIY run (one descriptor per connection).
if ls conns/*.json >/dev/null 2>&1; then
  echo
  echo "### Idle connections held by the ring server (\`conns.sh\`: the client opens them one at a time, each answered once, then holds them; nofile 65,535)"
  echo
  echo "| Run | step (connections) | held | server's own fds | Pss MiB | Pss_Anon MiB | memory.current MiB | established (VM) | fresh request ms | other containers |"
  echo "|---|---|---|---|---|---|---|---|---|---|"
  for f in conns/ring-1-ring.json conns/ring-2-rings.json; do
    [ -f "$f" ] || continue
    jq -r "$PRELUDE"'.other_containers.count as $o | .steps[] | "| \($f | sub("^conns/"; "") | sub("\\.json$"; "")) | \(.target) | \(.held) | \(.probe.server_fds) | \(.probe.pss_kb / 1024 | r2) | \(.probe.pss_anon_kb / 1024 | r2) | \(.probe.cgroup_current / 1048576 | r1) | \(.probe.tcp_established) | \(.probe.fresh_ms) | \($o) |"' --arg f "$f" "$f"
  done
  if [ -f ../2026-11-21-bake-off/conns-diy-8.5.json ]; then
    jq -r "$PRELUDE"'.steps[] | select(.target == 60000) | "| DIY, the bake-off'"'"'s run | \(.target) | \(.held) | about 60,012 (one per connection) | \(.probe.pss_kb / 1024 | r2) | \(.probe.pss_anon_kb / 1024 | r2) | \(.probe.cgroup_current / 1048576 | r1) | \(.probe.tcp_established) | \(.probe.fresh_ms) | - |"' ../2026-11-21-bake-off/conns-diy-8.5.json
  fi
  echo
  echo "| Run | max held and answered | stopped because | Pss per connection KiB | Pss_Anon per connection KiB | memory.current per connection KiB | baseline Pss / memory.current MiB |"
  echo "|---|---|---|---|---|---|---|"
  for f in conns/ring-1-ring.json conns/ring-2-rings.json ../2026-11-21-bake-off/conns-diy-8.5.json; do
    [ -f "$f" ] || continue
    jq -r "$PRELUDE"'.results as $r | "| \($f | sub("^.*/"; "") | sub("\\.json$"; "")) | \($r.max_connections) | \($r.reason_stopped) | \($r.memory_per_connection.pss_kib_per_connection | r2) | \($r.memory_per_connection.pss_anon_kib_per_connection | r2) | \($r.memory_per_connection.cgroup_current_kib_per_connection | r2) | \($r.baseline.pss_kb / 1024 | r1) / \($r.baseline.cgroup_current_bytes / 1048576 | r1) |"' --arg f "$f" "$f"
  done
fi

# ---------------------------------------------------------------------------------------------------------------------------------
# S1-d with no warm-up: the close count against k6's requests, exactly.
if [ -f s1-check/s1d-no-warm-up.json ]; then
  echo
  echo "### S1-d without a warm-up: the close count against k6's requests (60,000 idle, soft limit 60,000, 12,000 req/s, \`s = 0.02\`, 60 s)"
  echo
  jq -r "$PRELUDE"'(.results.run_total | map(.count) | add) as $k6 | .server_connections.telemetry.close_responses as $c
    | "Valid \(.valid), other containers \(.other_containers.count): \($c) `Connection: close` responses against \($k6) k6 requests (difference \($c - $k6), \(($c - $k6) / $k6 * 100 | r2) %)."' s1-check/s1d-no-warm-up.json
fi
