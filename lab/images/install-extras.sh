#!/usr/bin/env bash
# Runs once as root, after install-php-src.sh, on the image it built: adds the three shared extensions the event-loop
# runtimes need (pcntl, sockets, PECL event) and the two Workerman trees. Nothing here is enabled globally: a server
# loads what it needs with `-d extension=...`.
#
#   PHP_VERSION=8.5.13 PHP_SHA256=<sha256 of php-8.5.13.tar.xz> WITH_EVENT=1 bash install-extras.sh
#
# Load order: `sockets` before `event` (event declares sockets as a dependency, so PHP refuses the other order):
#   php -d extension=pcntl -d extension=sockets -d extension=event ...
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
: "${PHP_VERSION:?}" "${PHP_SHA256:?}" "${WITH_EVENT:=1}"

# Every download is pinned by sha256 and the build stops on a mismatch.
EVENT_VERSION=3.2.0
EVENT_SHA256=fb3d4e3c9fdc79125274f2b46461492923edec6b489ed7077973f7e65f41dc1c   # https://pecl.php.net/get/event-3.2.0.tgz
WORKERMAN_VERSION=5.2.4
WORKERMAN_SHA256=9fb77c17f6cfbf8663df1adee1114b3f03d9ea1bb313d0f8d03040ed1df3705f   # github.com/walkor/workerman, tag v5.2.4
COROUTINE_VERSION=1.1.7
COROUTINE_SHA256=23d053371e357f2acc85c5337da3da6bd73cbc5d49aa9d2fcfd52be99b19e088  # github.com/workerman-php/coroutine, tag v1.1.7

JOBS="$(nproc)"
[ "$JOBS" -le 8 ] || JOBS=8

# libevent-dev: what PECL event builds against. Its version is whatever the Ubuntu archive holds on the day of the build
# (`apt-get update` runs at build time, so two builds of the same base digest can differ; `dpkg-query -W libevent-dev` in
# the image says which one a build got). patch: applies the Workerman patch below.
apt-get update
apt-get install -y --no-install-recommends libevent-dev patch

tmp="$(mktemp -d)"
cd "$tmp"

fetch() { # fetch <url> <sha256> <file>
  curl -fsSL -o "$3" "$1"
  echo "$2  $3" | sha256sum -c -
}

# pcntl and sockets: shared extensions built with phpize from the very tarball the image's PHP was built from.
# CFLAGS=-O2 like PHP itself (see install-php-src.sh).
fetch "https://www.php.net/distributions/php-$PHP_VERSION.tar.xz" "$PHP_SHA256" php.tar.xz
tar -xJf php.tar.xz
for ext in pcntl sockets; do
  (
    cd "php-$PHP_VERSION/ext/$ext"
    phpize
    ./configure CFLAGS=-O2
    make -j"$JOBS"
    make install
  )
done
# Why: event's configure looks for sockets' header under the PHP include dir, and `make install` of a shared extension
# does not put it there.
mkdir -p "$(php-config --include-dir)/ext/sockets"
cp "php-$PHP_VERSION/ext/sockets/php_sockets.h" "$(php-config --include-dir)/ext/sockets/"

if [ "$WITH_EVENT" = 1 ]; then
  fetch "https://pecl.php.net/get/event-$EVENT_VERSION.tgz" "$EVENT_SHA256" event.tgz
  tar -xzf event.tgz
  (
    cd "event-$EVENT_VERSION"
    phpize
    # Core and the sockets support only: Workerman's Event loop uses neither OpenSSL nor threads from this extension.
    ./configure CFLAGS=-O2 --with-event-core --with-event-extra --enable-event-sockets \
      --without-event-openssl --without-event-pthreads
    make -j"$JOBS"
    make install
  )
fi

# Workerman: two trees, because the lab runs it with and without its request caches.
#   /opt/workerman/<tree>/workerman/   the Workerman release
#   /opt/workerman/<tree>/coroutine/   workerman/coroutine, which Workerman requires
#   /opt/workerman/<tree>/autoload.php PSR-4 autoloader, no Composer
fetch "https://github.com/walkor/workerman/archive/refs/tags/v$WORKERMAN_VERSION.tar.gz" "$WORKERMAN_SHA256" workerman.tar.gz
fetch "https://github.com/workerman-php/coroutine/archive/refs/tags/v$COROUTINE_VERSION.tar.gz" "$COROUTINE_SHA256" coroutine.tar.gz
for tree in stock nocache; do
  root="/opt/workerman/$tree"
  mkdir -p "$root/workerman" "$root/coroutine"
  tar -xzf workerman.tar.gz -C "$root/workerman" --strip-components=1
  tar -xzf coroutine.tar.gz -C "$root/coroutine" --strip-components=1
  cat > "$root/autoload.php" <<'PHP'
<?php
// The same mapping as the two composer.json files: `Workerman\Coroutine\` is the coroutine package's src/, and `Workerman\`
// is looked up in Workerman's src/ and then in the coroutine package's src/ (that package declares both prefixes).
spl_autoload_register(static function (string $class): void {
    $roots = [
        'Workerman\\Coroutine\\' => [__DIR__ . '/coroutine/src'],
        'Workerman\\' => [__DIR__ . '/workerman/src', __DIR__ . '/coroutine/src'],
    ];
    foreach ($roots as $prefix => $dirs) {
        if (!str_starts_with($class, $prefix)) {
            continue;
        }
        $relative = str_replace('\\', '/', substr($class, strlen($prefix))) . '.php';
        foreach ($dirs as $dir) {
            if (is_file("$dir/$relative")) {
                require $dir . '/' . $relative;
                return;
            }
        }
    }
});
PHP
done

# The caches are function-local statics: `static $requests` in TcpConnection::baseRead(), `static $cache` in Http::input()
# and in Request::parseHeaders(), parseGet() and parsePost().
CACHE_STATICS='static \$(requests|cache)\b'
cache_files=(src/Connection/TcpConnection.php src/Protocols/Http.php src/Protocols/Http/Request.php)

# The check is only worth something if the stock tree does hold the 5 statics.
found="$(cd /opt/workerman/stock/workerman && grep -n -E "$CACHE_STATICS" "${cache_files[@]}" | wc -l)"
if [ "$found" != 5 ]; then
  echo "BUILD FAILED: expected 5 request cache statics in the stock Workerman $WORKERMAN_VERSION, found $found" >&2
  exit 1
fi

cd /opt/workerman/nocache/workerman
if ! patch -p1 --fuzz=0 --forward --no-backup-if-mismatch < /tmp/workerman-nocache.patch; then
  echo "BUILD FAILED: lab/images/workerman-nocache.patch does not apply cleanly to Workerman $WORKERMAN_VERSION" >&2
  exit 1
fi
if left="$(grep -rn -E "$CACHE_STATICS" src)"; then
  echo "BUILD FAILED: the patched Workerman tree still has a request cache static:" >&2
  echo "$left" >&2
  exit 1
fi

cd /
rm -rf "$tmp"
php -d extension=pcntl -d extension=sockets -m | grep -E '^(pcntl|sockets)$'
