# Shared settings of the lab. Sourced by every lab script, never run.
# Why: the variables are read by the scripts that source this file, so shellcheck sees them as unused.
# shellcheck shell=bash disable=SC2034

LAB_IMAGE=php-lab

# Variants lab/build.sh knows. 8.3-apt has its own lab/images/Dockerfile.8.3-apt; the others are compiled from the
# php.net tarball with lab/images/Dockerfile.src.
LAB_VARIANTS=(8.3-apt 8.3 8.4 8.5 8.6)
LAB_SOURCE_VARIANTS=(8.3 8.4 8.5 8.6)

# lab_source_release <variant>: prints "<php version> <sha256 of its .tar.xz> <WITH_SWOOLE> <WITH_EVENT>".
# The sha256 values are the ones php.net publishes (https://www.php.net/releases/?json&version=<branch>), read on
# 2026-11-21. To move to a new patch release, change the line and re-read the checksum there.
lab_source_release() {
  case "$1" in
    8.3) echo "8.3.37 0237af84478b7a7649d3964153f1b8653d622550b846f56d63062de683fb86bb 1 1" ;;
    8.4) echo "8.4.28 0c8ec360e5dd8154f270b2fd50cd44ecc824e6ee39c85f911312b80d4daecd72 1 1" ;;
    8.5) echo "8.5.13 607602acaf0c3061818e9916ec44a058e8b3d43959a83862b9cd3ec7bf5b785f 1 1" ;;
    # Swoole 6.2.6 does not compile on PHP 8.6 (lab/results/swoole-on-php-8.6.md), so this image has no Swoole.
    8.6) echo "8.6.0 5f84beaa3d763aee1e4feed99bf54ec692c383b322e25626807b589238c3a087 0 1" ;;
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

# lab_start_server <container name> <variant> <port> <server file as the container sees it>: starts the server container the
# same way for lab/macro.sh and lab/conformance.sh (1 CPU, 2 GiB, the server CPU, host network, lab/ at /lab, the seed
# read-only at /lab/data). Needs LAB (the lab/ folder) and LAB_PHP_FLAGS (lab_build_php_flags); LAB_ENV, an array of K=V,
# is passed with -e after PORT. Never mount lab/data writable here: a server must copy feed.db, not open it (WAL files).
# LAB_SERVER_NOFILE, when set, replaces the container's `nofile` limit (a test hook for lab/conns.sh: the later --ulimit of the
# same name wins).
lab_start_server() {
  local name="$1" variant="$2" port="$3" server_in="$4" env_args=() nofile_args=() kv
  for kv in "${LAB_ENV[@]+"${LAB_ENV[@]}"}"; do env_args+=(-e "$kv"); done
  [ -z "${LAB_SERVER_NOFILE:-}" ] || nofile_args=(--ulimit "nofile=$LAB_SERVER_NOFILE:$LAB_SERVER_NOFILE")
  docker run -d --name "$name" "${LAB_RESOURCE_FLAGS[@]}" "${nofile_args[@]+"${nofile_args[@]}"}" --network host --cpuset-cpus "$LAB_CPUSET_SERVER" \
    -v "$LAB:/lab:ro" -v "$LAB/data:/lab/data:ro" -e "PORT=$port" "${env_args[@]+"${env_args[@]}"}" \
    "$LAB_IMAGE:$variant" php "${LAB_PHP_FLAGS[@]}" "$server_in" >/dev/null
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

# lab_socket_line <container>: the `socket: key=value ...` line a bake-off server prints at boot (the settings it asked
# for: the images' Swoole cannot read them back), as the text after `socket: `. Empty when the server prints none.
lab_socket_line() {
  docker logs "$1" 2>&1 | sed -n 's/^socket: //p' | head -n 1
}
