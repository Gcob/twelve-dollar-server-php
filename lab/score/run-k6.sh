#!/usr/bin/env bash
# One k6 run of the score search: restarts the server on a fresh database, starts the samplers, runs the challenge's own bench/load.js
# once, stops everything and writes <out>/run.json (lab/score/analyze.jq has its fields). lab/score/search.sh calls it for each run of the
# search; the k6-memory mode of lab/score/smoke.sh calls it too.
#
#   bash lab/score/run-k6.sh --base-url <url> --ctl <command> --out <run dir> --kind <warmup|probe|hold|memory> --users <n> --duration <d>
#                            [--ramp-up <d>] [--local-ips <list>] [--tokens <file>] [--challenge <dir>] [--api 127.0.0.1:6565] [--halves 1|2] [--load-cpus <lo-hi>]
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
# the sampler, called as `<command> <half dir> <half users> <duration>` (the run dir with one half), which writes rest.tsv, loadbox.csv, summary.json
# and k6.log in the folder and exits with k6's exit code. The controller's `loop` (the server's `loop:` line) is asked once after the restart and kept in
# server-loop.txt when it answers.
#
# --halves 2 splits the load in two k6 halves (default 1: the run is what phase 7 ran). Each half is a container of the same pinned k6 running the
# same bench/load.js with VUS set to half the users (the odd one goes to the first half), the same DURATION, its own half of --local-ips, its own
# REST API port (--api's, then the next one) and its own half of the load box's CPUs (a cpuset: --load-cpus is a range like 4-11, by default every CPU
# Docker sees, and the first half takes the first half of it, the extra CPU of an odd count included). Both start in the
# same second: each half is prepared (container, sampler), and all of them start at one agreed second a few seconds ahead. The load box's files of
# a half are in <out>/half-1 and <out>/half-2; run.json is the run's (lab/score/analyze.jq says how the halves are read and `halves` keeps each
# one's numbers). The run's k6 exit is 0 when both halves exit 0, 99 when one crossed a threshold, and the first other code otherwise (a harness error).
# The start of the second half is `start_half`: the one place that changes if the second half runs on another box.
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

usage() { echo "usage: lab/score/run-k6.sh --base-url <url> --ctl <command> --out <run dir> --kind <kind> --users <n> --duration <d> [--ramp-up <d>] [--local-ips <list>] [--tokens <file>] [--challenge <dir>] [--api <host:port>] [--halves 1|2] [--load-cpus <lo-hi>]" >&2; exit 2; }
refuse() { echo "run-k6: $*" >&2; exit 2; }

base_url="" ctl="" out="" kind="" users="" duration="" ramp_up="" local_ips="" tokens="" challenge="$REPO/reference/twelve-dollar-server-challenge" api=127.0.0.1:6565 halves=1 load_cpus=""
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
    --halves) halves="$2" ;;
    --load-cpus) load_cpus="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$base_url" ] && [ -n "$ctl" ] && [ -n "$out" ] && [ -n "$kind" ] && [ -n "$users" ] && [ -n "$duration" ] || usage
[[ "$users" =~ ^[0-9]+$ ]] || refuse "--users must be a whole number, got '$users'"
[[ "$halves" =~ ^[12]$ ]] || refuse "--halves is 1 or 2, got '$halves'"
[ "$halves" = 1 ] || [ "$users" -ge 2 ] || refuse "--halves 2 needs 2 users or more, got $users"
[ -z "$load_cpus" ] || [[ "$load_cpus" =~ ^[0-9]+-[0-9]+$ ]] || refuse "--load-cpus is a range like 4-11, got '$load_cpus'"
[[ "$api" =~ ^[^:]+:[0-9]+$ ]] || refuse "--api is <host>:<port>, got '$api'"
duration_s="$(score_seconds "$duration")" || refuse "--duration must be like 20s, 2m or 1h, got '$duration'"
read -r -a CTL <<<"$ctl"
[ "${#CTL[@]}" -gt 0 ] || usage
challenge="$(cd -P "$challenge" 2>/dev/null && pwd)" || refuse "no challenge folder: $challenge"
score_load_js_ok "$challenge/bench/load.js" || refuse "$challenge/bench/load.js is not the challenge's script (git blob $SCORE_LOAD_JS_BLOB at commit 162699a): it would not measure the challenge's test"
[ -n "$tokens" ] || [ -f "$challenge/seed/tokens.json" ] || [ -n "${SCORE_K6_COMMAND:-}" ] || refuse "no --tokens, and the challenge's folder has no seed/tokens.json"
[ -z "$tokens" ] || { tokens="$(cd -P "$(dirname "$tokens")" 2>/dev/null && pwd)/$(basename "$tokens")"; [ -f "$tokens" ] || refuse "no tokens file: $tokens"; }
mkdir -p "$out"
out="$(cd -P "$out" && pwd)"

healthy=0 layout=none
harness_error() {
  jq -n --arg kind "$kind" --argjson users "$users" --arg why "$1" '{kind: $kind, users: $users, harness_error: $why}' >"$out/run.json"
  echo "run-k6: $1" >&2
  exit 1
}

# --- the halves -----------------------------------------------------------------------------------------------------------------------
START_LEAD_S="${SCORE_START_LEAD_S:-5}"   # the second, this far ahead, at which every half starts: the time to create the containers and start the samplers (a test hook: lab/check.sh).

half_dir() { if [ "$halves" = 1 ]; then echo "$out"; else echo "$out/half-$1"; fi; }
half_users() { if [ "$halves" = 1 ]; then echo "$users"; elif [ "$1" = 1 ]; then echo $(((users + 1) / 2)); else echo $((users / 2)); fi; }
half_name() { if [ "$1" = 1 ]; then echo "$2"; else echo "$2-$1"; fi; }
half_api() { echo "${api%:*}:$((${api##*:} + $1 - 1))"; }

# half_ips <n>: the half's source addresses: --local-ips split in two, the first half taking the odd one. One address alone goes to both halves.
half_ips() {
  local list cnt first
  [ -n "$local_ips" ] || return 0
  IFS=, read -r -a list <<<"$local_ips"
  cnt="${#list[@]}"
  if [ "$halves" = 1 ] || [ "$cnt" -lt 2 ]; then echo "$local_ips"; return; fi
  first=$(((cnt + 1) / 2))
  if [ "$1" = 1 ]; then (IFS=,; echo "${list[*]:0:$first}"); else (IFS=,; echo "${list[*]:$first}"); fi
}

# half_cpus <n>: the half's cpuset: the load box's CPUs (load_lo to load_hi), the first half taking the extra one when the count is odd.
load_lo=0 load_hi=0
half_cpus() {
  local lo hi mid=$((load_lo + (load_hi - load_lo + 2) / 2))
  if [ "$1" = 1 ]; then lo=$load_lo hi=$((mid - 1)); else lo=$mid hi=$load_hi; fi
  if [ "$lo" = "$hi" ]; then echo "$lo"; else echo "$lo-$hi"; fi
}

# cgroup_of <container>: `<layout> <path under /sys/fs/cgroup>`, from `docker inspect` and the daemon's cgroup driver: Docker CE with the systemd
# driver has system.slice/docker-<id>.scope, Docker Desktop (cgroupfs) has docker/<id>.
cgroup_of() {
  local id parent
  id="$(docker inspect -f '{{.Id}}' "$1")"
  parent="$(docker inspect -f '{{.HostConfig.CgroupParent}}' "$1")"
  if [ "$(docker info --format '{{.CgroupDriver}}')" = systemd ]; then echo "systemd ${parent:-system.slice}/docker-$id.scope"
  else echo "cgroupfs ${parent:-docker}/$id"; fi
}

# k6_started_epoch <container>: the container's start as epoch seconds with a fraction, on the daemon's clock (the clock of the samplers).
k6_started_epoch() {
  docker inspect -f '{{.State.StartedAt}}' "$1" | jq -Rr '(sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) + ((capture("\\.(?<f>[0-9]+)Z$").f // "0") | "0." + . | tonumber)'
}

server_sampling=0
cleanup() {
  local n j
  # Why: the server box's sampler was started detached (setsid): a harness error or a signal after sample-start would leave it running there.
  if [ "$server_sampling" = 1 ]; then server_sampling=0; "${CTL[@]}" sample-stop "$out" >/dev/null 2>&1 || true; fi
  for n in $(seq 1 "$halves"); do touch "$(half_dir "$n")/.stop" 2>/dev/null || true; done
  docker rm -f "$(half_name 1 "$K6C")" "$(half_name 2 "$K6C")" "$(half_name 1 "$SAMPLER")" "$(half_name 2 "$SAMPLER")" >/dev/null 2>&1 || true
  for j in $(jobs -p); do kill "$j" 2>/dev/null || true; done
  for n in $(seq 1 "$halves"); do rm -f "$(half_dir "$n")/.stop"; done
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# native_sampler: 0 when the load box is this Linux host (its sampler runs here), 1 on a Mac (a helper container on the Docker VM's host network).
native_sampler() { [ "$(uname -s)" = Linux ] && [ -r /sys/fs/cgroup/cgroup.controllers ]; }

# wait_for_second <epoch>: returns at that second.
wait_for_second() { while [ "$(date +%s)" -lt "$1" ]; do sleep 0.05; done; }

# start_half <n> <go epoch>: half <n>'s k6 and the load box's sampler for it, started at the second <go> (so every half starts together). Runs in the
# background; leaves `.started` (epoch seconds with a fraction), `.layout` and the sampler's files in the half's folder, or `.error` and a non-zero
# status. With the test hook the hook runs here, to its end, and its exit code is in `.exit`.
# FIXME(pending): Q26 (plan.md) decides where the second half runs: one m5.8xlarge with two containers (A, coded) or a second m5.4xlarge started over SSH (B). Assumes A.
start_half() {
  local n="$1" go="$2" hd name sampler cg layout k6_args mounts create_args sampler_args ips hu
  hd="$(half_dir "$n")" name="$(half_name "$n" "$K6C")" sampler="$(half_name "$n" "$SAMPLER")" hu="$(half_users "$n")"
  mkdir -p "$hd"
  if [ -n "${SCORE_K6_COMMAND:-}" ]; then
    local hook rc=0
    read -r -a hook <<<"$SCORE_K6_COMMAND"
    wait_for_second "$go"
    "${hook[@]}" "$hd" "$hu" "$duration" || rc=$?
    echo "$rc" >"$hd/.exit"
    return 0
  fi
  k6_args=(run -e "BASE_URL=$base_url" -e "VUS=$hu" -e "DURATION=$duration")
  [ -z "$ramp_up" ] || k6_args+=(-e "RAMP_UP=$ramp_up")
  mounts=(-v "$challenge:/challenge:ro" -v "$hd:/out")
  [ -z "$tokens" ] || { mounts+=(-v "$tokens:/tokens.json:ro"); k6_args+=(-e TOKENS=/tokens.json); }
  ips="$(half_ips "$n")"
  [ -z "$ips" ] || k6_args+=(--local-ips "$ips")
  k6_args+=(--summary-export /out/summary.json --address "$(half_api "$n")" --no-color --quiet /challenge/bench/load.js)
  docker rm -f "$name" "$sampler" >/dev/null 2>&1 || true
  rm -f "$hd/.stop" "$hd/.sampler-rc"
  create_args=(--name "$name" --network host --ulimit nofile=1048576:1048576 --user "$(id -u):$(id -g)")
  [ "$halves" = 1 ] || create_args+=(--cpuset-cpus "$(half_cpus "$n")")
  docker create "${create_args[@]}" "${mounts[@]}" -e K6_NO_USAGE_REPORT=true "$LAB_K6_IMAGE" "${k6_args[@]}" >/dev/null || { echo "docker create of k6 (half $n) failed" >"$hd/.error"; return 1; }
  read -r layout cg <<<"$(cgroup_of "$name")"
  echo "$layout" >"$hd/.layout"
  sampler_args=(--api "$(half_api "$n")" --cgroup "$cg")
  [ "$halves" = 1 ] || sampler_args+=(--cpus "$(half_cpus "$n")" --mem-share 2)
  if native_sampler; then
    (bash "$LAB/score/loadbox-sample.sh" "${sampler_args[@]}" --dir "$hd" --stop-file "$hd/.stop"; echo $? >"$hd/.sampler-rc") &
  else
    docker run -d --name "$sampler" --network host --pid host --cgroupns host -v "$LAB:/lab:ro" -v "$hd:/out" "$LAB_TOOLS_IMAGE" \
      bash /lab/score/loadbox-sample.sh "${sampler_args[@]}" --dir /out --stop-file /out/.stop >/dev/null || { echo "the load box's sampler (half $n) did not start" >"$hd/.error"; return 1; }
  fi
  wait_for_second "$go"
  docker start "$name" >/dev/null || { echo "docker start of k6 (half $n) failed" >"$hd/.error"; return 1; }
  k6_started_epoch "$name" >"$hd/.started"
}

# wait_half <n>: until half <n>'s k6 is over, then its sampler is stopped and its log and exit code are in its folder.
wait_half() {
  local n="$1" hd name sampler tries=0
  hd="$(half_dir "$n")" name="$(half_name "$n" "$K6C")" sampler="$(half_name "$n" "$SAMPLER")"
  [ -z "${SCORE_K6_COMMAND:-}" ] || return 0
  docker wait "$name" >"$hd/.exit"
  touch "$hd/.stop"
  if native_sampler; then
    while [ ! -f "$hd/.sampler-rc" ] && [ "$tries" -lt 150 ]; do tries=$((tries + 1)); sleep 0.1; done
    [ "$(cat "$hd/.sampler-rc" 2>/dev/null || echo 1)" = 0 ] || harness_error "the load box's sampler (half $n) failed"
  else
    docker wait "$sampler" >/dev/null
  fi
  docker logs "$name" >"$hd/k6.log" 2>&1 || true
  docker rm -f "$name" "$sampler" >/dev/null 2>&1 || true
}

# --- the run --------------------------------------------------------------------------------------------------------------------------
healthy="$("${CTL[@]}" restart | tail -n 1)" || harness_error "restart failed"
[[ "$healthy" =~ ^[0-9]+$ ]] || harness_error "restart printed '$healthy' as its last line, expected the healthy seconds"
{ "${CTL[@]}" loop 2>/dev/null || true; } | tail -n 1 >"$out/server-loop.txt"
server_sampling=1
"${CTL[@]}" sample-start "$out" || harness_error "sample-start failed"

if [ -z "${SCORE_K6_COMMAND:-}" ]; then
  lab_ensure_tools_image
  if [ "$halves" = 2 ]; then
    if [ -n "$load_cpus" ]; then load_lo="${load_cpus%-*}" load_hi="${load_cpus#*-}"
    else load_lo=0 load_hi=$(($(docker info --format '{{.NCPU}}') - 1)); fi
    [ "$load_hi" -gt "$load_lo" ] || harness_error "--halves 2 needs 2 load CPUs or more, got $load_lo-$load_hi"
  fi
fi
go="$(date +%s)"
[ "$halves" = 1 ] || go=$((go + START_LEAD_S))
pids=()
for n in $(seq 1 "$halves"); do
  start_half "$n" "$go" &
  pids+=("$!")
done
for n in $(seq 1 "$halves"); do
  wait "${pids[$((n - 1))]}" || harness_error "$(cat "$(half_dir "$n")/.error" 2>/dev/null || echo "half $n did not start")"
done
for n in $(seq 1 "$halves"); do wait_half "$n"; done

server_sampling=0
"${CTL[@]}" sample-stop "$out" || harness_error "sample-stop failed"

# The run's k6 exit: 0 when every half exited 0; else the first code that is not a threshold failure (a harness error), else 99.
k6_exit=0 half_exits=() half_started=()
for n in $(seq 1 "$halves"); do
  hd="$(half_dir "$n")"
  half_exits+=("$(cat "$hd/.exit" 2>/dev/null || echo 1)")
  half_started+=("$(cat "$hd/.started" 2>/dev/null || echo null)")
  layout="$(cat "$hd/.layout" 2>/dev/null || echo "$layout")"
done
for e in "${half_exits[@]}"; do
  if [ "$e" != 0 ] && [ "$e" != 99 ]; then k6_exit="$e"; break; fi
  [ "$e" = 0 ] || k6_exit=99
done
started="${half_started[0]}"
[ "$started" != null ] || started=-
halves_json=null
if [ "$halves" = 2 ]; then
  halves_json="$(jq -nc --argjson u "[$(half_users 1), $(half_users 2)]" --argjson e "[$(IFS=,; echo "${half_exits[*]}")]" --argjson s "[$(IFS=,; echo "${half_started[*]}")]" \
    '{users: $u, exits: $e, started: $s, skew_s: (if $s[0] == null or $s[1] == null then null else (($s[1] - $s[0]) | fabs) end)}')"
fi
score_run_json "$out" "$kind" "$users" "$duration_s" "$k6_exit" "$healthy" "$started" "$layout" "$halves_json" >"$out/run.json.tmp" || harness_error "the analysis of the run's samples failed"
mv "$out/run.json.tmp" "$out/run.json"
