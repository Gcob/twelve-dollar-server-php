#!/usr/bin/env bash
# Prints the Markdown tables of README.md from the JSON files next to this script: aa-7500/ (the reference against itself: the floor),
# feed-micro/feed.json (the feed micro on both SQLites and its bar), sqlite-7500/, ring-7500/ and together-7500/ (the pairs, when the
# folder exists), the machine's facts (machine.txt) and the build times (builds.txt). A run counts when its JSON says valid: true and
# other_containers.count 0; every other run is listed in its table and counted nowhere. The bench estimate of a lever is
# BENCH_USERS x the reference's median µs/req / the lever's median µs/req (the phase's reference holds 86,800 users on the bench).
set -euo pipefail
cd "$(dirname "$0")"
LAB="$(cd ../.. && pwd)"
BENCH_USERS=86800
# The bench's loop: 1 feed per about 2.17 requests, so 0.46 feeds a request.
FEEDS_PER_REQUEST=0.46

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

runs_table() { # folder
  echo "| Run | position in its round | valid | other containers | idle held at the end | closed by the server | loop | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|"
  runs_of "$1" | jq -r "$PRELUDE"'sort_by(.steplab.round, .steplab.position)[] | .results.steps[0] as $s
    | "| \(.steplab.variant)-\(.steplab.round) | \(.steplab.position + 1) | \(.valid) | \(.other_containers.count) | \(.idle.held_at_end) | \(.idle.closed_by_server_at_end) | \(.server.loop // "-") | \($s.achieved_rps | r1) | \(ratio | r1) % | \($s.cpu_usec_per_request | r2) | \($s.latency_ms.overall.p95 | r2) | \($s.latency_ms.overall.p99 | r2) | \(if $s.pass then "pass" else "FAIL: " + ($s.reasons | join("; ")) end) |"'
}
host_table() { # folder
  echo "| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |"
  echo "|---|---|---|---|---|---|---|---|"
  runs_of "$1" | jq -r "$PRELUDE"'sort_by(.steplab.round, .steplab.position)[]
    | "| \(.steplab.variant)-\(.steplab.round) | \(.host.before.load1) | \(.host.plateau.load1) | \(.host.plateau.cpu_busy_pct) % | \(.host.plateau.steal_pct) % | \(.host.fsync_ms) | \(.steplab.time_wait.before.max) | \(.steplab.time_wait.before.waited_s) |"'
}
summary_block() { # folder [steplab-summary.sh arguments]
  local dir="$1"
  shift
  echo '```text'
  bash "$LAB/steplab-summary.sh" "$dir" "$@"
  echo '```'
}

echo "### The reference against itself (\`ref\` and \`ref2\`, the submission's server file twice, 7,500 req/s, \`s = 0.02\`, 60,000 idle, 5 pairs)"
echo
runs_table aa-7500
echo
host_table aa-7500
echo
FLOOR_JSON="$(bash "$LAB/steplab-floor.sh" aa-7500)"
REF_AA="$(runs_of aa-7500 | jq "$PRELUDE"'map(select(counted and .steplab.variant == "ref") | us) | med')"
echo "Valid runs: $(runs_of aa-7500 | jq 'map(select(.valid and .other_containers.count == 0)) | length') of $(runs_of aa-7500 | jq length). The reference's median over its runs: **$(jq -rn "$PRELUDE"'$m | r2' --argjson m "$REF_AA") µs/req**."
echo
jq -r "$PRELUDE"'"The floor, \(.pairs) paired differences: median \(.median_difference_us | sgn) µs, interquartile range \(.iqr_us | r2) µs, **floor \(.floor_us | r2) µs/req** (|median| + IQR)."' <<<"$FLOOR_JSON"
echo
summary_block aa-7500 --floor-from aa-7500

echo
echo "### The feed micro on Ubuntu's SQLite (\`8.5\`, 3.45.1) and the tuned one (\`8.5-sqlite\`, 3.54.1), JIT tracing"
echo
if [ -f feed-micro/feed.json ]; then
  jq -r "$PRELUDE"'
    def case_ns($img; $c): (.runs[] | select(.image == $img and .jit_state.on == true) | .cases[] | select(.case == $c) | .median_ns);
    def case_range($img; $c): (.runs[] | select(.image == $img and .jit_state.on == true) | .cases[] | select(.case == $c) | "\(.min_ns | r1) to \(.max_ns | r1)");
    def case_status($img; $c): (.runs[] | select(.image == $img and .jit_state.on == true) | .cases[] | select(.case == $c) | .status);
    "| Case | `8.5` ns | its processes (min to max) | `8.5-sqlite` ns | its processes (min to max) | saving ns | saving % |",
    "|---|---|---|---|---|---|---|",
    ("feed/reference/assoc", "post/reference/assoc", "feed/reference/assoc, APP_PRAGMAS=mmap-off") as $c
      | (case_ns("8.5"; $c)) as $a | (case_ns("8.5-sqlite"; $c)) as $b
      | select($a != null and $b != null)
      | "| \($c) | \($a | r1) | \(case_range("8.5"; $c)) | \($b | r1) | \(case_range("8.5-sqlite"; $c)) | \($a - $b | r1) | \(($a - $b) / $a * 100 | r1) % |"' feed-micro/feed.json
  echo
  FLOOR_US="$(jq .floor_us <<<"$FLOOR_JSON")"
  jq -r "$PRELUDE"'
    (.runs[] | select(.image == "8.5" and .jit_state.on == true) | .cases[] | select(.case == "feed/reference/assoc") | .median_ns) as $a
    | (.runs[] | select(.image == "8.5-sqlite" and .jit_state.on == true) | .cases[] | select(.case == "feed/reference/assoc") | .median_ns) as $b
    | ($a - $b) as $save | ($save / 1000 * $feeds) as $us
    | "**The bar** (the saving per feed times the feeds a request, against the A/A floor): (\($a | r1) - \($b | r1)) ns = \($save | r1) ns a feed = \($save / 1000 | r3) µs; × \($feeds) feeds a request = **\($us | r3) µs/req**; the floor is \($floor | r3) µs/req: the bar \(if $us >= $floor then "reaches" else "does not reach" end) the floor."' \
    --argjson feeds "$FEEDS_PER_REQUEST" --argjson floor "$FLOOR_US" feed-micro/feed.json
else
  echo "Not run."
fi

lever() { # folder title [floor arguments for steplab-summary.sh, default: --floor-from aa-7500]
  [ -d "$1" ] || return 0
  local folder="$1" title="$2"
  shift 2
  local floor_args=("$@")
  [ "${#floor_args[@]}" -gt 0 ] || floor_args=(--floor-from aa-7500)
  set -- "$folder" "$title"
  echo
  echo "### $2"
  echo
  runs_table "$1"
  echo
  host_table "$1"
  echo
  summary_block "$1" "${floor_args[@]}"
  echo
  runs_of "$1" | jq -r --argjson users "$BENCH_USERS" "$PRELUDE"'
    map(select(counted)) as $c | ($c | map(select(.steplab.variant != "ref") | .steplab.variant) | unique) as $vs
    | ([$c[] | select(.steplab.variant == "ref") | us] | med) as $mr
    | $vs[] as $v | ([$c[] | select(.steplab.variant == $v) | us] | med) as $ml
    | ($c | group_by(.steplab.round) | map(select(length == 2) | ((.[] | select(.steplab.variant == $v) | us) - (.[] | select(.steplab.variant == "ref") | us)))) as $d
    | "- **\($v)**: median \($ml | r2) µs/req against the reference'"'"'s \($mr | r2); paired differences \($d | map(sgn) | join(", ")), **median \($d | med | sgn) µs/req (\(($d | med) / $mr * 100 | sgn) %)**; bench estimate \($users) × \($mr | r2) ÷ \($ml | r2) = **\($users * $mr / $ml | round) users** (x86 on a shared host, not the bench)."'
}
lever sqlite-7500 "The tuned SQLite against the reference (\`8.5-sqlite\`, same server file, 7,500 req/s, 1 pair, 2 more if it beats the floor)"
[ -d aa-generic-7500 ] || {
  lever ring-7500 "The ring against the reference (\`APP_RING=1 APP_RINGS=3\`, \`APP_PRAGMAS=mmap-off\`, \`APP_SOFT_CONN_LIMIT=192000\`, \`--server-nofile 32768\`, 7,500 req/s)"
  lever together-7500 "The ring on the tuned SQLite against the reference (1 pair)"
}

# The pairs on 6.8.0-151-generic (scope 6d): their own A/A (3 pairs, aa-generic-7500/) and a floor that is the larger of that floor and the
# 6.8.0-1070-aws one (0.603), typed with --floor.
if [ -d aa-generic-7500 ]; then
  echo
  echo "### The reference against itself on 6.8.0-151-generic (\`ref\` and \`ref2\`, 7,500 req/s, \`s = 0.02\`, 60,000 idle, 3 pairs)"
  echo
  runs_table aa-generic-7500
  echo
  host_table aa-generic-7500
  echo
  GEN_FLOOR_JSON="$(bash "$LAB/steplab-floor.sh" aa-generic-7500)"
  GEN_FLOOR="$(jq -n --argjson g "$GEN_FLOOR_JSON" --argjson a "$(jq .floor_us <<<"$FLOOR_JSON")" '[$g.floor_us, $a] | max')"
  REF_GEN="$(runs_of aa-generic-7500 | jq "$PRELUDE"'map(select(counted and .steplab.variant == "ref") | us) | med')"
  echo "Valid runs: $(runs_of aa-generic-7500 | jq 'map(select(.valid and .other_containers.count == 0)) | length') of $(runs_of aa-generic-7500 | jq length). The reference's median over its runs: **$(jq -rn "$PRELUDE"'$m | r2' --argjson m "$REF_GEN") µs/req**."
  echo
  jq -r "$PRELUDE"'"The floor on this kernel, \(.pairs) paired differences: median \(.median_difference_us | sgn) µs, interquartile range \(.iqr_us | r2) µs, floor \(.floor_us | r2) µs/req (|median| + IQR). The floor used below is the larger of this and the first kernel'"'"'s (\($a | r3)): **\($f | r3) µs/req**."' --argjson f "$GEN_FLOOR" --argjson a "$(jq .floor_us <<<"$FLOOR_JSON")" <<<"$GEN_FLOOR_JSON"
  echo
  summary_block aa-generic-7500 --floor-from aa-generic-7500
  lever ring-7500 "The ring against the reference on 6.8.0-151-generic (\`APP_RING=1 APP_RINGS=3\`, \`URING_BUFFERS=auto\`, \`APP_PRAGMAS=mmap-off\`, \`APP_SOFT_CONN_LIMIT=192000\`, \`--server-nofile 32768\`, 7,500 req/s)" --floor "$GEN_FLOOR"
  lever together-7500 "The ring on the tuned SQLite against the reference on 6.8.0-151-generic (3 pairs)" --floor "$GEN_FLOOR"
  lever sqlite-generic-7500 "The tuned SQLite against the reference on 6.8.0-151-generic (\`8.5-sqlite\`, same server file, 1 pair)" --floor "$GEN_FLOOR"
fi
