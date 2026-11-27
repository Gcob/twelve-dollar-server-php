<?php
// The submission (submissions/php-Gcob), apart from the challenge's 42 checks.
//
// The server as a process, on the epoll loop it falls back to when io_uring is refused (the lab's containers run under Docker's default seccomp filter):
// the boot lines in their order, SQLITE_PATH or JWT_SECRET unset or empty and a missing database each stop it with exit
// code 1, a message and nothing listening, SIGTERM to the parent ends both workers with exit code 0, and a worker killed with SIGKILL ends the
// parent with exit code 1 and the other worker.
//
// The soft limit, on its own path and without an environment variable (the limit is built in at 64,000, too high to reach in a test): the
// connection and its count on socket pairs, with a small limit, and the loop with a small limit on a TCP port of this machine. Past the limit a
// response says `Connection: close` and its connection ends once it is written; an idle connection is never closed.
//
// Run: LAB_RUN_SUBMISSIONS=1 bash lab/run.sh 8.5 php -d extension=sockets -d extension=event -d extension=pcntl /lab/check/submission-test.php

const SUBMISSION = __DIR__ . '/../../submissions/php-Gcob';
const FIRST_PORT = 18510;

require SUBMISSION . '/loop.php';

/** The handler of the connection, for the cases that drive it: echoes the request line, 18 bytes for `GET /x`. */
function handler_handle(string $method, string $path, string $body, string $authorization): array
{
    return [200, '{"echo":"' . $method . ' ' . $path . ' ' . $body . '"}'];
}

$failed = false;
/** Runs one case: $fn returns null when it holds, or the reason it does not. */
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

function show(string $bytes): string
{
    return json_encode(strlen($bytes) > 200 ? substr($bytes, 0, 200) . '...(' . strlen($bytes) . ' bytes)' : $bytes, JSON_INVALID_UTF8_SUBSTITUTE);
}

/** Everything the peer can read right now. */
function read_all($peer): string
{
    $all = '';
    while (($chunk = fread($peer, 65536)) !== false && $chunk !== '') {
        $all .= $chunk;
    }
    return $all;
}

// The soft limit, on socket pairs.

const GET = "GET /x HTTP/1.1\r\n\r\n";
// What a connection answers below the limit: the body is 18 bytes.
const PLAIN = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 18\r\n\r\n{\"echo\":\"GET /x \"}";
const WITH_CLOSE = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 18\r\nConnection: close\r\n\r\n{\"echo\":\"GET /x \"}";

/** @return array{resource, resource} the server's end and the client's end, both non-blocking */
function pair(): array
{
    $pair = stream_socket_pair(STREAM_PF_UNIX, STREAM_SOCK_STREAM, STREAM_IPPROTO_IP);
    stream_set_blocking($pair[0], false);
    stream_set_blocking($pair[1], false);
    return $pair;
}

/**
 * A client that is open and has sent $request: its connection (counted as the loop counts it) and the client's end.
 *
 * @return array{DiyConnection, resource}
 */
function open_client(DiyConnectionCount $count, string $request = GET): array
{
    [$server, $client] = pair();
    $count->opened();
    $conn = new DiyConnection($server, $count);
    fwrite($client, $request);
    return [$conn, $client];
}

/** The loop's callback on a readable stream: false (and the count down, the stream closed) when the connection is finished. */
function serve(DiyConnection $conn, DiyConnectionCount $count): bool
{
    $alive = $conn->onReadable();
    if (!$alive) {
        $count->closed();
        $conn->close();
    }
    return $alive;
}

check_case('soft limit 2: the first two connections answer as usual and stay open, the third says close and ends after its response', function () {
    $count = new DiyConnectionCount(2);
    $answers = [];
    $alive = [];
    $clients = [];
    $conns = [];
    foreach ([1, 2, 3] as $i) {
        [$conns[$i], $clients[$i]] = open_client($count);
        $alive[$i] = serve($conns[$i], $count);
        $answers[$i] = read_all($clients[$i]);
    }
    if ($answers[1] !== PLAIN || $answers[2] !== PLAIN) {
        return 'the first two should answer as usual: ' . show($answers[1]) . ' and ' . show($answers[2]);
    }
    if ($answers[3] !== WITH_CLOSE) {
        return 'the third should carry Connection: close: ' . show($answers[3]);
    }
    if ($alive !== [1 => true, 2 => true, 3 => false]) {
        return 'the first two stay open and the third ends: ' . json_encode($alive);
    }
    if (!feof($clients[3]) || feof($clients[1]) || feof($clients[2])) {
        return 'the client of the third should see the end of the stream, the first two should not';
    }
    return $count->open === 2 ? null : "open {$count->open}, expected 2";
});

check_case('the limit equals the idle count: 50 idle connections keep alive, 20 more each close after one response, the 50 answer again', function () {
    $count = new DiyConnectionCount(50);
    $idle = [];
    for ($i = 0; $i < 50; $i++) {
        [$conn, $client] = open_client($count);
        if (!serve($conn, $count) || read_all($client) !== PLAIN) {
            return "idle connection $i was closed or answered with something else";
        }
        $idle[] = [$conn, $client];
    }
    for ($i = 0; $i < 20; $i++) {
        [$conn, $client] = open_client($count);
        if (serve($conn, $count) || read_all($client) !== WITH_CLOSE || !feof($client)) {
            return "new connection $i should say close and end";
        }
    }
    if ($count->open !== 50) {
        return "open {$count->open}, expected 50";
    }
    foreach ($idle as $i => [$conn, $client]) {
        fwrite($client, GET);
        if (!serve($conn, $count) || read_all($client) !== PLAIN) {
            return "idle connection $i did not answer a second request as usual";
        }
    }
    return null;
});

check_case('limit 0: every response says close and the connection ends', function () {
    $count = new DiyConnectionCount(0);
    for ($i = 0; $i < 3; $i++) {
        [$conn, $client] = open_client($count);
        if (serve($conn, $count) || read_all($client) !== WITH_CLOSE) {
            return "connection $i should say close and end";
        }
    }
    return null;
});

check_case('a request pipelined behind the closing response is not answered', function () {
    $count = new DiyConnectionCount(0);
    [$conn, $client] = open_client($count, GET . GET . GET);
    if (serve($conn, $count)) {
        return 'the connection should end';
    }
    return read_all($client) === WITH_CLOSE ? null : 'the client should get one response only';
});

check_case('a client that asked for close gets one Connection: close header, not two', function () {
    $count = new DiyConnectionCount(0);
    [$conn, $client] = open_client($count, "GET /x HTTP/1.1\r\nConnection: close\r\n\r\n");
    return !serve($conn, $count) && read_all($client) === WITH_CLOSE ? null : 'the connection should end with one Connection: close header';
});

/** One TCP connection on loopback: the server's end (non-blocking, as the loop has it) and the client's. @return array{resource, resource} */
function tcp_pair(): array
{
    $listener = stream_socket_server('tcp://127.0.0.1:0', $errno, $errstr);
    $client = stream_socket_client('tcp://' . stream_socket_get_name($listener, false), $errno, $errstr);
    $server = stream_socket_accept($listener, 2);
    fclose($listener);
    stream_set_blocking($server, false);
    stream_set_blocking($client, false);
    return [$server, $client];
}

check_case('unread bytes in the receive buffer at the close: the client still reads the whole response, then the end, never a reset', function () {
    [$server, $client] = tcp_pair();
    $count = new DiyConnectionCount(0);
    $count->opened();
    $conn = new DiyConnection($server, $count);
    // The request is followed by more than one read's worth (8 KiB) of a next request: the connection answers the first, says close, and
    // closes with bytes it never read. Without care the kernel answers that close with a reset, which can throw away the response.
    fwrite($client, GET . "POST /x HTTP/1.1\r\nContent-Length: 200000\r\n\r\n" . str_repeat('x', 150000));
    usleep(100000);
    if ($conn->onReadable()) {
        return 'the connection should end';
    }
    $conn->close();
    stream_set_blocking($client, true);
    stream_set_timeout($client, 2);
    $got = '';
    while (($chunk = fread($client, 65536)) !== false && $chunk !== '') {
        $got .= $chunk;
    }
    // Why the last value: a reset ends the reads with false, the end of the stream with ''.
    return $got === WITH_CLOSE && $chunk === '' ? null : 'the client read ' . show($got) . ', and its last read gave ' . var_export($chunk, true);
});

// The soft limit, through the loop.

check_case('the loop with a limit of 2: of three clients the third is told to close and is ended, the first two stay open and answer again', function () {
    $listener = diy_listen('127.0.0.1', FIRST_PORT, 128);
    $server = new DiyServer($listener, 2);
    // Why a timer that repeats: a turn of the loop blocks until an event is ready, and a case that fails would wait for ever. The turn runs in
    // the server's scope, as its callbacks are private methods that ext-event calls in the scope of whoever runs the loop.
    $turn = Closure::bind(function (): void {
        static $heartbeat = null;
        $heartbeat ??= new Event($this->base, -1, Event::TIMEOUT | Event::PERSIST, static function (): void {
        });
        $heartbeat->add(0.05);
        $this->base->loop(EventBase::LOOP_ONCE);
    }, $server, DiyServer::class);
    $clients = [];
    $got = [];
    foreach ([1, 2, 3] as $i) {
        $clients[$i] = stream_socket_client('tcp://127.0.0.1:' . FIRST_PORT, $errno, $errstr, 2);
        stream_set_blocking($clients[$i], false);
        $got[$i] = '';
        fwrite($clients[$i], GET);
        // One client at a time, so that the order of the connections is the order of the numbers.
        for ($turns = 0; $turns < 40 && strlen($got[$i]) < strlen(PLAIN); $turns++) {
            $turn();
            $got[$i] .= read_all($clients[$i]);
        }
    }
    for ($turns = 0; $turns < 10; $turns++) {
        $turn();
    }
    if ($got[1] !== PLAIN || $got[2] !== PLAIN || $got[3] !== WITH_CLOSE) {
        return 'the answers: ' . show($got[1]) . ' ' . show($got[2]) . ' ' . show($got[3]);
    }
    if (!feof($clients[3]) || feof($clients[1]) || feof($clients[2])) {
        return 'the third client should see the end of the stream, the first two should not';
    }
    foreach ([1, 2] as $i) {
        fwrite($clients[$i], GET);
        $again = '';
        for ($turns = 0; $turns < 40 && strlen($again) < strlen(PLAIN); $turns++) {
            $turn();
            $again .= read_all($clients[$i]);
        }
        if ($again !== PLAIN) {
            return "client $i did not answer a second request as usual: " . show($again);
        }
    }
    return null;
});

// The server as a process.

/**
 * A database with the challenge's schema and a few rows, enough for the server to open and answer /health.
 */
function make_db(string $path): void
{
    $db = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $db->exec("
      CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));
      CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500),
                          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));
      CREATE TABLE likes (user_id INTEGER NOT NULL REFERENCES users(id), post_id INTEGER NOT NULL REFERENCES posts(id),
                          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), PRIMARY KEY (user_id, post_id));
      INSERT INTO users (id, username) VALUES (1, 'ada');
      INSERT INTO posts (user_id, body) VALUES (1, 'first');
    ");
}

$dir = sys_get_temp_dir() . '/submission-test-' . getmypid();
mkdir($dir);
register_shutdown_function(fn () => array_map('unlink', glob($dir . '/*')) && rmdir($dir));
make_db("$dir/feed.db");

/**
 * Starts the submission's server.php as the lab starts it (the three extensions), with the environment given: no variable but the ones in
 * $env, and PATH. Reads the boot lines up to the `socket:` line, or until the process ends.
 *
 * @param array<string, string> $env
 * @return array{process: resource, pipes: array<int, resource>, lines: list<string>, port: int}
 */
function start_server(array $env): array
{
    static $n = 0;
    $port = FIRST_PORT + 1 + $n++;
    $command = [PHP_BINARY, '-d', 'extension=pcntl', '-d', 'extension=sockets', '-d', 'extension=event', SUBMISSION . '/server.php'];
    $process = proc_open($command, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes, null, $env + ['PORT' => (string) $port, 'PATH' => (string) getenv('PATH')]);
    stream_set_timeout($pipes[1], 20);
    $lines = [];
    while (($line = fgets($pipes[1])) !== false) {
        $lines[] = rtrim($line);
        if (str_starts_with($line, 'socket:')) {
            break;
        }
    }
    return ['process' => $process, 'pipes' => $pipes, 'lines' => $lines, 'port' => $port];
}

/** The exit code once the process has ended (waits up to $seconds), or null while it runs. */
function exit_code(array $server, float $seconds): ?int
{
    static $known = [];
    $id = get_resource_id($server['process']);
    $deadline = microtime(true) + $seconds;
    do {
        if (isset($known[$id])) {
            return $known[$id];
        }
        // Why remembered: proc_get_status() gives the code once, the first time it sees the process ended, and -1 after.
        $status = proc_get_status($server['process']);
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
    $code = exit_code($server, 8);
    if ($code === null) {
        proc_terminate($server['process'], 9);
    }
    proc_close($server['process']);
    return $code;
}

function stderr_of(array $server): string
{
    stream_set_blocking($server['pipes'][2], false);
    return (string) stream_get_contents($server['pipes'][2]);
}

function listens(int $port): bool
{
    $socket = @stream_socket_client("tcp://127.0.0.1:$port", $errno, $errstr, 1);
    $socket !== false && fclose($socket);
    return $socket !== false;
}

function alive(int $pid): bool
{
    $stat = @file_get_contents("/proc/$pid/stat");
    return $stat !== false && !str_starts_with(substr($stat, (int) strrpos($stat, ')') + 2), 'Z');
}

function wait_gone(array $pids, float $seconds): bool
{
    $deadline = microtime(true) + $seconds;
    while (microtime(true) < $deadline && array_filter($pids, alive(...)) !== []) {
        usleep(50000);
    }
    return array_filter($pids, alive(...)) === [];
}

/** The worker ids the `workers:` boot line names. @return list<int> */
function worker_pids(array $lines): array
{
    foreach ($lines as $line) {
        if (preg_match('/^workers: 2 \(pids (\d+) (\d+)\)$/', $line, $m)) {
            return [(int) $m[1], (int) $m[2]];
        }
    }
    return [];
}

$base = ['SQLITE_PATH' => "$dir/feed.db", 'JWT_SECRET' => 'a-secret-for-this-test', 'HOST' => '127.0.0.1'];

check_case('the boot lines, in order: workers, listening, soft limit per process, SQLite settings read back, loop, socket', function () use ($base) {
    $server = start_server($base);
    $lines = $server['lines'];
    $port = $server['port'];
    $code = stop_server($server);
    $expected = [
        '#^workers: 2 \(pids \d+ \d+\)$#',
        "#^listening on 127\\.0\\.0\\.1:$port\$#",
        '#^soft connection limit: 64000 per process$#',
        '#^sqlite: journal_mode=wal synchronous=1 mmap_size=0 cache_size=-65536$#',
        // Why this text: the lab's containers run under Docker's default seccomp filter, which refuses io_uring, so the ring's first step fails and the server falls back.
        '#^loop: epoll \(io_uring refused: setup \d+\)$#',
        '#^socket: backlog=4096 tcp_nodelay=1$#',
    ];
    if (count($lines) !== count($expected)) {
        return 'expected ' . count($expected) . ' lines, got ' . json_encode($lines);
    }
    foreach ($expected as $i => $pattern) {
        if (!preg_match($pattern, $lines[$i])) {
            return "line $i is " . json_encode($lines[$i]) . ", expected $pattern";
        }
    }
    return $code === 0 ? null : "SIGTERM ended it with exit code " . var_export($code, true);
});

check_case('HOST and PORT given: it listens there and answers /health with 200', function () use ($base) {
    $server = start_server($base);
    $port = $server['port'];
    $socket = stream_socket_client("tcp://127.0.0.1:$port", $errno, $errstr, 2);
    fwrite($socket, "GET /health HTTP/1.1\r\nHost: x\r\n\r\n");
    stream_set_timeout($socket, 3);
    $head = (string) fread($socket, 12);
    stop_server($server);
    return $head === 'HTTP/1.1 200' ? null : 'GET /health answered ' . json_encode($head);
});

$refusals = [
    'SQLITE_PATH unset' => [fn (array $env) => array_diff_key($env, ['SQLITE_PATH' => 1]), 'SQLITE_PATH and JWT_SECRET must be set'],
    'SQLITE_PATH empty' => [fn (array $env) => ['SQLITE_PATH' => ''] + $env, 'SQLITE_PATH and JWT_SECRET must be set'],
    'JWT_SECRET unset' => [fn (array $env) => array_diff_key($env, ['JWT_SECRET' => 1]), 'SQLITE_PATH and JWT_SECRET must be set'],
    'JWT_SECRET empty' => [fn (array $env) => ['JWT_SECRET' => ''] + $env, 'SQLITE_PATH and JWT_SECRET must be set'],
    'the database file missing' => [fn (array $env) => ['SQLITE_PATH' => '/nonexistent/feed.db'] + $env, 'the database file does not exist: /nonexistent/feed.db'],
];
foreach ($refusals as $label => [$change, $message]) {
    check_case("$label: exit code 1, a message on stderr, nothing on stdout and nothing listening", function () use ($base, $change, $message) {
        $server = start_server($change($base));
        $code = exit_code($server, 10);
        $stderr = stderr_of($server);
        $stdout = (string) stream_get_contents($server['pipes'][1]);
        $listening = listens($server['port']);
        proc_close($server['process']);
        if ($code !== 1 || !str_contains($stderr, $message) || $stdout !== '' || $server['lines'] !== [] || $listening) {
            return 'exit ' . var_export($code, true) . ', stderr ' . json_encode($stderr) . ', boot lines ' . json_encode($server['lines']) . ', listening ' . var_export($listening, true);
        }
        return null;
    });
}

check_case('SIGTERM to the parent: both workers end, and the parent exits 0', function () use ($base) {
    $server = start_server($base);
    $pids = worker_pids($server['lines']);
    if (count($pids) !== 2 || count(array_filter($pids, alive(...))) !== 2) {
        stop_server($server);
        return 'the workers are not both running: ' . json_encode($server['lines']);
    }
    $code = stop_server($server);
    $gone = wait_gone($pids, 3);
    return $code === 0 && $gone ? null : 'exit code ' . var_export($code, true) . ', workers gone ' . var_export($gone, true);
});

check_case('a worker killed with SIGKILL: the parent says which one, stops the other worker and exits 1', function () use ($base) {
    $server = start_server($base);
    $pids = worker_pids($server['lines']);
    if (count($pids) !== 2) {
        stop_server($server);
        return 'no workers line: ' . json_encode($server['lines']);
    }
    posix_kill($pids[0], SIGKILL);
    $code = exit_code($server, 10);
    $stderr = stderr_of($server);
    $other = wait_gone([$pids[1]], 3);
    proc_close($server['process']);
    if ($code !== 1 || !str_contains($stderr, "server: worker {$pids[0]} was killed by signal 9, stopping the others") || !$other) {
        return 'exit code ' . var_export($code, true) . ', stderr ' . json_encode($stderr) . ', the other worker gone ' . var_export($other, true);
    }
    return null;
});

exit($failed ? 1 : 0);
