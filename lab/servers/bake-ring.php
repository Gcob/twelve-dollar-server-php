<?php
// The ring server of lab/servers/ring-server.php (our own io_uring loop in PHP through FFI, one process, one ring) answering through
// handler.php (GET /noop and GET /posts/:id), so that lab/conformance.sh and lab/macro.sh run on it like on the DIY server. Port: PORT
// (default 8080). With APP_TELEMETRY=1 it prints a `ring:` line a second.
//
// Docker's default seccomp filter refuses io_uring: start it with `--seccomp-unconfined`. It needs no extension (`--ext sockets` keeps the
// PHP the same as the DIY server's, minus ext-event).

require __DIR__ . '/handler.php';
require __DIR__ . '/ring-server.php';

// The database copy takes a few seconds, so the server listens only once it is done.
handler_boot();
ring_serve('0.0.0.0', (int) (getenv('PORT') ?: 8080), null, getenv('APP_TELEMETRY') === '1');
