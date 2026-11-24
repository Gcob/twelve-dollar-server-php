#!/usr/bin/env bash
# Prints the tables of a step lab comparison from the run JSON files of one folder, and the verdict of each variant. It reads nothing else:
# lab/steplab.sh calls it at the end of a comparison, and a results folder's summarize.sh calls it to rebuild the tables from its files.
#
#   bash lab/steplab-summary.sh <folder> [--floor <us>] [--json <file>]
#
# The folder's `*.json` files that hold a `steplab` object are the runs (summary.json and any other file are skipped). --floor is the smallest
# median paired difference, in us of server CPU per request, that counts as a difference (it comes from an A/A calibration); without it no
# variant is judged. --json writes the computed summary (lab/steplab-verdict.jq has the rule). Exit codes: 0, 2 usage, 1 no run file.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"

usage() {
  echo "usage: lab/steplab-summary.sh <folder> [--floor <us>] [--json <file>]" >&2
  exit 2
}

[ "$#" -ge 1 ] || usage
dir="$1"
shift
floor=null json_out=""
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --floor) floor="$2" ;;
    --json) json_out="$2" ;;
    *) usage ;;
  esac
  shift 2
done
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
jq --argjson floor "$floor" -f "$LAB/steplab-verdict.jq" "$tmp/runs.json" >"$summary"
[ -z "$json_out" ] || cp "$summary" "$json_out"

fmt='def r1: if . == null then "-" else . * 10 | round / 10 | tostring end;
     def r2: if . == null then "-" else . * 100 | round / 100 | tostring end;
     def sgn: if . == null then "-" elif . > 0 then "+\(. * 10 | round / 10)" else "\(. * 10 | round / 10)" end;'

# Why a lookup of its own: the verdict (lab/steplab-verdict.jq) keeps the numbers the judgment reads; the host's state (the run's `host` object)
# is only shown, so it is joined here by variant and round. The two columns appear only when a run carries the host's readings (`host.fsync_ms`):
# a folder of earlier runs, whose READMEs hold the table byte for byte, prints the table it always printed.
hosts="$(jq -c 'map({key: "\(.steplab.variant)|\(.steplab.round)", value: {load1: .host.plateau.load1, fsync_ms: .host.fsync_ms}}) | from_entries' "$tmp/runs.json")"
with_host="$(jq 'any(.[]; (.host | type) == "object" and (.host | has("fsync_ms")))' "$tmp/runs.json")"

echo "runs, in the order they ran (one round runs every variant once, the first variant is the reference)"
if [ "$with_host" = true ]; then
  printf '%5s  %-14s %-5s %10s %9s %8s %8s %9s %6s %8s  %s\n' round variant valid "req/s" "us/req" "p95 ms" "p99 ms" "tw/addr" load1 "fsync ms" result
else
  printf '%5s  %-14s %-5s %10s %9s %8s %8s %9s  %s\n' round variant valid "req/s" "us/req" "p95 ms" "p99 ms" "tw/addr" result
fi
jq -r --argjson hosts "$hosts" "$fmt"'.runs[] | ($hosts["\(.variant)|\(.round)"] // {}) as $h
    | [.round, .variant, (if .valid then "yes" else "no" end), (.achieved_rps | r1), (.us_per_request | r1), (.p95_ms | r2), (.p99_ms | r2),
    (.time_wait_before_max // "-"), ($h.load1 | r2), ($h.fsync_ms | r2), .result] | map(tostring) | join("\t")' "$summary" |
  while IFS=$'\t' read -r round variant valid rps us p95 p99 tw load1 fsync result; do
    if [ "$with_host" = true ]; then
      printf '%5s  %-14s %-5s %10s %9s %8s %8s %9s %6s %8s  %s\n' "$round" "$variant" "$valid" "$rps" "$us" "$p95" "$p99" "$tw" "$load1" "$fsync" "$result"
    else
      printf '%5s  %-14s %-5s %10s %9s %8s %8s %9s  %s\n' "$round" "$variant" "$valid" "$rps" "$us" "$p95" "$p99" "$tw" "$result"
    fi
  done
echo "tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)"
if [ "$with_host" = true ]; then
  echo "load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)"
fi
echo
echo "variants (us is the server's CPU per request over the plateau)"
printf '%-14s %6s %9s %17s %8s  %-22s %9s  %s\n' variant valid "median us" "min to max" "p99 ms" "paired differences us" "median" verdict
jq -r "$fmt"'.variants[] | [.variant, "\(.valid_runs)/\(.runs)", (.median_us | r1), "\(.min_us | r1) to \(.max_us | r1)", (.median_p99_ms | r2),
    (if .reference then "reference" elif (.pairs | length) == 0 then "none" else (.pairs | map(.difference_us | sgn) | join(" ")) end),
    (if .reference then "-" else (.median_difference_us | sgn) end),
    (if .reason != null and .verdict != "reference" and .verdict != "beyond the noise" and .verdict != "within the noise" and (.verdict | startswith("screen:") | not) then "\(.verdict): \(.reason)" else .verdict end)] | join("\t")' "$summary" |
  while IFS=$'\t' read -r variant valid med range p99 diffs mdiff verdict; do
    printf '%-14s %6s %9s %17s %8s  %-22s %9s  %s\n' "$variant" "$valid" "$med" "$range" "$p99" "$diffs" "$mdiff" "$verdict"
  done
echo
printf 'Rule: %s\n' "$(jq -r '.rule' "$summary")"
if [ "$(jq '[.runs[] | select((.other_containers // 0) > 0)] | length' "$summary")" -gt 0 ]; then
  echo "WARNING: $(jq '[.runs[] | select((.other_containers // 0) > 0)] | length' "$summary") run(s) had other containers running on the VM"
fi
