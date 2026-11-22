#!/usr/bin/env bash
# Prints the Markdown tables of README.md from the run-*.json, info-*.json, conns-*.json and conformance-*.txt files next to this
# script. A macro run counts when its JSON says valid: true and other_containers.count 0; every other run is listed and left out
# of the medians.
set -euo pipefail
cd "$(dirname "$0")"

# One record per macro run: the label is the server and tree, the route comes from the target URL, the round from the file name.
PRELUDE='
def med: sort | if length == 0 then null elif length % 2 == 1 then .[length / 2 | floor] else (.[length / 2 - 1] + .[length / 2]) / 2 end;
def r1: if . == null then null else . * 10 | round / 10 end;
def r2: if . == null then null else . * 100 | round / 100 end;
def rec: {
  file: input_filename, date: .date, label: .label, image: .server.variant,
  route: (if (.k6.target_url | endswith("/noop")) then "noop" else "posts" end), rate: .k6.rate,
  round: (input_filename | sub("^.*/"; "") | (capture("^run-(?<r>[0-9])-") | .r) // "-"),
  valid: .valid, others: .other_containers.count, counted: (.valid and .other_containers.count == 0),
  us: .results.cpu_usec_per_request, achieved: .results.achieved_req_per_s, p99: .results.latency_ms.p99, max_ms: .results.latency_ms.max,
  srv_pct: .results.server_cpu_percent_of_one_cpu, dropped: .results.dropped_iterations, errors: .results.error_rate,
  pss: .results.memory.under_load.max_pss_mib, anon: .results.memory.under_load.max_pss_anon_mib,
  cur: .results.memory.under_load.max_cgroup_current_mib, socket: .server.socket, vus: .k6.max_vus
};
def counted_group($label; $route; $rate; $image):
  [inputs | rec | select(.counted and .label == $label and .route == $route and .rate == $rate and .image == $image)];
'
SERVERS="swoole workerman-nocache workerman-stock diy"

macro_files() { ls run-*.json info-*.json 2>/dev/null; }

# Median µs/req of the counted runs of one (server, route, rate, image), 7000 and 8.5 by default.
median_us() { # label route rate image
  # Why: the file names (run-*.json) hold no space, and the list must reach jq as separate arguments.
  # shellcheck disable=SC2046
  jq -n "$PRELUDE"'[counted_group($label; $route; ($rate | tonumber); $image)[] | .us] | med' \
    --arg label "$1" --arg route "$2" --arg rate "$3" --arg image "$4" $(macro_files)
}

echo "### Series A: per runtime and route at 7,000 req/s on 8.5 (counted runs only; spread = min to max)"
echo
echo "| Runtime | Route | Counted runs | µs CPU/req median | min .. max | p99 ms (median) | peak Pss_Anon MiB | peak memory.current MiB | peak Pss MiB (with the mapped database) |"
echo "|---|---|---|---|---|---|---|---|---|"
for s in $SERVERS; do
  for r in noop posts; do
    # shellcheck disable=SC2046
    jq -nr "$PRELUDE"'
      [counted_group($s; $r; 7000; "8.5")] | .[0] as $g
      | "| \($s) | \($r) | \($g | length) | \($g | map(.us) | med | r2) | \($g | map(.us) | min | r2) .. \($g | map(.us) | max | r2)"
        + " | \($g | map(.p99) | med | r2) | \($g | map(.anon) | max | r1) | \($g | map(.cur) | max | r1) | \($g | map(.pss) | max | r1) |"' \
      --arg s "$s" --arg r "$r" $(macro_files)
  done
done

# The medians the rest reads.
m_swoole_noop="$(median_us swoole noop 7000 8.5)"
m_swoole_posts="$(median_us swoole posts 7000 8.5)"
m_workerman_nocache_noop="$(median_us workerman-nocache noop 7000 8.5)"
m_workerman_nocache_posts="$(median_us workerman-nocache posts 7000 8.5)"
m_workerman_stock_noop="$(median_us workerman-stock noop 7000 8.5)"
m_workerman_stock_posts="$(median_us workerman-stock posts 7000 8.5)"
m_diy_noop="$(median_us diy noop 7000 8.5)"
m_diy_posts="$(median_us diy posts 7000 8.5)"

echo
echo "### Derived from the medians at 7,000 req/s"
echo
echo "| What | Value |"
echo "|---|---|"
jq -nr \
  --argjson s_n "$m_swoole_noop" --argjson s_p "$m_swoole_posts" \
  --argjson wn_n "$m_workerman_nocache_noop" --argjson wn_p "$m_workerman_nocache_posts" \
  --argjson ws_n "$m_workerman_stock_noop" --argjson ws_p "$m_workerman_stock_posts" \
  --argjson d_n "$m_diy_noop" --argjson d_p "$m_diy_posts" '
  def r1: . * 10 | round / 10;
  def r2: . * 100 | round / 100;
  def pct($a; $b): (($a - $b) / $b * 100) | r1;
  ([$s_p - $s_n, $wn_p - $wn_n, $d_p - $d_n]) as $g3
  | ([$s_p - $s_n, $wn_p - $wn_n, $ws_p - $ws_n, $d_p - $d_n]) as $g4
  | "| Gap posts minus noop, Swoole / Workerman nocache / Workerman stock / DIY (µs/req) | \($s_p - $s_n | r2) / \($wn_p - $wn_n | r2) / \($ws_p - $ws_n | r2) / \($d_p - $d_n | r2) |",
    "| Largest difference between the gaps of Swoole, Workerman nocache and DIY (µs/req) | \(($g3 | max) - ($g3 | min) | r2) |",
    "| Largest difference between the four gaps (µs/req) | \(($g4 | max) - ($g4 | min) | r2) |",
    "| Workerman nocache against Swoole on `/noop` | \(pct($wn_n; $s_n)) % |",
    "| Workerman nocache against Swoole on posts | \(pct($wn_p; $s_p)) % |",
    "| Workerman stock against nocache on `/noop` (negative: cheaper with the caches on) | \(pct($ws_n; $wn_n)) % |",
    "| Workerman stock against nocache on posts | \(pct($ws_p; $wn_p)) % |",
    "| DIY against Swoole on `/noop` | \(pct($d_n; $s_n)) % |",
    "| DIY against Swoole on posts | \(pct($d_p; $s_p)) % |"'

echo
echo "### The finalists: the two lowest median posts µs/req among Swoole, Workerman nocache and DIY (stock is not a candidate)"
echo
finalists="$(jq -nr --argjson s "$m_swoole_posts" --argjson w "$m_workerman_nocache_posts" --argjson d "$m_diy_posts" \
  '[{n: "swoole", v: $s}, {n: "workerman-nocache", v: $w}, {n: "diy", v: $d}] | sort_by(.v) | .[0:2] | map(.n) | join(" ")')"
echo "Finalists: $(jq -nr --arg f "$finalists" '$f | split(" ") | map("**\(.)**") | join(" and ")') (posts medians: Swoole $(jq -n "$m_swoole_posts | . * 100 | round / 100"), Workerman nocache $(jq -n "$m_workerman_nocache_posts | . * 100 | round / 100"), DIY $(jq -n "$m_diy_posts | . * 100 | round / 100") µs/req)."

echo
echo "### Series B: the finalists at 9,500 req/s on 8.5 (counted runs only), against their 7,000 medians"
echo
echo "| Runtime | Route | Counted runs | µs CPU/req median | min .. max | p99 ms (median) | median at 7,000 | lower than at 7,000 by |"
echo "|---|---|---|---|---|---|---|---|"
for s in $finalists; do
  for r in noop posts; do
    base="$(median_us "$s" "$r" 7000 8.5)"
    # shellcheck disable=SC2046
    jq -nr "$PRELUDE"'
      [counted_group($s; $r; 9500; "8.5")] | .[0] as $g | ($base | tonumber) as $b | ($g | map(.us) | med) as $m
      | "| \($s) | \($r) | \($g | length) | \($m | r2) | \($g | map(.us) | min | r2) .. \($g | map(.us) | max | r2)"
        + " | \($g | map(.p99) | med | r2) | \($b | r2) | \(($b - $m) / $b * 100 | r1) % |"' \
      --arg s "$s" --arg r "$r" --arg base "$base" $(macro_files)
  done
done

echo
echo "### Series D: PHP 8.6, information, one run each, at 7,000 req/s (not counted in any median)"
echo
echo "| Runtime | Route | µs CPU/req on 8.6 | median on 8.5 | difference | valid | other containers |"
echo "|---|---|---|---|---|---|---|"
# shellcheck disable=SC2046
jq -nr "$PRELUDE"'[inputs | rec | select(.image == "8.6")] | sort_by(.date) | .[]
  | "| \(.label) | \(.route) | \(.us | r2) | MEDIAN_\(.label)_\(.route) | DIFF | \(.valid) | \(.others) |"' $(ls info-*.json 2>/dev/null) |
  while IFS= read -r line; do
    label="$(cut -d'|' -f2 <<<"$line" | tr -d ' ')"; route="$(cut -d'|' -f3 <<<"$line" | tr -d ' ')"
    us="$(cut -d'|' -f4 <<<"$line" | tr -d ' ')"
    base="$(median_us "$label" "$route" 7000 8.5)"
    diff="$(jq -n "($us - $base) / $base * 100 | . * 10 | round / 10")"
    base_r="$(jq -n "$base | . * 100 | round / 100")"
    line="${line/MEDIAN_${label}_${route}/$base_r}"
    echo "${line/DIFF/$diff %}"
  done

echo
echo "### Series C: connections (one run per runtime, 8.5)"
echo
echo "| Runtime | Max connections | Stopped at step | Why it stopped | Source addresses | Pss slope KiB/conn | Pss_Anon slope KiB/conn | memory.current slope KiB/conn | Pss_Anon per connection at the max KiB | memory.current per connection at the max KiB | Pss per connection at the max KiB (with the mapped database) | Baseline Pss / Pss_Anon / memory.current MiB | Held steps in the slope | Valid (other containers) |"
echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
for s in swoole workerman-nocache diy; do
  f="$(ls conns-"$s"-*.json 2>/dev/null | head -1 || true)"
  [ -n "$f" ] || continue
  jq -r '
    def r2: if . == null then null else . * 100 | round / 100 end;
    .results as $r | ([.steps[] | select(.ceiling_reason == null and .probe != null)] | last) as $last
    | $r.baseline as $b
    | "| \(.label) | \($r.max_connections) | \($r.max_connections_step) | \($r.reason_stopped) | \(.client.source_addresses | length) (\(.client.source_addresses | first) .. \(.client.source_addresses | last))"
      + " | \($r.memory_per_connection.pss_kib_per_connection | r2) | \($r.memory_per_connection.pss_anon_kib_per_connection | r2) | \($r.memory_per_connection.cgroup_current_kib_per_connection | r2)"
      + " | \((($last.probe.pss_anon_kb - $b.pss_anon_kb) / $last.held) | r2) | \((($last.probe.cgroup_current - $b.cgroup_current_bytes) / 1024 / $last.held) | r2) | \((($last.probe.pss_kb - $b.pss_kb) / $last.held) | r2)"
      + " | \($b.pss_kb / 1024 | r2) / \($b.pss_anon_kb / 1024 | r2) / \($b.cgroup_current_bytes / 1048576 | r2) | \($r.memory_per_connection.held_steps_used) | \(.other_containers.count == 0) (\(.other_containers.count)) |"' "$f"
done

echo
echo "### Series C, every step"
echo
echo "| Runtime | Target | Held | Pss_Anon MiB | memory.current MiB | Established (kernel) | Fresh request ms | Stopped because |"
echo "|---|---|---|---|---|---|---|---|"
for s in swoole workerman-nocache diy; do
  f="$(ls conns-"$s"-*.json 2>/dev/null | head -1 || true)"
  [ -n "$f" ] || continue
  jq -r '
    def r2: if . == null then "n/a" else . * 100 | round / 100 end;
    .label as $l | .steps[]
    | "| \($l) | \(.target) | \(.held) | \(.probe.pss_anon_kb // null | if . == null then null else . / 1024 end | r2) | \(.probe.cgroup_current // null | if . == null then null else . / 1048576 end | r2) | \(.probe.tcp_established // "n/a") | \(.probe.fresh_ms // "n/a") | \(.ceiling_reason // "") |"' "$f"
done

echo
echo "### Socket settings each server printed at boot (from the JSON of its first run)"
echo
echo "| Runtime | backlog | TCP_NODELAY |"
echo "|---|---|---|"
for s in $SERVERS; do
  f="$(ls run-*-"$s"-noop-7000.json | head -1)"
  jq -r '"| \(.label) | \(.server.socket.backlog) | \(.server.socket.tcp_nodelay) |"' "$f"
done

echo
echo "### Bytes of the \`/noop\` response, per runtime (the conformance run's printed bytes)"
echo
for s in $SERVERS; do
  f="conformance-$s.txt"
  [ -f "$f" ] || continue
  echo "**$s**"
  echo
  echo '```text'
  sed -n '/^GET \/noop answers/,/^    {/p' "$f" | sed 's/^GET \/noop answers, byte for byte://' | sed '/^$/d'
  echo '```'
  echo
done

echo "### Every run, in the order it ran (the time is when the run ended and its JSON was written)"
echo
echo "| Written (UTC) | Run | Image | VUs | µs CPU/req | achieved req/s | p99 ms | max ms | server CPU % of one CPU | errors | dropped | other containers | valid | counted |"
echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
# shellcheck disable=SC2046
jq -nr "$PRELUDE"'
  [inputs | rec] | sort_by(.date) | .[]
  | (.file | sub("\\.json$"; "")) as $name
  | "| \(.date) | \($name) | \(.image) | \(.vus) | \(.us | r2) | \(.achieved | r2) | \(.p99 | r2) | \(.max_ms | r2) | \(.srv_pct | r2) | \(.errors) | \(.dropped) | \(.others) | \(.valid) | \(if (.file | startswith("info-")) then "information only" elif .counted then "yes" else "no" end) |"' $(macro_files)

echo
echo "### Connection runs, in the order they ran"
echo
echo "| Written (UTC) | Run | Max connections | Why it stopped | Other containers |"
echo "|---|---|---|---|---|"
for f in conns-*.json; do
  [ -f "$f" ] || continue
  jq -r '"| \(.date) | \(input_filename | sub("\\.json$"; "")) | \(.results.max_connections) | \(.results.reason_stopped) | \(.other_containers.count) |"' "$f"
done | sort

echo
echo "### The first try (rate / 10 VUs, stopped after round 2): kept, not counted anywhere"
echo
echo "| Written (UTC) | Run | VUs | µs CPU/req | p99 ms | max ms | dropped | other containers | valid |"
echo "|---|---|---|---|---|---|---|---|---|"
# shellcheck disable=SC2046
jq -nr "$PRELUDE"'
  [inputs | rec] | sort_by(.date) | .[]
  | "| \(.date) | \(.file | sub("^first-try-700-vus/"; "") | sub("\\.json$"; "")) | \(.vus) | \(.us | r2) | \(.p99 | r2) | \(.max_ms | r2) | \(.dropped) | \(.others) | \(.valid) |"' first-try-700-vus/run-*.json
