# Shared settings of the lab. Sourced by every lab script, never run.

LAB_IMAGE=php-lab

# Variants lab/build.sh knows. Each one has lab/images/Dockerfile.<variant>.
LAB_VARIANTS=(8.3-apt)

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
