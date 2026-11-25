#!/usr/bin/env bash
# Runs the challenge's own test suite (reference/twelve-dollar-server-challenge/test/test.sh, unchanged) against a server that
# reads the challenge's environment (SQLITE_PATH, JWT_SECRET, HOST, PORT). The server starts in a lab container on a fresh copy
# of the seed (lab_start_app: the suite's golden answers need a fresh database, and it writes to it); the suite runs in a second
# container on the same host network, from an image with the four programs it needs (lab/images/Dockerfile.tools).
#
#   bash lab/challenge-test.sh --image 8.5 [--server <php file under lab/ or submissions/>] [--php-ini <php.ini>] [--ext sockets --ext event] [--env K=V]... [--port 18110]
#
# --env K=V (repeatable) is passed to the server container, after JWT_SECRET and SQLITE_PATH: the way to run the suite on a variant
# (`--env APP_SOFT_CONN_LIMIT=0`).
#
# Prints the suite's output and exits with its code (0: every check passed). Exit 1 too when the server never answers
# GET /health (60 s at most, like test/run.sh), 2 on a usage error. Both containers are removed at the end, whatever happens.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$LAB")"
# shellcheck source=lib.sh
source "$LAB/lib.sh"

SERVER=lab-challenge-server
TESTER=lab-challenge-test

usage() {
  echo "usage: lab/challenge-test.sh --image <variant> [--server <php file under lab/ or submissions/>] [--php-ini <php.ini under lab/>] [--ext <name>]... [--env K=V]... [--port <n>]" >&2
  exit 2
}
fail() { echo "challenge-test: $*" >&2; exit 1; }

image="" server_file="$LAB/app/server.php" port=18110
LAB_EXT=() LAB_ENV=()
LAB_PHP_INI_FILE=""
# Why disable SC2034: lab_build_php_flags (lib.sh) reads LAB_PHP_INI_FILE, set below.
# shellcheck disable=SC2034
while [ "$#" -gt 0 ]; do
  [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; usage; }
  case "$1" in
    --image) image="$2" ;;
    --server) server_file="$2" ;;
    --php-ini) LAB_PHP_INI_FILE="$(lab_in_container_path "$2")" || exit 2 ;;
    --ext) LAB_EXT+=("$2") ;;
    --env) [[ "$2" == ?*=* ]] || { echo "--env must be K=V, got '$2'" >&2; usage; }; LAB_ENV+=("$2") ;;
    --port) port="$2" ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
  shift 2
done
[ -n "$image" ] || usage
[[ "$port" =~ ^[0-9]+$ ]] || { echo "--port must be a whole number, got '$port'" >&2; usage; }
[ "${#LAB_EXT[@]}" -gt 0 ] || LAB_EXT=(sockets event)

lab_require_variant "$image" || exit 1
docker image inspect "$LAB_IMAGE:$image" >/dev/null 2>&1 || fail "image $LAB_IMAGE:$image is missing (run lab/build.sh $image)"
server_in="$(lab_in_container_path "$server_file")" || exit 1
[ -f "$LAB/data/feed.db" ] || fail "lab/data/feed.db is missing (run lab/seed.sh)"
# -P: the folder may be reached through a symlink (a worktree's reference/), which Docker cannot mount.
challenge="$(cd -P "$REPO/reference/twelve-dollar-server-challenge" 2>/dev/null && pwd)" || fail "reference/twelve-dollar-server-challenge is missing"
[ -f "$challenge/test/test.sh" ] || fail "$challenge/test/test.sh is missing"
if [ -n "$(docker ps -a --format '{{.Names}}' | grep -x -e "$SERVER" -e "$TESTER" || true)" ]; then
  fail "a lab/challenge-test.sh run is in progress, or one was killed: remove its containers first (docker rm -f $SERVER $TESTER)"
fi
lab_ensure_tools_image

cleanup() {
  local rc=$?
  docker rm -f "$SERVER" "$TESTER" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

docker run -d --name "$TESTER" --network host --cpuset-cpus "$LAB_CPUSET_PROBE" -v "$challenge:/challenge:ro" \
  "$LAB_TOOLS_IMAGE" sleep 86400 >/dev/null
healthy() { docker exec "$TESTER" curl -sf -m 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1; }

# Why: a server that cannot bind would let the wait below succeed against somebody else's server.
if healthy; then
  fail "port $port is already in use on the VM's host network: pick another with --port"
fi

lab_build_php_flags
lab_start_app "$SERVER" "$image" "$port" "$server_in"

# The server copies the seed (250 MB) before it listens, and must still be running while we wait.
ready=""
for _ in $(seq 1 120); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$SERVER")" != true ]; then
    echo "challenge-test: the server container exited:" >&2
    docker logs "$SERVER" >&2 || true
    exit 1
  fi
  if healthy; then ready=1; break; fi
  sleep 0.5
done
[ -n "$ready" ] || { docker logs "$SERVER" >&2 || true; fail "GET /health did not answer on port $port within 60 s"; }

rc=0
docker exec -e "JWT_SECRET=$LAB_JWT_SECRET" "$TESTER" bash /challenge/test/test.sh "http://127.0.0.1:$port" || rc=$?
exit "$rc"
