# Shared settings of the lab. Sourced by every lab script, never run.

LAB_IMAGE=php-lab

# Variants lab/build.sh knows. 8.3-apt has its own lab/images/Dockerfile.8.3-apt; the others are compiled from the
# php.net tarball with lab/images/Dockerfile.src.
LAB_VARIANTS=(8.3-apt 8.3 8.4 8.5 8.6)
LAB_SOURCE_VARIANTS=(8.3 8.4 8.5 8.6)

# lab_source_release <variant>: prints "<php version> <sha256 of its .tar.xz> <WITH_SWOOLE>".
# The sha256 values are the ones php.net publishes (https://www.php.net/releases/?json&version=<branch>), read on
# 2026-11-21. To move to a new patch release, change the line and re-read the checksum there.
lab_source_release() {
  case "$1" in
    8.3) echo "8.3.37 0237af84478b7a7649d3964153f1b8653d622550b846f56d63062de683fb86bb 1" ;;
    8.4) echo "8.4.28 0c8ec360e5dd8154f270b2fd50cd44ecc824e6ee39c85f911312b80d4daecd72 1" ;;
    8.5) echo "8.5.13 607602acaf0c3061818e9916ec44a058e8b3d43959a83862b9cd3ec7bf5b785f 1" ;;
    # Swoole 6.2.6 does not compile on PHP 8.6 (lab/results/swoole-on-php-8.6.md), so this image has no Swoole.
    8.6) echo "8.6.0 5f84beaa3d763aee1e4feed99bf54ec692c383b322e25626807b589238c3a087 0" ;;
    *) return 1 ;;
  esac
}

# CPU layout of Docker's VM (12 vCPUs): CPUs 0 and 1 stay free for the VM itself.
LAB_CPUSET_SERVER=2     # the server and the micro benches
LAB_CPUSET_K6=4-11      # the load generator

# Resource limits of every lab container (the bench VM of the challenge has the same budget).
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
