#!/usr/bin/env bash
# Prints the Markdown tables of README.md from the run-*.json files next to this script.
set -euo pipefail
cd "$(dirname "$0")"

echo "### Per rate (median of 3 runs; spread = min to max)"
echo
echo "| Rate | µs CPU/req median | min .. max | achieved req/s | p95 ms | p99 ms | memory.peak MiB | VmHWM MiB | connections open | VUs in flight (max) | k6 CPU % of one CPU |"
echo "|---|---|---|---|---|---|---|---|---|---|---|"
for rate in 1000 3000 6000; do
  jq -rs --arg rate "$rate" '
    def med: sort | if length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
    def r2: . * 100 | round / 100;
    map(.results) as $r
    | ($r | map(.cpu_usec_per_request)) as $u
    | "| \($rate) | \($u | med | r2) | \($u | min | r2) .. \($u | max | r2) | \($r | map(.achieved_req_per_s) | med | r2)"
      + " | \($r | map(.latency_ms.p95) | med | r2) | \($r | map(.latency_ms.p99) | med | r2)"
      + " | \($r | map(.memory.cgroup_memory_peak_mib) | med | r2) | \($r | map(.memory.vmhwm_mib) | med | r2)"
      + " | \($r | map(.connections_open) | med) | \($r | map(.vus_used) | min)..\($r | map(.vus_used) | max)"
      + " | \($r | map(.k6_cpu_percent_of_one_cpu) | med | r2) |"' run-?-"${rate}"rps.json
done

echo
echo "### Every run, in the order they ran (the time is when the run ended and its JSON was written)"
echo
echo "| Written (UTC) | Run | µs CPU/req | achieved req/s | p95 ms | p99 ms | max ms | server CPU % of one CPU | idle µs/s | dropped | valid |"
echo "|---|---|---|---|---|---|---|---|---|---|---|"
for rep in 1 2 3; do
  for rate in 1000 3000 6000; do
    jq -r --arg run "$rep" --arg rate "$rate" '
      def r2: . * 100 | round / 100;
      .results as $r
      | "| \(.date) | \($run) @ \($rate) | \($r.cpu_usec_per_request | r2) | \($r.achieved_req_per_s | r2) | \($r.latency_ms.p95 | r2)"
        + " | \($r.latency_ms.p99 | r2) | \($r.latency_ms.max | r2) | \($r.server_cpu_percent_of_one_cpu | r2) | \($r.server_idle_usec_per_s | round) | \($r.dropped_iterations) | \(.valid) |"' "run-$rep-${rate}rps.json"
  done
done
