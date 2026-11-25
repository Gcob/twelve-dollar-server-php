#!/usr/bin/env bash
# Arjay's score search, driven from the load box: finds the highest user count that passes the challenge's own bench/load.js for 5 minutes.
# One k6 run at a time (lab/score/run-k6.sh), the server restarted on a fresh database before every one, the server and the load box sampled.
#
#   bash lab/score/search.sh --base-url <url> --ctl <command> --out <dir> [--start 71000] [--step 5] [--probe 2m] [--hold 5m]
#                            [--warmup 1000,2m] [--max-holds 6] [--max-probes 20] [--round 1000] [--pause 60] [--local-ips <list>]
#                            [--ramp-up <duration>] [--tokens <file>] [--challenge <dir>] [--api <host:port>]
#
# The search (the user's choice; the arithmetic is lab/score/score-lib.sh): a warm-up at --warmup (users,duration; not scored, and a warm-up
# that fails stops the search: the box is not ready), then probes of --probe from --start, each next one --step % up rounded to the nearest
# --round, until one fails; then holds of --hold starting at the highest passing probe (5 % under the first probe when that one failed),
# each next one --step % under the last, until one passes (the score) or --max-holds have failed ("no hold passed down to N"). --max-probes
# caps the climb: when that many probes passed, the holds start at the highest of them. --pause seconds between two k6 runs (default 60).
# k6's exit code decides: 0 passes, 99 fails (a threshold crossed), anything else is a harness error: the search stops. A run that FAILS is void when
# the load box was over 85 % CPU on more than 10 % of the plateau's seconds or on 5 in a row (k6's garbage collector alone spikes a second or two) or k6 held over 90 % of the load box's memory (k6 may have caused the failure; a run that passes anyway is a valid pass, its GC spikes could only hurt the latency).
# A void run is neither a pass nor a fail. A void PROBE ends the climb (the holds start at the highest passing probe, as after a fail) and the
# end says `bound_by_k6: true`: the load box, not the server, may have been the limit. A void HOLD runs again once, at the same size; void
# again, it counts as not passed and the next hold steps down. The rerun of a void probe is not the driver's: a person looks at it first
# (a bigger load box, say). A search that ends with no passing hold says so (`end.result` no-score). --ramp-up exists for the smoke only (it passes -e RAMP_UP); without it the script's own 60 s stands.
#
# <ctl> is a command line, split on spaces and tabs (see lab/score/run-k6.sh): `ssh host sudo /srv/score/server-ctl.sh`. It answers `facts`
# (one JSON object), `restart`, `sample-start <dir>` and `sample-stop <dir>`.
#
# It refuses to start (exit 2, a message, nothing run) when the challenge's bench/load.js is not the reference's (git blob hash), when
# `<ctl> facts` fails, or when --out exists. It writes <dir>/search.json (the facts, the arguments, every k6 run in order with its folder,
# every decision with its reason, and the end: the score or why there is none) and one folder a run, with its run.json. It prints one row a run
# (cpu% is the service's share of one core over the plateau; acc/s the median accepts a second on it).
# search.json keeps the arguments but not the server's address or the controller's command line (a results folder is public).
# Exit codes: 0 the search ended on a result (a score or no score: `end.result` says which, and `end.bound_by_k6` whether a void run touched the search), 1 a harness error, 2 usage or refusal.
set -euo pipefail

LAB="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(dirname "$LAB")"
# shellcheck source=score-lib.sh
source "$LAB/score/score-lib.sh"

usage() {
  echo "usage: lab/score/search.sh --base-url <url> --ctl <command> --out <dir> [--start 71000] [--step 5] [--probe 2m] [--hold 5m] [--warmup 1000,2m] [--max-holds 6] [--max-probes 20] [--round 1000] [--pause 60] [--local-ips <list>] [--ramp-up <d>] [--tokens <file>] [--challenge <dir>] [--api <host:port>]" >&2
  exit 2
}
refuse() { echo "search: $*" >&2; exit 2; }

base_url="" ctl="" out="" start=71000 step=5 probe=2m hold=5m warmup=1000,2m max_holds=6 max_probes=20 round=1000 pause=60
local_ips="" ramp_up="" tokens="" challenge="$REPO/reference/twelve-dollar-server-challenge" api=127.0.0.1:6565
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --base-url) base_url="$2" ;;
    --ctl) ctl="$2" ;;
    --out) out="$2" ;;
    --start) start="$2" ;;
    --step) step="$2" ;;
    --probe) probe="$2" ;;
    --hold) hold="$2" ;;
    --warmup) warmup="$2" ;;
    --max-holds) max_holds="$2" ;;
    --max-probes) max_probes="$2" ;;
    --round) round="$2" ;;
    --pause) pause="$2" ;;
    --local-ips) local_ips="$2" ;;
    --ramp-up) ramp_up="$2" ;;
    --tokens) tokens="$2" ;;
    --challenge) challenge="$2" ;;
    --api) api="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$base_url" ] && [ -n "$ctl" ] && [ -n "$out" ] || usage
for v in "$start" "$step" "$max_holds" "$max_probes" "$round" "$pause"; do
  [[ "$v" =~ ^[0-9]+$ ]] || refuse "a number is expected, got '$v'"
done
[ "$step" -gt 0 ] && [ "$step" -lt 100 ] && [ "$round" -gt 0 ] && [ "$start" -gt 0 ] && [ "$max_holds" -gt 0 ] && [ "$max_probes" -gt 0 ] || refuse "--step is 1 to 99, and --start, --round, --max-holds and --max-probes are above 0"
[[ "$warmup" =~ ^[0-9]+,[0-9smh]+$ ]] || refuse "--warmup is <users>,<duration> (1000,2m), got '$warmup'"
warm_users="${warmup%%,*}" warm_duration="${warmup#*,}"
for d in "$probe" "$hold" "$warm_duration"; do score_seconds "$d" >/dev/null || refuse "a duration like 20s or 2m is expected, got '$d'"; done
read -r -a CTL <<<"$ctl"
[ "${#CTL[@]}" -gt 0 ] || usage

# The refusals, before anything runs.
challenge="$(cd -P "$challenge" 2>/dev/null && pwd)" || refuse "no challenge folder: $challenge"
score_load_js_ok "$challenge/bench/load.js" || refuse "$challenge/bench/load.js is not the challenge's script (git blob $SCORE_LOAD_JS_BLOB at commit 162699a): nothing was run"
[ ! -e "$out" ] || refuse "$out exists: pick a new folder, a search never overwrites one"
facts="$("${CTL[@]}" facts)" && jq -e 'type == "object"' <<<"$facts" >/dev/null 2>&1 || refuse "'$ctl facts' did not print one JSON object: nothing was run"
mkdir -p "$out"
out="$(cd -P "$out" && pwd)"

# --- search.json ---------------------------------------------------------------------------------------------------------------------
sj_update() { jq "$@" "$out/search.json" >"$out/search.json.tmp" && mv "$out/search.json.tmp" "$out/search.json"; }
jq -n --argjson facts "$facts" --arg url "$(sed -E 's#^([a-z]+://)[^:/]+#\1<server>#' <<<"$base_url")" --arg ctl "${CTL[0]} ..." \
  --argjson start "$start" --argjson step "$step" --arg probe "$probe" --arg hold "$hold" --arg warmup "$warmup" --argjson max_holds "$max_holds" \
  --argjson max_probes "$max_probes" --argjson round "$round" --argjson pause "$pause" --arg ramp_up "$ramp_up" --arg local_ips "$local_ips" \
  '{facts: $facts,
    arguments: {base_url: $url, ctl: $ctl, start: $start, step_percent: $step, probe: $probe, hold: $hold, warmup: $warmup, max_holds: $max_holds,
                max_probes: $max_probes, round: $round, pause_s: $pause, ramp_up: (if $ramp_up == "" then null else $ramp_up end),
                local_ips: (if $local_ips == "" then null else $local_ips end)},
    runs: [], decisions: [], end: null}' >"$out/search.json"

decide() {
  echo "  -> $1 ($2)"
  sj_update --arg d "$1" --arg r "$2" '.decisions += [{decision: $d, reason: $r}]'
}

bound_by_k6=false
finish() {  # finish <result> <score or null> <reason> <exit code>
  sj_update --arg result "$1" --argjson score "$2" --arg reason "$3" --argjson bound "$bound_by_k6" '.end = {result: $result, score: $score, reason: $reason, bound_by_k6: $bound}'
  echo "end: $3"
  exit "$4"
}

# --- one run -------------------------------------------------------------------------------------------------------------------------
run_no=0
echo "kind     users  pass  p95 ms  p99 ms  errors   req/s   cpu%   us/req  acc/s  wall"
# run_one <kind> <users> <duration>: runs k6 once and sets R_PASS, R_VOID, R_EXIT, R_FOLDER from its run.json; prints the row.
run_one() {
  local kind="$1" users="$2" duration="$3" rc=0 extra=()
  run_no=$((run_no + 1))
  R_FOLDER="$(printf '%02d-%s-%s' "$run_no" "$kind" "$users")"
  [ "$run_no" -eq 1 ] || sleep "$pause"
  [ -z "$ramp_up" ] || extra+=(--ramp-up "$ramp_up")
  [ -z "$local_ips" ] || extra+=(--local-ips "$local_ips")
  [ -z "$tokens" ] || extra+=(--tokens "$tokens")
  bash "$LAB/score/run-k6.sh" --base-url "$base_url" --ctl "$ctl" --out "$out/$R_FOLDER" --kind "$kind" --users "$users" --duration "$duration" \
    --challenge "$challenge" --api "$api" ${extra[@]+"${extra[@]}"} || rc=$?
  if [ "$rc" -ne 0 ]; then
    sj_update --arg f "$R_FOLDER" --arg k "$kind" --argjson u "$users" '.runs += [{folder: $f, kind: $k, users: $u, k6_exit: null, pass: null, void: null}]'
    finish harness-error null "the harness failed at $R_FOLDER: $(jq -r '.harness_error // "run-k6 exited \($rc)"' --argjson rc "$rc" "$out/$R_FOLDER/run.json" 2>/dev/null || echo "run-k6 exited $rc")" 1
  fi
  R_PASS="$(jq -r '.pass' "$out/$R_FOLDER/run.json")" R_VOID="$(jq -r '.void' "$out/$R_FOLDER/run.json")" R_EXIT="$(jq -r '.k6_exit' "$out/$R_FOLDER/run.json")"
  sj_update --arg f "$R_FOLDER" --slurpfile r "$out/$R_FOLDER/run.json" \
    '.runs += [$r[0] | {folder: $f, kind, users, k6_exit, pass, void, wall}]'
  jq -r '[.kind, .users, .pass, (.p95_ms // 0 | . * 10 | round / 10), (.p99_ms // 0 | . * 10 | round / 10), (.error_rate // 0 | . * 10000 | round / 10000),
          (.plateau.req_per_s // 0 | round), ((.server.service_share // 0) * 1000 | round / 10), (.server.us_per_req // 0 | round),
          (.server.accepts_per_s_median // 0 | round), (.wall // "-")] | @tsv' "$out/$R_FOLDER/run.json" \
    | awk -F'\t' '{ printf "%-8s %5d  %-5s %7s %7s %7s %7d %6.1f %7d %6d  %s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11 }'
  if [ "$R_EXIT" != 0 ] && [ "$R_EXIT" != 99 ]; then
    finish harness-error null "k6 exited with $R_EXIT at $R_FOLDER: not a pass and not a threshold failure" 1
  fi
  return 0
}

void_reason() { jq -r '.void_reason' "$out/$R_FOLDER/run.json"; }

# --- the search ---------------------------------------------------------------------------------------------------------------------
decide "warm-up at $warm_users users for $warm_duration" "not scored; a failing warm-up is a harness error"
run_one warmup "$warm_users" "$warm_duration"
if [ "$R_PASS" != true ]; then
  finish harness-error null "the warm-up failed at $R_FOLDER (k6 exit $R_EXIT): the server is not ready, there is nothing to measure" 1
fi

users="$start" probes=0 last_pass=""
while true; do
  decide "probe at $users users for $probe" "$([ -z "$last_pass" ] && echo "the start" || echo "$step % up from $last_pass, rounded to $round")"
  run_one probe "$users" "$probe"
  if [ "$R_PASS" = true ]; then
    last_pass="$users"
    probes=$((probes + 1))
    if [ "$probes" -ge "$max_probes" ]; then
      decide "holds start at $last_pass" "$probes probes passed, the --max-probes cap"
      break
    fi
    users="$(score_next_up "$users" "$step" "$round")"
  else
    if [ "$R_VOID" = true ]; then
      bound_by_k6=true
      decide "the climb ends at $users users" "the probe is void ($(void_reason)): neither a pass nor a fail; the holds start at the highest passing probe"
    fi
    break
  fi
done

if [ -n "$last_pass" ]; then hold_users="$last_pass"; hold_why="the highest passing probe"
else hold_users="$(score_next_down "$start" "$step" "$round")"; hold_why="the first probe failed: $step % under $start, rounded to $round"; fi
failed_holds=0
while true; do
  [ "$hold_users" -gt 0 ] || finish no-score null "no hold passed: the next one would be 0 users" 0
  decide "hold at $hold_users users for $hold" "$hold_why"
  run_one hold "$hold_users" "$hold"
  if [ "$R_VOID" = true ] && [ "$R_PASS" != true ]; then
    bound_by_k6=true
    decide "hold at $hold_users users again, once" "the first one is void ($(void_reason)): k6 may have caused the failure"
    run_one hold "$hold_users" "$hold"
    [ "$R_VOID" != true ] || [ "$R_PASS" = true ] || decide "the hold at $hold_users users counts as not passed" "void twice: the next hold steps down"
  fi
  if [ "$R_PASS" = true ]; then
    finish score "$hold_users" "score $hold_users: the hold of $hold passed at $R_FOLDER" 0
  fi
  failed_holds=$((failed_holds + 1))
  if [ "$failed_holds" -ge "$max_holds" ]; then
    finish no-score null "no hold passed down to $hold_users ($failed_holds holds failed)$([ "$bound_by_k6" = false ] || echo ", and k6 may have been the limit: a void run was met")" 0
  fi
  hold_users="$(score_next_down "$hold_users" "$step" "$round")"
  hold_why="$step % under the failed hold, rounded to $round"
done
