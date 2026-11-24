#!/usr/bin/env bash
# The floor of an A/A folder, printed as JSON (lab/steplab-floor.jq has the rule): |median of the paired differences of its second variant
# against its reference| + their interquartile range. lab/steplab-summary.sh calls it for --floor-from, and lab/steplab.sh calls it before
# the first run, so a folder that gives no floor stops the comparison at once and not after its runs.
#
#   bash lab/steplab-floor.sh <A/A folder>
#
# The folder's `*.json` files that hold a `steplab` object are the runs. Exit codes: 0, 2 usage, 1 no run or fewer than 2 pairs.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"

[ "$#" -eq 1 ] || { echo "usage: lab/steplab-floor.sh <A/A folder>" >&2; exit 2; }
dir="$1"
[ -d "$dir" ] || { echo "steplab-floor: no folder $dir" >&2; exit 2; }

shopt -s nullglob
files=("$dir"/*.json)
[ "${#files[@]}" -gt 0 ] || { echo "steplab-floor: no JSON file in $dir" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
# Why the filter: the folder also holds summary.json, which is not a run.
jq -s 'map(select(type == "object" and has("steplab")))' "${files[@]}" >"$tmp/runs.json"
[ "$(jq 'length' "$tmp/runs.json")" -gt 0 ] || { echo "steplab-floor: no run file (with a steplab object) in $dir" >&2; exit 1; }
jq --argjson floor null --argjson floor_info null -f "$LAB/steplab-verdict.jq" "$tmp/runs.json" | jq -f "$LAB/steplab-floor.jq" >"$tmp/floor.json"
[ "$(jq '.floor_us' "$tmp/floor.json")" != null ] || { echo "steplab-floor: $dir has $(jq '.pairs' "$tmp/floor.json") paired difference(s), at least 2 are needed for a floor" >&2; exit 1; }
cat "$tmp/floor.json"
