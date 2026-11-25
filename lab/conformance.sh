#!/usr/bin/env bash
# Checks that a bake-off server speaks HTTP/1.1 correctly while it answers with lab/servers/handler.php: starts it in a lab
# container (the way lab/macro.sh does), then runs lab/conformance/client.php (raw sockets, no curl) in a second container on
# the same host network.
#
#   bash lab/conformance.sh --image 8.5 --server lab/servers/bake-swoole.php [--ext <name>]... [--env K=V]... [--port 18090]
#                           [--seccomp-unconfined]
#
# One line per case, `ok    <case>` or `FAIL  <case>: <why>`; exit 0 when every case is ok, 1 when one fails or the run could not
# be done, 2 on a usage error. The cases: /noop, /posts/1 (against what sqlite3 gives for the seed), the error bodies, two
# requests on a keep-alive connection, three pipelined requests, a request split across two writes, a POST with a body and the
# reuse of its connection. --seccomp-unconfined starts the server container without Docker's default seccomp filter, which refuses io_uring
# (only lab/servers/uring-noop.php needs it). After them: the exact bytes of the /noop response, the `loop:` line the server printed at boot
# (when it prints one) and its socket line (backlog, tcp_nodelay). Both containers are removed at the end, whatever happens.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$LAB/lib.sh"

SERVER=lab-conformance-server
CLIENT=lab-conformance-client

usage() {
  echo "usage: lab/conformance.sh --image <variant> --server <php file under lab/ or submissions/> [--ext <name>]... [--env K=V]... [--port <n>] [--seccomp-unconfined]" >&2
  exit 2
}
fail() { echo "conformance: $*" >&2; exit 1; }

image="" server_file="" port=18090
LAB_EXT=() LAB_ENV=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --seccomp-unconfined ]; then export LAB_SERVER_SECCOMP_UNCONFINED=1; shift; continue; fi
  [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; usage; }
  case "$1" in
    --image) image="$2" ;;
    --server) server_file="$2" ;;
    --ext) LAB_EXT+=("$2") ;;
    --env) LAB_ENV+=("$2") ;;
    --port) port="$2" ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
  shift 2
done
[ -n "$image" ] && [ -n "$server_file" ] || usage
[[ "$port" =~ ^[0-9]+$ ]] || { echo "--port must be a whole number, got '$port'" >&2; usage; }
[ "${#LAB_EXT[@]}" -gt 0 ] || LAB_EXT=(swoole)

lab_require_variant "$image" || exit 1
docker image inspect "$LAB_IMAGE:$image" >/dev/null 2>&1 || fail "image $LAB_IMAGE:$image is missing (run lab/build.sh $image)"
server_in="$(lab_in_container_path "$server_file")" || exit 1
if [ -n "$(docker ps -a --format '{{.Names}}' | grep -x -e "$SERVER" -e "$CLIENT" || true)" ]; then
  fail "a lab/conformance.sh run is in progress, or one was killed: remove its containers first (docker rm -f $SERVER $CLIENT)"
fi
command -v jq >/dev/null || fail "jq is needed (it turns the expected post into JSON)"

# What SQLite gives for post 1 with the spec's query, read here on the Mac, outside the server under test. `username` is
# the `author` key of the API. immutable=1: lab/data/feed.db is in WAL mode, a normal open would leave -wal and -shm files.
seed="$LAB/data/feed.db"
[ -f "$seed" ] || fail "lab/data/feed.db is missing (run lab/seed.sh)"
expected_post_1="$(sqlite3 -json "file:${seed// /%20}?immutable=1" "
  SELECT p.id, p.body, p.created_at, u.username,
         (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
    FROM posts p JOIN users u ON u.id = p.user_id WHERE p.id = 1" \
  | jq -c '.[0] | {id, body, created_at, author: .username, like_count}')"
[ -n "$expected_post_1" ] && [ "$expected_post_1" != null ] || fail "sqlite3 gave no post 1"

cleanup() {
  local rc=$?
  docker rm -f "$SERVER" "$CLIENT" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

docker run -d --name "$CLIENT" --network host --cpuset-cpus "$LAB_CPUSET_PROBE" -v "$LAB:/lab:ro" "$LAB_IMAGE:$image" sleep 86400 >/dev/null
client() { docker exec -e "EXPECTED_POST_1=$expected_post_1" "$CLIENT" php /lab/conformance/client.php "$@"; }

# Why: a server that cannot bind would let the wait below succeed against somebody else's server.
if client poll "$port"; then
  fail "port $port is already in use on the VM's host network: pick another with --port"
fi

lab_build_php_flags
lab_start_server "$SERVER" "$image" "$port" "$server_in"

# The server copies the seed (250 MB) before it listens: up to 30 s, and it must still be running while we wait.
ready=""
for _ in $(seq 1 150); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$SERVER")" != true ]; then
    echo "conformance: the server container exited:" >&2
    docker logs "$SERVER" >&2 || true
    exit 1
  fi
  if client poll "$port"; then ready=1; break; fi
  sleep 0.2
done
[ -n "$ready" ] || { docker logs "$SERVER" >&2 || true; fail "the server did not listen on port $port within 30 s"; }

rc=0
client run "$port" || rc=$?
loop="$(docker logs "$SERVER" 2>&1 | sed -n 's/^loop: //p' | head -n 1)"
[ -z "$loop" ] || echo "event loop the server printed at boot: $loop"
socket="$(lab_socket_line "$SERVER")"
echo "socket settings the server printed at boot: ${socket:-(none printed)}"
exit "$rc"
