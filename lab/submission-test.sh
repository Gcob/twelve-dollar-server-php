#!/usr/bin/env bash
# Installs and tests submissions/php-Gcob in a clean Ubuntu 24.04 container, the way the challenge's bench does it, or (--ci) the way
# the challenge's own CI does it.
#
#   bash lab/submission-test.sh [--ci | --seccomp-unconfined] [--keep]
#
# Default mode (the bench, LEADERBOARD.md): `bash install.sh` as root, `build.sh` as the user `deploy`, then, as `deploy` with only
# CAP_NET_BIND_SERVICE (setpriv, like systemd's AmbientCapabilities), the challenge's test/run.sh on port 80; then a second start on
# 0.0.0.0:80 whose /health is read from the container's own address, with the user and the open-files limit of every server process
# read from /proc, and a negative check: without the capability `deploy` cannot bind port 80.
#
# --ci (.github/workflows/test.yml of the challenge): the runner image has Ubuntu's PHP 8.3 first on the PATH and its tools; the entry
# installs with `sudo bash php-Gcob/install.sh` from the repo's root (sudo resets the PATH), then test/run.sh runs as a normal user on its defaults (127.0.0.1:3000).
# A bare `phpize` in install.sh would build the extensions for 8.3 and fail here. It runs twice, in a container of its own each time (a whole
# install each): under Docker's default seccomp filter and without it.
#
# Docker's default seccomp filter refuses io_uring, so the submission's ring cannot start and its server falls back to the epoll loop; the
# default way of both modes keeps the filter, and each run says which loop booted (the `loop:` line of the server's own boot lines) and checks it:
# `epoll (io_uring refused: setup 1)` under the filter, `ring, 3 rings, ...` without it (--seccomp-unconfined, or the second run of --ci). The ring
# is one process (the probe counts 1 process, and the open-files limit of that one), the fallback is a parent and two workers (3).
#
# What the container copies from the droplet: Ubuntu 24.04 (the lab's pinned digest), ONE CPU (so nproc is 1 and PHP compiles as slowly
# as it will there), 2 GiB with no swap, the unprivileged port floor at 1,024 (Docker sets 0 in containers) and 65,535 open files
# (systemd's LimitNOFILE). What it does not copy: the droplet's kernel, its network, systemd itself, the arm64 or x86 CPU (this VM may
# be arm64), and any other load: the times it prints are not a measurement. The container has its own network (port 80 is taken by
# other projects on this VM). The submission, the challenge's test/ and the seed are copied in, not mounted.
#
# Takes about 5 minutes a run, --ci two runs (the SQLite built twice with its training and the PHP compile on one arm64 CPU; the droplet was not measured): run it in the background and follow the install log it names. Not run by
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

usage() { echo "usage: lab/submission-test.sh [--ci | --seccomp-unconfined] [--keep]" >&2; exit 2; }
fail() { echo "submission-test: $*" >&2; exit 1; }

mode=bench keep=0 unconfined=0
for arg in "$@"; do
  case "$arg" in
    --ci) mode=ci ;;
    --seccomp-unconfined) unconfined=1 ;;
    --keep) keep=1 ;;
    *) echo "unknown option: $arg" >&2; usage ;;
  esac
done
[ "$mode" = bench ] || [ "$unconfined" = 0 ] || { echo "--ci runs both ways: it takes no --seccomp-unconfined" >&2; usage; }

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

work=""
created=0
# teardown: removes the run's container and network and its logs (not with --keep, on the last run).
teardown() {
  [ "$created" = 0 ] || { docker rm -f "$NAME" >/dev/null 2>&1 || true; docker network rm "$NET" >/dev/null 2>&1 || true; }
  created=0
  [ -z "$work" ] || rm -rf "$work"
  work=""
}
cleanup() {
  local rc=$?
  if [ "$keep" = 1 ] && [ "$created" = 1 ]; then
    echo "kept: container $NAME on network $NET, logs in $work"
  else
    teardown
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

# check_loop <the server's `loop:` text> <unconfined: 0|1> <processes the probe counted>: says which loop booted and checks it. Under Docker's
# default filter io_uring is refused at its first step (`setup 1`) and the server runs the epoll loop it falls back to: a parent and two
# workers. Without the filter the ring runs: one process.
check_loop() {
  local loop="$1" free="$2" count="$3"
  if [ "$free" = 1 ]; then
    if [[ "$loop" =~ ^ring,\ 3\ rings,\ (buffer\ ring|legacy\ buffers)$ ]] && [ "$count" = 1 ]; then ok "loop: $loop ($count process)"; else bad "loop: expected the ring ('ring, 3 rings, ...') as one process, got '$loop' and $count processes"; fi
  else
    if [ "$loop" = 'epoll (io_uring refused: setup 1)' ] && [ "$count" = 3 ]; then ok "loop: $loop ($count processes)"; else bad "loop: expected the epoll fallback ('epoll (io_uring refused: setup 1)') as 3 processes, got '$loop' and $count processes"; fi
  fi
}

# run_one <unconfined: 0|1>: one container, the install, the tests and the probes of the mode, with or without Docker's default seccomp filter.
run_one() {
  local unconfined="$1" label out
  label="Docker's default seccomp filter"
  [ "$unconfined" = 0 ] || label="seccomp unconfined"
  work="$(mktemp -d)"
  echo "submission-test: $mode mode, image $image, $label"
  docker network create "$NET" >/dev/null
  # From here the network is ours, so teardown removes it even if `docker run` fails (docker rm -f of a container that does not exist is silent).
  created=1
  # CI mode leaves the open-files limit at Docker's default: the runner has no systemd unit.
  limits=(--cpuset-cpus "$LAB_CPUSET_SERVER" --memory 2g --memory-swap 2g --sysctl net.ipv4.ip_unprivileged_port_start=1024)
  [ "$mode" = ci ] || limits+=(--ulimit nofile=65535:65535)
  [ "$unconfined" = 0 ] || limits+=(--security-opt seccomp=unconfined)
  docker run -d --name "$NAME" --network "$NET" "${limits[@]}" "$image" sleep infinity >/dev/null
  ok "container: $(ex "$NAME" nproc) CPU, $(docker inspect -f '{{.HostConfig.Memory}}' "$NAME") bytes of memory, port floor $(ex "$NAME" cat /proc/sys/net/ipv4/ip_unprivileged_port_start)"

  copy_in "$submission" php-Gcob
  copy_in "$challenge/test" test
  ex "$NAME" mkdir -p "$ROOT/seed"
  docker cp "$LAB/data/feed.db" "$NAME:$ROOT/seed/feed.db"
  ex "$NAME" chmod -R a+rX "$ROOT"

  if [ "$mode" = ci ]; then
    ci_run "$unconfined"
  else
    bench_run "$unconfined"
  fi
  [ "$failed" = 0 ] || fail "a check failed"
}

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

ci_run() {
  local unconfined="$1" trap_php out probe
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

  # The boot lines, read from a start of our own (run.sh removes its server's log): the same environment as run.sh's, on its port.
  # shellcheck disable=SC2016 # the script is for the container's shell
  probe="$(ex -u runner "$NAME" env ROOT="$ROOT" bash -c '
    dir="$(mktemp -d)"
    cp "$ROOT/seed/feed.db" "$dir/feed.db"
    SQLITE_PATH="$dir/feed.db" JWT_SECRET=twelve-dollar-challenge HOST=127.0.0.1 PORT=3000 bash "$ROOT/php-Gcob/start.sh" >"$dir/server.log" 2>&1 &
    parent=$!
    for _ in $(seq 600); do
      curl -sf --max-time 1 http://127.0.0.1:3000/health >/dev/null && break
      sleep 0.1
    done
    echo "processes $(( $(pgrep -P "$parent" | wc -l) + 1 ))"
    pkill -P "$parent" || true
    kill "$parent" 2>/dev/null || true
    wait "$parent" 2>/dev/null
    cat "$dir/server.log"' || true)"
  check_loop "$(sed -n 's/^loop: //p' <<<"$probe" | head -n 1)" "$unconfined" "$(sed -n 's/^processes //p' <<<"$probe")"
  [ "$failed" = 0 ] || { echo "--- the boot probe's output"; echo "$probe"; }
}

bench_run() {
  local unconfined="$1"
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
  # The ring is one process and the fallback a parent and two workers; every one of them is deploy's, with the bench's open-files limit.
  if [ "$count" = "$mine" ] && [ "$count" -ge 1 ]; then ok "processes: $count owned by deploy, nofile 65535"; else bad "processes: expected every one owned by deploy with nofile 65535, got: ${procs//$'\n'/ | }"; fi
  check_loop "$(sed -n '/^log-start$/,$p' <<<"$probe" | sed -n 's/^loop: //p' | head -n 1)" "$unconfined" "$count"
  [ "$failed" = 0 ] || { echo "--- the second start's output"; sed -n '/^log-start$/,$p' <<<"$probe"; }

  refused="$(ex "$NAME" setpriv --reuid deploy --regid deploy --init-groups /opt/php-gcob/bin/php -r \
    'echo @stream_socket_server("tcp://0.0.0.0:80", $errno, $error) ? "bound" : "refused: $error";')"
  case "$refused" in
    *"Permission denied"*) ok "port 80 without the capability: refused ($refused)" ;;
    *) bad "port 80 without the capability: $refused" ;;
  esac
}

if [ "$mode" = ci ]; then
  run_one 0
  teardown
  run_one 1
else
  run_one "$unconfined"
fi

[ "$failed" = 0 ] || fail "a check failed"
echo "submission-test: ok"
