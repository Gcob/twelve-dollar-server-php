# Shared functions of the score search (lab/score/). Sourced, never run. Pure logic: nothing here starts a container.
# shellcheck shell=bash

# The blob hash of the challenge's bench/load.js at commit 162699a of reference/twelve-dollar-server-challenge. The search runs that
# file as it is: a script with one byte changed is not the challenge's test and its score would mean nothing.
SCORE_LOAD_JS_BLOB=f4066f789ec9303a1525aaeabbe987ac4102cb2f

# score_round <users> <unit>: <users> rounded to the nearest <unit>, halves up (74,550 is 75,000 at a unit of 1,000).
score_round() {
  echo $(( (($1 + $2 / 2) / $2) * $2 ))
}

# score_next_up <users> <step %> <unit>: the next probe, <step> % up and rounded to the nearest <unit>. Integer arithmetic on
# users * (100 + step), so a half is exact.
score_next_up() {
  echo $(( (($1 * (100 + $2) + 50 * $3) / (100 * $3)) * $3 ))
}

# score_next_down <users> <step %> <unit>: the next hold, <step> % under and rounded.
score_next_down() {
  echo $(( (($1 * (100 - $2) + 50 * $3) / (100 * $3)) * $3 ))
}

# score_next_down_by <users> <permille> <unit>: the next hold, <permille> thousandths under (25 is 2.5 %) and rounded to the nearest <unit>, a half up.
# The finer search steps down by half the probe step, which is not a whole percent.
score_next_down_by() {
  echo $(( (($1 * (1000 - $2) + 500 * $3) / (1000 * $3)) * $3 ))
}

# score_halfway <pass> <fail> <unit>: the probe between the last passing probe and the failing one, the middle of the two rounded to the nearest
# <unit> (a half up). Prints nothing when that is not strictly between them (the two are one unit apart): there is nothing to probe.
score_halfway() {
  local mid
  mid="$(score_round $(( ($1 + $2) / 2 )) "$3")"
  if [ "$mid" -gt "$1" ] && [ "$mid" -lt "$2" ]; then echo "$mid"; fi
  return 0
}

# score_load_js_ok <file>: 0 when the file's git blob hash is the reference's.
score_load_js_ok() {
  [ "$(git hash-object "$1" 2>/dev/null)" = "$SCORE_LOAD_JS_BLOB" ]
}

# score_run_json <run dir> <kind> <users> <duration s> <k6 exit> <healthy s> <k6 start epoch or -> <cgroup layout> [<halves json>]: prints the run's JSON
# (lab/score/analyze.jq has the fields). Reads what the samplers left in the folder: rest.tsv, loadbox.csv, server.csv, server-start.txt,
# server-end.txt, summary.json and k6.log, each optional (a run whose server died has no server-end.txt), server-died.txt (the
# controller's word that the service was dead when the sampler stopped) and server-loop.txt (the server's `loop:` line).
# A run on two k6 halves has the load box's files (rest.tsv, loadbox.csv, summary.json, k6.log) in half-1/ and half-2/ instead, and the
# ninth argument {"users": [a, b], "exits": [a, b], "started": [a, b]}; <k6 exit> is then the run's (0 when both halves exited 0).
score_run_json() {
  local dir="$1" died=false dial=0 started=null f hd loop=null halves="${9:-null}" d1="$1" d2=""
  local lab_score
  lab_score="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  [ ! -e "$dir/server-died.txt" ] || died=true
  [ "$7" = - ] || started="$7"
  [ ! -s "$dir/server-loop.txt" ] || loop="$(jq -Rn --rawfile l "$dir/server-loop.txt" '$l | rtrimstr("\n") | if . == "" then null else . end')"
  if [ "$halves" != null ]; then d1="$dir/half-1" d2="$dir/half-2"; fi
  for hd in "$d1" ${d2:+"$d2"}; do
    [ ! -f "$hd/k6.log" ] || dial=$((dial + $(grep -c 'dial' "$hd/k6.log" || true)))
    for f in rest.tsv loadbox.csv; do [ -f "$hd/$f" ] || : >"$hd/$f"; done
  done
  for f in server.csv server-start.txt server-end.txt; do [ -f "$dir/$f" ] || : >"$dir/$f"; done
  local rest2=/dev/null loadbox2=/dev/null summary2=null
  if [ -n "$d2" ]; then
    rest2="$d2/rest.tsv" loadbox2="$d2/loadbox.csv"
    summary2="$( [ -s "$d2/summary.json" ] && cat "$d2/summary.json" || echo null )"
  fi
  jq -n -f "$lab_score/analyze.jq" \
    --rawfile rest "$d1/rest.tsv" --rawfile loadbox "$d1/loadbox.csv" --rawfile server "$dir/server.csv" \
    --rawfile server_start "$dir/server-start.txt" --rawfile server_end "$dir/server-end.txt" \
    --rawfile rest2 "$rest2" --rawfile loadbox2 "$loadbox2" --argjson summary2 "$summary2" \
    --argjson summary "$( [ -s "$d1/summary.json" ] && cat "$d1/summary.json" || echo null )" \
    --argjson meta "$(jq -n --arg kind "$2" --argjson users "$3" --argjson duration "$4" --argjson exit "$5" --argjson healthy "$6" \
      --argjson died "$died" --argjson dial "$dial" --argjson started "$started" --arg layout "$8" --argjson loop "$loop" --argjson halves "$halves" \
      '{kind: $kind, users: $users, duration_s: $duration, k6_exit: $exit, healthy_s: $healthy, server_died: $died, dial_errors: $dial, k6_started: $started, cgroup_layout: $layout, loop: $loop}
       + (if $halves == null then {} else {halves: $halves} end)')"
}

# score_seconds <duration>: a k6 duration ("20s", "2m", "1h", or a bare number of seconds) in seconds. Returns 1 on anything else.
score_seconds() {
  case "$1" in
    *[!0-9smh]* | "" | [smh]*) return 1 ;;
    *s) echo "${1%s}" ;;
    *m) echo $((${1%m} * 60)) ;;
    *h) echo $((${1%h} * 3600)) ;;
    *) echo "$1" ;;
  esac
}
