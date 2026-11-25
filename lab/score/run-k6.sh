#!/usr/bin/env bash
# One k6 run of the score search: restarts the server on a fresh database, starts the samplers, runs the challenge's own bench/load.js
# once, stops everything and writes <out>/run.json (lab/score/analyze.jq has its fields). lab/score/search.sh calls it for each run of the
# search; the k6-memory mode of lab/score/smoke.sh calls it too.
#
#   bash lab/score/run-k6.sh --base-url <url> --ctl <command> --out <run dir> --kind <warmup|probe|hold|memory> --users <n> --duration <d>
#                            [--ramp-up <d>] [--local-ips <list>] [--tokens <file>] [--challenge <dir>] [--api 127.0.0.1:6565]
#
# <ctl> is a command line, split on spaces and tabs (nothing is evaluated, no quote is read): `ssh host sudo /srv/score/server-ctl.sh`
# works, a path with a space does not. It answers `restart`, `sample-start <dir>`, `sample-stop <dir>` and `facts` (see lab/score/ctl-local.sh).
#
# k6 runs in the lab's pinned image (LAB_K6_IMAGE) on the host network with 1,048,576 open files, the challenge's folder mounted read-only,
# as the invoking user (so --summary-export can write into the run folder on a native Linux host, where the image's own uid could not).
# The script gets only BASE_URL, VUS, DURATION, TOKENS (the tokens file: the bench's default path is not where the lab keeps it) and,
# with --ramp-up, RAMP_UP (the local smoke only); k6 gets --local-ips (when given), --summary-export, --address, --no-color, --quiet.
# The load box's sampler (lab/score/loadbox-sample.sh) runs natively on a Linux host, in a helper container on the Docker VM's host network
# on a Mac (the VM is the load box there). SCORE_K6_COMMAND is a test hook (lab/check.sh): a command that stands in for the container and
# the sampler, called as `<command> <run dir> <users> <duration>`, which writes rest.tsv, loadbox.csv, summary.json and k6.log in the run folder
# and exits with k6's exit code.
#
# Exit codes: 0 the run is over and run.json is written (a failing k6 is a result: look at k6_exit); 1 a harness failure (the restart, a
# sampler, a container), with run.json holding `harness_error`; 2 usage, or a bench/load.js that is not the challenge's.
set -euo pipefail

LAB="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(dirname "$LAB")"
# shellcheck source=../lib.sh
source "$LAB/lib.sh"
# shellcheck source=score-lib.sh
source "$LAB/score/score-lib.sh"

K6C=lab-score-k6
SAMPLER=lab-score-loadbox

usage() { echo "usage: lab/score/run-k6.sh --base-url <url> --ctl <command> --out <run dir> --kind <kind> --users <n> --duration <d> [--ramp-up <d>] [--local-ips <list>] [--tokens <file>] [--challenge <dir>] [--api <host:port>]" >&2; exit 2; }
refuse() { echo "run-k6: $*" >&2; exit 2; }

base_url="" ctl="" out="" kind="" users="" duration="" ramp_up="" local_ips="" tokens="" challenge="$REPO/reference/twelve-dollar-server-challenge" api=127.0.0.1:6565
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --base-url) base_url="$2" ;;
    --ctl) ctl="$2" ;;
    --out) out="$2" ;;
    --kind) kind="$2" ;;
    --users) users="$2" ;;
    --duration) duration="$2" ;;
    --ramp-up) ramp_up="$2" ;;
    --local-ips) local_ips="$2" ;;
    --tokens) tokens="$2" ;;
    --challenge) challenge="$2" ;;
    --api) api="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$base_url" ] && [ -n "$ctl" ] && [ -n "$out" ] && [ -n "$kind" ] && [ -n "$users" ] && [ -n "$duration" ] || usage
[[ "$users" =~ ^[0-9]+$ ]] || refuse "--users must be a whole number, got '$users'"
duration_s="$(score_seconds "$duration")" || refuse "--duration must be like 20s, 2m or 1h, got '$duration'"
read -r -a CTL <<<"$ctl"
[ "${#CTL[@]}" -gt 0 ] || usage
challenge="$(cd -P "$challenge" 2>/dev/null && pwd)" || refuse "no challenge folder: $challenge"
score_load_js_ok "$challenge/bench/load.js" || refuse "$challenge/bench/load.js is not the challenge's script (git blob $SCORE_LOAD_JS_BLOB at commit 162699a): it would not measure the challenge's test"
[ -n "$tokens" ] || [ -f "$challenge/seed/tokens.json" ] || [ -n "${SCORE_K6_COMMAND:-}" ] || refuse "no --tokens, and the challenge's folder has no seed/tokens.json"
[ -z "$tokens" ] || { tokens="$(cd -P "$(dirname "$tokens")" 2>/dev/null && pwd)/$(basename "$tokens")"; [ -f "$tokens" ] || refuse "no tokens file: $tokens"; }
mkdir -p "$out"
out="$(cd -P "$out" && pwd)"

started=- healthy=0 layout=none
harness_error() {
  jq -n --arg kind "$kind" --argjson users "$users" --arg why "$1" '{kind: $kind, users: $users, harness_error: $why}' >"$out/run.json"
  echo "run-k6: $1" >&2
  exit 1
}

sampler_pid="" server_sampling=0
cleanup() {
  # Why: the server box's sampler was started detached (setsid): a harness error or a signal after sample-start would leave it running there.
  if [ "$server_sampling" = 1 ]; then server_sampling=0; "${CTL[@]}" sample-stop "$out" >/dev/null 2>&1 || true; fi
  touch "$out/.stop"
  docker rm -f "$K6C" "$SAMPLER" >/dev/null 2>&1 || true
  [ -z "$sampler_pid" ] || kill "$sampler_pid" 2>/dev/null || true
  rm -f "$out/.stop"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# set_cgroup <container>: sets `cg` (the container's cgroup under /sys/fs/cgroup) and `layout` (systemd or cgroupfs, what the run's JSON
# says was read), from `docker inspect` and the daemon's cgroup driver: Docker CE with the systemd driver has system.slice/docker-<id>.scope,
# Docker Desktop (cgroupfs) has docker/<id>.
cg=""
set_cgroup() {
  local id parent
  id="$(docker inspect -f '{{.Id}}' "$1")"
  parent="$(docker inspect -f '{{.HostConfig.CgroupParent}}' "$1")"
  if [ "$(docker info --format '{{.CgroupDriver}}')" = systemd ]; then
    layout=systemd
    cg="${parent:-system.slice}/docker-$id.scope"
  else
    layout=cgroupfs
    cg="${parent:-docker}/$id"
  fi
}

# k6_started_epoch <container>: the container's start as epoch seconds with a fraction, on the daemon's clock (the clock of the samplers).
k6_started_epoch() {
  docker inspect -f '{{.State.StartedAt}}' "$1" | jq -Rr '(sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) + ((capture("\\.(?<f>[0-9]+)Z$").f // "0") | "0." + . | tonumber)'
}

healthy="$("${CTL[@]}" restart | tail -n 1)" || harness_error "restart failed"
[[ "$healthy" =~ ^[0-9]+$ ]] || harness_error "restart printed '$healthy' as its last line, expected the healthy seconds"
server_sampling=1
"${CTL[@]}" sample-start "$out" || harness_error "sample-start failed"

k6_exit=0
if [ -n "${SCORE_K6_COMMAND:-}" ]; then
  read -r -a hook <<<"$SCORE_K6_COMMAND"
  "${hook[@]}" "$out" "$users" "$duration" || k6_exit=$?
else
  lab_ensure_tools_image
  k6_args=(run -e "BASE_URL=$base_url" -e "VUS=$users" -e "DURATION=$duration")
  [ -z "$ramp_up" ] || k6_args+=(-e "RAMP_UP=$ramp_up")
  mounts=(-v "$challenge:/challenge:ro" -v "$out:/out")
  [ -z "$tokens" ] || { mounts+=(-v "$tokens:/tokens.json:ro"); k6_args+=(-e TOKENS=/tokens.json); }
  [ -z "$local_ips" ] || k6_args+=(--local-ips "$local_ips")
  k6_args+=(--summary-export /out/summary.json --address "$api" --no-color --quiet /challenge/bench/load.js)
  docker rm -f "$K6C" "$SAMPLER" >/dev/null 2>&1 || true
  rm -f "$out/.stop"
  docker create --name "$K6C" --network host --ulimit nofile=1048576:1048576 --user "$(id -u):$(id -g)" "${mounts[@]}" \
    -e K6_NO_USAGE_REPORT=true "$LAB_K6_IMAGE" "${k6_args[@]}" >/dev/null || harness_error "docker create of k6 failed"
  set_cgroup "$K6C"
  sampler_args=(--api "$api" --cgroup "$cg")
  if [ "$(uname -s)" = Linux ] && [ -r /sys/fs/cgroup/cgroup.controllers ]; then
    bash "$LAB/score/loadbox-sample.sh" "${sampler_args[@]}" --dir "$out" --stop-file "$out/.stop" &
    sampler_pid=$!
  else
    docker run -d --name "$SAMPLER" --network host --pid host --cgroupns host -v "$LAB:/lab:ro" -v "$out:/out" "$LAB_TOOLS_IMAGE" \
      bash /lab/score/loadbox-sample.sh "${sampler_args[@]}" --dir /out --stop-file /out/.stop >/dev/null || harness_error "the load box's sampler did not start"
  fi
  docker start "$K6C" >/dev/null || harness_error "docker start of k6 failed"
  started="$(k6_started_epoch "$K6C")"
  k6_exit="$(docker wait "$K6C")"
  touch "$out/.stop"
  if [ -n "$sampler_pid" ]; then wait "$sampler_pid" || harness_error "the load box's sampler failed"; sampler_pid=""; else docker wait "$SAMPLER" >/dev/null; fi
  docker logs "$K6C" >"$out/k6.log" 2>&1 || true
  docker rm -f "$K6C" "$SAMPLER" >/dev/null 2>&1 || true
fi

server_sampling=0
"${CTL[@]}" sample-stop "$out" || harness_error "sample-stop failed"
score_run_json "$out" "$kind" "$users" "$duration_s" "$k6_exit" "$healthy" "$started" "$layout" >"$out/run.json.tmp" || harness_error "the analysis of the run's samples failed"
mv "$out/run.json.tmp" "$out/run.json"
