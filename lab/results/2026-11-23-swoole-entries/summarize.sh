#!/usr/bin/env bash
# Prints the Markdown tables of README.md from the JSON files next to this script (and in its subfolders) and from the S1 series' files in
# ../2026-11-23-s1-fd-wall/ (the skeleton's µs/req at 12,000 req/s and the A/A floor of that rate).
# A run counts when its JSON says valid: true and other_containers.count 0.
# The bench's µs per request are the leaderboard's (LEADERBOARD.md of the challenge repository, read for the entries' rows): 94 for
# php-swoole-mattsplat, 101 for php-swoole-tzimpel.
set -euo pipefail
cd "$(dirname "$0")"
LAB="$(cd ../.. && pwd)"
S1=../2026-11-23-s1-fd-wall

PRELUDE='
def med: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
def r1: if . == null then "-" else . * 10 | round / 10 end;
def r2: if . == null then "-" else . * 100 | round / 100 end;
def r3: if . == null then "-" else . * 1000 | round / 1000 end;
def sgn: if . == null then "-" elif . > 0 then "+\(. * 100 | round / 100)" else "\(. * 100 | round / 100)" end;
def counted: .valid and .other_containers.count == 0;
def us: .results.steps[0].cpu_usec_per_request;
def ratio: .results.steps[0] | .achieved_rps / .offered_rps * 100;
'
runs_of() { jq -s 'map(select(type == "object" and has("steplab")))' "$1"/*.json; }

# The A/A floor at 12,000 req/s and the skeleton's µs/req there: the S1 series' files.
FLOOR="$(runs_of "$S1/aa-12000" | jq -r "$PRELUDE"'map(select(counted)) | group_by(.steplab.round) | map(select(length == 2) | ((.[] | select(.steplab.variant == "b") | us) - (.[] | select(.steplab.variant == "a") | us)) | fabs) | max')"
SKELETON="$(runs_of "$S1/s1-12000" | jq -r "$PRELUDE"'map(select(counted and .steplab.variant == "s1a") | us) | med')"

echo "### One pair each against the skeleton: 12,000 req/s, \`s = 0.02\`, 60,000 idle, 60 s plateau, the skeleton first in the round (PHP 8.5, telemetry on), the entry second (PHP 8.3 from apt)"
for pair in mattsplat-pair tzimpel-pair; do
  echo
  echo "**$pair**"
  echo
  echo "| Run | valid | other containers | idle held at the end | closed by the server | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|"
  runs_of "$pair" | jq -r "$PRELUDE"'sort_by(.steplab.round, .steplab.variant_index)[] | .results.steps[0] as $s
    | "| \(.steplab.variant)-\(.steplab.round) | \(.valid) | \(.other_containers.count) | \(.idle.held_at_end) | \(.idle.closed_by_server_at_end) | \($s.achieved_rps | r1) | \(ratio | r1) % | \($s.cpu_usec_per_request | r2) | \($s.latency_ms.overall.p95 | r2) | \($s.latency_ms.overall.p99 | r2) | \(if $s.pass then "pass" else "FAIL: " + ($s.reasons | join("; ")) end) |"'
  echo
  echo '```text'
  bash "$LAB/steplab-summary.sh" "$pair" --floor "$FLOOR"
  echo '```'
done
echo
echo "The A/A floor at 12,000 req/s (S1 series): $(jq -n "$PRELUDE"'$f | r3' --argjson f "$FLOOR") µs/req. The skeleton's S1-a at 12,000 req/s there: median $(jq -n "$PRELUDE"'$s | r2' --argjson s "$SKELETON") µs/req over 5 runs."

echo
echo "### The entries' flags, as the runs recorded them"
echo
echo "| Entry | image | PHP | server file | PHP flags |"
echo "|---|---|---|---|---|"
for pair in mattsplat-pair tzimpel-pair; do
  runs_of "$pair" | jq -r 'map(select(.steplab.variant_index == 1))[] | "| \(.steplab.variant) | `php-lab:\(.server.variant)` | \(.server.php_version) | `\(.server.file)` | `\(.server.php_flags)` |"'
done

echo
echo "### Memory and descriptors: one run of each entry with the per-second probes on (same rate and shape)"
echo
echo "| Entry | valid | other containers | idle held at the end | closed by the server | file descriptors at the peak | \`memory.current\` peak MiB (limit 2,048) | anonymous memory (Pss_Anon) peak MiB | µs CPU/req (probes on) |"
echo "|---|---|---|---|---|---|---|---|---|"
for f in memory/php-swoole-mattsplat.json memory/php-swoole-tzimpel.json; do
  jq -r "$PRELUDE"'"| \(.label | sub("^memory-"; "")) | \(.valid) | \(.other_containers.count) | \(.idle.held_at_end) | \(.idle.closed_by_server_at_end) | \(.server_connections.fds_peak) | \(.server_memory.memory_current_peak_mib | r1) | \(.server_memory.pss_anon_peak_mib | r1) | \(us | r2) |"' "$f"
done
jq -rn "$PRELUDE"'[inputs] as $m | ($m[0].server_memory) as $a | ($m[1].server_memory) as $b
  | "", "`memory.current` of mattsplat over tzimpel: \(($a.memory_current_peak_mib / $b.memory_current_peak_mib) | r2) times (mattsplat is held at the cgroup limit, its anonymous memory plus the page cache the kernel keeps reclaiming, so it could not read higher: the ratio is a floor). Anonymous memory, mattsplat over tzimpel: \(($a.pss_anon_peak_mib / $b.pss_anon_peak_mib) | r1) times."' memory/php-swoole-mattsplat.json memory/php-swoole-tzimpel.json

echo
echo "### The Mac-to-bench factors and the skeleton's bench estimate"
echo
echo "| Entry | bench µs/req (leaderboard) | Mac µs/req (the pair above) | factor (bench over Mac) |"
echo "|---|---|---|---|"
{
  jq -r "$PRELUDE"'map(select(counted and .steplab.variant == "php-swoole-mattsplat"))[0] | "php-swoole-mattsplat 94 \(us)"' <(runs_of mattsplat-pair)
  jq -r "$PRELUDE"'map(select(counted and .steplab.variant == "php-swoole-tzimpel"))[0] | "php-swoole-tzimpel 101 \(us)"' <(runs_of tzimpel-pair)
} | jq -Rrn "$PRELUDE"'[inputs | split(" ") | {name: .[0], bench: (.[1] | tonumber), mac: (.[2] | tonumber)} | . + {factor: (.bench / .mac)}] as $e
  | ($e | map("| \(.name) | \(.bench) | \(.mac | r2) | \(.factor | r2) |") | .[]),
    "",
    ($e | map(.factor)) as $f | (($f | add) / ($f | length)) as $mean | ($skeleton * $mean) as $est
    | "Mean factor \($mean | r2); the two differ by \((($f | max) - ($f | min)) / $mean * 100 | r1) % of the mean. The skeleton'"'"'s S1-a at 12,000 req/s is \($skeleton | r2) µs/req on the Mac, so its **bench estimate is \($est | r1) µs/req** (\($skeleton | r2) times \($mean | r2); with each factor alone: \(($f | map($skeleton * . | r1) | join(" and "))))."' --argjson skeleton "$SKELETON"
