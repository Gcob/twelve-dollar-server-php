#!/usr/bin/env bash
# Runs a command in php-lab:<variant> with the lab's limits, pinned to the server CPU, on the host network.
# lab/ is mounted at /lab, read-only except lab/results/ and lab/data/.
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
exec docker run --rm "${LAB_RESOURCE_FLAGS[@]}" --network host --cpuset-cpus "$LAB_CPUSET_SERVER" \
  -v "$LAB:/lab:ro" -v "$LAB/results:/lab/results" -v "$LAB/data:/lab/data" \
  "$LAB_IMAGE:$variant" "$@"
