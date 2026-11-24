<?php
// APP_WORKERS=<n> of the challenge app (lab/app/server.php, lab/app/workers.php): n processes on one port with SO_REUSEPORT.
//
// The switch's values and what it is refused with (app_workers); then lab/app/server.php as a process: unset and 1 print the boot lines
// they always did, 2 workers print the workers line and the others, each child has its own connection to the database and the parent
// none, 200 connections each with a request are answered by both processes (read from the telemetry lines, which say their pid, so the
// response bytes need no extra header), every write is committed before its response whoever served it, a child killed with SIGKILL ends
// the parent with a non-zero code and the other child, SIGTERM to the parent ends everything, and the refusals (exclusive locking, the
// checkpointer, the profiler, no pcntl, no database).
// Run: bash lab/run.sh 8.5 php -d extension=sockets -d extension=event -d extension=pcntl /lab/check/app-workers-test.php

require __DIR__ . '/app-lib.php';
require __DIR__ . '/../app/workers.php';

$dir = sys_get_temp_dir() . '/app-workers-' . getmypid();
mkdir($dir);
// Why the pid: the supervision cases below fork this process, and a child that exits runs the shutdown functions too.
$owner = getmypid();
register_shutdown_function(fn () => getmypid() === $owner && array_map('unlink', glob($dir . '/*')) && rmdir($dir));
make_db("$dir/source.db", 30);

$failed = false;
function check_case(string $name, callable $fn): void
{
    global $failed;
    try {
        $why = $fn();
    } catch (Throwable $e) {
        $why = get_class($e) . ': ' . $e->getMessage();
    }
    if ($why === null) {
        echo "ok    $name\n";
    } else {
        echo "FAIL  $name: $why\n";
        $failed = true;
    }
}

// The switch.

check_case('unset, empty, 1, 2 and 64 are read; unset, empty and 1 are one process', function () {
    $got = [];
    foreach ([[], ['APP_WORKERS' => ''], ['APP_WORKERS' => '1'], ['APP_WORKERS' => '2'], ['APP_WORKERS' => '64']] as $env) {
        $got[] = app_workers($env, app_variants($env));
    }
    return $got === [1, 1, 1, 2, 64] ? null : 'got ' . json_encode($got);
});

foreach (['0', '65', '-1', 'two', '2.5', ' 2', '1000'] as $value) {
    check_case("APP_WORKERS=" . json_encode($value) . " is refused, and the message names the variable and the value", function () use ($value) {
        try {
            app_workers(['APP_WORKERS' => $value], app_variants([]));
        } catch (InvalidArgumentException $e) {
            return str_contains($e->getMessage(), 'APP_WORKERS must be a whole number from 1 to 64, got ' . json_encode($value)) ? null : $e->getMessage();
        }
        return 'accepted';
    });
}

foreach (['APP_LOCKING' => 'exclusive', 'APP_CHECKPOINTER' => '1000', 'APP_PROFILE' => '/tmp/profile'] as $name => $value) {
    check_case("APP_WORKERS=2 with $name=$value is refused and says why; with APP_WORKERS=1 it is allowed", function () use ($name, $value) {
        $env = ['APP_WORKERS' => '2', $name => $value];
        try {
            app_workers($env, app_variants($env));
            return 'accepted with 2 workers';
        } catch (InvalidArgumentException $e) {
            if (!str_contains($e->getMessage(), 'APP_WORKERS=2 cannot be set with ' . $name)) {
                return $e->getMessage();
            }
        }
        $env['APP_WORKERS'] = '1';
        return app_workers($env, app_variants($env)) === 1 ? null : 'not one process with APP_WORKERS=1';
    });
}

// The supervision, with children that do nothing but report: they are forked from this process, so no loop, no database and no port.

/**
 * Runs app_workers_supervise() for two children running $worker.
 *
 * @return array{int, array|null, float, list<int>} the exit code, what was announced (pids, loop line, socket line) or null, the seconds it
 *                                                  took, and the pids of the children (known only once announced)
 */
function supervised(Closure $worker): array
{
    $announced = null;
    $start = microtime(true);
    fflush(STDOUT);
    $code = app_workers_supervise(2, $worker, static function (array $pids, string $loop, string $socket) use (&$announced): void {
        $announced = [$pids, $loop, $socket];
    });
    return [$code, $announced, microtime(true) - $start];
}

check_case('children that report and then ask the parent to stop: the announce gets both pids and the first report, the parent returns 0 and both children are gone, fast', function () {
    [$code, $announced, $seconds] = supervised(static function (Closure $ready): never {
        $ready("test-loop\tsocket: test");
        usleep(300000);
        posix_kill(posix_getppid(), SIGTERM);
        sleep(30);
        exit(0);
    });
    if ($code !== 0 || $announced === null || count($announced[0]) !== 2 || array_slice($announced, 1) !== ['test-loop', 'socket: test']) {
        return 'code ' . var_export($code, true) . ', announced ' . json_encode($announced);
    }
    // Under 4 s: a child that kept the parent's SIGTERM handler would not stop and would wait for the SIGKILL after 5 s.
    return wait_gone($announced[0], 1) && $seconds < 4 ? null : 'children gone: ' . var_export(wait_gone($announced[0], 0), true) . ", took $seconds s";
});

foreach (['a child that exits with status 3 after it reported' => 'after', 'a child that exits with status 3 before it reported' => 'before'] as $label => $when) {
    check_case("$label: the parent returns 1, stops the other child and says which one ended", function () use ($when, $dir) {
        $elect = "$dir/elect-$when";
        [$code, $announced, $seconds] = supervised(static function (Closure $ready) use ($when, $elect): never {
            // The first child to create the file is the one that ends; the other reports and waits.
            $elected = @fopen($elect, 'x') !== false;
            if ($elected && $when === 'before') {
                exit(3);
            }
            $ready("loop\tsocket");
            if ($elected) {
                usleep(300000);
                exit(3);
            }
            sleep(30);
            exit(0);
        });
        $others = $announced === null ? [] : $announced[0];
        $gone = $others === [] || wait_gone($others, 1);
        if ($code !== 1 || $seconds > 4 || !$gone) {
            return 'code ' . var_export($code, true) . ", took $seconds s, children gone " . var_export($gone, true) . ', announced ' . json_encode($announced);
        }
        // Before it reported, the parent never announced anything; after, it did.
        return ($announced === null) === ($when === 'before') ? null : 'announced ' . json_encode($announced);
    });
}

// The server as a process.

/**
 * Starts lab/app/server.php on a copy of the source database with the switches in $env and the extensions in $ext.
 *
 * @return array{process: resource, port: int, pipes: array<int, resource>, lines: list<string>, path: string} lines: the boot lines, up to the
 *                                                                                                          `socket:` line (fewer if it never comes)
 */
function start_server(array $env, array $ext = ['sockets', 'event', 'pcntl'], string $db = 'copy'): array
{
    global $dir;
    static $n = 0;
    $port = 18420 + $n;
    $path = $dir . '/server-' . ++$n . '.db';
    if ($db === 'copy') {
        copy("$dir/source.db", $path);
    }
    $command = [PHP_BINARY];
    foreach ($ext as $name) {
        array_push($command, '-d', "extension=$name");
    }
    $command[] = __DIR__ . '/../app/server.php';
    $process = proc_open($command, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes,
        null, $env + ['SQLITE_PATH' => $path, 'JWT_SECRET' => SECRET, 'HOST' => '127.0.0.1', 'PORT' => (string) $port, 'PATH' => getenv('PATH')]);
    stream_set_timeout($pipes[1], 20);
    $lines = [];
    while (($line = fgets($pipes[1])) !== false) {
        $lines[] = rtrim($line);
        if (str_starts_with($line, 'socket:')) {
            break;
        }
    }
    return ['process' => $process, 'port' => $port, 'pipes' => $pipes, 'lines' => $lines, 'path' => $path];
}

/**
 * The exit code of the process once it has ended (waits up to $seconds), or null while it runs. Why remembered: proc_get_status() gives the
 * code once, the first time it sees the process ended, and -1 after.
 */
function exit_code($process, float $seconds): ?int
{
    static $known = [];
    $id = get_resource_id($process);
    $deadline = microtime(true) + $seconds;
    do {
        if (isset($known[$id])) {
            return $known[$id];
        }
        $status = proc_get_status($process);
        if (!$status['running']) {
            return $known[$id] = $status['exitcode'];
        }
        usleep(50000);
    } while (microtime(true) < $deadline);
    return null;
}

/** Ends the server the way a container's stop does (SIGTERM), then makes sure. Returns its exit code. */
function stop_server(array $server): ?int
{
    proc_terminate($server['process'], 15);
    $code = exit_code($server['process'], 8);
    if ($code === null) {
        proc_terminate($server['process'], 9);
    }
    proc_close($server['process']);
    return $code;
}

/** Whether a process is running (a zombie nobody reaped is gone all the same). */
function alive(int $pid): bool
{
    $stat = @file_get_contents("/proc/$pid/stat");
    return $stat !== false && !str_starts_with(substr($stat, (int) strrpos($stat, ')') + 2), 'Z');
}

function wait_gone(array $pids, float $seconds): bool
{
    $deadline = microtime(true) + $seconds;
    while (microtime(true) < $deadline) {
        if (array_filter($pids, alive(...)) === []) {
            return true;
        }
        usleep(50000);
    }
    return array_filter($pids, alive(...)) === [];
}

/** The process id of the server and the ids its workers line names, from the boot lines; null when there is no such line. */
function worker_pids(array $lines): ?array
{
    foreach ($lines as $line) {
        if (preg_match('/^workers: (\d+) \(pids ([\d ]+)\)$/', $line, $m)) {
            return array_map('intval', explode(' ', $m[2]));
        }
    }
    return null;
}

function parent_of(int $pid): int
{
    $stat = (string) @file_get_contents("/proc/$pid/stat");
    return (int) (explode(' ', substr($stat, (int) strrpos($stat, ')') + 2))[1] ?? 0);
}

/** One request over a connection of its own, read to the end of its body: [status, body]. */
function http(int $port, string $request): array
{
    $socket = stream_socket_client("tcp://127.0.0.1:$port", $errno, $errstr, 5);
    stream_set_timeout($socket, 5);
    fwrite($socket, $request);
    $data = '';
    while (!preg_match('/\r\n\r\n/', $data) || !preg_match('/Content-Length: (\d+)/', $data, $m) || strlen($data) < strpos($data, "\r\n\r\n") + 4 + (int) $m[1]) {
        $chunk = fread($socket, 65536);
        if ($chunk === false || $chunk === '') {
            break;
        }
        $data .= $chunk;
    }
    fclose($socket);
    return [(int) substr($data, 9, 3), (string) substr($data, (int) strpos($data, "\r\n\r\n") + 4)];
}

function get_request(string $target): string
{
    return "GET $target HTTP/1.1\r\n\r\n";
}

function post_request(string $target, string $token, string $body = ''): string
{
    return "POST $target HTTP/1.1\r\nAuthorization: $token\r\nContent-Length: " . strlen($body) . "\r\n\r\n$body";
}

/** What is committed in the database at $path, read through a connection of this process. */
function committed(string $path, string $sql): array
{
    $db = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    return $db->query($sql)->fetchAll(PDO::FETCH_COLUMN);
}

/** Whether something listens on the port. */
function listens(int $port): bool
{
    $socket = @stream_socket_client("tcp://127.0.0.1:$port", $errno, $errstr, 1);
    $socket !== false && fclose($socket);
    return $socket !== false;
}

/** The telemetry lines the server prints until $enough(lines) is true or $seconds pass. @return list<array<string, mixed>> */
function telemetry_until(array $server, callable $enough, float $seconds): array
{
    $lines = [];
    $deadline = microtime(true) + $seconds;
    stream_set_timeout($server['pipes'][1], 1);
    while (microtime(true) < $deadline && !$enough($lines)) {
        $line = fgets($server['pipes'][1]);
        if ($line !== false && str_starts_with($line, 'telemetry ')) {
            $lines[] = json_decode(substr($line, 10), true);
        }
    }
    return $lines;
}

/** @return array<int, array<string, int>> the requests of the telemetry lines, per process id and endpoint */
function requests_by_pid(array $lines): array
{
    $by = [];
    foreach ($lines as $line) {
        foreach ($line['requests'] as $endpoint => $count) {
            $by[$line['pid']][$endpoint] = ($by[$line['pid']][$endpoint] ?? 0) + $count;
        }
    }
    return $by;
}

function auth(int $user): string
{
    $names = [1 => 'ada', 2 => 'grace', 8 => 'barbara'];
    return 'Bearer ' . token($user, $names[$user]);
}

check_case('unset and APP_WORKERS=1 print the same boot lines, no workers line, and the soft limit line as it always was', function () {
    $seen = [];
    foreach (['unset' => [], 'one' => ['APP_WORKERS' => '1']] as $label => $extra) {
        $server = start_server($extra + ['APP_SOFT_CONN_LIMIT' => '5']);
        stop_server($server);
        $seen[$label] = $server['lines'];
    }
    $lines = $seen['unset'];
    $shape = count($lines) === 4 && preg_match('/^listening on 127\.0\.0\.1:\d+$/', $lines[0]) && $lines[1] === 'soft connection limit: 5'
        && str_starts_with($lines[2], 'loop: ') && $lines[3] === 'socket: backlog=4096 tcp_nodelay=1';
    if (!$shape) {
        return 'the boot lines of the unset server: ' . json_encode($lines);
    }
    // The port differs between the two starts, nothing else may.
    $normal = static fn (array $l): array => preg_replace('/:\d+$/', ':PORT', $l);
    return $normal($seen['unset']) === $normal($seen['one']) ? null : 'unset ' . json_encode($seen['unset']) . ', 1: ' . json_encode($seen['one']);
});

check_case('2 workers: the workers line names two processes whose parent is the server, then the lines of one process, the soft limit says per process', function () {
    $server = start_server(['APP_WORKERS' => '2', 'APP_SOFT_CONN_LIMIT' => '5', 'APP_PRAGMAS' => 'mmap-off']);
    $pids = worker_pids($server['lines']);
    $parent = proc_get_status($server['process'])['pid'];
    $parents = $pids === null ? null : array_map(parent_of(...), $pids);
    stop_server($server);
    $lines = $server['lines'];
    if ($pids === null || count($pids) !== 2 || $parents !== [$parent, $parent]) {
        return 'workers line / parents ' . json_encode([$pids, $parents, $parent]) . ' in ' . json_encode($lines);
    }
    $ok = count($lines) === 6 && $lines[0] === 'workers: 2 (pids ' . implode(' ', $pids) . ')' && preg_match('/^listening on 127\.0\.0\.1:\d+$/', $lines[1])
        && $lines[2] === 'soft connection limit: 5 per process' && str_starts_with($lines[3], 'app variants: ') && str_ends_with($lines[3], 'pragmas=mmap-off locking=normal group_commit=off checkpointer=off')
        && str_starts_with($lines[4], 'loop: ') && $lines[5] === 'socket: backlog=4096 tcp_nodelay=1';
    return $ok ? null : 'the boot lines: ' . json_encode($lines);
});

check_case('each worker has its own connection to the database and its own listening socket; the parent has neither', function () {
    $server = start_server(['APP_WORKERS' => '2']);
    $pids = worker_pids($server['lines']);
    $parent = proc_get_status($server['process'])['pid'];
    // The inodes of the sockets listening on the server's port, from the kernel's table (state 0A is LISTEN).
    $listening = [];
    foreach (file('/proc/net/tcp', FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) ?: [] as $row) {
        $f = preg_split('/\s+/', trim($row));
        if (($f[3] ?? '') === '0A' && str_ends_with($f[1], sprintf(':%04X', $server['port']))) {
            $listening[] = $f[9];
        }
    }
    $holds = static function (int $pid, callable $matches): int {
        $n = 0;
        foreach (glob("/proc/$pid/fd/*") ?: [] as $fd) {
            $n += $matches((string) @readlink($fd)) ? 1 : 0;
        }
        return $n;
    };
    $all = $pids === null ? [] : [$parent, ...$pids];
    $dbs = array_map(static fn (int $pid): int => $holds($pid, static fn (string $l): bool => str_contains($l, basename($server['path']))), $all);
    $sockets = array_map(static fn (int $pid): int => $holds($pid, static fn (string $l): bool => preg_match('/^socket:\[(\d+)\]$/', $l, $m) === 1 && in_array($m[1], $listening, true)), $all);
    stop_server($server);
    if ($pids === null) {
        return 'no workers line: ' . json_encode($server['lines']);
    }
    // The database appears as the file, its -wal and its -shm; the parent never opened it. Each worker holds its own listening socket (two
    // sockets on the port, one per worker), the parent none.
    return count($listening) === 2 && $dbs[0] === 0 && $dbs[1] >= 1 && $dbs[2] >= 1 && $sockets === [0, 1, 1] ? null
        : 'listening inodes ' . json_encode($listening) . ', database fds [parent, worker, worker] ' . json_encode($dbs) . ', listening socket fds ' . json_encode($sockets);
});

check_case('200 connections with one request each are answered by both processes (the telemetry lines say which), and 60 writes are each committed before their 201', function () {
    $server = start_server(['APP_WORKERS' => '2', 'APP_TELEMETRY' => '1']);
    $pids = worker_pids($server['lines']);
    if ($pids === null) {
        stop_server($server);
        return 'no workers line: ' . json_encode($server['lines']);
    }
    $statuses = [];
    for ($i = 0; $i < 200; $i++) {
        $statuses[] = http($server['port'], get_request('/health'))[0];
    }
    $before = (int) committed($server['path'], 'SELECT count(*) FROM posts')[0];
    $uncommitted = [];
    for ($i = 1; $i <= 60; $i++) {
        $answer = http($server['port'], post_request('/posts', auth(8), json_encode(['body' => "from the test $i"])));
        $count = (int) committed($server['path'], 'SELECT count(*) FROM posts')[0];
        if ($answer[0] !== 201 || $count !== $before + $i) {
            $uncommitted[] = "$i: status {$answer[0]}, rows $count of " . ($before + $i);
        }
    }
    $lines = telemetry_until($server, static function (array $lines): bool {
        $by = requests_by_pid($lines);
        return array_sum(array_map(static fn (array $r): int => $r['GET /health'] ?? 0, $by)) >= 200 && array_sum(array_map(static fn (array $r): int => $r['POST /posts'] ?? 0, $by)) >= 60;
    }, 8);
    stop_server($server);
    $by = requests_by_pid($lines);
    if (array_unique($statuses) !== [200]) {
        return 'the health checks answered ' . json_encode(array_count_values($statuses));
    }
    if ($uncommitted !== []) {
        return 'a write was answered before it was committed (or failed): ' . implode('; ', array_slice($uncommitted, 0, 3));
    }
    $pidsInTelemetry = array_keys($by);
    sort($pidsInTelemetry);
    $sortedPids = $pids;
    sort($sortedPids);
    if ($pidsInTelemetry !== $sortedPids) {
        return 'the telemetry names ' . json_encode($pidsInTelemetry) . ', the workers line ' . json_encode($sortedPids);
    }
    foreach ($by as $pid => $requests) {
        if (($requests['GET /health'] ?? 0) < 1 || ($requests['POST /posts'] ?? 0) < 1) {
            return "process $pid did not answer both kinds of request: " . json_encode($by);
        }
    }
    $total = [array_sum(array_column($by, 'GET /health')), array_sum(array_column($by, 'POST /posts'))];
    return $total === [200, 60] ? null : 'the telemetry counts ' . json_encode($total) . ' requests, 200 health checks and 60 posts were sent';
});

check_case('a worker killed with SIGKILL ends the parent with exit code 1 and the other worker, and frees the port', function () {
    $server = start_server(['APP_WORKERS' => '2']);
    $pids = worker_pids($server['lines']);
    if ($pids === null) {
        stop_server($server);
        return 'no workers line: ' . json_encode($server['lines']);
    }
    posix_kill($pids[0], SIGKILL);
    $code = exit_code($server['process'], 8);
    $gone = wait_gone($pids, 8);
    // Why not read stderr of a server whose worker still runs: the pipe stays open as long as one process holds it.
    $err = $code === null || !$gone ? '' : stream_get_contents($server['pipes'][2]);
    $listening = listens($server['port']);
    stop_server($server);
    foreach ($pids as $pid) {
        @posix_kill($pid, SIGKILL);
    }
    if ($code !== 1) {
        return 'the parent exit code is ' . var_export($code, true);
    }
    if (!$gone || $listening) {
        return 'workers gone ' . var_export($gone, true) . ', port still answers ' . var_export($listening, true);
    }
    return str_contains($err, "server: worker {$pids[0]} was killed by signal 9, stopping the others") ? null : "stderr: $err";
});

check_case('SIGTERM to the parent ends both workers and the parent exits 0', function () {
    $server = start_server(['APP_WORKERS' => '2']);
    $pids = worker_pids($server['lines']);
    if ($pids === null) {
        stop_server($server);
        return 'no workers line: ' . json_encode($server['lines']);
    }
    $answered = http($server['port'], get_request('/health'))[0];
    $code = stop_server($server);
    $gone = wait_gone($pids, 8);
    return $answered === 200 && $code === 0 && $gone && !listens($server['port']) ? null : "health $answered, exit " . var_export($code, true) . ', workers gone ' . var_export($gone, true);
});

foreach ([
    'APP_LOCKING=exclusive' => ['APP_LOCKING' => 'exclusive'],
    'APP_CHECKPOINTER=1000' => ['APP_CHECKPOINTER' => '1000'],
    'APP_PROFILE' => ['APP_PROFILE' => '/tmp/profile-of-the-test'],
] as $label => $extra) {
    check_case("2 workers with $label: the server refuses to start, exits 1 and says why", function () use ($extra, $label) {
        $server = start_server(['APP_WORKERS' => '2'] + $extra);
        $code = exit_code($server['process'], 8);
        $code === null && proc_terminate($server['process'], 9);
        $err = stream_get_contents($server['pipes'][2]);
        proc_close($server['process']);
        $name = explode('=', $label)[0];
        return $code === 1 && $server['lines'] === [] && str_contains($err, "APP_WORKERS=2 cannot be set with $name") ? null : 'exit ' . var_export($code, true) . ", stdout " . json_encode($server['lines']) . ", stderr: $err";
    });
}

check_case('2 workers without pcntl: the server says so and exits 1', function () {
    $server = start_server(['APP_WORKERS' => '2'], ['sockets', 'event']);
    $code = exit_code($server['process'], 8);
    $code === null && proc_terminate($server['process'], 9);
    $err = stream_get_contents($server['pipes'][2]);
    proc_close($server['process']);
    return $code === 1 && str_contains($err, 'APP_WORKERS=2 needs ext-pcntl') ? null : 'exit ' . var_export($code, true) . ", stderr: $err";
});

check_case('2 workers without a database file: the server says so and exits 1, forking nothing', function () {
    $server = start_server(['APP_WORKERS' => '2'], ['sockets', 'event', 'pcntl'], 'none');
    $code = exit_code($server['process'], 8);
    $code === null && proc_terminate($server['process'], 9);
    $err = stream_get_contents($server['pipes'][2]);
    proc_close($server['process']);
    return $code === 1 && str_contains($err, 'the database file does not exist') && $server['lines'] === [] ? null : 'exit ' . var_export($code, true) . ", stderr: $err";
});

exit($failed ? 1 : 0);
