#!/usr/bin/env bash
# Runs once as root on a clean Ubuntu 24.04: installs PHP 8.3 (Ubuntu's own packages) and builds the
# Swoole 6.2.6 extension from its source tarball (checksum pinned) into PHP's extension directory.
# The extension is not enabled globally; the server loads it with `-d extension=swoole`.
# Written to also work as a submission's install.sh on a bare Ubuntu 24.04.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl build-essential autoconf pkg-config \
  php8.3-cli php8.3-dev php8.3-sqlite3 php8.3-mbstring php8.3-opcache

VERSION=6.2.6
SHA256=b0a97398d50dc9442d48a71238cafa5f75d2c53d2e35d12a59235f9d52dab718
tmp="$(mktemp -d)"
curl -fsSL -o "$tmp/swoole.tar.gz" "https://github.com/swoole/swoole-src/archive/refs/tags/v$VERSION.tar.gz"
echo "$SHA256  $tmp/swoole.tar.gz" | sha256sum -c -
tar -xzf "$tmp/swoole.tar.gz" -C "$tmp"
cd "$tmp/swoole-src-$VERSION"
phpize
# Only the HTTP server is used: no OpenSSL, HTTP/2 client libs, curl/sqlite coroutine hooks or brotli.
./configure --disable-brotli --disable-zstd
make -j"$(nproc)"
make install
cd /
rm -rf "$tmp"
php -d extension=swoole -r 'echo "PHP ", PHP_VERSION, ", Swoole ", phpversion("swoole"), ", SQLite ", (new PDO("sqlite::memory:"))->query("select sqlite_version()")->fetchColumn(), "\n";'
