#!/usr/bin/env bash
# Runs a command in php-lab:<variant> with the lab's limits, pinned to the server CPU, on the host network.
# lab/ is mounted at /lab, read-only except lab/results/ and lab/data/. With LAB_RUN_SUBMISSIONS=1 the repo's submissions/ folder is
# mounted read-only at /submissions too (the checks of a submission run its files there; not mounted by default, so that a bind mount
# of a folder that does not exist never makes an empty one).
#
#   bash lab/run.sh 8.3-apt php-info
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$LAB/lib.sh"

variant="${1:-}"
lab_require_variant "$variant" || exit 1
shift
[ "$#" -gt 0 ] || { echo "usage: lab/run.sh <variant> <command...>" >&2; exit 1; }

mkdir -p "$LAB/results" "$LAB/data"
submissions_args=()
if [ "${LAB_RUN_SUBMISSIONS:-}" = 1 ]; then
  [ -d "$(dirname "$LAB")/submissions" ] || { echo "LAB_RUN_SUBMISSIONS=1 but there is no submissions/ folder" >&2; exit 1; }
  submissions_args=(-v "$(dirname "$LAB")/submissions:/submissions:ro")
fi
exec docker run --rm "${LAB_RESOURCE_FLAGS[@]}" --network host --cpuset-cpus "$LAB_CPUSET_SERVER" \
  -v "$LAB:/lab:ro" -v "$LAB/results:/lab/results" -v "$LAB/data:/lab/data" "${submissions_args[@]+"${submissions_args[@]}"}" \
  "$LAB_IMAGE:$variant" "$@"
