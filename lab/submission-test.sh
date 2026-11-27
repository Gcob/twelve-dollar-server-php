#!/usr/bin/env bash
# Installs and tests submissions/php-Gcob in a clean Ubuntu 24.04 container, the way the challenge's bench does it, or (--ci) the way
# the challenge's own CI does it.
#
#   bash lab/submission-test.sh [--ci] [--keep]
#
# Default mode (the bench, LEADERBOARD.md): `bash install.sh` as root, `build.sh` as the user `deploy`, then, as `deploy` with only
# CAP_NET_BIND_SERVICE (setpriv, like systemd's AmbientCapabilities), the challenge's test/run.sh on port 80; then a second start on
# 0.0.0.0:80 whose /health is read from the container's own address, with the user and the open-files limit of every server process
# read from /proc, and a negative check: without the capability `deploy` cannot bind port 80.
#
# --ci (.github/workflows/test.yml of the challenge): the runner image has Ubuntu's PHP 8.3 first on the PATH and its tools; the entry
# installs with `sudo bash php-Gcob/install.sh` from the repo's root (sudo resets the PATH), then test/run.sh runs as a normal user on its defaults (127.0.0.1:3000).
# A bare `phpize` in install.sh would build the extensions for 8.3 and fail here.
#
# What the container copies from the droplet: Ubuntu 24.04 (the lab's pinned digest), ONE CPU (so nproc is 1 and PHP compiles as slowly
# as it will there), 2 GiB with no swap, the unprivileged port floor at 1,024 (Docker sets 0 in containers) and 65,535 open files
# (systemd's LimitNOFILE). What it does not copy: the droplet's kernel, its network, systemd itself, the arm64 or x86 CPU (this VM may
# be arm64), and any other load: the times it prints are not a measurement. The container has its own network (port 80 is taken by
# other projects on this VM). The submission, the challenge's test/ and the seed are copied in, not mounted.
#
# Takes about 5 minutes (the SQLite built twice with its training and the PHP compile on one arm64 CPU, 277 s measured, against 222 s before the SQLite build; the droplet was not measured): run it in the background and follow the install log it names. Not run by
# lab/check.sh, which would take that long on every run. Prints one summary line per check, then `submission-test: ok` and exits 0 only
# when every check passed. The container and its network are removed at the end, whatever happens, unless --keep.
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$LAB")"
# shellcheck source=lib.sh
source "$LAB/lib.sh"

NAME=lab-submission-test
NET=lab-submission-test-net
ROOT=/srv
TEST_JWT_SECRET=twelve-dollar-challenge

usage() { echo "usage: lab/submission-test.sh [--ci] [--keep]" >&2; exit 2; }
fail() { echo "submission-test: $*" >&2; exit 1; }

mode=bench keep=0
for arg in "$@"; do
  case "$arg" in
    --ci) mode=ci ;;
    --keep) keep=1 ;;
    *) echo "unknown option: $arg" >&2; usage ;;
  esac
done

submission="$REPO/submissions/php-Gcob"
[ -f "$submission/install.sh" ] || fail "submissions/php-Gcob/install.sh is missing"
[ -f "$LAB/data/feed.db" ] || fail "lab/data/feed.db is missing (run lab/seed.sh)"
# -P: the folder may be reached through a symlink (a worktree's reference/), which tar would copy as a link.
challenge="$(cd -P "$REPO/reference/twelve-dollar-server-challenge" 2>/dev/null && pwd)" || fail "reference/twelve-dollar-server-challenge is missing"
[ -f "$challenge/test/run.sh" ] || fail "$challenge/test/run.sh is missing"
image="$(lab_base_image)"
[ -n "$image" ] || fail "no base image found in lab/images/Dockerfile.src"
if [ -n "$(docker ps -a --format '{{.Names}}' | grep -x "$NAME" || true)" ]; then
  fail "a lab/submission-test.sh container exists (a run in progress, or one kept): docker rm -f $NAME; docker network rm $NET first"
fi

work="$(mktemp -d)"
created=0
cleanup() {
  local rc=$?
  if [ "$keep" = 1 ]; then
    echo "kept: container $NAME on network $NET, logs in $work"
  else
    [ "$created" = 0 ] || { docker rm -f "$NAME" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
    rm -rf "$work"
  fi
  exit "$rc"
}
trap cleanup EXIT

failed=0
ok() { echo "$1"; }
bad() { echo "FAIL $1"; failed=1; }

# ex <docker exec options>... -- <command>...: runs in the container, in $ROOT unless -w says otherwise.
ex() { docker exec -w "$ROOT" "$@"; }
# as_deploy <command>...: as the user deploy with the capability to bind ports below 1,024 and nothing else added.
as_deploy() {
  ex "$NAME" setpriv --reuid deploy --regid deploy --init-groups --inh-caps +net_bind_service --ambient-caps +net_bind_service "$@"
}
# copy_in <folder> <name in $ROOT>: copies a folder with tar (docker cp would make a symlinked folder a link).
copy_in() {
  COPYFILE_DISABLE=1 tar -C "$1" --no-xattrs --exclude .DS_Store -cf - . | docker exec -i "$NAME" sh -c "mkdir -p '$ROOT/$2' && tar -C '$ROOT/$2' -xf -"
}
# show_tail <log>: the end of a log that explains a failure.
show_tail() { echo "--- last 30 lines of $1"; tail -30 "$1"; }

echo "submission-test: $mode mode, image $image"
docker network create "$NET" >/dev/null
# From here the network is ours, so cleanup removes it even if `docker run` fails (docker rm -f of a container that does not exist is silent).
created=1
# CI mode leaves the open-files limit at Docker's default: the runner has no systemd unit.
limits=(--cpuset-cpus "$LAB_CPUSET_SERVER" --memory 2g --memory-swap 2g --sysctl net.ipv4.ip_unprivileged_port_start=1024)
[ "$mode" = ci ] || limits+=(--ulimit nofile=65535:65535)
docker run -d --name "$NAME" --network "$NET" "${limits[@]}" "$image" sleep infinity >/dev/null
ok "container: $(ex "$NAME" nproc) CPU, $(docker inspect -f '{{.HostConfig.Memory}}' "$NAME") bytes of memory, port floor $(ex "$NAME" cat /proc/sys/net/ipv4/ip_unprivileged_port_start)"

copy_in "$submission" php-Gcob
copy_in "$challenge/test" test
ex "$NAME" mkdir -p "$ROOT/seed"
docker cp "$LAB/data/feed.db" "$NAME:$ROOT/seed/feed.db"
ex "$NAME" chmod -R a+rX "$ROOT"

# run_install <user, or empty for root> <folder to run from> <command words...>: the install, timed; its output goes to a log the caller can follow.
run_install() {
  local user="$1" dir="$2" started secs line
  shift 2
  echo "install: running, follow it with: tail -f $work/install.log"
  started="$(date +%s)"
  if ! docker exec ${user:+-u "$user"} -w "$dir" "$NAME" "$@" >"$work/install.log" 2>&1; then
    show_tail "$work/install.log"
    bad "install: failed"
    exit 1
  fi
  secs=$(( $(date +%s) - started ))
  ok "install: $secs s"
  line="$(grep '^installed: ' "$work/install.log" | tail -1 || true)"
  [ -n "$line" ] && ok "$line" || bad "install: no 'installed:' line at the end of the log"
}

if [ "$mode" = ci ]; then
  # The runner image: Ubuntu's PHP first on the PATH, then the workflow's tools, then sudo (the pinned image has none).
  ex "$NAME" bash -c 'apt-get update -qq && apt-get install -y -qq --no-install-recommends php8.3-cli php8.3-dev' >"$work/runner-image.log" 2>&1 \
    || { show_tail "$work/runner-image.log"; fail "apt-get install php8.3-cli php8.3-dev failed"; }
  ex "$NAME" bash -c 'apt-get install -y -qq --no-install-recommends sqlite3 jq curl openssl procps sudo' >>"$work/runner-image.log" 2>&1 \
    || { show_tail "$work/runner-image.log"; fail "apt-get install of the workflow's tools failed"; }
  ex "$NAME" useradd -m runner
  ex "$NAME" sh -c 'echo "runner ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/runner && chmod 440 /etc/sudoers.d/runner'
  ex "$NAME" chown -R runner:runner "$ROOT/php-Gcob"
  trap_php="$(ex -u runner "$NAME" sh -c 'command -v php; php -r "echo PHP_VERSION;"' | paste -sd' ' -)"
  case "$trap_php" in
    */php\ 8.3.*) ok "ci: php on the PATH is $trap_php (the trap is armed)" ;;
    *) bad "ci: expected Ubuntu's PHP 8.3 on the PATH, got: $trap_php" ;;
  esac
  # From the repo's root with the folder in the path, as the workflow runs it (`sudo bash <dir>/install.sh`).
  run_install runner "$ROOT" sudo bash php-Gcob/install.sh
  out="$(ex -u runner "$NAME" bash test/run.sh "$ROOT/php-Gcob" 2>&1)" || true
  if grep -qx 'passed=42 failed=0' <<<"$out"; then
    ok "run.sh: passed=42 failed=0 (127.0.0.1:3000, as runner)"
  else
    echo "$out" | tail -30; bad "run.sh: $(grep '^passed=' <<<"$out" || echo 'no summary line')"
  fi
else
  run_install "" "$ROOT/php-Gcob" bash install.sh

  # The test suite's tools come after the install, so that install.sh proves it brings its own curl. procps: pkill, which test/run.sh uses.
  ex "$NAME" bash -c 'apt-get install -y -qq --no-install-recommends curl jq openssl procps' >"$work/tools.log" 2>&1 \
    || { show_tail "$work/tools.log"; fail "apt-get install curl jq openssl failed"; }
  ex "$NAME" useradd -m deploy
  ex "$NAME" chown -R deploy:deploy "$ROOT/php-Gcob"
  if as_deploy bash "$ROOT/php-Gcob/build.sh" >"$work/build.log" 2>&1; then
    ok "build: ok (as deploy)"
  else
    show_tail "$work/build.log"; bad "build: failed"; exit 1
  fi

  out="$(as_deploy env PORT=80 bash test/run.sh "$ROOT/php-Gcob" 2>&1)" || true
  if grep -qx 'passed=42 failed=0' <<<"$out"; then
    ok "run.sh: passed=42 failed=0 (127.0.0.1:80, as deploy)"
  else
    echo "$out" | tail -30; bad "run.sh: $(grep '^passed=' <<<"$out" || echo 'no summary line')"
  fi

  # The second start: HOST=0.0.0.0 like the bench's systemd unit, on a fresh seed copy, left running while it is looked at.
  # It prints `healthy <s>`, `address <addr> <body>`, one `process <pid> <user> <open files soft limit>` per server process, then the
  # server's own output after `log-start`.
  read -r -d '' probe_script <<'PROBE' || true
dir="$(mktemp -d)"
export SQLITE_PATH="$dir/feed.db"
cp "$ROOT/seed/feed.db" "$SQLITE_PATH"
started=${EPOCHREALTIME/./}
bash "$ROOT/php-Gcob/start.sh" >"$dir/server.log" 2>&1 &
parent=$!
for _ in $(seq 600); do
  if curl -sf --max-time 1 http://127.0.0.1:80/health >/dev/null; then
    now=${EPOCHREALTIME/./}
    echo "healthy $(( (now - started) / 1000000 )).$(( (now - started) % 1000000 / 100000 ))"
    break
  fi
  sleep 0.1
done
addr="$(hostname -I | awk '{print $1}')"
echo "address $addr $(curl -s --max-time 3 "http://$addr:80/health")"
for pid in $parent $(pgrep -P "$parent"); do
  echo "process $pid $(id -nu "$(awk '/^Uid:/ {print $2}' /proc/$pid/status)") $(awk '/^Max open files/ {print $4}' /proc/$pid/limits)"
done
pkill -P "$parent" || true
kill "$parent" || true
wait "$parent" 2>/dev/null
echo "log-start"
cat "$dir/server.log"
PROBE
  probe="$(as_deploy env ROOT="$ROOT" JWT_SECRET="$TEST_JWT_SECRET" HOST=0.0.0.0 PORT=80 bash -c "$probe_script" || true)"
  seconds="$(sed -n 's/^healthy //p' <<<"$probe")"
  if [ -n "$seconds" ] && [ "${seconds%.*}" -lt 60 ]; then ok "healthy after $seconds s (0.0.0.0:80)"; else bad "healthy: no /health in under 60 s"; fi
  addr_line="$(sed -n 's/^address //p' <<<"$probe")"
  if grep -q '"status":"ok"' <<<"$addr_line"; then ok "direct: /health on ${addr_line%% *}:80 ok"; else bad "direct: /health on the container's address answered: $addr_line"; fi
  procs="$(sed -n 's/^process //p' <<<"$probe")"
  count="$(grep -c . <<<"$procs" || true)"
  mine="$(grep -c '^[0-9]* deploy 65535$' <<<"$procs" || true)"
  if [ "$count" = 3 ] && [ "$mine" = 3 ]; then ok "processes: 3 owned by deploy, nofile 65535"; else bad "processes: expected 3 owned by deploy with nofile 65535, got: ${procs//$'\n'/ | }"; fi
  [ "$failed" = 0 ] || { echo "--- the second start's output"; sed -n '/^log-start$/,$p' <<<"$probe"; }

  refused="$(ex "$NAME" setpriv --reuid deploy --regid deploy --init-groups /opt/php-gcob/bin/php -r \
    'echo @stream_socket_server("tcp://0.0.0.0:80", $errno, $error) ? "bound" : "refused: $error";')"
  case "$refused" in
    *"Permission denied"*) ok "port 80 without the capability: refused ($refused)" ;;
    *) bad "port 80 without the capability: $refused" ;;
  esac
fi

[ "$failed" = 0 ] || fail "a check failed"
echo "submission-test: ok"
