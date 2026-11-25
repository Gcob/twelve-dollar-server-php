#!/usr/bin/env bash
# The smoke's server controller (the interface lab/score/search.sh and run-k6.sh drive; on AWS it is lab/score/server-ctl.sh behind ssh, through lab/score/ctl-ssh.sh):
# runs submissions/php-Gcob/server.php in a lab container, on a fresh copy of the seed, the way lab/challenge-test.sh starts the app.
#
#   bash lab/score/ctl-local.sh restart              fresh seed copy, start, wait for GET /health (60 s at most), print the healthy seconds
#   bash lab/score/ctl-local.sh sample-start <dir>   start lab/score/server-sample.sh inside the server container
#   bash lab/score/ctl-local.sh sample-stop <dir>    stop it and leave server.csv, server-start.txt, server-end.txt (and sampler.txt) in <dir>;
#                                                    server-died.txt too when the container was not running
#   bash lab/score/ctl-local.sh facts                one JSON object: cpu_model, nproc, mem_total_mib, kernel, swap_mib (Docker's VM here)
#
# Environment: SCORE_CTL_PORT (18130), SCORE_CTL_STATE (a folder for the restart counter, default under TMPDIR), SCORE_CTL_IMAGE (8.5),
# SCORE_CTL_FAIL_RESTARTS (a list like "4,5": the server is stopped 3 s after the sampler starts, on those restarts counted from the
# folder's first one, so k6 fails on errors: the smoke's way to make a probe and a hold fail). The server container has 1 CPU, 2 GiB and 65,535 open files
# (lab/lib.sh), the three extensions the submission loads, and the lab's PHP flags.
set -euo pipefail

LAB="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib.sh
source "$LAB/lib.sh"

NAME=lab-score-server
PORT="${SCORE_CTL_PORT:-18130}"
IMAGE="${SCORE_CTL_IMAGE:-8.5}"
STATE="${SCORE_CTL_STATE:-${TMPDIR:-/tmp}/lab-score-ctl}"

usage() { echo "usage: lab/score/ctl-local.sh restart | sample-start <dir> | sample-stop <dir> | facts" >&2; exit 2; }
fail() { echo "ctl-local: $*" >&2; exit 1; }

healthy() { docker exec "$NAME" curl -sf -m 2 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; }

cmd_restart() {
  local n=0 began now ready=""
  mkdir -p "$STATE"
  [ ! -f "$STATE/restarts" ] || n="$(cat "$STATE/restarts")"
  n=$((n + 1))
  echo "$n" >"$STATE/restarts"
  docker rm -f "$NAME" >/dev/null 2>&1 || true
  # Why disable SC2034: lab_build_php_flags (lib.sh) reads these two arrays.
  # shellcheck disable=SC2034
  LAB_EXT=(pcntl sockets event) LAB_ENV=()
  lab_build_php_flags
  began="$(date +%s)"
  lab_start_app "$NAME" "$IMAGE" "$PORT" /submissions/php-Gcob/server.php
  for _ in $(seq 1 120); do
    [ "$(docker inspect -f '{{.State.Running}}' "$NAME")" = true ] || { docker logs "$NAME" >&2 || true; fail "the server container exited"; }
    if healthy; then ready=1; break; fi
    sleep 0.5
  done
  [ -n "$ready" ] || fail "GET /health did not answer within 60 s"
  now="$(date +%s)"
  rm -f "$STATE/fail-pending"
  case ",${SCORE_CTL_FAIL_RESTARTS:-}," in *",$n,"*) : >"$STATE/fail-pending" ;; esac
  echo $((now - began))
}

cmd_sample_start() {
  [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ] || fail "the server container is not running"
  docker exec -d "$NAME" bash -c 'mkdir -p /tmp/score; echo $$ >/tmp/score/pid; exec bash /lab/score/server-sample.sh --cgroup /sys/fs/cgroup --pids-of server.php --out /tmp/score/server.csv >/tmp/score/sampler.txt 2>&1'
  for _ in $(seq 1 50); do
    if docker exec "$NAME" test -s /tmp/score/server.csv 2>/dev/null; then
      # The forced failure: the sampler has started, so the run has its rows up to the stop; k6 then gets refused connections.
      if [ -f "$STATE/fail-pending" ]; then
        sleep 3
        docker stop -t 1 "$NAME" >/dev/null
        echo "ctl-local: the server is stopped on purpose" >&2
      fi
      return 0
    fi
    sleep 0.2
  done
  fail "the sampler wrote nothing: $(docker exec "$NAME" cat /tmp/score/sampler.txt 2>&1 || true)"
}

cmd_sample_stop() {
  local dir="$1" f
  mkdir -p "$dir"
  if [ "$(docker inspect -f '{{.State.Running}}' "$NAME" 2>/dev/null)" = true ]; then
    docker exec "$NAME" bash -c 'kill -TERM "$(cat /tmp/score/pid)"' || true
    for _ in $(seq 1 50); do
      docker exec "$NAME" test -s /tmp/score/server-end.txt 2>/dev/null && break
      sleep 0.2
    done
  else
    : >"$dir/server-died.txt"
  fi
  for f in server.csv server-start.txt server-end.txt sampler.txt; do
    docker cp "$NAME:/tmp/score/$f" "$dir/$f" >/dev/null 2>&1 || true
  done
  [ -f "$dir/server.csv" ] || fail "no server.csv in the container"
}

cmd_facts() {
  local out model nproc mem swap kernel
  out="$(docker run --rm --network none "$LAB_IMAGE:$IMAGE" bash -c '
    m="$(grep -m1 "model name" /proc/cpuinfo | cut -d: -f2- | sed "s/^ *//")"
    echo "${m:-unknown}"; getconf _NPROCESSORS_ONLN
    awk "/MemTotal/ {print int(\$2 / 1024)} " /proc/meminfo; awk "/SwapTotal/ {print int(\$2 / 1024)}" /proc/meminfo; uname -r')"
  { read -r model; read -r nproc; read -r mem; read -r swap; read -r kernel; } <<<"$out"
  jq -nc --arg m "$model" --argjson n "$nproc" --argjson mem "$mem" --argjson s "$swap" --arg k "$kernel" \
    '{cpu_model: $m, nproc: $n, mem_total_mib: $mem, kernel: $k, swap_mib: $s}'
}

[ "$#" -ge 1 ] || usage
case "$1" in
  restart) [ "$#" -eq 1 ] || usage; cmd_restart ;;
  sample-start) [ "$#" -eq 2 ] || usage; cmd_sample_start "$2" ;;
  sample-stop) [ "$#" -eq 2 ] || usage; cmd_sample_stop "$2" ;;
  facts) [ "$#" -eq 1 ] || usage; cmd_facts ;;
  *) usage ;;
esac
