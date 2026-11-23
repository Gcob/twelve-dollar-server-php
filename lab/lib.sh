# Shared settings of the lab. Sourced by every lab script, never run.
# Why: the variables are read by the scripts that source this file, so shellcheck sees them as unused.
# shellcheck shell=bash disable=SC2034

LAB_IMAGE=php-lab

# Variants lab/build.sh knows. 8.3-apt has its own lab/images/Dockerfile.8.3-apt; the others are compiled from the
# php.net tarball with lab/images/Dockerfile.src.
LAB_VARIANTS=(8.3-apt 8.3 8.4 8.5 8.6)
LAB_SOURCE_VARIANTS=(8.3 8.4 8.5 8.6)

# lab_source_release <variant>: prints "<php version> <sha256 of its .tar.xz> <WITH_SWOOLE> <WITH_EVENT> <WITH_EXCIMER>".
# The sha256 values are the ones php.net publishes (https://www.php.net/releases/?json&version=<branch>), read on
# 2026-11-21. To move to a new patch release, change the line and re-read the checksum there.
lab_source_release() {
  case "$1" in
    8.3) echo "8.3.37 0237af84478b7a7649d3964153f1b8653d622550b846f56d63062de683fb86bb 1 1 1" ;;
    8.4) echo "8.4.28 0c8ec360e5dd8154f270b2fd50cd44ecc824e6ee39c85f911312b80d4daecd72 1 1 1" ;;
    8.5) echo "8.5.13 607602acaf0c3061818e9916ec44a058e8b3d43959a83862b9cd3ec7bf5b785f 1 1 1" ;;
    # Swoole 6.2.6 does not compile on PHP 8.6 (lab/results/swoole-on-php-8.6.md), so this image has no Swoole.
    # Excimer 1.2.6 does not compile on PHP 8.6 either (lab/results/excimer-on-php-8.6.md): this image has no profiler.
    8.6) echo "8.6.0 5f84beaa3d763aee1e4feed99bf54ec692c383b322e25626807b589238c3a087 0 1 0" ;;
    *) return 1 ;;
  esac
}

# CPU layout of Docker's VM (12 vCPUs): CPUs 0 and 1 stay free for the VM itself.
LAB_CPUSET_SERVER=2     # the server and the micro benches
LAB_CPUSET_K6=4-11      # the load generator
LAB_CPUSET_PROBE=0-1    # the helper that reads cgroup files and /proc for lab/macro.sh, next to the VM's own CPUs

# Resource limits of every lab container: 1 CPU, 2 GiB, no swap, like the challenge VM (1 vCPU, about 2 GB). Not the same
# budget, though: the VM's memory is shared with the OS (and Nginx when used), the lab gives the server the whole 2 GiB. A
# variant that peaks near 2 GiB passes here and can be OOM-killed there.
LAB_RESOURCE_FLAGS=(--cpus=1 --memory=2g --memory-swap=2g --ulimit nofile=65535:65535)

lab_known_variant() {
  local v
  for v in "${LAB_VARIANTS[@]}"; do
    [ "$v" = "$1" ] && return 0
  done
  return 1
}

# Exits non-zero with the list of known variants when $1 is not one of them.
lab_require_variant() {
  if [ -z "${1:-}" ] || ! lab_known_variant "$1"; then
    echo "unknown variant: '${1:-}'. Known variants: ${LAB_VARIANTS[*]}" >&2
    return 1
  fi
}

# The load generator of lab/macro.sh: pinned by tag and by digest (the multi-arch index digest, so the same line works on
# arm64 here and amd64 on the bench VM). 1.8.3 is the latest 1.x release (2.x exists); to move, change both.
LAB_K6_IMAGE=grafana/k6:1.8.3@sha256:2cd9cd09e4119340a122aaf06f30cf3009c19db23b87954909fba0d3eda58e08

# The linter of lab/check.sh: pinned by tag and by digest (the multi-arch index digest, like the k6 image above). 0.11.0 is
# the release the `stable` tag points at; to move, change both.
LAB_SHELLCHECK_IMAGE=koalaman/shellcheck:v0.11.0@sha256:61862eba1fcf09a484ebcc6feea46f1782532571a34ed51fedf90dd25f925a8d

# PHP flags of a server in lab/macro.sh and lab/conformance.sh: the ones of the php-swoole-mattsplat entry's start.sh, plus two
# the lab pins. The extensions are not here: each run names its own (--ext, see lab_build_php_flags). Source images ship no
# php.ini, so nothing else configures PHP.
# - opcache.file_update_protection=0: by default a file modified less than 2 s ago is not cached, so a server file saved just
#   before a run would run without OPcache and without JIT.
# - zend.assertions=-1: Ubuntu's php.ini sets it, PHP's built-in default (source images) is 1; the same on every image.
LAB_SERVER_PHP_FLAGS=(-d memory_limit=-1 -d opcache.enable_cli=1 -d opcache.jit=tracing -d opcache.jit_buffer_size=32M
  -d opcache.file_update_protection=0 -d zend.assertions=-1)

# lab_build_php_flags: fills LAB_PHP_FLAGS with `-d extension=<name>` for each name of the array LAB_EXT, then
# LAB_SERVER_PHP_FLAGS, then `-d <k=v>` for each entry of the array LAB_INI. The caller sets LAB_EXT and LAB_INI.
lab_build_php_flags() {
  local e kv
  LAB_PHP_FLAGS=()
  for e in "${LAB_EXT[@]+"${LAB_EXT[@]}"}"; do LAB_PHP_FLAGS+=(-d "extension=$e"); done
  LAB_PHP_FLAGS+=("${LAB_SERVER_PHP_FLAGS[@]}")
  for kv in "${LAB_INI[@]+"${LAB_INI[@]}"}"; do LAB_PHP_FLAGS+=(-d "$kv"); done
}

# lab_run_server_container <container name> <variant> <port> <command...>: the `docker run` of every server container (1 CPU,
# 2 GiB, the server CPU, host network, lab/ at /lab, the seed read-only at /lab/data), running <command> in php-lab:<variant>.
# Needs LAB (the lab/ folder); LAB_ENV, an array of K=V, is passed with -e after PORT. Never mount lab/data writable here: a
# server must copy feed.db, not open it (WAL files). LAB_SERVER_NOFILE, when set, replaces the container's `nofile` limit (a test
# hook for lab/conns.sh: the later --ulimit of the same name wins). LAB_SERVER_SECCOMP_UNCONFINED=1 starts the container without
# Docker's default seccomp filter, which refuses the io_uring syscalls (EPERM): only the io_uring server uses it, through the
# --seccomp-unconfined option of lab/macro.sh, lab/conformance.sh, lab/conns.sh and lab/stress.sh.
lab_run_server_container() {
  local name="$1" variant="$2" port="$3" env_args=() nofile_args=() seccomp_args=() kv
  shift 3
  for kv in "${LAB_ENV[@]+"${LAB_ENV[@]}"}"; do env_args+=(-e "$kv"); done
  [ -z "${LAB_SERVER_NOFILE:-}" ] || nofile_args=(--ulimit "nofile=$LAB_SERVER_NOFILE:$LAB_SERVER_NOFILE")
  [ "${LAB_SERVER_SECCOMP_UNCONFINED:-}" != 1 ] || seccomp_args=(--security-opt seccomp=unconfined)
  docker run -d --name "$name" "${LAB_RESOURCE_FLAGS[@]}" "${nofile_args[@]+"${nofile_args[@]}"}" "${seccomp_args[@]+"${seccomp_args[@]}"}" --network host --cpuset-cpus "$LAB_CPUSET_SERVER" \
    -v "$LAB:/lab:ro" -v "$LAB/data:/lab/data:ro" -e "PORT=$port" "${env_args[@]+"${env_args[@]}"}" \
    "$LAB_IMAGE:$variant" "$@" >/dev/null
}

# lab_start_server <container name> <variant> <port> <server file as the container sees it>: starts a bake-off server container the
# same way for lab/macro.sh and lab/conformance.sh (see lab_run_server_container). Needs LAB and LAB_PHP_FLAGS (lab_build_php_flags).
lab_start_server() {
  local name="$1" variant="$2" port="$3" server_in="$4"
  lab_run_server_container "$name" "$variant" "$port" php "${LAB_PHP_FLAGS[@]}" "$server_in"
}

# The challenge's secret, the one of its test suite and of the benchmark box.
LAB_JWT_SECRET=twelve-dollar-challenge
# Where the challenge app finds its database inside the container: a fresh copy of the seed, on the container's own disk.
LAB_APP_DB=/tmp/feed.db

# lab_start_app <container name> <variant> <port> <app file as the container sees it>: starts the challenge app (lab/app/server.php,
# or another file that reads the same environment) on a FRESH copy of the seed: every run of a harness starts from the same
# database, because the challenge's tests and its golden answers need it. The copy is made by `cp` inside the server container, so
# that the page cache it fills is charged to the server's cgroup like the bake-off's copy was, and `sync <file>` writes it to disk
# before the app starts: the first requests then do not wait on a dirty copy. The app only opens SQLITE_PATH. Needs LAB,
# LAB_PHP_FLAGS (lab_build_php_flags); LAB_ENV is passed too, after JWT_SECRET and SQLITE_PATH.
#
# LAB_COLD=1 (set by the caller, default 0) starts the app on a cold copy: after the `sync` (a dirty page is not evicted) the copy's pages
# are evicted from the page cache with posix_fadvise(DONTNEED) on that file only (`dd iflag=nocache count=0`; never a VM-wide
# drop_caches), so the app's first reads come from disk. Either way, just before the app opens the copy, lab/macro/fincore.php reads
# how much of it the page cache holds and prints it as the container's first line, `fincore: resident_bytes=... size_bytes=...`
# (lab_fincore_line reads it back): the whole file after a plain copy, near 0 when cold.
lab_start_app() {
  local name="$1" variant="$2" port="$3" server_in="$4" extra=("JWT_SECRET=$LAB_JWT_SECRET" "SQLITE_PATH=$LAB_APP_DB")
  local own_env=("${extra[@]}" "${LAB_ENV[@]+"${LAB_ENV[@]}"}")
  local LAB_ENV
  LAB_ENV=("${own_env[@]}")
  lab_run_server_container "$name" "$variant" "$port" sh -c '
    src="$1"; dst="$2"; cold="$3"; shift 3
    cp "$src" "$dst" && sync "$dst" || exit 1
    [ "$cold" != 1 ] || dd if="$dst" iflag=nocache count=0 2>/dev/null || exit 1
    php -d ffi.enable=1 /lab/macro/fincore.php "$dst" || exit 1
    exec php "$@"' lab-app /lab/data/feed.db "$LAB_APP_DB" "${LAB_COLD:-0}" "${LAB_PHP_FLAGS[@]}" "$server_in"
}

# lab_fincore_line <container>: the `fincore: ...` line lab_start_app printed (the text after `fincore: `), empty when there is none.
lab_fincore_line() {
  docker logs "$1" 2>&1 | sed -n 's/^fincore: //p' | head -n 1
}

# The image of lab/challenge-test.sh's test container: the four programs the challenge's test/test.sh needs (bash, curl, jq,
# openssl), which the php-lab images lack (jq). Built from lab/images/Dockerfile.tools (the same pinned Ubuntu as the other images)
# by lab_ensure_tools_image. Not a published image: pulling a third-party image for four packages is more trust than building them.
LAB_TOOLS_IMAGE=php-lab-tools:1

# lab_ensure_tools_image: builds LAB_TOOLS_IMAGE when it is missing. Needs LAB.
lab_ensure_tools_image() {
  docker image inspect "$LAB_TOOLS_IMAGE" >/dev/null 2>&1 && return 0
  echo "building $LAB_TOOLS_IMAGE (once)" >&2
  docker build -q -t "$LAB_TOOLS_IMAGE" -f "$LAB/images/Dockerfile.tools" "$LAB/images" >/dev/null
}

# The image of lab/syscalls.sh's sidecar: strace 6.8-0ubuntu2 on the same pinned Ubuntu (lab/images/Dockerfile.strace), built by
# lab_ensure_strace_image on first use. A version pinned by apt, not a pulled image: the lab trusts one base image and one archive.
LAB_STRACE_IMAGE=php-lab-strace:1

# lab_ensure_strace_image: builds LAB_STRACE_IMAGE when it is missing. Needs LAB.
lab_ensure_strace_image() {
  docker image inspect "$LAB_STRACE_IMAGE" >/dev/null 2>&1 && return 0
  echo "building $LAB_STRACE_IMAGE (once)" >&2
  docker build -q -t "$LAB_STRACE_IMAGE" -f "$LAB/images/Dockerfile.strace" "$LAB/images" >/dev/null
}

# lab_in_container_path <file under lab/>: prints the file's path in the containers (lab/ is mounted at /lab). Returns 1 with a
# message on stderr when the file is missing or is not under lab/. Needs LAB.
lab_in_container_path() {
  local abs
  [ -f "$1" ] || { echo "file not found: $1" >&2; return 1; }
  abs="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
  case "$abs" in
    "$LAB"/*) echo "/lab/${abs#"$LAB"/}" ;;
    *) echo "the file must be under lab/ (it is mounted in the containers): $1" >&2; return 1 ;;
  esac
}

# lab_other_containers <name>...: the names of the running containers other than the ones named (the run's own), one per
# line. A measurement on a VM that runs other work, a lab run started from another checkout included, is not comparable
# with one on a quiet VM, so every measuring script records these just before it measures.
lab_other_containers() {
  local own
  own="$(printf '%s\n' "$@")"
  docker ps --format '{{.Names}}' | grep -v -x -F -e "$own" || true
}

# lab_other_containers_count <name>...: how many there are. This is all a result file or a log may keep: the names belong
# to other projects and the results are committed.
lab_other_containers_count() {
  lab_other_containers "$@" | grep -c . || true
}

# lab_socket_line <container>: the `socket: key=value ...` line a bake-off server prints at boot (the settings it asked
# for: the images' Swoole cannot read them back), as the text after `socket: `. Empty when the server prints none.
lab_socket_line() {
  docker logs "$1" 2>&1 | sed -n 's/^socket: //p' | head -n 1
}
