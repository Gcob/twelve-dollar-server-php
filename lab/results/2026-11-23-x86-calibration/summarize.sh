#!/usr/bin/env bash
# Prints the Markdown tables of README.md from the JSON files next to this script (its subfolders) and from the Mac's runs it is read
# against: the S1 series' S1-a at 12,000 req/s (../2026-11-23-s1-fd-wall/s1-12000) and the skeleton of each Swoole pair
# (../2026-11-23-swoole-entries). A run counts when its JSON says valid: true and other_containers.count 0.
set -euo pipefail
cd "$(dirname "$0")"
LAB="$(cd ../.. && pwd)"
S1=../2026-11-23-s1-fd-wall
SW=../2026-11-23-swoole-entries

PRELUDE='
def med: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
def r1: if . == null then "-" else . * 10 | round / 10 end;
def r2: if . == null then "-" else . * 100 | round / 100 end;
def sgn: if . == null then "-" elif . > 0 then "+\(. * 100 | round / 100)" else "\(. * 100 | round / 100)" end;
def counted: .valid and .other_containers.count == 0;
def us: .results.steps[0].cpu_usec_per_request;
def ratio: .results.steps[0] | .achieved_rps / .offered_rps * 100;
'
runs_of() { jq -s 'map(select(type == "object" and has("steplab")))' "$1"/*.json; }

echo "### The staircases: the skeleton (PHP 8.5, telemetry on, probes on), \`s = 0.02\`, 60,000 idle, 60 s steps, the 97 % rule"
for f in staircase/coarse.json staircase/fine.json; do
  echo
  echo "**$(basename "$f" .json)** (valid: $(jq -r '.valid' "$f"), other containers: $(jq -r '.other_containers.count' "$f"), k6 connection errors: $(jq -r '.k6_connection_errors' "$f"), CPU model and layout: $(jq -r '.host | "\(.cpu_layout), server cpuset \(.cpuset_server), idle sibling \(.cpuset_idle_sibling), k6 cpuset \(.cpuset_k6), probe cpuset \(.cpuset_probe)"' "$f"))"
  echo
  echo "| Offered req/s | VUs | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |"
  echo "|---|---|---|---|---|---|---|---|"
  jq -r "$PRELUDE"'.results.steps[] | "| \(.offered_rps | round) | \(.vus) | \(.achieved_rps | r1) | \(.achieved_rps / .offered_rps * 100 | r1) % | \(.cpu_usec_per_request | r2) | \(.latency_ms.overall.p95) | \(.latency_ms.overall.p99) | \(if .pass then "pass" else "FAIL: " + (.reasons | join("; ")) end) |"' "$f"
done

# One folder of step lab runs as a table, then the step lab's own summary (no floor: no A/A calibration was made on the instance).
pair_section() {
  local dir="$1" title="$2"
  echo
  echo "### $title"
  echo
  echo "| Run | valid | other containers | idle held at the end | closed by the server | limit closes | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | idle bind retries | result |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|"
  runs_of "$dir" | jq -r "$PRELUDE"'sort_by(.steplab.round, .steplab.variant_index)[] | .results.steps[0] as $s
    | "| \(.steplab.variant)-\(.steplab.round) | \(.valid) | \(.other_containers.count) | \(.idle.held_at_end) | \(.idle.closed_by_server_at_end) | \(.server_connections.telemetry.close_responses // "-") | \($s.achieved_rps | r1) | \(ratio | r1) % | \($s.cpu_usec_per_request | r2) | \($s.latency_ms.overall.p95) | \($s.latency_ms.overall.p99) | \(.idle.bind_retries // "-") | \(if $s.pass then "pass" else "FAIL: " + ($s.reasons | join("; ")) end) |"'
  echo
  echo '```text'
  bash "$LAB/steplab-summary.sh" "$dir"
  echo '```'
}
pair_section pairs "The skeleton against S1-d (\`APP_SOFT_CONN_LIMIT=65450\`, above the run's connections), 7,500 req/s, 3 rounds, the skeleton first in each round"
pair_section reconnect "The skeleton against S1-d with every request reconnecting (\`APP_SOFT_CONN_LIMIT=60000\`), 7,500 req/s, one round"
pair_section mattsplat-pair "php-swoole-mattsplat (unchanged, PHP 8.3 from apt) against the skeleton, 7,500 req/s, one round"
pair_section tzimpel-pair "php-swoole-tzimpel (unchanged, PHP 8.3 from apt, his Swoole patch) against the skeleton, 7,500 req/s, one round"

# The Xeon's skeleton: every counted skeleton run of the four comparisons (7,500 req/s, telemetry on). The Mac's references, at 12,000 req/s with
# telemetry on: the S1 series' S1-a (5 runs) and the skeleton of each Swoole pair.
XEON="$(jq -s "$PRELUDE"'map(.[] | select(counted and .steplab.variant == "skeleton") | us)' <(runs_of pairs) <(runs_of reconnect) <(runs_of mattsplat-pair) <(runs_of tzimpel-pair))"
MAC_S1A="$(runs_of "$S1/s1-12000" | jq "$PRELUDE"'map(select(counted and .steplab.variant == "s1a") | us)')"
MAC_MATT="$(runs_of "$SW/mattsplat-pair" | jq "$PRELUDE"'map(select(counted and .steplab.variant == "s1a") | us)')"
MAC_TZIM="$(runs_of "$SW/tzimpel-pair" | jq "$PRELUDE"'map(select(counted and .steplab.variant == "s1a") | us)')"

echo
echo "### The x86 factor: the Xeon's skeleton over the Mac's (µs of server CPU per request)"
echo
jq -rn "$PRELUDE"'
  def row($name; $mac; $note): "| \($name) | \($mac | med | r2) | \($note) | \(($xeon | med) / ($mac | med) | r2) |";
  "| Mac reference | Mac µs/req (median) | Mac runs | factor (Xeon median over Mac median) |",
  "|---|---|---|---|",
  row("S1 series, S1-a, 12,000 req/s"; $s1a; "\($s1a | length) runs"),
  row("skeleton of the mattsplat pair, 12,000 req/s"; $matt; "1 run"),
  row("skeleton of the tzimpel pair, 12,000 req/s"; $tzim; "1 run"),
  "",
  "The Xeon'"'"'s skeleton at 7,500 req/s: median **\($xeon | med | r2) µs/req** over \($xeon | length) counted runs (\($xeon | map(r2) | join(", ")); min \($xeon | min | r2), max \($xeon | max | r2)). The Mac'"'"'s reference runs are at 12,000 req/s (the Xeon cannot hold that rate, so the rates differ); the Xeon'"'"'s µs/req in the staircases (probes on) run from \($stair | min | r1) to \($stair | max | r1) over rates from 4,000 to 10,000 req/s, so the rate moves them by under 2 µs: the factor is read as rate-free here, not measured at one rate.",
  "",
  "Factor against the S1 series: \((($xeon | med) / ($s1a | med)) | r2). The bench estimate of the skeleton (prediction 18) was 88 µs/req on the bench'"'"'s VM; the Xeon reads \($xeon | med | r1) µs/req, \((($xeon | med) / 88 * 100) | r1) % of it."' \
  --argjson xeon "$XEON" --argjson s1a "$MAC_S1A" --argjson matt "$MAC_MATT" --argjson tzim "$MAC_TZIM" \
  --argjson stair "$(jq -s 'map(.results.steps[].cpu_usec_per_request)' staircase/coarse.json staircase/fine.json)"

# The Mac at the Xeon's rate (7,500 req/s, the same flags): the same-rate factor, next to the 12,000-based one above.
if [ -d mac-same-rate ]; then
  pair_section mac-same-rate "The Mac at the Xeon's rate: the skeleton against S1-d (\`APP_SOFT_CONN_LIMIT=65450\`), 7,500 req/s, 3 rounds, the skeleton first in each round, the Xeon's flags"
  echo
  echo "### The x86 factor at the same rate: the Xeon's skeleton over the Mac's, both at 7,500 req/s with telemetry on"
  echo
  jq -rn "$PRELUDE"'
    def pc: map(select(counted and .steplab.variant == "skeleton")) | sort_by(.steplab.round) | map(us);
    ($macpairs | pc) as $mac | ($xeonpairs | pc) as $x
    | "| Reading | Xeon µs/req | Mac µs/req | factor |",
      "|---|---|---|---|",
      "| median of the skeleton runs (Xeon: its 6 counted runs; Mac: its \($mac | length)) | \($xeon | med | r2) | \($mac | med | r2) | \(($xeon | med) / ($mac | med) | r2) |",
      "| the 3 skeleton runs of the pairs, by round | \($x | map(r2) | join(", ")) | \($mac | map(r2) | join(", ")) | \([range(0; ($x | length)) as $i | $x[$i] / $mac[$i] | r2] | join(", ")) |",
      "",
      "The 12,000-based factor above is \(($xeon | med) / ($s1a | med) | r2) (the Mac'"'"'s S1-a, \($s1a | med | r2) µs/req at 12,000 req/s); at 7,500 req/s the Mac'"'"'s own skeleton costs \($mac | med | r2) µs/req, \((($mac | med) / ($s1a | med) - 1) * 100 | r1) % more than at 12,000, so a rate-free factor was not right on the Mac side: the Mac'"'"'s µs/req fall with the rate (impression: the CPU the loop spends on waking up for few requests counts for more per request), the Xeon'"'"'s do not (53.7 to 55.4 over 4,000 to 10,000). Both factors are kept; the same-rate one is the measured one."' \
    --argjson xeon "$XEON" --argjson s1a "$MAC_S1A" --argjson macpairs "$(runs_of mac-same-rate)" --argjson xeonpairs "$(runs_of pairs)"
fi

echo
echo "### The reconnect's price on the Xeon and S1-d's cost at the bench's sizes"
echo
jq -r "$PRELUDE"'.results.k6_summary.metrics.http_reqs.count as $k6 | (.steplab.warmup | split(",") | (.[0] | tonumber) * ((.[1] | tonumber) + 5)) as $warm | .server_connections.telemetry.close_responses as $closes
  | "S1-d with every request reconnecting: the server sent \($closes) `Connection: close` responses; k6 made \($k6) requests, plus the warm-up'"'"'s nominal \($warm | round) (its rate times its plateau plus half its 10 s ramp; the server counts its whole life): a difference of \($closes - $k6 - $warm | round), \((($closes - $k6 - $warm) / $closes * 100 | fabs) | r2) % of the closes, so every request reconnected."' reconnect/s1d-every-1.json
echo
RECON="$(runs_of reconnect | jq "$PRELUDE"'map(select(counted)) | ((map(select(.steplab.variant == "skeleton") | us)[0]) as $a | (map(select(.steplab.variant == "s1d-every") | us)[0]) as $b | {skeleton: $a, every: $b, cost: ($b - $a)})')"
jq -rn "$PRELUDE"'
  ($recon.cost) as $cost | ($xeon | med) as $skel
  | "One pair: the skeleton \($recon.skeleton | r2), S1-d with every request reconnecting \($recon.every | r2) µs/req: **one reconnect costs \($cost | r2) µs on the Xeon** (\($cost / $skel * 100 | r1) % of the skeleton'"'"'s median). The Mac'"'"'s was 6.62 µs (median of 5 pairs, S1 series): \(($cost / 6.62) | r2) times.",
  "",
  "S1-d with the soft limit L = 64,000 never closes an idle connection, so a share 1 - L / N of the requests reconnect (the S1 series'"'"' model). Added µs/req = share times the cost of one reconnect; the share of the skeleton is read against the Xeon'"'"'s median above.",
  "",
  "| Users N | share that reconnect | added µs/req on the Xeon | as a share of the Xeon skeleton | the Mac'"'"'s added µs/req (6.62) | above 15 %? |",
  "|---|---|---|---|---|---|",
  ([100000, 150000, 200000][] | . as $n | (1 - 64000 / $n) as $sh
    | "| \($n) | \($sh * 100 | r1) % | \($sh * $cost | r2) | \($sh * $cost / $skel * 100 | r1) % | \($sh * 6.62 | r2) | \(if $sh * $cost / $skel > 0.15 then "yes" else "no" end) |")' \
  --argjson recon "$RECON" --argjson xeon "$XEON"

echo
echo "### The Swoole entries on the Xeon against the Mac"
echo
{
  runs_of mattsplat-pair | jq -r "$PRELUDE"'map(select(counted)) | "php-swoole-mattsplat 94 \(map(select(.steplab.variant == "skeleton") | us)[0]) \(map(select(.steplab.variant == "php-swoole-mattsplat") | us)[0])"'
  runs_of tzimpel-pair | jq -r "$PRELUDE"'map(select(counted)) | "php-swoole-tzimpel 101 \(map(select(.steplab.variant == "php-swoole-tzimpel") | us)[0]) \(map(select(.steplab.variant == "skeleton") | us)[0])"' | awk '{print $1, $2, $4, $3}'
} | jq -Rrn "$PRELUDE"'
  [inputs | split(" ") | {name: .[0], bench: (.[1] | tonumber), skeleton: (.[2] | tonumber), entry: (.[3] | tonumber)}] as $e
  | "| Entry | Xeon µs/req (its pair) | its pair'"'"'s skeleton on the Xeon | entry over skeleton | Mac µs/req (scope-13 pair) | Xeon over Mac | bench µs/req (leaderboard) | bench over Xeon |",
    "|---|---|---|---|---|---|---|---|",
    ($e[] | (if .name == "php-swoole-mattsplat" then $mm else $mt end) as $mac
      | "| \(.name) | \(.entry | r2) | \(.skeleton | r2) | \(.entry / .skeleton | r2) | \($mac | r2) | \(.entry / $mac | r2) | \(.bench) | \(.bench / .entry | r2) |"),
    "",
    ($e | map(.bench / .entry)) as $f | (($f | add) / ($f | length)) as $mean
    | "Through the Xeon, the leaderboard'"'"'s 94 and 101 µs/req are \($f | map(r2) | join(" and ")) times the Xeon'"'"'s entries (mean \($mean | r2)). The skeleton'"'"'s Xeon median \($xeon | med | r2) µs/req times that mean is **\($xeon | med | . * $mean | r1) µs/req on the bench** (\(($xeon | med) as $m | $f | map($m * . | r1) | join(" and ")) with each factor alone), against 88 through the Mac (prediction 18, scope 13'"'"'s factors)."' \
  --argjson xeon "$XEON" \
  --argjson mm "$(runs_of "$SW/mattsplat-pair" | jq "$PRELUDE"'map(select(counted and .steplab.variant == "php-swoole-mattsplat") | us)[0]')" \
  --argjson mt "$(runs_of "$SW/tzimpel-pair" | jq "$PRELUDE"'map(select(counted and .steplab.variant == "php-swoole-tzimpel") | us)[0]')"
