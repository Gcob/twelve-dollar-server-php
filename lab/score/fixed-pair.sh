#!/usr/bin/env bash
# The fixed-load pair of the score session: the same load at a fixed user count on two servers, in the order A B B A, so a drift of the boxes
# (a warm cache, a neighbour) cancels in the difference. Each run is lab/score/run-k6.sh: the server restarts on a fresh database, the samplers
# run, the usual pause lies between two runs. It writes <out>/pair.json and judges nothing: whether the difference means anything on two boxes
# is for a person to read.
#
#   bash lab/score/fixed-pair.sh --a-url <url> --a-ctl <command> --b-url <url> --b-ctl <command> --out <dir> [--users 101000] [--duration 2m]
#                                [--pause 60] [--halves 1|2] [--load-cpus <lo-hi>] [--local-ips <list>] [--ramp-up <d>] [--tokens <file>]
#                                [--challenge <dir>] [--api <host:port>]
#
# <command> is a server controller's command line, as for lab/score/search.sh. Prints one row a run, then each server's mean and the B minus A
# difference of each pair (pair 1 is runs 1 and 2, pair 2 is runs 3 and 4). pair.json has:
#   runs   in order: the server (A or B), the folder, pass, void, k6_exit, us_per_req, service_share, p95_ms, p99_ms, req_per_s, loop (the server's
#          `loop:` line when its controller can read it)
#   means  per server: the mean of its two runs' us_per_req, service_share and p99_ms
#   pairs  per pair: the order of its two runs and B minus A of each of the three numbers
# A run that fails or is void is still in the file (with its pass and void): nothing is dropped. Exit codes: 0 the four runs are done, 1 a harness error
# (run-k6.sh failed, or k6 exited with something other than 0 or 99), 2 usage. It refuses to start when --out exists.
set -euo pipefail

LAB="$(cd "$(dirname "$0")/.." && pwd)"
REPO="$(dirname "$LAB")"
# shellcheck source=score-lib.sh
source "$LAB/score/score-lib.sh"

usage() {
  echo "usage: lab/score/fixed-pair.sh --a-url <url> --a-ctl <command> --b-url <url> --b-ctl <command> --out <dir> [--users 101000] [--duration 2m] [--pause 60] [--halves 1|2] [--load-cpus <lo-hi>] [--local-ips <list>] [--ramp-up <d>] [--tokens <file>] [--challenge <dir>] [--api <host:port>]" >&2
  exit 2
}
refuse() { echo "fixed-pair: $*" >&2; exit 2; }

a_url="" a_ctl="" b_url="" b_ctl="" out="" users=101000 duration=2m pause=60 halves=1 load_cpus="" local_ips="" ramp_up="" tokens=""
challenge="$REPO/reference/twelve-dollar-server-challenge" api=127.0.0.1:6565
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || usage
  case "$1" in
    --a-url) a_url="$2" ;;
    --a-ctl) a_ctl="$2" ;;
    --b-url) b_url="$2" ;;
    --b-ctl) b_ctl="$2" ;;
    --out) out="$2" ;;
    --users) users="$2" ;;
    --duration) duration="$2" ;;
    --pause) pause="$2" ;;
    --halves) halves="$2" ;;
    --load-cpus) load_cpus="$2" ;;
    --local-ips) local_ips="$2" ;;
    --ramp-up) ramp_up="$2" ;;
    --tokens) tokens="$2" ;;
    --challenge) challenge="$2" ;;
    --api) api="$2" ;;
    *) usage ;;
  esac
  shift 2
done
[ -n "$a_url" ] && [ -n "$a_ctl" ] && [ -n "$b_url" ] && [ -n "$b_ctl" ] && [ -n "$out" ] || usage
for v in "$users" "$pause"; do [[ "$v" =~ ^[0-9]+$ ]] || refuse "a number is expected, got '$v'"; done
[ "$users" -gt 0 ] || refuse "--users is above 0"
[[ "$halves" =~ ^[12]$ ]] || refuse "--halves is 1 or 2, got '$halves'"
score_seconds "$duration" >/dev/null || refuse "a duration like 20s or 2m is expected, got '$duration'"
challenge="$(cd -P "$challenge" 2>/dev/null && pwd)" || refuse "no challenge folder: $challenge"
score_load_js_ok "$challenge/bench/load.js" || refuse "$challenge/bench/load.js is not the challenge's script (git blob $SCORE_LOAD_JS_BLOB at commit 162699a): nothing was run"
[ ! -e "$out" ] || refuse "$out exists: pick a new folder, a pair never overwrites one"
mkdir -p "$out"
out="$(cd -P "$out" && pwd)"

echo "run  server  users  pass  p95 ms  p99 ms   req/s   cpu%   us/req  loop"
# one_run <n> <A|B>: runs k6 once against that server and prints the row.
one_run() {
  local n="$1" which="$2" url ctl rc=0 folder extra=()
  if [ "$which" = A ]; then url="$a_url" ctl="$a_ctl"; else url="$b_url" ctl="$b_ctl"; fi
  folder="$(printf '%02d-%s' "$n" "$(echo "$which" | tr '[:upper:]' '[:lower:]')")"
  [ "$n" -eq 1 ] || sleep "$pause"
  [ -z "$ramp_up" ] || extra+=(--ramp-up "$ramp_up")
  [ -z "$local_ips" ] || extra+=(--local-ips "$local_ips")
  [ -z "$tokens" ] || extra+=(--tokens "$tokens")
  [ -z "$load_cpus" ] || extra+=(--load-cpus "$load_cpus")
  bash "$LAB/score/run-k6.sh" --base-url "$url" --ctl "$ctl" --out "$out/$folder" --kind pair --users "$users" --duration "$duration" \
    --challenge "$challenge" --api "$api" --halves "$halves" ${extra[@]+"${extra[@]}"} || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "fixed-pair: the harness failed at $folder: $(jq -r '.harness_error // "run-k6 exited \($rc)"' --argjson rc "$rc" "$out/$folder/run.json" 2>/dev/null || echo "run-k6 exited $rc")" >&2
    exit 1
  fi
  if [ "$(jq -r '.k6_exit' "$out/$folder/run.json")" != 0 ] && [ "$(jq -r '.k6_exit' "$out/$folder/run.json")" != 99 ]; then
    echo "fixed-pair: k6 exited with $(jq -r '.k6_exit' "$out/$folder/run.json") at $folder: not a pass and not a threshold failure" >&2
    exit 1
  fi
  jq -r --arg n "$n" --arg w "$which" '[$n, $w, .users, .pass, (.p95_ms // 0 | . * 10 | round / 10), (.p99_ms // 0 | . * 10 | round / 10), (.plateau.req_per_s // 0 | round),
          ((.server.service_share // 0) * 1000 | round / 10), (.server.us_per_req // 0 | round), (.server.loop // "-")] | @tsv' "$out/$folder/run.json" \
    | awk -F'\t' '{ printf "%-4s %-7s %5d  %-5s %7s %7s %7d %6.1f %7d  %s\n", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10 }'
  printf '%s %s\n' "$which" "$folder" >>"$out/.order"
}

n=0
for which in A B B A; do
  n=$((n + 1))
  one_run "$n" "$which"
done

# pair.json: from the four run.json files, in order.
args=()
while read -r which folder; do args+=("$which:$out/$folder/run.json"); done <"$out/.order"
rm -f "$out/.order"
runs='[]'
i=0
for a in "${args[@]}"; do
  i=$((i + 1))
  runs="$(jq -c --arg w "${a%%:*}" --arg f "$(basename "$(dirname "${a#*:}")")" --argjson n "$i" --slurpfile r "${a#*:}" \
    '. + [$r[0] | {n: $n, server: $w, folder: $f, pass, void, k6_exit, us_per_req: .server.us_per_req, service_share: .server.service_share,
                   p95_ms, p99_ms, req_per_s: .plateau.req_per_s, loop: .server.loop}]' <<<"$runs")"
done
jq -n --argjson runs "$runs" --argjson users "$users" --arg duration "$duration" --argjson halves "$halves" '
  def mean: map(select(. != null)) | if length == 0 then null else add / length end;
  def minus($b; $a): if $b == null or $a == null then null else $b - $a end;
  def pick($which; $k): [$runs[] | select(.server == $which) | .[$k]] | mean;
  def one($r; $w): $r | select(.server == $w);
  {users: $users, duration: $duration, halves: $halves, order: ["A", "B", "B", "A"], runs: $runs,
   means: (["A", "B"] | map(. as $w | {key: $w, value: {us_per_req: pick($w; "us_per_req"), service_share: pick($w; "service_share"), p99_ms: pick($w; "p99_ms")}}) | from_entries),
   pairs: ([[$runs[0], $runs[1]], [$runs[2], $runs[3]]] | to_entries | map(.value as $p | ($p | map(select(.server == "A"))[0]) as $a | ($p | map(select(.server == "B"))[0]) as $b
           | {pair: (.key + 1), order: ($p | map(.server) | join(" ")), a_run: $a.n, b_run: $b.n,
              us_per_req_b_minus_a: minus($b.us_per_req; $a.us_per_req), service_share_b_minus_a: minus($b.service_share; $a.service_share), p99_ms_b_minus_a: minus($b.p99_ms; $a.p99_ms)}))}' >"$out/pair.json"
jq -r '"mean A: \(.means.A.us_per_req // 0 | round) us/req, \((.means.A.service_share // 0) * 1000 | round / 10) % of the core, p99 \(.means.A.p99_ms // 0 | round) ms",
       "mean B: \(.means.B.us_per_req // 0 | round) us/req, \((.means.B.service_share // 0) * 1000 | round / 10) % of the core, p99 \(.means.B.p99_ms // 0 | round) ms",
       (.pairs[] | "pair \(.pair) (\(.order)): B minus A = \(.us_per_req_b_minus_a // 0 | . * 10 | round / 10) us/req")' "$out/pair.json"
