#!/usr/bin/env bash
# The server box's sampler: one CSV row a second of cheap counters, for the score search (lab/score/run-k6.sh reads the file).
#
#   bash lab/score/server-sample.sh --cgroup <dir> --pids-of <unit or pattern> --out <csv> [--iface <name>]
#   bash lab/score/server-sample.sh --facts-only         prints the start facts (below) and exits
#
# --cgroup is the service's cgroup directory (/sys/fs/cgroup/system.slice/<unit>.service on the AWS box; inside a lab container it is
# /sys/fs/cgroup, the container's own). --pids-of names the processes whose memory and open files are read: a systemd unit (a name ending
# in .service or .scope: the pids in its cgroup.procs) or a pattern that a process's command line contains. Stop it with SIGTERM or SIGINT.
# Needs bash 5 (EPOCHREALTIME) and no package: it runs as root on Ubuntu 24.04, and in a lab container.
#
# Each row costs only bash builtins reads of /proc and the cgroup's files: no fork on the one-second path (a `stat` for the open
# files of each process, one row in 10, is the only exception). Columns:
#   ts            epoch seconds with milliseconds, taken just after a whole second. The load box stamps its REST polls the same way, and both
#                 boxes sync to Amazon Time Sync, so the plateau is matched to these rows by time, never by "the same second";
#   cpu_*         /proc/stat's first line (user, nice, system, idle, iowait, irq, softirq, steal), as counters: the reader computes shares;
#   cg_usage_usec the cgroup's cpu.stat usage_usec; mem_current, mem_peak (empty when the kernel has no memory.peak; all three empty once the
#                 service's cgroup is gone: the sampler goes on, and still writes server-end.txt);
#   rss_bytes     the processes' resident memory summed (/proc/<pid>/statm, the same number as VmRSS, read without parsing a status file);
#   mem_available_kb, tcp_inuse, tcp_tw, tcp_mem (/proc/net/sockstat), passive_opens, active_opens, curr_estab, retrans_segs
#   (/proc/net/snmp), listen_overflows, listen_drops (/proc/net/netstat);
#   fds           every 10th row: `pid:open files` for each process, separated by `;`; empty on the other rows. The count is the size of
#                 /proc/<pid>/fd (Linux 6.2 and later report the number of open files there); an older kernel reports 0, then the entries are counted.
#
# server-start.txt and server-end.txt, next to the CSV, hold one fact a line: `nproc <n>`, `ena <counter> <value>` for each `allowance`
# line of `ethtool -S <iface>` (or `ena-unread <why>`), `oom <message>` for each kernel OOM line (the part after the host name and
# `kernel: `, the results are public; or `oom-unread <why>`). server-end.txt also has `sampler_cpu_ms` and `sampler_wall_ms`: the sampler's own CPU
# time (it prints the share, which must stay under 1 % of one core).
set -euo pipefail

usage() { echo "usage: server-sample.sh --cgroup <dir> --pids-of <unit or pattern> --out <csv> [--iface <name>] | --facts-only" >&2; exit 2; }
[ "${BASH_VERSINFO[0]}" -ge 5 ] || { echo "server-sample: needs bash 5 (EPOCHREALTIME)" >&2; exit 2; }

cgroup="" pids_of="" out="" iface="" facts_only=0
while [ "$#" -gt 0 ]; do
  if [ "$1" = --facts-only ]; then facts_only=1; shift; continue; fi
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --cgroup) cgroup="$2" ;;
    --pids-of) pids_of="$2" ;;
    --out) out="$2" ;;
    --iface) iface="$2" ;;
    *) usage ;;
  esac
  shift 2
done
if [ "$facts_only" = 0 ]; then
  [ -n "$cgroup" ] && [ -n "$pids_of" ] && [ -n "$out" ] || usage
  [ -r "$cgroup/cpu.stat" ] && [ -r "$cgroup/memory.current" ] || { echo "server-sample: no cpu.stat or memory.current in $cgroup" >&2; exit 2; }
fi
dir="$(dirname "${out:-.}")"
page_bytes="$(getconf PAGESIZE)"
clk_tck="$(getconf CLK_TCK)"

# --- the facts at the start and at the stop ---------------------------------------------------------------------------------------
default_iface() {
  local name dest _
  while read -r name dest _; do
    [ "$dest" = 00000000 ] && { echo "$name"; return; }
  done < <(tail -n +2 /proc/net/route)
}

oom_lines() {
  local lines
  if [ -n "${SCORE_KERNEL_LOG:-}" ]; then lines="$(<"$SCORE_KERNEL_LOG")"   # a test hook: a file of kernel log lines
  elif command -v journalctl >/dev/null 2>&1 && lines="$(journalctl -k --no-pager -q 2>/dev/null)"; then :
  elif command -v dmesg >/dev/null 2>&1 && lines="$(dmesg 2>/dev/null)"; then :
  else echo "oom-unread neither journalctl -k nor dmesg could read the kernel log"; return; fi
  local line
  while IFS= read -r line; do
    case "$line" in
      *[Oo]ut\ of\ memory* | *oom-kill* | *[Kk]illed\ process*)
        # journalctl -k: `Nov 24 10:00:00 <host> kernel: <message>`; dmesg: `[ 123.456] <message>`. Only the message is kept.
        line="${line#*kernel: }"
        [[ "$line" != "["* ]] || line="${line#*] }"
        echo "oom $line" ;;
    esac
  done <<<"$lines"
  return 0
}

facts() {
  local nic="${iface:-$(default_iface)}" line name value
  echo "nproc $(getconf _NPROCESSORS_ONLN)"
  if ! command -v ethtool >/dev/null 2>&1; then
    echo "ena-unread ethtool is not installed"
  elif [ -z "$nic" ] || ! lines="$(ethtool -S "$nic" 2>&1)"; then
    echo "ena-unread ethtool -S ${nic:-?} failed"
  else
    while IFS= read -r line; do
      case "$line" in *allowance*) name="${line%%:*}"; name="${name// /}"; value="${line##*: }"; echo "ena $name $value" ;; esac
    done <<<"$lines"
  fi
  oom_lines
}

# --- the processes -----------------------------------------------------------------------------------------------------------------
PIDS=()
resolve_pids() {
  local p args f
  PIDS=()
  case "$pids_of" in
    *.service | *.scope)
      for f in "/sys/fs/cgroup/system.slice/$pids_of/cgroup.procs" "$cgroup/cgroup.procs"; do
        [ -r "$f" ] || continue
        while read -r p; do PIDS+=("$p"); done <"$f"
        break
      done ;;
    *)
      for f in /proc/[0-9]*; do
        p="${f#/proc/}"
        [ "$p" != "$$" ] || continue
        mapfile -d '' -t args <"$f/cmdline" 2>/dev/null || continue
        case "${args[*]-}" in
          *server-sample.sh*) ;;
          *"$pids_of"*) PIDS+=("$p") ;;
        esac
      done ;;
  esac
}

# --- the tables of /proc/net ---------------------------------------------------------------------------------------------------
# column_index <file> <prefix> <name>: the index of a column in the table of /proc/net/snmp or netstat (header line, then values line).
column_index() {
  local f=() i
  while read -r -a f; do
    [ "${f[0]}" = "$2" ] || continue
    for i in "${!f[@]}"; do [ "${f[$i]}" = "$3" ] && { echo "$i"; return; }; done
    break
  done <"$1"
  echo "server-sample: no column $3 in $1" >&2
  exit 1
}

# values_line <file> <prefix>: sets VALUES to the second line that starts with the prefix (the first is the header).
VALUES=()
values_line() {
  local f=() n=0
  while read -r -a f; do
    [ "${f[0]}" = "$2" ] || continue
    n=$((n + 1))
    [ "$n" -eq 2 ] && { VALUES=("${f[@]}"); return; }
  done <"$1"
}

i_passive=$(column_index /proc/net/snmp Tcp: PassiveOpens)
i_active=$(column_index /proc/net/snmp Tcp: ActiveOpens)
i_estab=$(column_index /proc/net/snmp Tcp: CurrEstab)
i_retrans=$(column_index /proc/net/snmp Tcp: RetransSegs)
i_overflow=$(column_index /proc/net/netstat TcpExt: ListenOverflows)
i_drops=$(column_index /proc/net/netstat TcpExt: ListenDrops)

open_fds() {
  local p size entries out=""
  for p in "${PIDS[@]-}"; do
    [ -n "$p" ] || continue
    size="$(stat -c %s "/proc/$p/fd" 2>/dev/null)" || continue
    if [ "$size" = 0 ]; then
      entries=("/proc/$p/fd/"*)
      size="${#entries[@]}"
    fi
    out+="${out:+;}$p:$size"
  done
  FDS="$out"
}

# --- one row -----------------------------------------------------------------------------------------------------------------------
row_no=0
sample_row() {
  local us ts cu cn cs ci cw cirq csirq cst usage="" mem_cur="" mem_peak="" rss=0 p pages avail="" k v
  local inuse="" tw="" tmem="" passive active estab retrans overflow drops
  us="${EPOCHREALTIME/./}"
  printf -v ts '%d.%03d' $((us / 1000000)) $(((us / 1000) % 1000))
  read -r _ cu cn cs ci cw cirq csirq cst _ </proc/stat
  # Why the guards: when the unit fails (Restart=no) systemd removes its cgroup, and the sampler must go on: it still has to write server-end.txt
  # (the OOM lines that name the memory wall). The cgroup columns are empty from then on.
  if [ -r "$cgroup/cpu.stat" ]; then
    while read -r k v _; do [ "$k" = usage_usec ] && { usage="$v"; break; }; done <"$cgroup/cpu.stat" || true
  fi
  [ ! -r "$cgroup/memory.current" ] || read -r mem_cur <"$cgroup/memory.current" || mem_cur=""
  [ ! -r "$cgroup/memory.peak" ] || read -r mem_peak <"$cgroup/memory.peak" || mem_peak=""
  for p in "${PIDS[@]-}"; do
    [ -n "$p" ] || continue
    read -r _ pages _ <"/proc/$p/statm" 2>/dev/null || continue
    rss=$((rss + pages * page_bytes))
  done
  while read -r k avail _; do [ "$k" = MemAvailable: ] && break; done </proc/meminfo
  # TCP: inuse <n> orphan <n> tw <n> alloc <n> mem <n>
  while read -r k _ inuse _ _ _ tw _ _ _ tmem; do
    [ "$k" = TCP: ] && break
  done </proc/net/sockstat
  values_line /proc/net/snmp Tcp:
  passive="${VALUES[$i_passive]}" active="${VALUES[$i_active]}" estab="${VALUES[$i_estab]}" retrans="${VALUES[$i_retrans]}"
  values_line /proc/net/netstat TcpExt:
  overflow="${VALUES[$i_overflow]}" drops="${VALUES[$i_drops]}"
  FDS=""
  if [ $((row_no % 10)) -eq 0 ]; then resolve_pids; open_fds; fi
  row_no=$((row_no + 1))
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' \
    "$ts" "$cu" "$cn" "$cs" "$ci" "$cw" "$cirq" "$csirq" "$cst" "$usage" "$mem_cur" "$mem_peak" "$rss" "$avail" \
    "$inuse" "$tw" "$tmem" "$passive" "$active" "$estab" "$retrans" "$overflow" "$drops" "$FDS" >&3
}

# own_cpu_ms: this shell's user and system time (and its waited children') from /proc/<its pid>/stat, in ms. Field 2 (the name) can hold spaces.
own_cpu_ms() {
  local stat f
  stat="$(</proc/$$/stat)"
  read -r -a f <<<"${stat##*) }"
  echo $(((${f[11]} + ${f[12]} + ${f[13]} + ${f[14]}) * 1000 / clk_tck))
}

# wait_next_second: sleeps (a `read` with a timeout on a pipe nothing writes to) until 5 ms after the next whole second.
wait_next_second() {
  local us wait
  us=$((10#${EPOCHREALTIME#*.}))
  wait=$((1000000 - us + 5000))
  printf -v wait '%d.%06d' $((wait / 1000000)) $((wait % 1000000))
  read -r -t "$wait" -u "$sleep_fd" || true
}

# --- main --------------------------------------------------------------------------------------------------------------------------
if [ "$facts_only" = 1 ]; then facts; exit 0; fi
exec {sleep_fd}<> <(:)
stop=0
trap 'stop=1' TERM INT
facts >"$dir/server-start.txt"
resolve_pids
exec 3>"$out"
echo "ts,cpu_user,cpu_nice,cpu_system,cpu_idle,cpu_iowait,cpu_irq,cpu_softirq,cpu_steal,cg_usage_usec,mem_current,mem_peak,rss_bytes,mem_available_kb,tcp_inuse,tcp_tw,tcp_mem,passive_opens,active_opens,curr_estab,retrans_segs,listen_overflows,listen_drops,fds" >&3
started_us="${EPOCHREALTIME/./}"
while [ "$stop" = 0 ]; do
  wait_next_second
  [ "$stop" = 0 ] || break
  sample_row
done
cpu_ms="$(own_cpu_ms)"
wall_ms=$(((${EPOCHREALTIME/./} - started_us) / 1000))
{
  facts
  echo "sampler_cpu_ms $cpu_ms"
  echo "sampler_wall_ms $wall_ms"
} >"$dir/server-end.txt"
exec 3>&-
if [ "$wall_ms" -gt 0 ]; then
  printf 'sampler: %d ms of CPU over %d s (%d.%02d %% of one core)\n' "$cpu_ms" $((wall_ms / 1000)) $((cpu_ms * 100 / wall_ms)) $(((cpu_ms * 10000 / wall_ms) % 100))
fi
