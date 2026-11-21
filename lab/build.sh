#!/usr/bin/env bash
# Builds php-lab:<variant> and appends the build time to lab/results/build-times.md.
#
#   bash lab/build.sh 8.3-apt
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib.sh
source "$LAB/lib.sh"

variant="${1:-}"
lab_require_variant "$variant" || exit 1

start="$(date +%s)"
docker build -t "$LAB_IMAGE:$variant" -f "$LAB/images/Dockerfile.$variant" "$LAB/images"
seconds=$(( $(date +%s) - start ))

mkdir -p "$LAB/results"
table="$LAB/results/build-times.md"
if [ ! -f "$table" ]; then
  printf '# Image build times\n\n| Date | Variant | Seconds | Docker Desktop |\n| --- | --- | --- | --- |\n' > "$table"
fi
docker_version="$(docker version --format '{{.Server.Platform.Name}}' 2>/dev/null || echo unknown)"
printf '| %s | %s | %s | %s |\n' "$(date +%Y-%m-%d)" "$variant" "$seconds" "$docker_version" >> "$table"
echo "built $LAB_IMAGE:$variant in ${seconds}s"
