#!/usr/bin/env bash
# Builds a second Swoole 6.2.6 on top of php-lab:8.3-apt: the same tarball (same checksum) and the same configure line as
# install-php83-apt.sh, with the one memory patch of the php-swoole-tzimpel entry's build.sh applied to the source first. The result is
# /opt/swoole-tzimpel/swoole.so, loaded by path (`-d extension=/opt/swoole-tzimpel/swoole.so`); the stock extension in PHP's extension
# directory is left as it is.
#
# The two lines below the tarball (the `perl -0pi` substitution and its check that it applied exactly twice) are copied from the entry's
# build.sh, lines 17 and 18, byte for byte (lab/check.sh compares them with the challenge repository's copy). Nothing else of that
# build.sh is used: not its download, not its configure line, not its install.sh.
# The entry's code is MIT licensed (the text is in lab/NOTICE.md).
set -euo pipefail

VERSION=6.2.6
SHA256=b0a97398d50dc9442d48a71238cafa5f75d2c53d2e35d12a59235f9d52dab718
work="$(mktemp -d)"
cd "$work"
mkdir -p build/src
curl -fsSL -o build/swoole.tar.gz "https://github.com/swoole/swoole-src/archive/refs/tags/v$VERSION.tar.gz"
echo "$SHA256  build/swoole.tar.gz" | sha256sum -c -
tar -xzf build/swoole.tar.gz -C build/src --strip-components=1
perl -0pi -e 's/(\} else \{\n\s+port->destroy_http_request\(conn\);\n\s+)buffer->clear\(\);(\n\s+return SW_OK;)/$1delete _socket->recv_buffer; _socket->recv_buffer = nullptr; \/\/ patched$2/; s/if \(_socket->recv_buffer && _socket->recv_buffer->size > SW_BUFFER_SIZE_BIG \* 2\) \{(\n\s+delete _socket->recv_buffer;\n\s+_socket->recv_buffer = nullptr;\n\s+\} else \{\n\s+buffer->clear\(\);\n\s+\})/if (_socket->recv_buffer) { \/\/ patched$1/' build/src/src/server/port.cc
[ "$(grep -c '// patched' build/src/src/server/port.cc)" = 2 ] || { echo "swoole memory patch did not apply"; exit 1; }
(
  cd build/src
  phpize
  ./configure --disable-brotli --disable-zstd
  make -j"$(nproc)"
)
install -D build/src/modules/swoole.so /opt/swoole-tzimpel/swoole.so
cd /
rm -rf "$work"
php -d extension=/opt/swoole-tzimpel/swoole.so -r 'echo "PHP ", PHP_VERSION, ", patched Swoole ", phpversion("swoole"), "\n";'
