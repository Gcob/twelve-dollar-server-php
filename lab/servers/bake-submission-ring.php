<?php
// The ring of the submission (submissions/php-Gcob/ring.php: the io_uring loop in PHP through FFI, three rings, the older buffers when the kernel
// refuses the buffer ring) answering through handler.php (GET /noop and GET /posts/:id), so that lab/conformance.sh runs on the submission's own
// copy of the ring like it runs on the lab's (lab/servers/bake-ring.php). Port: PORT (default 8080).
//
// Docker's default seccomp filter refuses io_uring: start it with `--seccomp-unconfined`, and with `--with-submissions` (conformance.sh), which
// mounts the submissions folder this file loads the ring from. It needs no extension.

require __DIR__ . '/handler.php';
require __DIR__ . '/../../submissions/php-Gcob/ring.php';

if (($why = ring_unavailable()) !== null) {
    fwrite(STDERR, "bake-submission-ring: $why\n");
    exit(1);
}
// The database copy takes a few seconds, so the server listens only once it is done.
handler_boot();
try {
    $loop = ring_open(3, 192000);
} catch (RingRefused $e) {
    fwrite(STDERR, "bake-submission-ring: io_uring refused: {$e->getMessage()}\n");
    exit(1);
}
ring_serve($loop, '0.0.0.0', (int) (getenv('PORT') ?: 8080));
