#!/usr/bin/env bash
# Runs as root, once, on a clean Ubuntu 24.04: builds liburing from its release tarball (sha256 checked) and installs it under /usr/local
# (headers, liburing.so.2, liburing.a, liburing.pc), then runs ldconfig so that a PHP extension linked to it finds it at run time.
# Ubuntu 24.04 ships liburing 2.5; Swoole's `--enable-uring_socket` wants 2.8 or later (its configure checks `liburing >= 2.8` with
# --enable-iouring, and its help text says 2.13 for --with-liburing-dir), so the lab builds its own. The Ubuntu package stays untouched
# (it is not installed in the image: nothing here pulls it in).
#
#   bash install-liburing.sh
#
# The build refuses a version under 2.8 before it downloads anything. LIBURING_VERSION (default: the pin below) is a test hook for that
# refusal: another version never gets as far as a download.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# Pinned like every download of the lab: the build stops on a mismatch. liburing-2.15 is the newest tag of github.com/axboe/liburing (read
# on 2026-11-26; released 2026-06-29). The tarball is GitHub's archive of the tag, so its sha256 is the one `sha256sum` prints for it.
# To move to a new release, change the three lines and read the hash again.
LIBURING_PINNED_VERSION=2.15
LIBURING_URL=https://github.com/axboe/liburing/archive/refs/tags/liburing-2.15.tar.gz
LIBURING_SHA256=8d052f2622dcb3678cbaee5ff582a87572672a6c0a56533cdda5b65cb636120a
LIBURING_MIN_VERSION=2.8
LIBURING_VERSION="${LIBURING_VERSION:-$LIBURING_PINNED_VERSION}"

# `sort -V` puts the lower version first: the minimum must be the first of the two (or equal).
if [ "$(printf '%s\n%s\n' "$LIBURING_MIN_VERSION" "$LIBURING_VERSION" | sort -V | head -n 1)" != "$LIBURING_MIN_VERSION" ]; then
  echo "install-liburing: liburing $LIBURING_VERSION is under $LIBURING_MIN_VERSION, the oldest Swoole's uring_socket accepts: refusing to build" >&2
  exit 1
fi
if [ "$LIBURING_VERSION" != "$LIBURING_PINNED_VERSION" ]; then
  echo "install-liburing: only liburing $LIBURING_PINNED_VERSION is pinned (sha256), not $LIBURING_VERSION: change the pin to move" >&2
  exit 1
fi

JOBS="$(nproc)"
[ "$JOBS" -le 8 ] || JOBS=8

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl build-essential pkg-config

tmp="$(mktemp -d)"
cd "$tmp"
curl -fsSL -o liburing.tar.gz "$LIBURING_URL"
echo "$LIBURING_SHA256  liburing.tar.gz" | sha256sum -c -
tar -xzf liburing.tar.gz
cd "liburing-liburing-$LIBURING_VERSION"
./configure --prefix=/usr/local
# Why not plain `make`: its default target also builds liburing's own tests and examples, which the image has no use for.
make -C src -j"$JOBS"
make install
ldconfig

# What the next layers will find: the version the .pc file says, and the library the loader knows.
echo "liburing: $(pkg-config --modversion liburing)"
ldconfig -p | grep -F liburing.so.2
cd /
rm -rf "$tmp"
