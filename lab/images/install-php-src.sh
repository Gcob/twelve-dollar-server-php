#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: compiles PHP $PHP_VERSION from the php.net tarball (sha256 checked)
# and, when WITH_SWOOLE=1, the Swoole 6.2.6 extension from its source tarball (same pin as install-php83-apt.sh).
# The extension is not enabled globally; the server loads it with `-d extension=swoole`, like on the apt image.
#
#   PHP_VERSION=8.4.28 PHP_SHA256=<sha256 of php-8.4.28.tar.xz> WITH_SWOOLE=1 bash install-php-src.sh
#
# SQLITE_PREFIX (default empty): where a SQLite built by install-sqlite-tuned.sh lives. When it is set, pdo_sqlite is built against that
# library (its sqlite3.pc comes first for pkg-config) and php records the folder as its RUNPATH, so that it finds the library at run time
# without LD_LIBRARY_PATH. Every other flag is the same, so the image differs from the plain one by its SQLite and nothing else.
#
# WITH_SWOOLE_URING (default 0, only with WITH_SWOOLE=1): Swoole is configured with --enable-uring_socket and --with-liburing-dir=/usr/local, so
# that its coroutine HTTP server (Swoole\Coroutine\Http\Server) runs its sockets on io_uring. It needs liburing 2.8 or later under /usr/local
# (install-liburing.sh runs first in lab/images/Dockerfile.8.5-uring). Unset, Swoole is built as it always was.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${PHP_VERSION:?}" "${PHP_SHA256:?}" "${WITH_SWOOLE:=1}" "${SQLITE_PREFIX:=}" "${WITH_SWOOLE_URING:=0}"

# At most 8 compiler jobs, so a build leaves the Mac usable even when Docker's VM has 12 CPUs.
JOBS="$(nproc)"
[ "$JOBS" -le 8 ] || JOBS=8

# libssl-dev: Swoole's configure looks for it even though the build leaves OpenSSL off (php8.3-dev pulls it in on
# the apt image). PHP itself is not configured with OpenSSL.
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl xz-utils build-essential autoconf pkg-config \
  libxml2-dev libsqlite3-dev libonig-dev libsodium-dev libffi-dev libssl-dev

# The flags are identical for every PHP version, so the versions are compared on equal terms.
# Why each one:
#   CFLAGS=-O2                  -O2 like Ubuntu's build, without its other flags: dpkg-buildflags in the apt image prints
#                               -g -O2 -fno-omit-frame-pointer -flto=auto -fstack-protector-strong -fstack-clash-protection
#                               -mbranch-protection=standard ... (so 8.3 from source vs 8.3-apt stays a control, not a twin)
#   --prefix=/usr/local         php and php-config land on the PATH
#   --with-config-file-path     where php looks for php.ini (none is shipped: the server passes its settings with -d)
#   --with-config-file-scan-dir where the OPcache ini below goes
#   --disable-cgi, --disable-fpm  CLI only: the servers under test are started with `php file.php`
#   --enable-opcache            OPcache with its JIT (a flag up to 8.4; always built from 8.5, where it is ignored)
#   --with-pdo-sqlite           pdo_sqlite against the system libsqlite3, the one the apt image uses (or $SQLITE_PREFIX's, see above)
#   --enable-mbstring           mbstring (needs libonig)
#   --with-sodium               sodium (needs libsodium)
#   --with-ffi                  ffi (needs libffi)
#   --enable-ctype, --with-iconv  ctype and iconv (iconv uses glibc)
FLAGS=(
  CFLAGS=-O2
  --prefix=/usr/local
  --with-config-file-path=/usr/local/etc/php
  --with-config-file-scan-dir=/usr/local/etc/php/conf.d
  --disable-cgi
  --disable-fpm
  --enable-opcache
  --with-pdo-sqlite
  --enable-mbstring
  --with-sodium
  --with-ffi
  --enable-ctype
  --with-iconv
)
if [ -n "$SQLITE_PREFIX" ]; then
  export PKG_CONFIG_PATH="$SQLITE_PREFIX/lib/pkgconfig"
  FLAGS+=("LDFLAGS=-Wl,-rpath,$SQLITE_PREFIX/lib")
fi
echo "PHP $PHP_VERSION configure flags: ${FLAGS[*]}"
# Why: php -i leaves CFLAGS out of its "Configure Command" line, so the full list is kept here for lab/check.sh.
mkdir -p /usr/local/etc/php/conf.d
echo "${FLAGS[*]}" > /usr/local/etc/php/configure-flags

tmp="$(mktemp -d)"
cd "$tmp"
curl -fsSL -o php.tar.xz "https://www.php.net/distributions/php-$PHP_VERSION.tar.xz"
echo "$PHP_SHA256  php.tar.xz" | sha256sum -c -
tar -xJf php.tar.xz
cd "php-$PHP_VERSION"
./configure "${FLAGS[@]}"
# What configure found of SQLite: the one the build is going to link, and the options it was built with.
echo "pkg-config sqlite3: $(pkg-config --modversion sqlite3) $(pkg-config --cflags --libs sqlite3)"
grep -E "^(#define|/\* #undef) [A-Z0-9_]*SQLITE" main/php_config.h || true
make -j"$JOBS"
make install

# Up to 8.4 OPcache is a shared extension that must be loaded; from 8.5 it is built in and needs nothing.
if [ -f "$(php-config --extension-dir)/opcache.so" ]; then
  echo "zend_extension=opcache" > /usr/local/etc/php/conf.d/opcache.ini
fi
cd "$tmp"

if [ "$WITH_SWOOLE" = 1 ]; then
  SWOOLE_VERSION=6.2.6
  SWOOLE_SHA256=b0a97398d50dc9442d48a71238cafa5f75d2c53d2e35d12a59235f9d52dab718
  curl -fsSL -o swoole.tar.gz "https://github.com/swoole/swoole-src/archive/refs/tags/v$SWOOLE_VERSION.tar.gz"
  echo "$SWOOLE_SHA256  swoole.tar.gz" | sha256sum -c -
  tar -xzf swoole.tar.gz
  cd "swoole-src-$SWOOLE_VERSION"
  phpize
  # Only the HTTP server is used: no OpenSSL, HTTP/2 client libs, curl/sqlite coroutine hooks or brotli.
  SWOOLE_FLAGS=(--disable-brotli --disable-zstd)
  if [ "$WITH_SWOOLE_URING" = 1 ]; then
    # --with-liburing-dir turns io_uring on (it also moves the coroutine sleep, file and poll hooks to it); --enable-uring_socket is what
    # puts the coroutine servers' sockets on it. Without liburing's header, configure stops: the build never falls back to epoll silently.
    SWOOLE_FLAGS+=(--enable-uring_socket --with-liburing-dir=/usr/local)
  fi
  echo "Swoole $SWOOLE_VERSION configure flags: ${SWOOLE_FLAGS[*]}"
  ./configure "${SWOOLE_FLAGS[@]}"
  make -j"$JOBS"
  make install
  if [ "$WITH_SWOOLE_URING" = 1 ]; then
    # The build is only worth keeping if the extension says it has both.
    ri="$(php -d extension=swoole --ri swoole)"
    grep -E '^(io_uring|uring_socket) => enabled$' <<<"$ri"
    [ "$(grep -cE '^(io_uring|uring_socket) => enabled$' <<<"$ri")" = 2 ] || { echo "Swoole was built without io_uring sockets" >&2; exit 1; }
  fi
fi

cd /
rm -rf "$tmp"
php -v
