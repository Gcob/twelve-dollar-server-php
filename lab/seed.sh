#!/usr/bin/env bash
# Builds the challenge's seed database into lab/data/ (feed.db + tokens.json), outside git.
#
#   bash lab/seed.sh
#
# The upstream make-seed.sh writes next to itself and reads ../schema.sql, so we copy the three files it needs into
# a temporary build folder (same relative layout), run it there, and keep only its two outputs.
# REFERENCE_DIR overrides where the upstream clone lives (used to test the "missing clone" failure).
set -euo pipefail

LAB="$(cd "$(dirname "$0")" && pwd)"
REFERENCE_DIR="${REFERENCE_DIR:-$LAB/../reference/twelve-dollar-server-challenge}"
DATA="$LAB/data"
BUILD="$DATA/.build"

if [ ! -d "$REFERENCE_DIR" ]; then
  echo "FAIL: the challenge repo is missing: $REFERENCE_DIR" >&2
  echo "Get it with: git clone https://github.com/arjaythedev/twelve-dollar-server-challenge reference/twelve-dollar-server-challenge" >&2
  exit 1
fi

for f in seed/generate.mjs seed/make-seed.sh schema.sql; do
  if [ ! -f "$REFERENCE_DIR/$f" ]; then
    echo "FAIL: $REFERENCE_DIR/$f not found: is it the right repo?" >&2
    exit 1
  fi
done

mkdir -p "$DATA"
trap 'rm -rf "$BUILD"' EXIT
rm -rf "$BUILD"
mkdir -p "$BUILD/seed"
cp "$REFERENCE_DIR/seed/generate.mjs" "$REFERENCE_DIR/seed/make-seed.sh" "$BUILD/seed/"
cp "$REFERENCE_DIR/schema.sql" "$BUILD/"

# Its last line (OK: ... content sha256 matches) and its exit code pass through: set -e stops us on failure.
bash "$BUILD/seed/make-seed.sh"

# Only reached on success: a failed build never replaces the previous seed.
rm -f "$DATA/feed.db" "$DATA/feed.db-wal" "$DATA/feed.db-shm"
mv "$BUILD/seed/feed.db" "$BUILD/seed/tokens.json" "$DATA/"
