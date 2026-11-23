#!/usr/bin/env bash
# Runs inside the probe container of lab/macro.sh (--cgroupns host --pid host): reads cgroup files and /proc from
# OUTSIDE the server's and k6's cgroups, so reading them costs the server and k6 nothing. Prints `<group> <key> <number>`
# lines, which lab/macro.sh turns into JSON.
#
#   probe.sh cpu <server container id> <k6 container id>     time (us) and cpu.stat of both cgroups
#   probe.sh memory <server container id>                    memory.* of the server's cgroup and VmHWM of its processes
#   probe.sh memory-now <server container id>               Pss and Pss_Anon (kB, summed over the server's processes) and memory.current now
#   probe.sh connections <port>                              established connections whose local port is <port> (server side)
#   probe.sh memory-events <server container id>             memory.events of the server's cgroup (oom_kill, max, ...)
#   probe.sh fresh-request <port> <path>                     one request from 127.0.0.1 with a 1 s limit: `fresh http_code <n>`, `fresh ms <n>`
#   probe.sh port-open <port>                                exit 0 if something accepts connections on 127.0.0.1:<port>
#   probe.sh http-answers <port> <path>                      exit 0 if 127.0.0.1:<port><path> answers any HTTP status
#   probe.sh poll <server id> <k6 id> <status file>          k6's memory, the server's memory now, the aggregator's status line
#   probe.sh fds <server container id>                       open file descriptors of the server's processes (`fds open <n>`)
#   probe.sh client-ips <port>                               established connections to <port> by the client's address (`clients <ip> <n>`)
#   probe.sh cgroup-memory <container id>                    memory of any container's cgroup: current, peak, anon, socket buffers and kernel (bytes)
#   probe.sh time-wait <first ip>-<last ip> [file]           TIME_WAIT sockets (host network, /proc/net/tcp or <file>) with each address of the range
#                                                            at either end (`time_wait <ip> <n>`), then max, in_range and all (`time_wait_summary`)
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
  memory-now)
    # Why Pss: it splits a shared page between the processes that map it, so the sum is what the server costs, where VmHWM counts
    # the shared libraries in full and memory.peak counts page cache. Read while the server works, it is the memory under load.
    # Why also Pss_Anon: Pss counts the file pages a process maps, and the handler maps the SQLite database (mmap_size), so Pss
    # grows with the rows the requests touched. Pss_Anon (heap and stacks, no file pages) is what separates one runtime from
    # another; compare runtimes on it and on memory.current.
    s="$(cgroup_dir "$2")"
    total=0
    anon=0
    for pid in $(cat "$s/cgroup.procs"); do
      read -r pss pss_anon < <(awk '/^Pss:/ {p=$2} /^Pss_Anon:/ {a=$2} END {print p+0, a+0}' "/proc/$pid/smaps_rollup" 2>/dev/null || echo "0 0")
      total=$(( total + ${pss:-0} ))
      anon=$(( anon + ${pss_anon:-0} ))
    done
    echo "memory_now pss_kb $total"
    echo "memory_now pss_anon_kb $anon"
    echo "memory_now cgroup_current $(cat "$s/memory.current")"
    ;;
  connections)
    # Why: the host network namespace is shared (--network host), so /proc/net/tcp lists the server's sockets. Column 2 is
    # the local address (`0100007F:4650`), column 4 the state (01 = ESTABLISHED).
    hex="$(printf '%04X' "$2")"
    n="$(awk -v p=":$hex" '$4 == "01" && substr($2, index($2, ":")) == p' /proc/net/tcp /proc/net/tcp6 2>/dev/null | wc -l)"
    echo "connections established $(( n ))"
    ;;
  memory-events)
    sed 's/^/memory_events /' "$(cgroup_dir "$2")/memory.events"
    ;;
  fresh-request)
    # Why a new curl each time: a new connection, so a server at its limit shows as a request that does not answer.
    out="$(curl -s -o /dev/null --max-time 1 -w '%{http_code} %{time_total}' "http://127.0.0.1:$2$3" || true)"
    read -r code seconds <<<"${out:-000 0}"
    echo "fresh http_code $code"
    echo "fresh ms $(awk -v s="${seconds:-0}" 'BEGIN { printf "%.1f", s * 1000 }')"
    ;;
  port-open)
    (exec 3<>"/dev/tcp/127.0.0.1/$2") 2>/dev/null
    ;;
  http-answers)
    code="$(curl -s -o /dev/null --max-time 2 -w '%{http_code}' "http://127.0.0.1:$2$3" || true)"
    [ -n "$code" ] && [ "$code" != 000 ]
    ;;
  poll)
    # One call a second during lab/realistic.sh: k6's memory (current, peak, OOM kills), the server's memory now (as memory-now), and
    # the aggregator's status file (written in the volume the probe shares with it), as the last line. With a 5th argument `light`
    # (lab/realistic.sh --no-series) the server is not read at all: no `smaps_rollup`, which walks its page tables once a second.
    k="$(cgroup_dir "$3")"
    echo "k6 memory_current $(cat "$k/memory.current")"
    echo "k6 memory_peak $(cat "$k/memory.peak")"
    echo "k6 oom_kill $(awk '$1 == "oom_kill" {print $2}' "$k/memory.events")"
    [ "${5:-}" = light ] || bash "$0" memory-now "$2" | sed 's/^memory_now /server /'
    echo "status $(cat "$4" 2>/dev/null || echo '{}')"
    ;;
  fds)
    s="$(cgroup_dir "$2")"
    n=0
    for pid in $(cat "$s/cgroup.procs"); do
      n=$(( n + $(ls "/proc/$pid/fd" 2>/dev/null | wc -l) ))
    done
    echo "fds open $n"
    ;;
  client-ips)
    # Why: the clients of a server on the host network are in /proc/net/tcp, column 3 is the remote address (`0101007F:C350`, the IPv4
    # address in little-endian hex).
    hex="$(printf '%04X' "$2")"
    awk -v p=":$hex" '$4 == "01" && substr($2, index($2, ":")) == p { split($3, a, ":"); n[a[1]]++ } END { for (h in n) print h, n[h] }' /proc/net/tcp |
      while read -r h count; do
        echo "clients $((16#${h:6:2})).$((16#${h:4:2})).$((16#${h:2:2})).$((16#${h:0:2})) $count"
      done
    ;;
  cgroup-memory)
    # Why anon, sock and kernel: the idle client's memory is its heap (anon), the socket buffers (sock) and the kernel's structures for its
    # sockets (kernel: slab and the like), all charged to its cgroup.
    c="$(cgroup_dir "$2")"
    echo "cgroup current $(cat "$c/memory.current")"
    echo "cgroup peak $(cat "$c/memory.peak")"
    echo "cgroup anon $(awk '$1 == "anon" {print $2}' "$c/memory.stat")"
    echo "cgroup sock $(awk '$1 == "sock" {print $2}' "$c/memory.stat")"
    echo "cgroup kernel $(awk '$1 == "kernel" {print $2}' "$c/memory.stat")"
    ;;
  time-wait)
    # Why either end: the side that closes first keeps the TIME_WAIT socket for 60 s. When k6 closes it is the local address (a source
    # address of the range); when the server closes it is the remote one. Either way the 4-tuple, and so that source port, is taken for
    # that address. Column 2 is the local address, column 3 the remote one (`0101007F:C350`, IPv4 in little-endian hex), column 4 the
    # state (06 = TIME_WAIT).
    first="${2%-*}" last="${2#*-}"
    [ "${first%.*}" = "${last%.*}" ] || { echo "time-wait wants a range of one /24 (127.0.1.1-127.0.1.4), got '$2'" >&2; exit 2; }
    map=""
    for n in $(seq "${first##*.}" "${last##*.}"); do
      IFS=. read -r o1 o2 o3 _ <<<"$first"
      map="$map $(printf '%02X%02X%02X%02X' "$n" "$o3" "$o2" "$o1")=$o1.$o2.$o3.$n"
    done
    awk -v map="$map" '
      BEGIN { n = split(map, items, " "); for (i = 1; i <= n; i++) { split(items[i], kv, "="); ip[kv[1]] = kv[2]; order[i] = kv[1] } }
      $4 == "06" {
        all++
        l = substr($2, 1, index($2, ":") - 1); r = substr($3, 1, index($3, ":") - 1)
        if (l in ip) count[l]++
        if (r in ip) count[r]++
        if ((l in ip) || (r in ip)) in_range++
      }
      END {
        for (i = 1; i <= n; i++) { c = count[order[i]] + 0; print "time_wait", ip[order[i]], c; if (c > max) max = c }
        print "time_wait_summary max", max + 0
        print "time_wait_summary in_range", in_range + 0
        print "time_wait_summary all", all + 0
      }' "${3:-/proc/net/tcp}"
    ;;
  *)
    echo "usage: probe.sh cpu|memory|memory-now|connections|memory-events|fresh-request|port-open|http-answers|poll|fds|client-ips|cgroup-memory|time-wait ..." >&2
    exit 2
    ;;
esac
