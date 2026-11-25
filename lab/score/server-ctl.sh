#!/usr/bin/env bash
# The server box's controller: what the score search (lab/score/search.sh, through run-k6.sh) asks of the server. Installed at
# /srv/score/ by server-setup.sh and run as root through sudo, from the load box over ssh (lab/score/ctl-ssh.sh).
#
#   server-ctl.sh restart              stop the service, remove the live database and its -wal and -shm, copy the seed, hand the copy to
#                                      deploy, start the service, poll GET /health every 0.1 s (60 s at most, then exit 1); the last line
#                                      printed is the healthy seconds. No page cache is dropped: the copy is warm, as on a droplet that
#                                      was just restarted.
#   server-ctl.sh sample-start <dir>   start lab/score/server-sample.sh, detached, on the service's cgroup and processes, writing into <dir>
#   server-ctl.sh sample-stop <dir>    stop it; <dir> then holds server.csv, server-start.txt, server-end.txt and sampler.txt, and
#                                      server-died.txt when the service was not running (files stay readable for every user)
#   server-ctl.sh facts                one JSON object: cpu_model, nproc, mem_total_mib, kernel, swap_mib
#   server-ctl.sh died                 exit 0 when the service is not active, 1 when it is
#
# The paths it reads and the unit it drives can be swapped (SCORE_CTL_SEED, SCORE_CTL_DATA, SCORE_CTL_UNIT, SCORE_CTL_URL, SCORE_CTL_OWNER,
# SCORE_CTL_TIMEOUT in seconds, SCORE_CTL_CGROUP, SCORE_CTL_PIDS_OF, SCORE_CTL_SAMPLER, and SCORE_CPUINFO, SCORE_MEMINFO for `facts`):
# lab/check.sh runs it that way. Plain bash 3.2 syntax, so the checks can run it on a laptop; the sampler it starts needs bash 5 and Linux.
set -euo pipefail

SEED="${SCORE_CTL_SEED:-/srv/seed/feed.db}"
DATA="${SCORE_CTL_DATA:-/srv/data/feed.db}"
UNIT="${SCORE_CTL_UNIT:-php-gcob}"
URL="${SCORE_CTL_URL:-http://127.0.0.1:80/health}"
OWNER="${SCORE_CTL_OWNER:-deploy}"
TIMEOUT="${SCORE_CTL_TIMEOUT:-60}"
CGROUP="${SCORE_CTL_CGROUP:-/sys/fs/cgroup/system.slice/$UNIT.service}"
PIDS_OF="${SCORE_CTL_PIDS_OF:-$UNIT.service}"
SAMPLER="${SCORE_CTL_SAMPLER:-$(cd "$(dirname "$0")" && pwd)/server-sample.sh}"
CPUINFO="${SCORE_CPUINFO:-/proc/cpuinfo}"
MEMINFO="${SCORE_MEMINFO:-/proc/meminfo}"

usage() { echo "usage: server-ctl.sh restart | sample-start <dir> | sample-stop <dir> | facts | died" >&2; exit 2; }
fail() { echo "server-ctl: $*" >&2; exit 1; }

cmd_restart() {
  local began now tries
  [ -f "$SEED" ] || fail "no seed at $SEED: nothing was touched"
  systemctl stop "$UNIT"
  rm -f "$DATA" "$DATA-wal" "$DATA-shm"
  cp "$SEED" "$DATA"
  chown "$OWNER:$OWNER" "$DATA"
  sync
  began="$(date +%s)"
  systemctl start "$UNIT"
  tries=$((TIMEOUT * 10))
  while [ "$tries" -gt 0 ]; do
    if curl -sf -m 1 "$URL" >/dev/null 2>&1; then
      now="$(date +%s)"
      echo $((now - began))
      return 0
    fi
    tries=$((tries - 1))
    sleep 0.1
  done
  fail "GET /health did not answer within $TIMEOUT s"
}

cmd_sample_start() {
  local dir="$1" waited=0
  mkdir -p "$dir"
  rm -f "$dir/server.csv" "$dir/server-start.txt" "$dir/server-end.txt" "$dir/server-died.txt" "$dir/sampler.txt" "$dir/sampler.pid"
  # Why setsid and the files: the sampler must outlive this ssh session, and ssh waits for every descriptor a child holds. The shell writes its
  # own pid, then becomes the sampler (exec), so the pid file names the sampler.
  setsid -f bash -c 'echo $$ >"$1"; exec bash "$2" --cgroup "$3" --pids-of "$4" --out "$5" >"$6" 2>&1 </dev/null' _ \
    "$dir/sampler.pid" "$SAMPLER" "$CGROUP" "$PIDS_OF" "$dir/server.csv" "$dir/sampler.txt"
  # The sampler writes its start facts first (the kernel log can take a moment), then the CSV header.
  while [ ! -s "$dir/server.csv" ]; do
    waited=$((waited + 1))
    [ "$waited" -le 150 ] || fail "the sampler wrote nothing in 15 s: $(cat "$dir/sampler.txt" 2>&1 || true)"
    sleep 0.1
  done
}

cmd_sample_stop() {
  local dir="$1" waited=0 pid
  [ -f "$dir/sampler.pid" ] || fail "no sampler was started for $dir"
  pid="$(cat "$dir/sampler.pid")"
  kill -TERM "$pid" 2>/dev/null || true
  while [ ! -s "$dir/server-end.txt" ] && kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 100 ]; do
    waited=$((waited + 1))
    sleep 0.1
  done
  if systemctl is-active --quiet "$UNIT"; then :; else : >"$dir/server-died.txt"; fi
  chmod a+r "$dir"/* 2>/dev/null || true
  [ -s "$dir/server.csv" ] || fail "no server.csv in $dir"
  echo "$dir: $(cd "$dir" && ls server*.csv server*.txt sampler.txt 2>/dev/null | paste -sd' ' -)"
}

cmd_facts() {
  local model nproc mem swap
  model="$(grep -m1 '^model name' "$CPUINFO" | cut -d: -f2- | sed 's/^ *//; s/["\\]//g')"
  nproc="$(grep -c '^processor' "$CPUINFO")"
  mem="$(awk '/^MemTotal:/ {print int($2 / 1024)}' "$MEMINFO")"
  swap="$(awk '/^SwapTotal:/ {print int($2 / 1024)}' "$MEMINFO")"
  printf '{"cpu_model":"%s","nproc":%s,"mem_total_mib":%s,"kernel":"%s","swap_mib":%s}\n' "${model:-unknown}" "$nproc" "$mem" "$(uname -r)" "${swap:-0}"
}

cmd_died() {
  if systemctl is-active --quiet "$UNIT"; then return 1; else return 0; fi
}

[ "$#" -ge 1 ] || usage
case "$1" in
  restart) [ "$#" -eq 1 ] || usage; cmd_restart ;;
  sample-start) [ "$#" -eq 2 ] || usage; cmd_sample_start "$2" ;;
  sample-stop) [ "$#" -eq 2 ] || usage; cmd_sample_stop "$2" ;;
  facts) [ "$#" -eq 1 ] || usage; cmd_facts ;;
  died) [ "$#" -eq 1 ] || usage; cmd_died ;;
  *) usage ;;
esac
