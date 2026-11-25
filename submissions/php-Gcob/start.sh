#!/usr/bin/env bash
# Runs the server in the foreground: server.php on the PHP that install.sh builds at /opt/php-gcob, with the three extensions it needs
# and the PHP settings it was measured with. Config: SQLITE_PATH, JWT_SECRET, HOST (default 0.0.0.0), PORT (default 80).
set -euo pipefail
cd "$(dirname "$0")"
exec /opt/php-gcob/bin/php -d extension=pcntl -d extension=sockets -d extension=event \
  -d memory_limit=-1 -d opcache.enable_cli=1 -d opcache.jit=tracing -d opcache.jit_buffer_size=32M \
  -d opcache.file_update_protection=0 -d zend.assertions=-1 \
  server.php
