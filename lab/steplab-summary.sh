#!/usr/bin/env bash
# Prints the tables of a step lab comparison from the run JSON files of one folder, and the verdict of each variant. It reads nothing else:
# lab/steplab.sh calls it at the end of a comparison, and a results folder's summarize.sh calls it to rebuild the tables from its files.
#
#   bash lab/steplab-summary.sh <folder> [--floor <us> | --floor-from <A/A folder>] [--json <file>]
#
# The folder's `*.json` files that hold a `steplab` object are the runs (summary.json and any other file are skipped). The floor is the smallest
# median paired difference, in us of server CPU per request, that counts as a difference: --floor types it, --floor-from computes it from an
# A/A folder's run files (lab/steplab-floor.sh: |median of its paired differences| + their interquartile range) and records the folder and the
# value; both together are a usage error. Without a floor no variant is judged. --json writes the computed summary (lab/steplab-verdict.jq
# has the rule). Exit codes: 0, 2 usage, 1 no run file or no floor in the A/A folder.
#
# Runs of 5b and later carry their `position` in the round and the round `order`; for them the table flags a run whose step failed the 97 %
# rule (it counts, with a `*` next to its us/req) and says the floor and the order. A folder of earlier runs (the results folders' READMEs
# hold its tables byte for byte) prints the tables it always printed.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "usage: lab/steplab-summary.sh <folder> [--floor <us> | --floor-from <A/A folder>] [--json <file>]" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
dir="$1"
shift
floor=null floor_from="" json_out=""
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --floor) floor="$2" ;;
    --floor-from) floor_from="$2" ;;
    --json) json_out="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ "$floor" = null ] || [ -z "$floor_from" ] || { echo "steplab-summary: --floor and --floor-from are two ways to give the floor, use one" >&2; usage; }
[ -d "$dir" ] || { echo "steplab-summary: no folder $dir" >&2; usage; }
[ "$floor" = null ] || [[ "$floor" =~ ^[0-9]+([.][0-9]+)?$ ]] || { echo "steplab-summary: --floor must be a number of microseconds, got '$floor'" >&2; usage; }

shopt -s nullglob
files=("$dir"/*.json)
[ "${#files[@]}" -gt 0 ] || { echo "steplab-summary: no JSON file in $dir" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
summary="$tmp/summary.json"
# Why the filter: the folder also holds summary.json, which is not a run.
jq -s 'map(select(type == "object" and has("steplab")))' "${files[@]}" >"$tmp/runs.json"
[ "$(jq 'length' "$tmp/runs.json")" -gt 0 ] || { echo "steplab-summary: no run file (with a steplab object) in $dir" >&2; exit 1; }
floor_info=null
if [ -n "$floor_from" ]; then
  [ -d "$floor_from" ] || { echo "steplab-summary: --floor-from: no folder $floor_from" >&2; usage; }
  floor_json="$(bash "$LAB/steplab-floor.sh" "$floor_from")" || exit 1
  # Why the repository's own prefix goes: the summary is committed to a public repository, and a path of this checkout is not.
  floor_info="$(jq -c --arg from "${floor_from#"$(dirname "$LAB")"/}" '. + {from: $from}' <<<"$floor_json")"
  floor="$(jq '.floor_us' <<<"$floor_json")"
fi
jq --argjson floor "$floor" --argjson floor_info "$floor_info" -f "$LAB/steplab-verdict.jq" "$tmp/runs.json" >"$summary"
[ -z "$json_out" ] || cp "$summary" "$json_out"

fmt='def r1: if . == null then "-" else . * 10 | round / 10 | tostring end;
     def r2: if . == null then "-" else . * 100 | round / 100 | tostring end;
     def sgn: if . == null then "-" elif . > 0 then "+\(. * 10 | round / 10)" else "\(. * 10 | round / 10)" end;'

# Why a lookup of its own: the verdict (lab/steplab-verdict.jq) keeps the numbers the judgment reads; the host's state (the run's `host` object)
# is only shown, so it is joined here by variant and round. The two columns appear only when a run carries the host's readings (`host.fsync_ms`):
# a folder of earlier runs, whose READMEs hold the table byte for byte, prints the table it always printed.
hosts="$(jq -c 'map({key: "\(.steplab.variant)|\(.steplab.round)", value: {load1: .host.plateau.load1, fsync_ms: .host.fsync_ms}}) | from_entries' "$tmp/runs.json")"
with_host="$(jq 'any(.[]; (.host | type) == "object" and (.host | has("fsync_ms")))' "$tmp/runs.json")"

# Why `order` decides: it is the field of runs from 5b on (position and order are in their steplab object); runs of earlier phases keep their tables.
order="$(jq -r '.order // ""' "$summary")"
case "$order" in
  "") echo "runs, in the order they ran (one round runs every variant once, the first variant is the reference)" ;;
  fixed) echo "runs, in the order they ran (one round runs every variant once, in the order given every round; the first variant is the reference)" ;;
  alternate) echo "runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)" ;;
  *) echo "runs, in the order they ran (one round runs every variant once, the first variant is the reference; the rounds' orders differ)" ;;
esac
if [ "$with_host" = true ]; then
  printf '%5s  %-14s %-5s %10s %9s %8s %8s %9s %6s %8s  %s\n' round variant valid "req/s" "us/req" "p95 ms" "p99 ms" "tw/addr" load1 "fsync ms" result
else
  printf '%5s  %-14s %-5s %10s %9s %8s %8s %9s  %s\n' round variant valid "req/s" "us/req" "p95 ms" "p99 ms" "tw/addr" result
fi
jq -r --argjson hosts "$hosts" --argjson flag "$([ -n "$order" ] && echo true || echo false)" "$fmt"'.runs[] | ($hosts["\(.variant)|\(.round)"] // {}) as $h
    | [.round, .variant, (if .valid then "yes" else "no" end), (.achieved_rps | r1), ((.us_per_request | r1) + (if $flag and .failed_rule then "*" else "" end)), (.p95_ms | r2), (.p99_ms | r2),
    (.time_wait_before_max // "-"), ($h.load1 | r2), ($h.fsync_ms | r2), .result] | map(tostring) | join("\t")' "$summary" |
  while IFS=$'\t' read -r round variant valid rps us p95 p99 tw load1 fsync result; do
    if [ "$with_host" = true ]; then
      printf '%5s  %-14s %-5s %10s %9s %8s %8s %9s %6s %8s  %s\n' "$round" "$variant" "$valid" "$rps" "$us" "$p95" "$p99" "$tw" "$load1" "$fsync" "$result"
    else
      printf '%5s  %-14s %-5s %10s %9s %8s %8s %9s  %s\n' "$round" "$variant" "$valid" "$rps" "$us" "$p95" "$p99" "$tw" "$result"
    fi
  done
echo "tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)"
if [ -n "$order" ] && [ "$(jq '[.runs[] | select(.failed_rule)] | length' "$summary")" -gt 0 ]; then
  echo "*: the run counts in the pairs but its step failed (see result): that us/req rests on a run that did not pass"
fi
if [ "$with_host" = true ]; then
  echo "load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)"
fi
echo
echo "variants (us is the server's CPU per request over the plateau)"
if [ -n "$order" ]; then
  printf '%-14s %6s %6s %9s %17s %8s  %-22s %9s  %s\n' variant valid failed "median us" "min to max" "p99 ms" "paired differences us" "median" verdict
else
  printf '%-14s %6s %9s %17s %8s  %-22s %9s  %s\n' variant valid "median us" "min to max" "p99 ms" "paired differences us" "median" verdict
fi
jq -r "$fmt"'.variants[] | [.variant, "\(.valid_runs)/\(.runs)", (.failed_rule | tostring), (.median_us | r1), "\(.min_us | r1) to \(.max_us | r1)", (.median_p99_ms | r2),
    (if .reference then "reference" elif (.pairs | length) == 0 then "none" else (.pairs | map(.difference_us | sgn) | join(" ")) end),
    (if .reference then "-" else (.median_difference_us | sgn) end),
    (if .reason != null and .verdict != "reference" and .verdict != "beyond the noise" and .verdict != "within the noise" and (.verdict | startswith("screen:") | not) then "\(.verdict): \(.reason)" else .verdict end)] | join("\t")' "$summary" |
  while IFS=$'\t' read -r variant valid failed med range p99 diffs mdiff verdict; do
    if [ -n "$order" ]; then
      printf '%-14s %6s %6s %9s %17s %8s  %-22s %9s  %s\n' "$variant" "$valid" "$failed" "$med" "$range" "$p99" "$diffs" "$mdiff" "$verdict"
    else
      printf '%-14s %6s %9s %17s %8s  %-22s %9s  %s\n' "$variant" "$valid" "$med" "$range" "$p99" "$diffs" "$mdiff" "$verdict"
    fi
  done
echo
if [ "$floor" != null ] && { [ -n "$floor_from" ] || [ -n "$order" ]; }; then
  if [ -n "$floor_from" ]; then
    jq -r '"Floor: \(.floor_us) us, from \(.floor_from): |median \(.floor_detail.median_difference_us)| + interquartile range \(.floor_detail.iqr_us) of \(.floor_detail.pairs) paired differences (quartiles by linear interpolation, inclusive)"' "$summary"
  else
    echo "Floor: $floor us (typed with --floor)"
  fi
fi
printf 'Rule: %s\n' "$(jq -r '.rule' "$summary")"
if [ "$(jq '[.runs[] | select((.other_containers // 0) > 0)] | length' "$summary")" -gt 0 ]; then
  echo "WARNING: $(jq '[.runs[] | select((.other_containers // 0) > 0)] | length' "$summary") run(s) had other containers running on the VM"
fi
