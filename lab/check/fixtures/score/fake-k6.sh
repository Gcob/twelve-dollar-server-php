#!/usr/bin/env bash
# Stands in for k6 and the samplers in lab/check.sh check_score (SCORE_K6_COMMAND of lab/score/run-k6.sh): called as
# `fake-k6.sh <run dir> <users> <duration>`, it writes the sampler files of a made-up run (make-run.awk) and exits with the next code of
# $FAKE_EXITS, a file of words, each `<exit>` or `<exit>/<option>+<option>` (options of make-run.awk, for that run). Logs the call to $FAKE_LOG.
set -euo pipefail
dir="$1" users="$2"
here="$(cd "$(dirname "$0")" && pwd)"
word="$(head -n 1 "$FAKE_EXITS" | awk '{ print $1 }')"
sed -i.bak '1s/^[^ ]* *//' "$FAKE_EXITS" && rm -f "$FAKE_EXITS.bak"
code="${word%%/*}"
opts=""
[ "$word" = "$code" ] || opts="${word#*/}"
echo "k6 $users $3" >>"$FAKE_LOG"
awk -v "dir=$dir" -v "opts=users=$users ${opts//+/ }" -f "$here/make-run.awk"
exit "$code"
