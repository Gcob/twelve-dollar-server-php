#!/usr/bin/env bash
# The load box's sampler: once a second it polls k6's REST API and reads the host's CPU and the k6 container's memory, for the score
# search (lab/score/run-k6.sh starts it with k6 and stops it after).
#
#   bash lab/score/loadbox-sample.sh --api <host:port> --cgroup <path under /sys/fs/cgroup> --dir <folder> --stop-file <file>
#                                    [--cpus <list>] [--mem-share <n>]
#
# Writes into <folder>: rest.tsv (one line a second: `ts`, then the bodies of GET /v1/metrics/vus, /http_reqs and /http_req_failed, a tab
# after each; an empty body when k6 did not answer) and loadbox.csv (`ts`, /proc/stat's CPU counters, the k6 container's memory.current and
# memory.peak, the host's MemTotal in kB). `ts` is the epoch in seconds with milliseconds, taken just after a whole second, like the server's sampler
# (lab/score/server-sample.sh): the plateau comes from these REST rows and the server's rows are matched to it by time. Runs until the stop file
# exists. --cgroup is the k6 container's cgroup, read as `<path>/memory.current` (empty columns until it exists): `system.slice/docker-<id>.scope`
# on Docker CE with the systemd driver, `docker/<id>` with Docker Desktop's cgroupfs driver (lab/score/run-k6.sh works it out from `docker inspect`).
# --cpus (a list like 0-7,12) reads only those CPUs' counters from /proc/stat (the first half's cpuset when the load is split in two k6 halves),
# --mem-share <n> writes MemTotal divided by n as the memory column (a half's share). Without them: every CPU, the whole memory. SCORE_PROC_STAT is a test
# hook (lab/check.sh): the file read in place of /proc/stat.
# Runs on the load box itself, or, on a Mac, in a helper container on the Docker VM's host network and cgroup namespace (the VM is the load box
# there). Needs bash 5 and curl.
set -euo pipefail

usage() { echo "usage: loadbox-sample.sh --api <host:port> --cgroup <path under /sys/fs/cgroup> --dir <folder> --stop-file <file> [--cpus <list>] [--mem-share <n>]" >&2; exit 2; }
[ "${BASH_VERSINFO[0]}" -ge 5 ] || { echo "loadbox-sample: needs bash 5 (EPOCHREALTIME)" >&2; exit 2; }

api="" cg="" dir="" stop_file="" cpus="" mem_share=1
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --api) api="$2" ;;
    --cgroup) cg="/sys/fs/cgroup/$2" ;;
    --dir) dir="$2" ;;
    --stop-file) stop_file="$2" ;;
    --cpus) cpus="$2" ;;
    --mem-share) mem_share="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$api" ] && [ -n "$cg" ] && [ -d "$dir" ] && [ -n "$stop_file" ] || usage
[[ "$mem_share" =~ ^[1-9][0-9]*$ ]] || usage

stat_file="${SCORE_PROC_STAT:-/proc/stat}"
# want[<n>]=1 for each CPU of --cpus ("0-3,8": 0 1 2 3 8).
declare -A want=()
if [ -n "$cpus" ]; then
  IFS=, read -r -a ranges <<<"$cpus"
  for r in "${ranges[@]}"; do
    [[ "$r" =~ ^[0-9]+(-[0-9]+)?$ ]] || usage
    lo="${r%-*}" hi="${r#*-}"
    for ((c = lo; c <= hi; c++)); do want[$c]=1; done
  done
fi

# read_cpu: sets cu cn cs ci cw cirq csirq cst to the counters of the CPUs asked for (the whole box without --cpus).
read_cpu() {
  local name a b c d e f g h _
  if [ -z "$cpus" ]; then
    read -r _ cu cn cs ci cw cirq csirq cst _ <"$stat_file"
    return
  fi
  cu=0 cn=0 cs=0 ci=0 cw=0 cirq=0 csirq=0 cst=0
  while read -r name a b c d e f g h _; do
    case "$name" in
      cpu[0-9]*) [ -n "${want[${name#cpu}]:-}" ] || continue
                 cu=$((cu + a)) cn=$((cn + b)) cs=$((cs + c)) ci=$((ci + d)) cw=$((cw + e)) cirq=$((cirq + f)) csirq=$((csirq + g)) cst=$((cst + h)) ;;
    esac
  done <"$stat_file"
}

wait_next_second() {
  local us wait
  us=$((10#${EPOCHREALTIME#*.}))
  wait=$((1000000 - us + 5000))
  printf -v wait '%d.%06d' $((wait / 1000000)) $((wait % 1000000))
  read -r -t "$wait" -u "$sleep_fd" || true
}

exec {sleep_fd}<> <(:)
exec 3>"$dir/rest.tsv" 4>"$dir/loadbox.csv"
echo "ts,cpu_user,cpu_nice,cpu_system,cpu_idle,cpu_iowait,cpu_irq,cpu_softirq,cpu_steal,k6_mem_current,k6_mem_peak,mem_total_kb" >&4
url="http://$api/v1/metrics"
while [ ! -e "$stop_file" ]; do
  wait_next_second
  us="${EPOCHREALTIME/./}"
  printf -v ts '%d.%03d' $((us / 1000000)) $(((us / 1000) % 1000))
  # One curl for the three metrics (one connection), 0.8 s at most so a stuck k6 does not skip a second.
  body="$(curl -s -m 0.8 -w '\t' "$url/vus" "$url/http_reqs" "$url/http_req_failed" 2>/dev/null || true)"
  printf '%s\t%s\n' "$ts" "${body//$'\n'/}" >&3
  read_cpu
  mem="" peak=""
  [ ! -r "$cg/memory.current" ] || read -r mem <"$cg/memory.current" || true
  [ ! -r "$cg/memory.peak" ] || read -r peak <"$cg/memory.peak" || true
  read -r _ total _ </proc/meminfo
  total=$((total / mem_share))
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$ts" "$cu" "$cn" "$cs" "$ci" "$cw" "$cirq" "$csirq" "$cst" "$mem" "$peak" "$total" >&4
done
