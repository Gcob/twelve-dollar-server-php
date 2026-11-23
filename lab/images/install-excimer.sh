#!/usr/bin/env bash
# Runs once as root, after install-extras.sh, on the image it built: adds the Excimer profiler (PECL excimer), a shared extension
# that is never enabled globally: a run that profiles loads it with `-d extension=excimer` (lab `--ext excimer`).
#
#   WITH_EXCIMER=1 bash install-excimer.sh
#
# Its own script and its own layer: install-extras.sh starts with an `apt-get update`, so changing that layer could move libevent
# between two builds. Excimer needs nothing from apt (a C compiler and phpize come with the PHP build).
set -euo pipefail
: "${WITH_EXCIMER:=1}"

# Pinned by sha256, the build stops on a mismatch. 1.2.6 is the latest stable release on pecl.php.net (2026-04-16).
EXCIMER_VERSION=1.2.6
EXCIMER_SHA256=7b5fe1f68f2b1a62bd0394d4bf165eafe6b7ceb3fc20ab885e733d356db0d034   # https://pecl.php.net/get/excimer-1.2.6.tgz

if [ "$WITH_EXCIMER" != 1 ]; then
  echo "excimer: not built (WITH_EXCIMER=$WITH_EXCIMER)"
  exit 0
fi

JOBS="$(nproc)"
[ "$JOBS" -le 8 ] || JOBS=8

tmp="$(mktemp -d)"
cd "$tmp"
curl -fsSL -o excimer.tgz "https://pecl.php.net/get/excimer-$EXCIMER_VERSION.tgz"
echo "$EXCIMER_SHA256  excimer.tgz" | sha256sum -c -
tar -xzf excimer.tgz
(
  cd "excimer-$EXCIMER_VERSION"
  phpize
  # CFLAGS=-O2 like PHP itself (see install-php-src.sh).
  ./configure CFLAGS=-O2
  make -j"$JOBS"
  make install
)
cd /
rm -rf "$tmp"
php -d extension=excimer -r 'echo "excimer ", phpversion("excimer"), "\n";'
