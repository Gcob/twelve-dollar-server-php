#!/usr/bin/env bash
# Builds php-lab:<variant> and appends the build time to lab/results/build-times.md.
#
#   bash lab/build.sh 8.3-apt
#   bash lab/build.sh 8.4
#   bash lab/build.sh all        # every variant, one after the other (never in parallel: the times are recorded)
#   bash lab/build.sh 8.5-sqlite # 8.5 on a SQLite built from the amalgamation with PGO (LAB_SQLITE_TRAIN_LOOPS=0 makes it fail: a test hook)
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$LAB")"
# shellcheck source=lib.sh
source "$LAB/lib.sh"

if [ "${1:-}" = all ]; then
  for v in "${LAB_VARIANTS[@]}"; do
    bash "$0" "$v"
  done
  exit 0
fi

variant="${1:-}"
lab_require_variant "$variant" || exit 1

start="$(date +%s)"
if release="$(lab_source_release "$variant")"; then
  read -r php_version php_sha256 with_swoole with_event with_excimer <<<"$release"
  docker build -t "$LAB_IMAGE:$variant" -f "$LAB/images/Dockerfile.src" \
    --build-arg PHP_VERSION="$php_version" --build-arg PHP_SHA256="$php_sha256" --build-arg WITH_SWOOLE="$with_swoole" --build-arg WITH_EVENT="$with_event" --build-arg WITH_EXCIMER="$with_excimer" \
    "$LAB/images"
elif [ "$variant" = 8.5-sqlite ]; then
  # Why: the training reads the challenge's schema and the submission's SQL, which live outside lab/images/ (the build context), so the
  # context is a copy of it with the two files added; the seed itself never enters the image.
  read -r php_version php_sha256 _ <<<"$(lab_source_release 8.5)"
  context="$(mktemp -d)"
  trap 'rm -rf "$context"' EXIT
  cp -R "$LAB/images/." "$context/"
  cp "$REPO/reference/twelve-dollar-server-challenge/schema.sql" "$REPO/submissions/php-Gcob/app.php" "$context/"
  docker build -t "$LAB_IMAGE:$variant" -f "$LAB/images/Dockerfile.$variant" \
    --build-arg PHP_VERSION="$php_version" --build-arg PHP_SHA256="$php_sha256" --build-arg SQLITE_TRAIN_LOOPS="${LAB_SQLITE_TRAIN_LOOPS:-}" \
    "$context"
else
  docker build -t "$LAB_IMAGE:$variant" -f "$LAB/images/Dockerfile.$variant" "$LAB/images"
fi
seconds=$(( $(date +%s) - start ))

mkdir -p "$LAB/results"
table="$LAB/results/build-times.md"
if [ ! -f "$table" ]; then
  printf '# Image build times\n\n| Date | Variant | Seconds | Docker Desktop |\n| --- | --- | --- | --- |\n' > "$table"
fi
docker_version="$(docker version --format '{{.Server.Platform.Name}}' 2>/dev/null || echo unknown)"
printf '| %s | %s | %s | %s |\n' "$(date +%Y-%m-%d)" "$variant" "$seconds" "$docker_version" >> "$table"
echo "built $LAB_IMAGE:$variant in ${seconds}s"
