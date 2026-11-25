#!/usr/bin/env bash
# Nothing to compile: PHP and its extensions come from install.sh. Lint every PHP file so that a syntax error fails the build.
set -euo pipefail
cd "$(dirname "$0")"
for file in *.php; do
  /opt/php-gcob/bin/php -l "$file"
done
