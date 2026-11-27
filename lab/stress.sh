#!/usr/bin/env bash
# Stress test of a server whose responses say which request they answer: lab/conformance/stress.php sends requests that each carry an
# id over many connections and checks that every response is the one of its request, in order on its connection. Starts the server the way
# lab/conformance.sh does, runs the client in a second container on the same host network (the load CPUs), once per pipeline setting.
#
#   bash lab/stress.sh --image 8.5 --server lab/servers/uring-noop.php --ext sockets --seccomp-unconfined
#                      [--env K=V]... [--connections 1000] [--requests 2000000] [--procs 4] [--pipelines 1,16] [--port 18110]
#                      [--path '/noop?id={id}'] [--app]
#
# --path is the request's target, `{id}` standing for the id. `/noop?id={id}` (the default) is for lab/servers/uring-noop.php, which echoes
# the id (`{"status":"ok","id":<n>}`, unique ids, byte for byte). `/posts/{id}` is for the challenge app (or the bake-off's handler): the ids are
# random posts of the seed (1 to 500,000) and each response must be a 200 whose post has that id. --app starts the server as the challenge
# app, on a fresh copy of the seed with SQLITE_PATH and JWT_SECRET (lab_start_app), like lab/challenge-test.sh does.
#
# The first line says the loop the server printed at boot (`event loop the server printed at boot: ring, 3 rings, ...`); then one line per
# pipeline setting, `ok    pipeline=<n>: <totals>` or `FAIL  pipeline=<n>: <totals>`; then the last `ring:` line the server printed (its turns,
# requests and requests per turn). Exit 0 when every setting finds 0 mismatches and 0 lost, 1 when one does not or
# the run could not be done, 2 on a usage error. Both containers are removed at the end, whatever happens.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$LAB/lib.sh"

SERVER=lab-stress-server
CLIENT=lab-stress-client

usage() {
  echo "usage: lab/stress.sh --image <variant> --server <php file under lab/ or submissions/> [--ext <name>]... [--env K=V]... [--seccomp-unconfined]" >&2
  echo "                     [--connections <n>] [--requests <n>] [--procs <n>] [--pipelines 1,16] [--port <n>] [--path <template with {id}>] [--app]" >&2
  exit 2
}
fail() { echo "stress: $*" >&2; exit 1; }

image="" server_file="" port=18110 connections=1000 requests=2000000 procs=4 pipelines=1,16 path='/noop?id={id}' app=""
LAB_EXT=() LAB_ENV=()
while [ "$#" -gt 0 ]; do
  if [ "$1" = --seccomp-unconfined ]; then export LAB_SERVER_SECCOMP_UNCONFINED=1; shift; continue; fi
  if [ "$1" = --app ]; then app=1; shift; continue; fi
  [ "$#" -ge 2 ] || { echo "missing value for $1" >&2; usage; }
  case "$1" in
    --image) image="$2" ;;
    --server) server_file="$2" ;;
    --ext) LAB_EXT+=("$2") ;;
    --env) LAB_ENV+=("$2") ;;
    --port) port="$2" ;;
    --connections) connections="$2" ;;
    --requests) requests="$2" ;;
    --procs) procs="$2" ;;
    --pipelines) pipelines="$2" ;;
    --path) path="$2" ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
  shift 2
done
[ -n "$image" ] && [ -n "$server_file" ] || usage
for n in port connections requests procs; do
  [[ "${!n}" =~ ^[1-9][0-9]*$ ]] || { echo "--$n must be a whole number above 0, got '${!n}'" >&2; usage; }
done
[[ "$pipelines" =~ ^[1-9][0-9]*(,[1-9][0-9]*)*$ ]] || { echo "--pipelines must be whole numbers separated by commas, got '$pipelines'" >&2; usage; }
[[ "$path" == *'{id}'* ]] || { echo "--path must hold {id}, got '$path'" >&2; usage; }
[ "${#LAB_EXT[@]}" -gt 0 ] || LAB_EXT=(sockets)

lab_require_variant "$image" || exit 1
docker image inspect "$LAB_IMAGE:$image" >/dev/null 2>&1 || fail "image $LAB_IMAGE:$image is missing (run lab/build.sh $image)"
server_in="$(lab_in_container_path "$server_file")" || exit 1
if [ -n "$(docker ps -a --format '{{.Names}}' | grep -x -e "$SERVER" -e "$CLIENT" || true)" ]; then
  fail "a lab/stress.sh run is in progress, or one was killed: remove its containers first (docker rm -f $SERVER $CLIENT)"
fi

cleanup() {
  local rc=$?
  docker rm -f "$SERVER" "$CLIENT" >/dev/null 2>&1 || true
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

# Far above the client's connections: a client that runs out of descriptors is a harness failure.
docker run -d --name "$CLIENT" --network host --cpuset-cpus "$LAB_CPUSET_K6" --ulimit nofile=200000:200000 \
  -v "$LAB:/lab:ro" "$LAB_IMAGE:$image" sleep 86400 >/dev/null
poll() { docker exec "$CLIENT" php /lab/conformance/client.php poll "$port"; }

# Why: a server that cannot bind would let the wait below succeed against somebody else's server.
if poll; then
  fail "port $port is already in use on the VM's host network: pick another with --port"
fi

lab_build_php_flags
if [ -n "$app" ]; then
  # Why disable SC2034: lab_start_app (lib.sh) reads LAB_COLD.
  # shellcheck disable=SC2034
  LAB_COLD=0
  lab_start_app "$SERVER" "$image" "$port" "$server_in"
else
  lab_start_server "$SERVER" "$image" "$port" "$server_in"
fi

# The server copies the seed (250 MB) before it listens: up to 30 s, and it must still be running while we wait.
ready=""
for _ in $(seq 1 150); do
  if [ "$(docker inspect -f '{{.State.Running}}' "$SERVER")" != true ]; then
    echo "stress: the server container exited:" >&2
    docker logs "$SERVER" >&2 || true
    exit 1
  fi
  if poll; then ready=1; break; fi
  sleep 0.2
done
[ -n "$ready" ] || { docker logs "$SERVER" >&2 || true; fail "the server did not listen on port $port within 30 s"; }
# The loop the server booted on (a server that falls back to another loop says so here).
loop="$(lab_loop_line "$SERVER")"
echo "event loop the server printed at boot: ${loop:-(none printed)}"

rc=0
IFS=, read -r -a settings <<<"$pipelines"
for p in "${settings[@]}"; do
  out=0
  result="$(docker exec "$CLIENT" php -d memory_limit=-1 /lab/conformance/stress.php "$port" --connections "$connections" --requests "$requests" \
    --procs "$procs" --pipeline "$p" --path "$path")" || out=$?
  if [ "$out" = 0 ]; then
    echo "ok    pipeline=$p: $result"
  else
    echo "FAIL  pipeline=$p: ${result:-no output (exit code $out)}"
    rc=1
  fi
done
# The server prints a line a second while it works: the last one with requests in it is the end of the run's last second.
sleep 1.2
ring_line="$(docker logs "$SERVER" 2>&1 | sed -n 's/^ring: //p' | grep -v 'requests=0 ' | tail -n 1 || true)"
echo "last busy second of the server: ${ring_line:-(none printed)}"
exit "$rc"
