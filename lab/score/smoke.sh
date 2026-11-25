#!/usr/bin/env bash
# The score search on the Mac at a small size, against the submission in a lab container (lab/score/ctl-local.sh): proves the driver, the
# samplers and the analysis end to end before any AWS run. Nothing it prints is a measurement.
#
#   bash lab/score/smoke.sh [--out <dir>]        the whole search, at a small size
#   bash lab/score/smoke.sh --k6-memory [--out <dir>]   k6's memory a VU (see below)
#
# The search: a warm-up of 50 users for 20 s, probes from 200 users (50 % steps rounded to 10: 200, 300, 450) of 20 s, holds of 30 s, a
# 10 s ramp, 3 s between runs. The controller stops the server right after its 4th and 5th restarts, so the third probe and the first hold fail
# (k6 exits 99 on errors): the search must walk warm-up, probe pass, probe pass, probe fail, hold fail, hold pass (150 users), and exit 0.
# The smoke checks that sequence and that each run's JSON has every field the analysis promises; it exits 0 only then. The folder keeps
# search.json and a folder a run (printed at the end).
#
# --k6-memory: the challenge's bench/load.js once at 1, 2,000 and 5,000 users, with its real think time and its own 60 s ramp, 1 minute of plateau,
# against the local server; prints the k6 container's memory peak of each, and the peak a VU at 2,000 and 5,000 users with and without the memory
# of the 1-user run (the k6 process, the script and the tokens, before any VU). This is the one number of the Mac run that is meant to be read:
# k6's memory does not depend on a quiet CPU. It sizes the load box (a c5.2xlarge has 16 GiB).
set -euo pipefail

LAB="$(cd "$(dirname "$0")/.." && pwd)"

usage() { echo "usage: lab/score/smoke.sh [--k6-memory] [--out <dir>]" >&2; exit 2; }
fail() { echo "smoke: $*" >&2; exit 1; }

mode=search out=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --k6-memory) mode=memory; shift ;;
    --out) [ "$#" -ge 2 ] || usage; out="$2"; shift 2 ;;
    *) usage ;;
  esac
done
[ -n "$out" ] || out="$(mktemp -d)/score-smoke"
[ -f "$LAB/data/tokens.json" ] || fail "lab/data/tokens.json is missing (run lab/seed.sh)"
state="$(mktemp -d)"
export SCORE_CTL_STATE="$state"
ctl="bash $LAB/score/ctl-local.sh"
base_url=http://127.0.0.1:18130
cleanup() {
  docker rm -f lab-score-server lab-score-k6 lab-score-loadbox >/dev/null 2>&1 || true
  rm -rf "$state"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

smoke_search() {
  local want got
  SCORE_CTL_FAIL_RESTARTS=4,5 bash "$LAB/score/search.sh" --base-url "$base_url" --ctl "$ctl" --out "$out" --tokens "$LAB/data/tokens.json" \
    --start 200 --step 50 --round 10 --warmup 50,20s --probe 20s --hold 30s --ramp-up 10s --pause 3 || fail "search.sh exited $?"
  want="warmup:50:true probe:200:true probe:300:true probe:450:false hold:300:false hold:150:true"
  got="$(jq -r '[.runs[] | "\(.kind):\(.users):\(.pass)"] | join(" ")' "$out/search.json")"
  [ "$got" = "$want" ] || fail "the runs are '$got', expected '$want'"
  [ "$(jq -r '.end | [.result, .score] | join(" ")' "$out/search.json")" = "score 150" ] || fail "the search does not end on the score 150: $(jq -c .end "$out/search.json")"
  local f missing
  for f in "$out"/[0-9]*/run.json; do
    missing="$(jq -r '[ "kind", "users", "k6_exit", "pass", "void", "p95_ms", "p99_ms", "error_rate", "http_reqs", "plateau", "vu_init_s", "server", "loadbox", "healthy_s", "wall"
      | select(. as $k | $ARGS.named.run | has($k) | not) ] | join(" ")' --argjson run "$(cat "$f")")"
    [ -z "$missing" ] || fail "$f lacks: $missing"
    jq -e '.plateau != null and .server.us_per_req != null and .server.accepts_per_s_median != null and .server.rows > 10 and .loadbox.k6_memory_peak_bytes != null' "$f" >/dev/null \
      || { [ "$(jq -r '.pass' "$f")" = false ] || fail "$f has no plateau, us/req, accepts a second or load box memory: $(jq -c '{plateau, us: .server.us_per_req, rows: .server.rows}' "$f")"; }
  done
  echo "smoke: ok, the folder is $out"
}

smoke_k6_memory() {
  local users run
  mkdir -p "$out"
  for users in 1 2000 5000; do
    echo "k6 memory: $users users" >&2
    bash "$LAB/score/run-k6.sh" --base-url "$base_url" --ctl "$ctl" --out "$out/users-$users" --kind memory --users "$users" --duration 1m \
      --tokens "$LAB/data/tokens.json" || fail "run-k6.sh failed at $users users"
    sleep 3
  done
  jq -n --slurpfile a "$out/users-1/run.json" --slurpfile b "$out/users-2000/run.json" --slurpfile c "$out/users-5000/run.json" '
    def mib: . / 1048576;
    ($a[0].loadbox.k6_memory_peak_bytes) as $base
    | [{users: 1, peak: $base}, {users: 2000, peak: $b[0].loadbox.k6_memory_peak_bytes}, {users: 5000, peak: $c[0].loadbox.k6_memory_peak_bytes}]
    | map(. + {peak_mib: (.peak | mib), mib_per_vu: ((.peak | mib) / .users), mib_per_vu_over_baseline: (((.peak - $base) | mib) / .users)})' >"$out/k6-memory.json"
  jq -r '.[] | "users \(.users): peak \(.peak_mib * 10 | round / 10) MiB, \(.mib_per_vu * 1000 | round / 1000) MiB a VU, \(.mib_per_vu_over_baseline * 1000 | round / 1000) MiB a VU over the 1-user run"' "$out/k6-memory.json"
  for run in 2000 5000; do
    [ "$(jq -r '.k6_exit' "$out/users-$run/run.json")" = 0 ] || echo "smoke: note: k6 exited $(jq -r '.k6_exit' "$out/users-$run/run.json") at $run users (thresholds are not the point here)" >&2
  done
}

if [ "$mode" = memory ]; then smoke_k6_memory; else smoke_search; fi
