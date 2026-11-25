#!/usr/bin/env bash
# Prints the Markdown tables of README.md from the two searches' files next to this script: <dir>/search.json (the arguments, the decisions, the end)
# and <dir>/<NN-kind-users>/run.json (one a k6 run; a folder called rerun-... holds a run made again by hand), for search-1-void/ (the first search, ended by a void rule that was then replaced),
# search-2/ (the second, up to 129,000 users) and search-3/ (the runs made by hand after it: no search.json, a decisions.log). Nothing is computed from anything else. SEARCH_DIRS overrides
# the folders, in order (lab/check.sh runs it on a made-up search).
set -euo pipefail
cd "$(dirname "$0")"

# Port 80 of the server box's security group, in the box's clock (UTC) of search 3: the last read without the rule was at 14:32:12 and the first with it
# at 14:34:43. Everything before search 3 ran with it closed.
PORT_LAST_CLOSED=14:32:12
PORT_FIRST_OPEN=14:34:43
PRELUDE='
def r1: if . == null then "-" else . * 10 | round / 10 end;
def r2: if . == null then "-" else . * 100 | round / 100 end;
def pct: if . == null then "-" else "\(. * 1000 | round / 10) %" end;
def mib: if . == null then "-" else (. / 1048576 | round) end;
def gib: if . == null then "-" else (. / 1073741824 * 10 | round / 10) end;
def n0: if . == null then "-" else round end;
'

# port_state <dir> <folder>: closed, open, or "opened during" for a run of search-3 (its start is in decisions.log, its end is the next result line:
# a run that started before the last closed read and ended after it may have seen the rule appear), closed for the other searches.
port_state() {
  local start end
  [ -f "$1/decisions.log" ] || { echo closed; return; }
  start="$(grep " start .* -> .*/$2\$" "$1/decisions.log" | cut -d' ' -f1)"
  end="$(awk -v f="$2" '$2 == "start" && index($0, "/" f) { seen = 1; next } seen && $2 == "result" { print $1; exit }' "$1/decisions.log")"
  if [[ "$end" < "$PORT_LAST_CLOSED" || "$end" = "$PORT_LAST_CLOSED" ]]; then echo closed
  elif [[ "$start" > "$PORT_FIRST_OPEN" || "$start" = "$PORT_FIRST_OPEN" ]]; then echo open
  else echo "opened during the run"; fi
}

tables() {
  local DIR="$1"
  # Every run's JSON, in folder order, with its folder name.
  all_runs() {
    local f
    for f in "$DIR"/*/run.json; do
      jq -c --arg f "$(basename "$(dirname "$f")")" --arg port "$(port_state "$DIR" "$(basename "$(dirname "$f")")")" '. + {folder: $f, port: $port}' "$f"
    done
  }

  echo "| Run | kind | users | k6 exit | pass | p95 ms | p99 ms | error rate | plateau req/s | service share of the core | service share, median second | µs CPU/req | others on the box | VU init s | healthy s | wall | reading | port 80 at the start |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
  all_runs | jq -r "$PRELUDE"'
    "| \(.folder) | \(.kind) | \(.users) | \(.k6_exit) | \(.pass) | \(.p95_ms | r2) | \(.p99_ms | r2) | \(.error_rate | if . == null then "-" else (. * 100000 | round / 1000) end) % | \(.plateau.req_per_s | n0) | \(.server.service_share | pct) | \(.server.service_share_median | pct) | \(.server.us_per_req | r1) | \(.server.others_median | pct) | \(.vu_init_s | r1) | \(.healthy_s) | \(.wall // "-") | \(if .pass then "valid pass" elif .void then "void (k6 over the line)" else "fail" end) | \(.port) |"'
  echo
  echo "| Run | accepts/s median on the plateau | accepts/s max on the plateau | accepts/s max in the run | CPU busy median | k6 memory GiB | load box CPU max | load box seconds over 85 % (longest streak) / plateau seconds | service memory.current MiB | MemAvailable min MiB | ENA allowance counters grown | ListenDrops | TCP in use peak | TCP memory peak (pages) | kernel OOM lines new in the run | dial errors |"
  echo "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|"
  all_runs | jq -r "$PRELUDE"'
    "| \(.folder) | \(.server.accepts_per_s_median | r1) | \(.server.accepts_per_s_max_plateau | r1) | \(.server.accepts_per_s_max_run | r1) | \(.server.cpu_busy_median | pct) | \(.loadbox.k6_memory_peak_bytes | gib) | \(.loadbox.cpu_max | pct) | \(.loadbox.seconds_over_85 // "-") (\(.loadbox.longest_streak_over_85 // "-")) / \(.loadbox.plateau_seconds // "-") | \(.server.memory_current_peak | mib) | \(if .server.mem_available_min_kb == null then "-" else (.server.mem_available_min_kb / 1024 | round) end) | \(.server.ena_allowance_diff // {} | to_entries | map(select(.value > 0 and (.key | endswith("_exceeded"))) | "\(.key) +\(.value)") | if length == 0 then "none" else join(", ") end) | \(.server.listen_drops // "-") | \(.server.tcp_inuse_peak // "-") | \(.server.tcp_mem_peak // "-") | \(if .server.oom_lines_start == null or .server.oom_lines_end == null then "-" else .server.oom_lines_end - .server.oom_lines_start end) | \(.dial_errors) |"'
  echo
  echo "| Run | users | pps_allowance_exceeded (packets over the packets-a-second allowance, over the run) | conntrack_allowance_exceeded | conntrack_allowance_available change | reading |"
  echo "|---|---|---|---|---|---|"
  all_runs | jq -r "$PRELUDE"'
    "| \(.folder) | \(.users) | \(.server.ena_allowance_diff.pps_allowance_exceeded // "-") | \(.server.ena_allowance_diff.conntrack_allowance_exceeded // "-") | \(.server.ena_allowance_diff.conntrack_allowance_available // "-") | \(if .pass then "valid pass" elif .void then "void (k6 over the line)" else "fail" end) |"'
  echo
  if [ -f "$DIR/search.json" ]; then
    echo "| # | decision | reason |"
    echo "|---|---|---|"
    jq -r '.decisions | to_entries[] | "| \(.key + 1) | \(.value.decision) | \(.value.reason) |"' "$DIR/search.json"
    echo
    jq -r '"End: **\(.end.result)**" + (if .end.score != null then ", score **\(.end.score)**" else "" end) + ". \(.end.reason)"' "$DIR/search.json"
  else
    echo "The decisions, in the load box's clock (UTC), as the by-hand script logged them:"
    echo
    echo '```text'
    cat "$DIR/decisions.log"
    echo '```'
  fi
}

first=1
for d in ${SEARCH_DIRS:-search-1-void search-2 search-3}; do
  [ -f "$d/search.json" ] || [ -f "$d/decisions.log" ] || continue
  [ "$first" = 1 ] || echo
  first=0
  echo "### ${d%%/*}"
  echo
  tables "$d"
done
