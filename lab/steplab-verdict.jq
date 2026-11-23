# The step lab's verdict, a pure function of the run JSON files of one comparison (lab/steplab.sh writes them, lab/steplab-summary.sh
# calls this program): `jq -s --argjson floor <µs or null> -f lab/steplab-verdict.jq <run>.json...`.
#
# Each run file is a lab/realistic.sh --hold JSON with a `steplab` object (variant, variant_index, round, ...) added by the runner. The
# variant with index 0 is the reference. A run counts when its JSON says valid and its step has a CPU per request. A variant's paired
# differences are its CPU per request minus the reference's, round by round: a round where either run does not count has no pair.
#
# The rule: a variant is `beyond the noise` when it has at least 2 pairs, every difference has the same sign (a zero has none) and the
# median difference is at least the floor in absolute value; else `within the noise`. Without a floor nothing is judged, and with fewer
# than 2 pairs there is no verdict, except the screen: with exactly 1 pair and a floor, the variant `screen: beats the floor` when it is
# lower than the reference by at least the floor, else `screen: not better in one pair` (a first look that decides what deserves more
# pairs, never a verdict of "beyond the noise"). No pair: no verdict.

def median:
  sort | length as $n
  | if $n == 0 then null
    elif $n % 2 == 1 then .[$n / 2 | floor]
    else (.[$n / 2 - 1] + .[$n / 2]) / 2 end;

def run_row:
  (.results.steps[0] // null) as $s
  | { variant: .steplab.variant, index: .steplab.variant_index, round: .steplab.round, valid: .valid,
      counted: (.valid and $s != null and (($s.cpu_usec_per_request | type) == "number")),
      achieved_rps: $s.achieved_rps, us_per_request: $s.cpu_usec_per_request,
      p95_ms: $s.latency_ms.overall.p95, p99_ms: $s.latency_ms.overall.p99,
      result: (if (.valid | not) then "INVALID: " + (.invalid_reasons | join("; "))
               elif $s == null then "no step"
               elif $s.pass then "pass"
               else "FAIL: " + ($s.reasons | join("; ")) end),
      time_wait_before_max: .steplab.time_wait.before.max, other_containers: .other_containers.count };

def rule_text($floor):
  "a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least "
  + (if $floor == null then "the floor" else "\($floor) µs" end)
  + " in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).";

(map(run_row) | sort_by(.round, .index)) as $runs
| ($runs | map({index, variant}) | unique_by(.index)) as $variants
| ($runs | map(select(.index == 0 and .counted) | {key: (.round | tostring), value: .us_per_request}) | from_entries) as $ref_us
| { floor_us: $floor, rule: rule_text($floor), reference: ($variants[0].variant), runs: $runs,
    variants: [ $variants[] | . as $v
      | ($runs | map(select(.index == $v.index and .counted))) as $ok
      | (if $v.index == 0 then []
         else [$ok[] | select($ref_us[.round | tostring] != null)
               | {round, us_per_request, reference_us: $ref_us[.round | tostring], difference_us: (.us_per_request - $ref_us[.round | tostring])}]
         end) as $pairs
      | ($pairs | map(.difference_us)) as $diffs
      | ($diffs | median) as $med
      | (($diffs | length) > 0 and (($diffs | all(. > 0)) or ($diffs | all(. < 0)))) as $same_sign
      | { variant: $v.variant, index: $v.index, reference: ($v.index == 0),
          runs: ($runs | map(select(.index == $v.index)) | length), valid_runs: ($ok | length),
          median_us: ($ok | map(.us_per_request) | median), min_us: ($ok | map(.us_per_request) | min),
          max_us: ($ok | map(.us_per_request) | max), median_p99_ms: ($ok | map(.p99_ms) | median),
          pairs: $pairs, median_difference_us: $med, same_sign: $same_sign }
      | . + (if .reference then {verdict: "reference", reason: "the others are judged against it"}
             elif ($pairs | length) == 0 then {verdict: "no verdict", reason: "0 pairs, at least 1 needed"}
             elif $floor == null then {verdict: "no floor: not judged", reason: "run with --floor <µs> from an A/A calibration"}
             elif ($pairs | length) == 1 and $med <= (0 - $floor) then {verdict: "screen: beats the floor", reason: "one pair, \($med | fabs) µs lower, at least \($floor) µs"}
             elif ($pairs | length) == 1 then {verdict: "screen: not better in one pair", reason: "one pair, not lower by \($floor) µs"}
             elif $same_sign and ($med | fabs) >= $floor then {verdict: "beyond the noise", reason: "every pair has the same sign and the median is at least \($floor) µs"}
             elif $same_sign then {verdict: "within the noise", reason: "same sign but the median is under \($floor) µs"}
             else {verdict: "within the noise", reason: "the pairs do not all have the same sign"} end) ] }
