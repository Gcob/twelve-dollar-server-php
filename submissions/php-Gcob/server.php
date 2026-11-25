<?php
// The $12 server challenge's submission in PHP: the challenge's five endpoints (app.php) on an event loop of our own (loop.php,
// connection.php), two worker processes sharing the port (workers.php).
//
// Configuration, as the challenge's SPEC.md says: SQLITE_PATH (the database it opens, never a copy) and JWT_SECRET are required, HOST
// defaults to 0.0.0.0 and PORT to 80. It listens only once every worker has opened the database.
//
// Built in, with no switch: two processes on SO_REUSEPORT, each with its own database connection and its own loop; a soft limit of 64,000
// client connections per process (a response built while more are open says `Connection: close` and its connection ends once written; an
// idle connection is never closed); a backlog of 4,096; the SQLite settings of app_connection_pragmas().
//
// It starts with the extensions loaded in this order: pcntl, sockets, event (start.sh).

require __DIR__ . '/app.php';
require __DIR__ . '/loop.php';
require __DIR__ . '/workers.php';

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
    static function (array $pids, string $loop, string $socket, string $sqlite) use ($host, $port): void {
        echo 'workers: ' . SERVER_WORKERS . ' (pids ' . implode(' ', $pids) . ")\n";
        echo "listening on $host:$port\n";
        echo 'soft connection limit: ' . SERVER_SOFT_CONN_LIMIT . " per process\n";
        echo "$sqlite\n";
        echo "loop: $loop\n";
        echo "$socket\n";
    }
));
