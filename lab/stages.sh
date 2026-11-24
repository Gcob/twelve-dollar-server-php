#!/usr/bin/env bash
# The series driver of the step lab: runs the series of a file one after the other, each one a `lab/steplab.sh` call, and records what the
# machine was doing around each of them. Every measured series goes through it, so the quiet check, the dates and the gap are the same each time.
#
#   bash lab/stages.sh <series file> [--out <dir>] [--gap <s>] [--dry-run] [--allow-busy] [--keep-going]
#
# The series file is plain text, one series per line: a name (letters, digits, . _ and -), then the arguments of one lab/steplab.sh call.
# Blank lines and lines that start with # are skipped. Quotes group a word ("ref=--image 8.5" is one argument); nothing else is expanded.
# The series' --out is <dir>/<name>: the file never sets it.
#
# For each series, in order:
#  1. the quiet check: the running containers on the Docker VM that are not the lab's (lab/lib.sh `lab_other_containers_count`, with the names
#     lab/realistic.sh gives its own). 0 is quiet. Otherwise the driver refuses to start the series, records the refusal and exits 1;
#     --allow-busy runs it anyway and marks it `busy: true` (a smoke only: a busy VM does not measure anything);
#  2. the start, from `date` (UTC, ISO 8601), the steplab call, the end, its exit code;
#  3. the gap (--gap <s>, default 60) so the machine settles; none after the last series.
# A series that exits non-zero stops the file and its code is the driver's exit code; with --keep-going the next series runs anyway and the
# driver exits with the first non-zero code. A refusal always stops the file: the VM would still be busy for the next one.
#
# <dir>/stages.json (default lab/results/stages-<time>/) is written after every series: {commit, dirty, gap_s, allow_busy, keep_going, series: [{name, command,
# start, end, exit_code, other_containers, busy, refused}]}. `command` is the steplab call as the file gives it (without the --out the driver
# adds); a refused series has null start, end and exit_code. Only counts are recorded: the containers' names belong to other projects.
# `commit` is the lab's checkout HEAD when the file starts and `dirty` whether a tracked file differs from it (`git diff --quiet HEAD`: the results
# folder this driver writes is untracked and must not make every measurement dirty): what ties a results folder to its code. Never a file list.
# --dry-run prints each series' command, when it would start and end and the gap, and runs nothing: no container, no folder, no file.
# Exit codes: 0 every series exited 0, 1 a refusal or a harness failure, 2 usage, otherwise the code of the series that failed.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$LAB")"
# shellcheck source=lib.sh
source "$LAB/lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: lab/stages.sh <series file> [--out <dir>] [--gap <s>] [--dry-run] [--allow-busy] [--keep-going]
a series file has one series per line: a name, then the arguments of one lab/steplab.sh call (# comments and blank lines are skipped)
EOF
  exit 2
}
fail() { echo "stages: $*" >&2; exit 1; }

file="" out="" gap=60 dry_run="" allow_busy="" keep_going=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --allow-busy) allow_busy=1 ;;
    --keep-going) keep_going=1 ;;
    --out | --gap)
      [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; usage; }
      if [ "$1" = --out ]; then out="$2"; else gap="$2"; fi
      shift
      ;;
    -*) echo "unknown option: $1" >&2; usage ;;
    *) [ -z "$file" ] || { echo "one series file only, got '$file' and '$1'" >&2; usage; }; file="$1" ;;
  esac
  shift
done
[ -n "$file" ] || usage
[ -f "$file" ] || { echo "no series file $file" >&2; usage; }
[[ "$gap" =~ ^[0-9]+$ ]] || { echo "--gap must be a whole number of seconds, got '$gap'" >&2; usage; }

# split_words <string>: sets WORDS to the words of the string, cut on spaces and tabs, with '...' and "..." grouping a word (no escapes, no
# expansion: a series file is data, never run as shell). Returns 1 on a quote that is never closed.
WORDS=()
split_words() {
  local s="$1" word="" in_word=0 quote="" c i
  WORDS=()
  for (( i = 0; i < ${#s}; i++ )); do
    c="${s:i:1}"
    if [ -n "$quote" ]; then
      if [ "$c" = "$quote" ]; then quote=""; else word+="$c"; fi
    else
      case "$c" in
        "'" | '"') quote="$c"; in_word=1 ;;
        ' ' | $'\t')
          if [ "$in_word" = 1 ]; then WORDS+=("$word"); word=""; in_word=0; fi
          ;;
        *) word+="$c"; in_word=1 ;;
      esac
    fi
  done
  [ -z "$quote" ] || return 1
  if [ "$in_word" = 1 ]; then WORDS+=("$word"); fi
  return 0
}

# The series: S_NAMES and S_LINES (the text after the name, split again when the series runs).
S_NAMES=() S_LINES=()
lineno=0
while IFS= read -r line || [ -n "$line" ]; do
  lineno=$(( lineno + 1 ))
  # A comment is skipped before it is split: it may hold an apostrophe.
  trimmed="${line#"${line%%[![:space:]]*}"}"
  [[ "$trimmed" != '#'* ]] || continue
  split_words "$line" || { echo "line $lineno: a quote is never closed" >&2; usage; }
  [ "${#WORDS[@]}" -gt 0 ] || continue
  name="${WORDS[0]}"
  [[ "$name" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "line $lineno: a series' name may only hold letters, digits, . _ and -, got '$name'" >&2; usage; }
  for seen in "${S_NAMES[@]+"${S_NAMES[@]}"}"; do
    [ "$seen" != "$name" ] || { echo "line $lineno: the series '$name' is named twice" >&2; usage; }
  done
  [ "${#WORDS[@]}" -gt 1 ] || { echo "line $lineno: the series '$name' has no steplab arguments" >&2; usage; }
  for word in "${WORDS[@]:1}"; do
    [ "$word" != --out ] || { echo "line $lineno: the series '$name' sets --out: the driver does (<dir>/<name>)" >&2; usage; }
  done
  S_NAMES+=("$name")
  rest="${line#*"$name"}"
  S_LINES+=("${rest# }")
done <"$file"
[ "${#S_NAMES[@]}" -gt 0 ] || { echo "no series in $file" >&2; usage; }

stamp="$(date -u +%Y%m%d-%H%M%S)"
[ -n "$out" ] || out="$LAB/results/stages-$stamp"
total="${#S_NAMES[@]}"

# command_for <index>: the steplab call as the file gives it, without a path of this checkout.
command_for() {
  local c="lab/steplab.sh ${S_LINES[$1]}"
  echo "${c//$REPO/.}"
}

if [ -n "$dry_run" ]; then
  echo "stages (dry run): $total series, into ${out#"$REPO"/}, gap $gap s: nothing runs"
  for i in "${!S_NAMES[@]}"; do
    echo "[$(( i + 1 ))/$total] ${S_NAMES[$i]}"
    echo "  quiet check: no running container but the lab's (--allow-busy runs a busy VM anyway and marks the series busy)"
    echo "  start: the date (UTC, ISO 8601) when the series starts"
    split_words "${S_LINES[$i]}"
    printf '  command: bash lab/steplab.sh'
    for word in "${WORDS[@]}"; do
      if [[ "$word" == *' '* ]]; then printf " '%s'" "$word"; else printf ' %s' "$word"; fi
    done
    printf ' --out %s\n' "${out#"$REPO"/}/${S_NAMES[$i]}"
    echo "  end: the date (UTC, ISO 8601) when it ends, with its exit code"
    [ "$i" -eq $(( total - 1 )) ] || echo "  gap: $gap s"
  done
  exit 0
fi

# Why: lab_other_containers_count would read an unreachable daemon as a quiet VM (its grep sees nothing).
docker info >/dev/null 2>&1 || fail "the Docker daemon is not reachable"
mkdir -p "$out"

# The containers lab/realistic.sh starts (SERVER, K6C, PROBE, AGG, IDLEC): the lab's own, never counted as another project's.
OWN=(lab-realistic-server lab-realistic-k6 lab-realistic-probe lab-realistic-agg lab-realistic-idle)

# The code this file measures: both null outside a git checkout.
COMMIT="$(git -C "$REPO" rev-parse HEAD 2>/dev/null || true)"
DIRTY=null
if [ -n "$COMMIT" ]; then
  if git -C "$REPO" diff --quiet HEAD 2>/dev/null; then DIRTY=false; else DIRTY=true; fi
fi

ENTRIES='[]'
write_json() {
  jq -n --arg commit "$COMMIT" --argjson dirty "$DIRTY" --argjson entries "$ENTRIES" --argjson gap "$gap" --argjson allow_busy "$([ -n "$allow_busy" ] && echo true || echo false)" \
    --argjson keep_going "$([ -n "$keep_going" ] && echo true || echo false)" \
    '{commit: (if $commit == "" then null else $commit end), dirty: $dirty, gap_s: $gap, allow_busy: $allow_busy, keep_going: $keep_going, series: $entries}' >"$out/stages.json"
}
# add_entry <name> <command> <start|""> <end|""> <exit code|""> <other containers> <busy> <refused>
add_entry() {
  ENTRIES="$(jq -c --arg name "$1" --arg command "$2" --arg start "$3" --arg end "$4" --arg rc "$5" --argjson others "$6" --argjson busy "$7" --argjson refused "$8" \
    '. + [{name: $name, command: $command, start: (if $start == "" then null else $start end), end: (if $end == "" then null else $end end),
           exit_code: (if $rc == "" then null else ($rc | tonumber) end), other_containers: $others, busy: $busy, refused: $refused}]' <<<"$ENTRIES")"
  write_json
}

run_pid=""
cleanup() {
  local rc=$?
  if [ -n "$run_pid" ] && kill -0 "$run_pid" 2>/dev/null; then
    kill -TERM "$run_pid" 2>/dev/null || true
    wait "$run_pid" 2>/dev/null || true
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

echo "stages: $total series, into ${out#"$REPO"/}, gap $gap s${allow_busy:+, --allow-busy}${keep_going:+, --keep-going}"
first_rc=0
for i in "${!S_NAMES[@]}"; do
  name="${S_NAMES[$i]}"
  command="$(command_for "$i")"
  others="$(lab_other_containers_count "${OWN[@]}")"
  busy=false
  if [ "$others" -gt 0 ]; then
    if [ -z "$allow_busy" ]; then
      add_entry "$name" "$command" "" "" "" "$others" false true
      fail "the VM is not quiet: $others other container(s) running (see docker ps); the series '$name' was not started. Stop them, or --allow-busy for a smoke"
    fi
    busy=true
    echo "stages: $others other container(s) running: the series '$name' is marked busy" >&2
  fi
  split_words "${S_LINES[$i]}"
  start="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[$(( i + 1 ))/$total] $name: start $start"
  rc=0
  bash "$LAB/steplab.sh" "${WORDS[@]}" --out "$out/$name" &
  run_pid=$!
  wait "$run_pid" || rc=$?
  run_pid=""
  end="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  add_entry "$name" "$command" "$start" "$end" "$rc" "$others" "$busy" false
  echo "[$(( i + 1 ))/$total] $name: $start to $end, exit $rc, $others other container(s)$([ "$busy" = false ] || echo ', busy')"
  if [ "$rc" -ne 0 ]; then
    [ "$first_rc" -ne 0 ] || first_rc="$rc"
    [ -n "$keep_going" ] || { echo "stages: the series '$name' exited $rc: stopping" >&2; break; }
  fi
  if [ "$i" -lt $(( total - 1 )) ]; then
    echo "  gap: $gap s"
    sleep "$gap"
  fi
done
echo "stages: wrote ${out#"$REPO"/}/stages.json"
exit "$first_rc"
