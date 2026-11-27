<?php
// The $12 server challenge's submission in PHP: the challenge's five endpoints (app.php) on an event loop of our own, in one of two forms.
//
// The first choice is an io_uring loop written in PHP (ring.php): one process, three rings, no system call per socket operation. When the
// machine cannot run it (Docker's default seccomp filter, a kernel without io_uring, a limit) the server runs the epoll loop it had
// before (loop.php, connection.php), two worker processes sharing the port (workers.php), and says why in its `loop:` boot line. The choice
// is made once, before the database is opened and before anything listens, and never changes later.
//
// Configuration, as the challenge's SPEC.md says: SQLITE_PATH (the database it opens, never a copy) and JWT_SECRET are required, HOST
// defaults to 0.0.0.0 and PORT to 80. The server prints its boot lines once it listens.
//
// Built in, with no switch:
// - the ring: three rings in one process (each with a table of up to 65,535 direct descriptors, so a connection takes no file descriptor), the
//   receive buffers chosen by the kernel's answer (the buffer ring, or the older provided buffers on Ubuntu's 6.8 kernels), a soft limit of
//   192,000 client connections over all the rings (a response built while more are open says `Connection: close` and its connection ends once
//   written; an idle connection is never closed), a backlog of 4,096;
// - the fallback: two processes on SO_REUSEPORT, each with its own database connection and its own loop, a soft limit of 64,000 client
//   connections per process, a backlog of 4,096;
// - the SQLite settings of app_connection_pragmas().
//
// It starts with the extensions loaded in this order: pcntl, sockets, event (start.sh).

require __DIR__ . '/app.php';
require __DIR__ . '/loop.php';
require __DIR__ . '/workers.php';
require __DIR__ . '/ring.php';

const SERVER_RINGS = 3;
const SERVER_RING_SOFT_CONN_LIMIT = 192000;
const SERVER_WORKERS = 2;
const SERVER_SOFT_CONN_LIMIT = 64000;
const SERVER_BACKLOG = 4096;

$path = (string) getenv('SQLITE_PATH');
$secret = (string) getenv('JWT_SECRET');
if ($path === '' || $secret === '') {
    fwrite(STDERR, "server: SQLITE_PATH and JWT_SECRET must be set\n");
    exit(1);
}
$host = (string) (getenv('HOST') ?: '0.0.0.0');
$port = (int) (getenv('PORT') ?: 80);

if (!extension_loaded('pcntl') || !function_exists('posix_kill')) {
    fwrite(STDERR, "server: ext-pcntl and ext-posix must be loaded\n");
    exit(1);
}
if (!is_file($path)) {
    fwrite(STDERR, "server: the database file does not exist: $path\n");
    exit(1);
}
// Why the whole init before anything else: a refusal must decide the loop before the database is opened and before a socket listens. Why the
// try around nothing but the init: a refusal after the server runs is a crash, never a silent switch of loop. Why any Throwable: a machine we
// did not foresee (a C library that is not Ubuntu's, an error while the rings are built) is a reason to run the epoll loop, not to die.
$ringFallback = null;
try {
    $ringFallback = ring_unavailable();
    if ($ringFallback !== null) {
        $ringFallback = "ring unavailable: $ringFallback";
    } elseif (ip2long($host) === false) {
        // Why: the ring listens on an IPv4 address; the epoll loop also takes a name or an IPv6 address.
        $ringFallback = 'ring unavailable: HOST is not an IPv4 address';
    } else {
        $ringLoop = ring_open(SERVER_RINGS, SERVER_RING_SOFT_CONN_LIMIT);
    }
} catch (RingRefused $e) {
    $ringFallback = 'io_uring refused: ' . $e->step . ' ' . $e->errnoValue;
} catch (Throwable $e) {
    $ringFallback = 'ring unavailable: ' . str_replace("\n", ' ', $e->getMessage());
}
if (isset($ringLoop)) {
    app_boot($path, $secret);
    ring_serve($ringLoop, $host, $port, static function (): void {
        echo 'soft connection limit: ' . SERVER_RING_SOFT_CONN_LIMIT . "\n";
        echo app_sqlite_line() . "\n";
    });
}

exit(app_workers_supervise(
    SERVER_WORKERS,
    static function (Closure $ready) use ($path, $secret, $host, $port): never {
        app_boot($path, $secret);
        $listener = diy_listen($host, $port, SERVER_BACKLOG);
        $server = new DiyServer($listener, SERVER_SOFT_CONN_LIMIT);
        $ready($server->loopLine() . "\t" . diy_socket_line($listener, SERVER_BACKLOG) . "\t" . app_sqlite_line());
        $server->run();
        exit(0);
    },
    static function (array $pids, string $loop, string $socket, string $sqlite) use ($host, $port, $ringFallback): void {
        echo 'workers: ' . SERVER_WORKERS . ' (pids ' . implode(' ', $pids) . ")\n";
        echo "listening on $host:$port\n";
        echo 'soft connection limit: ' . SERVER_SOFT_CONN_LIMIT . " per process\n";
        echo "$sqlite\n";
        echo "loop: $loop ($ringFallback)\n";
        echo "$socket\n";
    }
));
