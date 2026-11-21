#!/usr/bin/env bash
# Runs inside the probe container of lab/macro.sh (--cgroupns host --pid host): reads cgroup files and /proc from
# OUTSIDE the server's and k6's cgroups, so reading them costs the server and k6 nothing. Prints `<group> <key> <number>`
# lines, which lab/macro.sh turns into JSON.
#
#   probe.sh cpu <server container id> <k6 container id>     time (us) and cpu.stat of both cgroups
#   probe.sh memory <server container id>                    memory.* of the server's cgroup and VmHWM of its processes
#   probe.sh port-open <port>                                exit 0 if something accepts connections on 127.0.0.1:<port>
#   probe.sh http-answers <port> <path>                      exit 0 if 127.0.0.1:<port><path> answers any HTTP status
set -euo pipefail

CG=/sys/fs/cgroup/docker

cgroup_dir() {
  [ -d "$CG/$1" ] || { echo "no cgroup directory $CG/$1 (is this Docker Desktop with cgroup v2?)" >&2; exit 1; }
  echo "$CG/$1"
}

case "${1:-}" in
  cpu)
    s="$(cgroup_dir "$2")" k="$(cgroup_dir "$3")"
    echo "time us $(( $(date +%s%N) / 1000 ))"
    sed 's/^/server /' "$s/cpu.stat"
    sed 's/^/k6 /' "$k/cpu.stat"
    ;;
  memory)
    s="$(cgroup_dir "$2")"
    for f in memory.peak memory.current memory.max; do
      echo "memory ${f#memory.} $(cat "$s/$f")"
    done
    sed 's/^/memory_stat /' "$s/memory.stat"
    for pid in $(cat "$s/cgroup.procs"); do
      # A process can exit between the two reads; VmHWM is missing for kernel threads.
      hwm="$(awk '/^VmHWM:/ {print $2}' "/proc/$pid/status" 2>/dev/null || true)"
      [ -z "$hwm" ] || echo "vmhwm_kb $pid $hwm"
    done
    ;;
  port-open)
    (exec 3<>"/dev/tcp/127.0.0.1/$2") 2>/dev/null
    ;;
  http-answers)
    code="$(curl -s -o /dev/null --max-time 2 -w '%{http_code}' "http://127.0.0.1:$2$3" || true)"
    [ -n "$code" ] && [ "$code" != 000 ]
    ;;
  *)
    echo "usage: probe.sh cpu|memory|port-open|http-answers ..." >&2
    exit 2
    ;;
esac
