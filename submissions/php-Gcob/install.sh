#!/usr/bin/env bash
# Runs once, as root, on a clean Ubuntu 24.04: builds PHP 8.5.13 and the three extensions start.sh loads (pcntl, sockets and
# PECL event) from their source tarballs into /opt/php-gcob. Nothing else on the machine is touched: no php.ini is written and
# nothing is enabled globally, start.sh loads the extensions with `-d extension=`.
#
# Why from source: Ubuntu 24.04 ships PHP 8.3, and this server is measured on PHP 8.5 with the JIT. Every download is
# pinned by sha256 and checked before it is unpacked; the apt packages are not pinned (the archive moves on, the pins
# below are what the build depends on).
#
# Every PHP tool is called by its full path: the machine may have another PHP first on its PATH (the challenge's CI
# runner has Ubuntu's 8.3), and `sudo` resets the PATH. A bare `phpize` would build the extensions for the wrong PHP.
#
# On one CPU the compile takes about 4 minutes (232 to 237 s measured on one arm64 core; the droplet was not
# measured). The last line it prints says what was installed.
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

PREFIX=/opt/php-gcob
PHP_VERSION=8.5.13
PHP_SHA256=607602acaf0c3061818e9916ec44a058e8b3d43959a83862b9cd3ec7bf5b785f   # https://www.php.net/releases/?json&version=8.5
EVENT_VERSION=3.2.0
EVENT_SHA256=fb3d4e3c9fdc79125274f2b46461492923edec6b489ed7077973f7e65f41dc1c   # https://pecl.php.net/get/event-3.2.0.tgz

# build-essential, autoconf, pkg-config: the compiler and what `configure` and `phpize` need.
# libxml2-dev, libsqlite3-dev, libonig-dev, libsodium-dev, libffi-dev: what PHP's own configure flags below link against.
# libevent-dev: what PECL event builds against.
apt-get -o DPkg::Lock::Timeout=120 update
apt-get -o DPkg::Lock::Timeout=120 install -y --no-install-recommends \
  ca-certificates curl xz-utils build-essential autoconf pkg-config \
  libxml2-dev libsqlite3-dev libonig-dev libsodium-dev libffi-dev libevent-dev

tmp="$(mktemp -d)"
trap 'cd /; rm -rf "$tmp"' EXIT
cd "$tmp"

fetch() { # fetch <url> <sha256> <file>
  curl -fsSL --retry 3 --retry-delay 2 --connect-timeout 20 -o "$3" "$1"
  echo "$2  $3" | sha256sum -c -
}

# Why each flag:
#   CFLAGS=-O2                   -O2 like Ubuntu's build, without its other flags
#   --prefix, --with-config-file-path, --with-config-file-scan-dir
#                                everything under /opt/php-gcob, and no php.ini there: start.sh passes its settings with -d
#   --disable-cgi, --disable-fpm CLI only: the server is started with `php server.php`
#   --enable-opcache             OPcache with its JIT (built in from PHP 8.5; configure ignores this flag there: it is kept because the
#                                flags match the lab's measured build)
#   --with-pdo-sqlite            pdo_sqlite against the system libsqlite3 (Ubuntu's 3.45, which has RETURNING)
#   --enable-mbstring            mbstring (needs libonig)
#   --with-sodium, --with-ffi    sodium and ffi (libsodium, libffi)
#   --enable-ctype, --with-iconv ctype and iconv (iconv uses glibc)
# posix, hash and json are built in by default.
fetch "https://www.php.net/distributions/php-$PHP_VERSION.tar.xz" "$PHP_SHA256" php.tar.xz
tar -xJf php.tar.xz
(
  cd "php-$PHP_VERSION"
  ./configure CFLAGS=-O2 \
    --prefix="$PREFIX" \
    --with-config-file-path="$PREFIX/etc" \
    --with-config-file-scan-dir="$PREFIX/etc/conf.d" \
    --disable-cgi --disable-fpm \
    --enable-opcache \
    --with-pdo-sqlite \
    --enable-mbstring \
    --with-sodium \
    --with-ffi \
    --enable-ctype \
    --with-iconv
  make -j"$(nproc)"
  make install
)
mkdir -p "$PREFIX/etc/conf.d"

# pcntl and sockets: shared extensions built with phpize from the tarball PHP itself was built from.
for ext in pcntl sockets; do
  (
    cd "php-$PHP_VERSION/ext/$ext"
    "$PREFIX/bin/phpize"
    ./configure --with-php-config="$PREFIX/bin/php-config" CFLAGS=-O2
    make -j"$(nproc)"
    make install
  )
done
# Why: event's configure looks for sockets' header under PHP's include dir, and `make install` of a shared extension does
# not put it there.
mkdir -p "$("$PREFIX/bin/php-config" --include-dir)/ext/sockets"
cp "php-$PHP_VERSION/ext/sockets/php_sockets.h" "$("$PREFIX/bin/php-config" --include-dir)/ext/sockets/"

# ext-event: the core and the sockets support only, no OpenSSL and no threads.
fetch "https://pecl.php.net/get/event-$EVENT_VERSION.tgz" "$EVENT_SHA256" event.tgz
tar -xzf event.tgz
(
  cd "event-$EVENT_VERSION"
  "$PREFIX/bin/phpize"
  ./configure --with-php-config="$PREFIX/bin/php-config" CFLAGS=-O2 \
    --with-event-core --with-event-extra --enable-event-sockets \
    --without-event-openssl --without-event-pthreads
  make -j"$(nproc)"
  make install
)

# Load order: sockets before event (event declares sockets as a dependency). The JIT only starts with OPcache enabled in the
# CLI, so the probe turns it on like start.sh does. Everything the server needs at runtime must be there, or the build fails.
PHP_FLAGS=(-d extension=pcntl -d extension=sockets -d extension=event -d opcache.enable_cli=1 -d opcache.jit=tracing -d opcache.jit_buffer_size=32M)
libevent="$("$PREFIX/bin/php" "${PHP_FLAGS[@]}" --ri event | sed -n 's/^libevent2 headers version => //p')"
"$PREFIX/bin/php" "${PHP_FLAGS[@]}" -r '
$missing = array_filter(["pcntl", "posix", "sockets", "event", "pdo_sqlite", "mbstring", "ctype", "hash", "json", "Zend OPcache"],
    fn ($name) => !extension_loaded($name));
$jit = function_exists("opcache_get_status") ? (opcache_get_status(false)["jit"]["on"] ?? false) : false;
if ($missing || !$jit) {
    fwrite(STDERR, "install: missing " . implode(", ", $missing) . ($jit ? "" : " (JIT is off)") . "\n");
    exit(1);
}
echo "installed: PHP ", PHP_VERSION, ", SQLite ", (new PDO("sqlite::memory:"))->query("select sqlite_version()")->fetchColumn(),
    ", libevent ", $argv[1], ", ext-event ", phpversion("event"), ", OPcache with JIT, pcntl posix sockets event pdo_sqlite mbstring ctype hash json\n";
' -- "$libevent"
