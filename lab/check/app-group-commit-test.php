<?php
// The two S9 switches of the challenge app, APP_GROUP_COMMIT=1 and APP_CHECKPOINTER=<ms>, on a small database made here.
//
// Group commit: through the app's own functions (a write answers with a Closure that app_group_commit() runs, in one transaction with each
// write in its own savepoint), through a DiyServer in this process with its clients (two writes in one turn, a like then a read pipelined,
// two likes pipelined, a write that fails inside the batch: a trigger of the test's database makes one statement throw, so no test hook
// is in the app), and through lab/app/server.php as a child process (a 201 is received, the process is killed with SIGKILL, the row is
// there). The checkpointer: its value is refused when it is not a whole number of milliseconds or when APP_LOCKING=exclusive is also set
// (the second process could not open the database), the server's connection stops checkpointing by itself, and the second process
// checkpoints the WAL and ends with the server.
// Run: bash lab/run.sh 8.5 php -d extension=sockets -d extension=event /lab/check/app-group-commit-test.php

require __DIR__ . '/app-lib.php';
require __DIR__ . '/diy-rig.php';

$dir = sys_get_temp_dir() . '/app-group-commit-' . getmypid();
mkdir($dir);
register_shutdown_function(fn () => array_map('unlink', glob($dir . '/*')) && rmdir($dir));
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

/** A fresh copy of the source database, with the switches booted on it (and a trigger that makes a post with the body `boom` fail). */
function boot_copy(array $env): string
{
    global $dir;
    static $n = 0;
    $copy = $dir . '/copy-' . ++$n . '.db';
    copy("$dir/source.db", $copy);
    $db = new PDO('sqlite:' . $copy, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $db->exec("CREATE TRIGGER fail_boom BEFORE INSERT ON posts WHEN NEW.body = 'boom' BEGIN SELECT RAISE(ABORT, 'boom'); END");
    $db = null;
    app_boot($copy, SECRET, app_variants($env));
    return $copy;
}

/** A second connection to $path, as another process would have: what is committed. */
function committed(string $path, string $sql): array
{
    $db = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    return $db->query($sql)->fetchAll(PDO::FETCH_COLUMN);
}

function auth(int $user): string
{
    $names = [1 => 'ada', 2 => 'grace', 8 => 'barbara'];
    return 'Bearer ' . token($user, $names[$user]);
}

/** The group commit, the way the server calls it. */
function run_group(array $writes): array
{
    return app_group_commit($writes);
}

// The switches.

check_case('unset, empty and the default values are the same switches (no group commit, no checkpointer)', function () {
    $default = ['feed_sql' => 'reference', 'fetch' => 'assoc', 'pragmas' => 'default', 'locking' => 'normal', 'group_commit' => false, 'checkpointer' => 0];
    foreach ([[], ['APP_GROUP_COMMIT' => '', 'APP_CHECKPOINTER' => ''], ['APP_GROUP_COMMIT' => '0']] as $env) {
        if (app_variants($env) !== $default) {
            return 'got ' . json_encode(app_variants($env)) . ' for ' . json_encode($env);
        }
    }
    return null;
});

check_case('APP_GROUP_COMMIT=1 and APP_CHECKPOINTER=1000 are read', function () {
    $got = app_variants(['APP_GROUP_COMMIT' => '1', 'APP_CHECKPOINTER' => '1000']);
    return $got['group_commit'] === true && $got['checkpointer'] === 1000 ? null : 'got ' . json_encode($got);
});

foreach ([['APP_GROUP_COMMIT', 'yes', '0, 1'], ['APP_GROUP_COMMIT', '2', '0, 1'], ['APP_CHECKPOINTER', 'fast', 'whole number'],
          ['APP_CHECKPOINTER', '0', 'whole number'], ['APP_CHECKPOINTER', '-5', 'whole number'], ['APP_CHECKPOINTER', '1.5', 'whole number']] as [$name, $value, $says]) {
    check_case("$name=$value is refused, and the message names the variable, the value and what is allowed ($says)", function () use ($name, $value, $says) {
        try {
            app_variants([$name => $value]);
        } catch (InvalidArgumentException $e) {
            $message = $e->getMessage();
            return str_contains($message, $name) && str_contains($message, $value) && str_contains($message, $says) ? null : "the message is: $message";
        }
        return 'no exception';
    });
}

check_case('APP_CHECKPOINTER with APP_LOCKING=exclusive is refused, and the message says why', function () {
    try {
        app_variants(['APP_CHECKPOINTER' => '1000', 'APP_LOCKING' => 'exclusive']);
    } catch (InvalidArgumentException $e) {
        $message = $e->getMessage();
        return str_contains($message, 'APP_CHECKPOINTER') && str_contains($message, 'APP_LOCKING=exclusive') && str_contains($message, 'second process') ? null : "the message is: $message";
    }
    return 'no exception';
});

check_case('APP_GROUP_COMMIT with APP_LOCKING=exclusive is allowed (one process commits)', function () {
    return app_variants(['APP_GROUP_COMMIT' => '1', 'APP_LOCKING' => 'exclusive'])['group_commit'] === true ? null : 'refused';
});

// Group commit through the app's functions.

check_case('unset, a write answers at once (an array) and the telemetry line has no group_commit', function () {
    $path = boot_copy([]);
    $answer = handler_handle('POST', '/posts/5/like', '', auth(8));
    app_telemetry_enable();
    $fields = app_telemetry_fields();
    $likes = committed($path, 'SELECT count(*) FROM likes WHERE user_id = 8 AND post_id = 5');
    return is_array($answer) && $answer[0] === 201 && $likes === [1] && !array_key_exists('group_commit', $fields) ? null : 'got ' . json_encode($answer) . ', fields ' . json_encode(array_keys($fields));
});

check_case('with group commit a like waits: a Closure, nothing committed until app_group_commit runs it, then the same 201 as without', function () {
    $path = boot_copy(['APP_GROUP_COMMIT' => '1']);
    $write = handler_handle('POST', '/posts/5/like', '', auth(8));
    if (!($write instanceof Closure)) {
        return 'the like did not wait: ' . json_encode($write);
    }
    $before = committed($path, 'SELECT count(*) FROM likes WHERE user_id = 8 AND post_id = 5');
    $responses = run_group([$write]);
    $after = committed($path, 'SELECT count(*) FROM likes WHERE user_id = 8 AND post_id = 5');
    $expected = [[201, '{"liked":true,"already_liked":false,"post_id":5}']];
    return $before === [0] && $after === [1] && $responses === $expected ? null : 'before ' . json_encode($before) . ', after ' . json_encode($after) . ', responses ' . json_encode($responses);
});

check_case('with group commit a repeated like answers 200 already_liked, and a new post answers 201 with its id and the same shape as without', function () {
    $answers = [];
    foreach ([[], ['APP_GROUP_COMMIT' => '1']] as $env) {
        $path = boot_copy($env);
        $out = [];
        foreach ([['/posts/5/like', ''], ['/posts/5/like', ''], ['/posts', '{"body":"  hello \"you\" é  "}']] as [$target, $body]) {
            $answer = handler_handle('POST', $target, $body, auth(8));
            $out[] = $answer instanceof Closure ? run_group([$answer])[0] : $answer;
        }
        // created_at is the database's clock: only its shape is compared.
        $out[2][1] = preg_replace('/"created_at":"[^"]+"/', '"created_at":"T"', $out[2][1]);
        $answers[] = $out;
        committed($path, 'SELECT 1');
    }
    $literal = [201, '{"post":{"id":31,"body":"hello \"you\" é","created_at":"T","author":"barbara","like_count":0}}'];
    return $answers[0] === $answers[1] && $answers[0][1][0] === 200 && $answers[0][2] === $literal
        ? null : 'unset ' . json_encode($answers[0]) . ', group ' . json_encode($answers[1]);
});

check_case('what does not write never waits: a bad token, a bad body, a bad id and a like on a missing post answer at once', function () {
    boot_copy(['APP_GROUP_COMMIT' => '1']);
    $cases = [['POST', '/posts/5/like', '', 'Bearer x', 401], ['POST', '/posts', '{}', auth(8), 400], ['POST', '/posts/abc/like', '', auth(8), 400],
              ['POST', '/posts/999/like', '', auth(8), 404], ['GET', '/feed', '', '', 200], ['GET', '/posts/5', '', '', 200]];
    foreach ($cases as [$method, $target, $body, $token, $status]) {
        $answer = handler_handle($method, $target, $body, $token);
        if (!is_array($answer) || $answer[0] !== $status) {
            return "$method $target: " . json_encode($answer instanceof Closure ? 'a Closure' : $answer) . ", expected $status";
        }
    }
    return null;
});

check_case('three writes in one commit: all three rows, one commit of three on the telemetry line', function () {
    $path = boot_copy(['APP_GROUP_COMMIT' => '1']);
    app_telemetry_enable();
    $writes = [handler_handle('POST', '/posts/5/like', '', auth(8)), handler_handle('POST', '/posts', '{"body":"one"}', auth(1)),
               handler_handle('POST', '/posts/6/like', '', auth(8))];
    $responses = run_group($writes);
    $statuses = array_column($responses, 0);
    $rows = committed($path, "SELECT (SELECT count(*) FROM likes WHERE user_id = 8 AND post_id IN (5, 6)) || ',' || (SELECT count(*) FROM posts WHERE body = 'one')");
    $line = app_telemetry_fields()['group_commit'] ?? null;
    $again = app_telemetry_fields()['group_commit'] ?? null;
    if ($statuses !== [201, 201, 201] || $rows !== ['2,1']) {
        return 'statuses ' . json_encode($statuses) . ', rows ' . json_encode($rows);
    }
    if ($line !== ['commits' => 1, 'batch_mean' => 3.0, 'batch_max' => 3] || $again !== ['commits' => 0, 'batch_mean' => 0.0, 'batch_max' => 0]) {
        return 'the line says ' . json_encode($line) . ' then ' . json_encode($again);
    }
    return null;
});

check_case('a write that fails inside the batch rolls back alone and answers 500; the writes around it commit', function () {
    $path = boot_copy(['APP_GROUP_COMMIT' => '1']);
    $writes = [handler_handle('POST', '/posts', '{"body":"before"}', auth(1)), handler_handle('POST', '/posts', '{"body":"boom"}', auth(1)),
               handler_handle('POST', '/posts/5/like', '', auth(8)), handler_handle('POST', '/posts', '{"body":"after"}', auth(2))];
    $responses = run_group($writes);
    $statuses = array_column($responses, 0);
    $bodies = committed($path, "SELECT body FROM posts WHERE id > 30 ORDER BY id");
    $likes = committed($path, 'SELECT count(*) FROM likes WHERE user_id = 8 AND post_id = 5');
    if ($statuses !== [201, 500, 201, 201] || $responses[1][1] !== '{"error":"internal server error"}') {
        return 'responses ' . json_encode($responses);
    }
    // The ids are 31 and 32: the failed insert took none (it rolled back to its savepoint).
    return $bodies === ['before', 'after'] && $likes === [1] ? null : 'posts ' . json_encode($bodies) . ', likes ' . json_encode($likes);
});

check_case('a write that changed rows and then failed leaves none of them (its savepoint rolls back), and the next write commits', function () {
    global $app_db;
    $path = boot_copy(['APP_GROUP_COMMIT' => '1']);
    $partial = static function () use ($app_db): array {
        $app_db['db']->exec("INSERT INTO posts (user_id, body) VALUES (1, 'half')");
        $app_db['db']->exec("INSERT INTO likes (user_id, post_id) VALUES (3, 1)");
        throw new RuntimeException('fails after two inserts');
    };
    $responses = run_group([$partial, handler_handle('POST', '/posts/5/like', '', auth(8))]);
    $rows = committed($path, "SELECT (SELECT count(*) FROM posts WHERE body = 'half') || (SELECT count(*) FROM likes WHERE user_id = 3 AND post_id = 1) || (SELECT count(*) FROM likes WHERE user_id = 8 AND post_id = 5)");
    return array_column($responses, 0) === [500, 201] && $rows === ['001'] ? null : 'responses ' . json_encode($responses) . ', rows ' . json_encode($rows);
});

check_case('a batch whose own transaction cannot start answers 500 to every write and commits nothing', function () {
    $path = boot_copy(['APP_GROUP_COMMIT' => '1']);
    $writes = [handler_handle('POST', '/posts/5/like', '', auth(8)), handler_handle('POST', '/posts', '{"body":"x"}', auth(1))];
    // Another connection holds the write lock (the app's busy_timeout is 5 s: the test shortens it on the app's own connection).
    global $app_db;
    $app_db['db']->exec('PRAGMA busy_timeout = 0');
    $other = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $other->exec('BEGIN IMMEDIATE');
    $responses = run_group($writes);
    $other->exec('ROLLBACK');
    $rows = committed($path, 'SELECT (SELECT count(*) FROM likes WHERE user_id = 8 AND post_id = 5) || (SELECT count(*) FROM posts WHERE body = \'x\')');
    return array_column($responses, 0) === [500, 500] && $rows === ['00'] ? null : 'responses ' . json_encode($responses) . ', rows ' . json_encode($rows);
});

// Group commit through a DiyServer in this process, a client for each connection.

/**
 * The $count responses client $client has read, turning the loop until they are all there (or 2 s have passed).
 *
 * @return list<array{int, string}> [status, body]
 */
function responses_of(DiyRig $rig, int $client, int $count): array
{
    $deadline = hrtime(true) + 2_000_000_000;
    while (hrtime(true) < $deadline) {
        $out = [];
        $rest = $rig->got[$client];
        while (preg_match('/\AHTTP\/1\.1 (\d{3}) [^\r]*\r\n(?:[^\r]+\r\n)*?Content-Length: (\d+)\r\n\r\n/', $rest, $m) && strlen($rest) >= strlen($m[0]) + (int) $m[2]) {
            $out[] = [(int) $m[1], substr($rest, strlen($m[0]), (int) $m[2])];
            $rest = substr($rest, strlen($m[0]) + (int) $m[2]);
        }
        if (count($out) >= $count) {
            return $out;
        }
        $rig->server->turn();
        $rig->collect();
    }
    return $out;
}

function post_request(string $target, string $token, string $body = ''): string
{
    return "POST $target HTTP/1.1\r\nAuthorization: $token\r\nContent-Length: " . strlen($body) . "\r\n\r\n$body";
}

function get_request(string $target): string
{
    return "GET $target HTTP/1.1\r\n\r\n";
}

check_case('two writes on two connections in one turn: one commit of two, both rows, both answered 201', function () {
    $path = boot_copy(['APP_GROUP_COMMIT' => '1']);
    app_telemetry_enable();
    $rig = new DiyRig(app_group_commit(...));
    $a = $rig->connect();
    $b = $rig->connect();
    $rig->send($a, post_request('/posts/5/like', auth(8)));
    $rig->send($b, post_request('/posts', auth(1), '{"body":"two at once"}'));
    $gotA = responses_of($rig, $a, 1);
    $gotB = responses_of($rig, $b, 1);
    $rig->close();
    $line = app_telemetry_fields()['group_commit'] ?? null;
    $rows = committed($path, "SELECT (SELECT count(*) FROM likes WHERE user_id = 8 AND post_id = 5) || (SELECT count(*) FROM posts WHERE body = 'two at once')");
    if (($gotA[0][0] ?? 0) !== 201 || ($gotB[0][0] ?? 0) !== 201 || $rows !== ['11']) {
        return 'a ' . json_encode($gotA) . ', b ' . json_encode($gotB) . ', rows ' . json_encode($rows);
    }
    return $line === ['commits' => 1, 'batch_mean' => 2.0, 'batch_max' => 2] ? null : 'the line says ' . json_encode($line);
});

check_case('a like then a feed pipelined on one connection: the like answers first and the post read after it shows the like', function () {
    boot_copy(['APP_GROUP_COMMIT' => '1']);
    $rig = new DiyRig(app_group_commit(...));
    $a = $rig->connect();
    $rig->send($a, post_request('/posts/5/like', auth(8)) . get_request('/posts/5'));
    $got = responses_of($rig, $a, 2);
    $rig->close();
    if (count($got) !== 2 || $got[0][0] !== 201 || !str_contains($got[0][1], '"liked":true') || $got[1][0] !== 200) {
        return 'got ' . json_encode($got);
    }
    // Post 5 has 5 likes in the source database: the sixth is the one just committed.
    return str_contains($got[1][1], '"like_count":6') ? null : 'the post read says ' . $got[1][1];
});

check_case('two likes pipelined on one connection: both answered, in order, with no stall', function () {
    $path = boot_copy(['APP_GROUP_COMMIT' => '1']);
    $rig = new DiyRig(app_group_commit(...));
    $a = $rig->connect();
    $rig->send($a, post_request('/posts/5/like', auth(8)) . post_request('/posts/6/like', auth(8)) . post_request('/posts/5/like', auth(8)));
    $got = responses_of($rig, $a, 3);
    $rig->close();
    $ids = array_map(static fn (array $r): string => json_decode($r[1], true)['post_id'] . ':' . $r[0], $got);
    $likes = committed($path, 'SELECT count(*) FROM likes WHERE user_id = 8 AND post_id IN (5, 6)');
    return $ids === ['5:201', '6:201', '5:200'] && $likes === [2] ? null : 'answers ' . json_encode($ids) . ', likes ' . json_encode($likes);
});

check_case('a write that fails in a batch of two connections: it alone answers 500, the other commits and answers 201', function () {
    $path = boot_copy(['APP_GROUP_COMMIT' => '1']);
    $rig = new DiyRig(app_group_commit(...));
    $a = $rig->connect();
    $b = $rig->connect();
    $rig->send($a, post_request('/posts', auth(1), '{"body":"boom"}'));
    $rig->send($b, post_request('/posts', auth(2), '{"body":"fine"}'));
    $gotA = responses_of($rig, $a, 1);
    $gotB = responses_of($rig, $b, 1);
    $rig->close();
    $bodies = committed($path, 'SELECT body FROM posts WHERE id > 30');
    return ($gotA[0][0] ?? 0) === 500 && ($gotB[0][0] ?? 0) === 201 && $bodies === ['fine'] ? null : 'a ' . json_encode($gotA) . ', b ' . json_encode($gotB) . ', posts ' . json_encode($bodies);
});

// The server as a process.

/** Starts lab/app/server.php on a copy of the source database with the switches in $env. Returns [process, port, pipes, boot lines, database path]. */
function start_server(array $env): array
{
    global $dir;
    static $n = 0;
    $port = 18390 + $n;
    $path = $dir . '/server-' . ++$n . '.db';
    copy("$dir/source.db", $path);
    $process = proc_open([PHP_BINARY, '-d', 'extension=sockets', '-d', 'extension=event', __DIR__ . '/../app/server.php'], [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes,
        null, $env + ['SQLITE_PATH' => $path, 'JWT_SECRET' => SECRET, 'HOST' => '127.0.0.1', 'PORT' => (string) $port, 'PATH' => getenv('PATH')]);
    stream_set_timeout($pipes[1], 20);
    $lines = [];
    while (($line = fgets($pipes[1])) !== false) {
        $lines[] = rtrim($line);
        if (str_starts_with($line, 'socket:')) {
            break;
        }
    }
    return [$process, $port, $pipes, $lines, $path];
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

function stop_server($process): void
{
    proc_terminate($process, 9);
    proc_close($process);
}

/** The frames in the WAL (mxFrame) and the frames copied back (nBackfill), from the first 100 bytes of the -shm file; null when there is no such file. */
function wal_frames_and_backfill(string $path): ?array
{
    $head = @file_get_contents($path . '-shm', false, null, 0, 100);
    if ($head === false || strlen($head) < 100) {
        return null;
    }
    return [unpack('L', $head, 16)[1], unpack('L', $head, 96)[1]];
}

foreach (['group commit' => ['APP_GROUP_COMMIT' => '1'], 'group commit and the checkpointer' => ['APP_GROUP_COMMIT' => '1', 'APP_CHECKPOINTER' => '100']] as $label => $env) {
    check_case("$label: a like answered 201 survives a kill with SIGKILL, and the process names its switches at boot", function () use ($env) {
        [$process, $port, $pipes, $lines, $path] = start_server($env);
        if (!in_array('listening on 127.0.0.1:' . $port, $lines, true)) {
            stop_server($process);
            return 'the server did not listen: ' . implode(' | ', $lines) . ' ' . stream_get_contents($pipes[2]);
        }
        $answer = http($port, post_request('/posts/5/like', auth(8)));
        stop_server($process);
        $likes = committed($path, 'SELECT count(*) FROM likes WHERE user_id = 8 AND post_id = 5');
        $boot = implode(' | ', $lines);
        $named = 'group_commit=on checkpointer=' . ($env['APP_CHECKPOINTER'] ?? 'off');
        if ($answer[0] !== 201 || $likes !== [1]) {
            return 'answer ' . json_encode($answer) . ', likes ' . json_encode($likes);
        }
        return str_contains($boot, $named) ? null : "the boot lines do not say '$named': $boot";
    });
}

check_case('the telemetry line of the server process has the commits and the batch sizes with group commit, and none without it', function () {
    $seen = [];
    foreach (['group commit' => ['APP_GROUP_COMMIT' => '1', 'APP_TELEMETRY' => '1'], 'unset' => ['APP_TELEMETRY' => '1']] as $label => $env) {
        [$process, $port, $pipes, $lines, $path] = start_server($env);
        http($port, post_request('/posts/5/like', auth(8)));
        http($port, post_request('/posts/6/like', auth(8)));
        $found = null;
        $lineNumber = 0;
        while ($lineNumber++ < 12 && ($line = fgets($pipes[1])) !== false) {
            $telemetry = str_starts_with($line, 'telemetry ') ? json_decode(substr($line, 10), true) : null;
            if ($telemetry !== null && (($telemetry['group_commit']['commits'] ?? 0) > 0 || $label === 'unset' && ($telemetry['requests']['POST /posts/:id/like'] ?? 0) > 0)) {
                $found = $telemetry;
                break;
            }
        }
        stop_server($process);
        $seen[$label] = $found;
    }
    $group = $seen['group commit']['group_commit'] ?? null;
    if ($group === null || $group['commits'] < 1 || $group['commits'] > 2 || $group['batch_max'] < 1 || $group['batch_mean'] < 1) {
        return 'with group commit: ' . json_encode($seen['group commit']);
    }
    return $seen['unset'] !== null && !array_key_exists('group_commit', $seen['unset']) ? null : 'unset: ' . json_encode($seen['unset']);
});

check_case('APP_CHECKPOINTER with APP_LOCKING=exclusive: the server refuses to start and says why', function () {
    [$process, , $pipes, $lines] = start_server(['APP_CHECKPOINTER' => '100', 'APP_LOCKING' => 'exclusive']);
    $status = proc_get_status($process);
    for ($i = 0; $i < 20 && $status['running']; $i++) {
        usleep(100000);
        $status = proc_get_status($process);
    }
    $running = $status['running'];
    // Why the kill first: a server that did start never closes its end, and reading to the end would wait for it.
    $running && proc_terminate($process, 9);
    $err = stream_get_contents($pipes[2]);
    proc_close($process);
    return !$running && $status['exitcode'] === 1 && str_contains($err, 'APP_CHECKPOINTER') && str_contains($err, 'APP_LOCKING=exclusive') ? null
        : 'running ' . var_export($running, true) . ', exit ' . $status['exitcode'] . ", stderr: $err";
});

check_case('with the checkpointer the server connection does not checkpoint by itself (wal_autocheckpoint 0); without it, SQLite\'s 1000 pages', function () {
    global $app_db;
    $got = [];
    foreach ([['APP_CHECKPOINTER' => '1000'], []] as $env) {
        boot_copy($env);
        $got[] = (int) $app_db['db']->query('PRAGMA wal_autocheckpoint')->fetchColumn();
    }
    return $got === [0, 1000] ? null : 'got ' . json_encode($got);
});

check_case('the checkpointer process copies the WAL back into the database within a few intervals, and ends with the server (SIGKILL)', function () {
    [$process, $port, $pipes, $lines, $path] = start_server(['APP_CHECKPOINTER' => '100']);
    $boot = implode(' | ', $lines);
    if (!preg_match('/checkpointer: 100 ms \(process (\d+)\)/', $boot, $m)) {
        stop_server($process);
        return "the boot lines do not name the checkpointer's process: $boot";
    }
    $pid = (int) $m[1];
    foreach ([[8, 5], [8, 6], [8, 7]] as [$user, $post]) {
        http($port, post_request("/posts/$post/like", auth($user)));
    }
    $frames = null;
    for ($i = 0; $i < 30; $i++) {
        usleep(100000);
        $frames = wal_frames_and_backfill($path);
        if ($frames !== null && $frames[0] > 0 && $frames[1] === $frames[0]) {
            break;
        }
    }
    $alive = static function (int $pid): bool {
        $stat = @file_get_contents("/proc/$pid/stat");
        // A process the container's init does not reap stays a zombie: it is gone all the same.
        return $stat !== false && !str_starts_with(substr($stat, (int) strrpos($stat, ')') + 2), 'Z');
    };
    $aliveWhileServing = $alive($pid);
    stop_server($process);
    for ($i = 0; $i < 30 && $alive($pid); $i++) {
        usleep(100000);
    }
    if ($frames === null || $frames[0] === 0 || $frames[1] !== $frames[0]) {
        return 'the WAL frames and the frames copied back: ' . json_encode($frames);
    }
    return $aliveWhileServing && !$alive($pid) ? null : 'the checkpointer ' . ($aliveWhileServing ? 'was running' : 'was not running') . ' while serving and ' . ($alive($pid) ? 'still runs' : 'ended') . ' after the kill';
});

check_case('without the checkpointer a few writes are not copied back (the 1000 pages of SQLite\'s own checkpoint are not reached)', function () {
    [$process, $port, , , $path] = start_server([]);
    foreach ([[8, 5], [8, 6], [8, 7]] as [$user, $post]) {
        http($port, post_request("/posts/$post/like", auth($user)));
    }
    usleep(500000);
    $frames = wal_frames_and_backfill($path);
    stop_server($process);
    return $frames !== null && $frames[0] > 0 && $frames[1] === 0 ? null : 'frames and copied back: ' . json_encode($frames);
});

exit($failed ? 1 : 0);
