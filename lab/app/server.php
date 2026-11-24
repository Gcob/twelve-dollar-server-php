<?php
// The challenge app on the DIY loop (lab/servers/diy-server.php, lab/servers/diy-connection.php), the way a challenge submission is
// configured: SQLITE_PATH (the database it opens, never a copy), JWT_SECRET, HOST (default 0.0.0.0) and PORT (default 8080), and
// APP_TELEMETRY=1 (off by default): one line a second on stdout about the loop and the database (lab/servers/diy-telemetry.php), and
// APP_PROFILE=<file> (off by default, needs `--ext excimer`): a CPU-time profiler whose collapsed stacks are written to that file every
// 2 s, one sample every APP_PROFILE_PERIOD seconds of CPU time (default 0.001; lab/servers/diy-profile.php), and
// APP_SOFT_CONN_LIMIT=<n> (off by default; 0 is a limit): a response built while more than <n> client connections are open says
// `Connection: close` and its connection ends once it is written (lab/servers/diy-server.php), and the S6 variants of lab/app/app.php
// (off by default): APP_FEED_SQL=reference|join|two-step, APP_FETCH=assoc|num|assoc-loop|num-loop, APP_PRAGMAS=default|mmap-off|cache-256m|cache-8m,
// and APP_LOCKING=normal|exclusive (off by default; exclusive: no other process can open the database while the server runs), and the
// S9 switches: APP_GROUP_COMMIT=1 (off by default: the writes of one turn of the loop are committed together, lab/servers/diy-server.php) and
// APP_CHECKPOINTER=<ms> (off by default: a second process checkpoints the WAL every <ms> milliseconds, lab/app/checkpointer.php; refused
// with APP_LOCKING=exclusive; don't use it as it is: under a steady writer the WAL never restarts and grows without bound), and
// APP_WORKERS=<n> (off by default; n of 2 or more needs `--ext pcntl`): n processes serve on the one port with SO_REUSEPORT, each with its own
// loop, its own connection to the database and its own file descriptors (lab/app/workers.php). Each one's telemetry line says its pid, and
// APP_SOFT_CONN_LIMIT counts each process's own connections. Refused with APP_LOCKING=exclusive, APP_CHECKPOINTER and APP_PROFILE.
//
// It starts with the extensions loaded in this order: `--ext sockets --ext event`. It listens only once the database is open.
// lab/challenge-test.sh starts it on a fresh copy of the seed.

require __DIR__ . '/app.php';
require __DIR__ . '/../servers/diy-server.php';
require __DIR__ . '/../servers/diy-telemetry.php';
require __DIR__ . '/../servers/diy-profile.php';

$path = (string) getenv('SQLITE_PATH');
$secret = (string) getenv('JWT_SECRET');
if ($path === '' || $secret === '') {
    fwrite(STDERR, "server: SQLITE_PATH and JWT_SECRET must be set\n");
    exit(1);
}
$host = (string) (getenv('HOST') ?: '0.0.0.0');
$port = (int) (getenv('PORT') ?: 8080);
$backlog = 4096;

try {
    $variants = app_variants(getenv());
    $workers = app_workers(getenv(), $variants);
} catch (InvalidArgumentException $e) {
    fwrite(STDERR, 'server: ' . $e->getMessage() . "\n");
    exit(1);
}
$softLimit = null;
$softLimitValue = getenv('APP_SOFT_CONN_LIMIT');
if ($softLimitValue !== false && $softLimitValue !== '') {
    if (!ctype_digit($softLimitValue)) {
        fwrite(STDERR, "server: APP_SOFT_CONN_LIMIT must be a whole number, got '$softLimitValue'\n");
        exit(1);
    }
    $softLimit = (int) $softLimitValue;
}
if ($workers >= 2) {
    if (!extension_loaded('pcntl')) {
        fwrite(STDERR, "server: APP_WORKERS=$workers needs ext-pcntl (start with --ext sockets --ext event --ext pcntl)\n");
        exit(1);
    }
    if (!is_file($path)) {
        fwrite(STDERR, "server: the database file does not exist: $path\n");
        exit(1);
    }
    require __DIR__ . '/workers.php';
    exit(app_workers_supervise(
        $workers,
        static function (Closure $ready) use ($path, $secret, $variants, $host, $port, $backlog, $softLimit): never {
            app_boot($path, $secret, $variants);
            $listener = diy_listen($host, $port, $backlog, true);
            $telemetry = null;
            if (getenv('APP_TELEMETRY') === '1') {
                app_telemetry_enable();
                $pid = getmypid();
                $telemetry = new DiyTelemetry(static fn (): array => ['pid' => $pid] + app_telemetry_fields());
            }
            $server = new DiyServer($listener, $telemetry, null, $softLimit, $variants['group_commit'] ? app_group_commit(...) : null);
            $ready($server->loopMethod() . "\t" . diy_socket_line($listener, $backlog));
            $server->run();
            exit(0);
        },
        static function (array $pids, string $loop, string $socket) use ($host, $port, $softLimit, $variants, $workers): void {
            echo "workers: $workers (pids " . implode(' ', $pids) . ")\n";
            echo "listening on $host:$port\n";
            if ($softLimit !== null) {
                echo "soft connection limit: $softLimit per process\n";
            }
            if ($variants !== app_variants([])) {
                echo 'app variants: feed_sql=' . $variants['feed_sql'] . ' fetch=' . $variants['fetch'] . ' pragmas=' . $variants['pragmas'] . ' locking=' . $variants['locking']
                    . ' group_commit=' . ($variants['group_commit'] ? 'on' : 'off') . ' checkpointer=off' . "\n";
            }
            echo "loop: $loop\n";
            echo "$socket\n";
        }
    ));
}

app_boot($path, $secret, $variants);
$checkpointerPid = $variants['checkpointer'] > 0 ? app_checkpointer_start($path, $variants['checkpointer']) : null;

$listener = diy_listen($host, $port, $backlog);
$telemetry = null;
if (getenv('APP_TELEMETRY') === '1') {
    app_telemetry_enable();
    $telemetry = new DiyTelemetry(app_telemetry_fields(...));
}
$profile = null;
if ((string) getenv('APP_PROFILE') !== '') {
    $profile = new DiyProfile((string) getenv('APP_PROFILE'), (float) (getenv('APP_PROFILE_PERIOD') ?: 0.001));
}
$server = new DiyServer($listener, $telemetry, $profile, $softLimit, $variants['group_commit'] ? app_group_commit(...) : null);
echo "listening on $host:$port\n";
if ($softLimit !== null) {
    echo "soft connection limit: $softLimit\n";
}
if ($variants !== app_variants([])) {
    echo 'app variants: feed_sql=' . $variants['feed_sql'] . ' fetch=' . $variants['fetch'] . ' pragmas=' . $variants['pragmas'] . ' locking=' . $variants['locking']
        . ' group_commit=' . ($variants['group_commit'] ? 'on' : 'off') . ' checkpointer=' . ($checkpointerPid === null ? 'off' : $variants['checkpointer']) . "\n";
}
if ($checkpointerPid !== null) {
    echo "checkpointer: {$variants['checkpointer']} ms (process $checkpointerPid)\n";
}
echo 'loop: ' . $server->loopMethod() . "\n";
echo diy_socket_line($listener, $backlog) . "\n";
$server->run();
