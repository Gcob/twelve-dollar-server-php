# The floor of an A/A folder: reads the verdict's summary of that folder (lab/steplab-verdict.jq run on its run files, without a floor) and
# computes, from the paired differences of its second variant against its reference:
#
#   floor = |median of the differences| + their interquartile range (q3 - q1)
#
# One rule for every pair, A/A included. The differences are the verdict's: every run that is harness-valid with a CPU per request counts,
# whether its step passed the 97 % rule or not, and a round where either run is invalid has no pair. The interquartile range spares the floor
# one outlier (a largest absolute difference let one run that failed the 97 % rule set it at 2.57 us where the four others said 0.27).
#
# Quartiles by linear interpolation, inclusive: the p-quantile of n sorted values sits at position p * (n - 1) (0-based) and is interpolated
# between its two neighbours (numpy's default `percentile`, Excel's `QUARTILE.INC`; with 5 values q1 is the 2nd and q3 the 4th).
#
# Settled by Jacob on 2026-11-25: the round order alternates, and the floor is |median| + interquartile range of an A/A folder, every run counted.
#
# Output: {pairs, differences_us, median_difference_us, q1_us, q3_us, iqr_us, floor_us}, the numbers to 3 decimals (the floor is judged as
# printed); floor_us is null with fewer than 2 pairs (the spread of one difference says nothing).

def median:
  sort | length as $n
  | if $n == 0 then null
    elif $n % 2 == 1 then .[$n / 2 | floor]
    else (.[$n / 2 - 1] + .[$n / 2]) / 2 end;

def quantile($p):
  sort | length as $n
  | ($p * ($n - 1)) as $pos | ($pos | floor) as $lo
  | if $lo + 1 < $n then .[$lo] + ($pos - $lo) * (.[$lo + 1] - .[$lo]) else .[$lo] end;

def r3: if . == null then null else . * 1000 | round / 1000 end;

([.variants[] | select(.index == 1)][0] // null) as $v
| ($v.pairs // [] | map(.difference_us)) as $d
| ($d | length) as $n
| (if $n >= 2 then ($d | quantile(0.25)) else null end) as $q1
| (if $n >= 2 then ($d | quantile(0.75)) else null end) as $q3
| (if $n >= 2 then ($d | median | fabs) + ($q3 - $q1) else null end) as $floor
| { pairs: $n, differences_us: ($d | map(r3)), median_difference_us: ($d | median | r3),
    q1_us: ($q1 | r3), q3_us: ($q3 | r3), iqr_us: (if $n >= 2 then $q3 - $q1 else null end | r3), floor_us: ($floor | r3) }
