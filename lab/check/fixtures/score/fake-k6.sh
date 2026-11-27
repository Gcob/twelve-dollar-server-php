#!/usr/bin/env bash
# Stands in for k6 and the samplers in lab/check.sh check_score (SCORE_K6_COMMAND of lab/score/run-k6.sh): called as
# `fake-k6.sh <run dir> <users> <duration>`, it writes the sampler files of a made-up run (make-run.awk) and exits with the next code of
# $FAKE_EXITS, a file of words, each `<exit>` or `<exit>/<option>+<option>` (options of make-run.awk, for that run). Logs the call to $FAKE_LOG, and sleeps $FAKE_K6_SLEEP seconds first when that is set.
#
# On two k6 halves it is called once for each, in a folder named half-1 or half-2 of the run's: both take the same word of $FAKE_EXITS (the run's;
# whichever half comes first takes it, under a lock), written `<exit 1>:<exit 2>/<options 1>~<options 2>` (the second exit and the second options are
# the second half's; with no `:` or no `~` both halves get the same). The server's files (the box's, not the load box's) are written in the run's folder
# from the first half's options. The second the call started is in `.hook-started`.
set -euo pipefail
dir="$1" users="$2"
here="$(cd "$(dirname "$0")" && pwd)"
half=0
case "$(basename "$dir")" in half-1) half=1 ;; half-2) half=2 ;; esac
date +%s >"$dir/.hook-started"
if [ "$half" = 0 ]; then
  word="$(head -n 1 "$FAKE_EXITS" | awk '{ print $1 }')"
  sed -i.bak '1s/^[^ ]* *//' "$FAKE_EXITS" && rm -f "$FAKE_EXITS.bak"
else
  run="$(dirname "$dir")"
  until mkdir "$run/.word-lock" 2>/dev/null; do sleep 0.05; done
  if [ ! -f "$run/.word" ]; then
    head -n 1 "$FAKE_EXITS" | awk '{ print $1 }' >"$run/.word"
    sed -i.bak '1s/^[^ ]* *//' "$FAKE_EXITS" && rm -f "$FAKE_EXITS.bak"
  fi
  rmdir "$run/.word-lock"
  word="$(cat "$run/.word")"
fi
codes="${word%%/*}"
opts=""
[ "$word" = "$codes" ] || opts="${word#*/}"
code="${codes%%:*}"
[ "$half" != 2 ] || code="${codes#*:}"
if [ -n "$opts" ] && [ "$half" != 0 ]; then
  case "$opts" in
    *~*) if [ "$half" = 1 ]; then opts="${opts%%~*}"; else opts="${opts#*~}"; fi ;;
  esac
fi
echo "k6 $users $3" >>"$FAKE_LOG"
[ -z "${FAKE_K6_SLEEP:-}" ] || sleep "$FAKE_K6_SLEEP"   # a run that takes a while, for a check that stops it midway
awk -v "dir=$dir" -v "opts=users=$users ${opts//+/ }" -f "$here/make-run.awk"
if [ "$half" != 0 ]; then
  # Why: the server's sampler files belong to the run, not to a half; the first half's options make them.
  [ "$half" != 1 ] || cp "$dir/server.csv" "$dir/server-start.txt" "$dir/server-end.txt" "$(dirname "$dir")/"
fi
exit "$code"
