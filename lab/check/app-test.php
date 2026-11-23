<?php
// The challenge app's behavior that the challenge's own test suite does not reach, through its public entry point (handler_handle,
// what the DIY connection calls) on a small database made here: the JWT rules (a token without `exp`, a non-HS256 header, junk
// after the signature), the body rules (non-objects, characters and not bytes), auth before body and before id, one like per user,
// the feed's order and size, a write already committed when the response is built. Run: bash lab/run.sh 8.5 php /lab/check/app-test.php

require __DIR__ . '/../app/app.php';

const SECRET = 'a-secret-for-this-test';

// The challenge's schema (reference/twelve-dollar-server-challenge/schema.sql), without its comments.
$path = sys_get_temp_dir() . '/app-test-' . getmypid() . '.db';
$db = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$db->exec("
  CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));
  CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500),
                      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));
  CREATE TABLE likes (user_id INTEGER NOT NULL REFERENCES users(id), post_id INTEGER NOT NULL REFERENCES posts(id),
                      created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), PRIMARY KEY (user_id, post_id));
  CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);
  INSERT INTO users (id, username) VALUES (1, 'ada'), (2, 'grace');
  INSERT INTO posts (id, user_id, body, created_at) VALUES (1, 1, 'first', '2025-01-01T00:00:00.000Z'), (2, 1, 'second', '2025-01-01T00:00:00.000Z'),
                                                         (3, 2, 'older', '2024-12-31T00:00:00.000Z');
");
unset($db);
register_shutdown_function(fn () => array_map('unlink', glob($path . '*')));
app_boot($path, SECRET);

function b64url(string $bytes): string
{
    return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
}

/** A token signed with $secret: the header and the payload as given (an array is JSON-encoded, a string goes in as is). */
function token(array|string $payload, array|string $header = ['alg' => 'HS256', 'typ' => 'JWT'], string $secret = SECRET): string
{
    $h = b64url(is_string($header) ? $header : json_encode($header));
    $p = b64url(is_string($payload) ? $payload : json_encode($payload));
    return "$h.$p." . b64url(hash_hmac('sha256', "$h.$p", $secret, true));
}

function claims(array $override = []): array
{
    return array_merge(['sub' => '1', 'username' => 'ada', 'iat' => time(), 'exp' => time() + 3600], $override);
}

/** @return array{int, string} */
function call(string $method, string $path, string $body = '', ?string $token = null): array
{
    return handler_handle($method, $path, $body, $token === null ? '' : "Bearer $token");
}

/** Null when the response is the error table's: $status and {"error":"<message>"}. */
function expect_error(array $got, int $status, string $message): ?string
{
    $body = '{"error":"' . $message . '"}';
    return $got === [$status, $body] ? null : "got $got[0] $got[1], expected $status $body";
}

/** Null when the status is $status; the decoded body is passed to $then (null, or the reason it is wrong) when given. */
function expect_status(array $got, int $status, ?callable $then = null): ?string
{
    if ($got[0] !== $status) {
        return "got $got[0] $got[1], expected status $status";
    }
    return $then === null ? null : $then(json_decode($got[1], true), $got[1]);
}

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

$good = '{"body":"hello"}';

check_case('a good token creates a post, answered with its author and 0 likes', fn () => expect_status(
    call('POST', '/posts', '{"body":"  hello  "}', token(claims())), 201,
    fn ($json, $raw) => preg_match('/^\{"post":\{"id":4,"body":"hello","created_at":"[^"]+","author":"ada","like_count":0\}\}$/', $raw) ? null : "the body is $raw"));

check_case('the post is committed when the response is built (a second connection sees it)', function () use ($path) {
    $other = new PDO('sqlite:' . $path);
    return $other->query("SELECT body FROM posts WHERE id = 4")->fetchColumn() === 'hello' ? null : 'a second connection does not see post 4';
});

check_case('no Authorization value: missing bearer token', fn () => expect_error(handler_handle('POST', '/posts', $good, ''), 401, 'missing bearer token'));
foreach (['Basic abc', 'bearer abc', 'Bearer', 'Token abc'] as $value) {
    check_case("Authorization '$value': missing bearer token", fn () => expect_error(handler_handle('POST', '/posts', $good, $value), 401, 'missing bearer token'));
}

$invalid = [
    'a token without exp' => token(['sub' => '1', 'username' => 'ada', 'iat' => time()]),
    'an exp that is a string' => token(claims(['exp' => (string) (time() + 3600)])),
    'an exp that is now' => token(claims(['exp' => time()])),
    'an exp in the past' => token(claims(['exp' => time() - 1])),
    'a header with alg HS512' => token(claims(), ['alg' => 'HS512', 'typ' => 'JWT']),
    'a header with alg none' => token(claims(), ['alg' => 'none']),
    'a header without alg' => token(claims(), ['typ' => 'JWT']),
    'a header that is not JSON' => token(claims(), 'not json'),
    'a payload that is not JSON' => token('not json'),
    'a payload that is a list' => token('[1,2]'),
    'a token signed with another secret' => token(claims(), ['alg' => 'HS256', 'typ' => 'JWT'], 'another-secret'),
    'two parts' => implode('.', array_slice(explode('.', token(claims())), 0, 2)),
    'four parts' => token(claims()) . '.x',
    'junk after the signature' => token(claims()) . '!',
    'an empty signature' => implode('.', array_slice(explode('.', token(claims())), 0, 2)) . '.',
    'nothing after Bearer' => '',
];
foreach ($invalid as $name => $bad) {
    check_case("401 invalid or expired token: $name", fn () => expect_error(call('POST', '/posts', $good, $bad), 401, 'invalid or expired token'));
}

$payloads = [
    'a sub that is an integer' => claims(['sub' => 1]),
    'a sub of 0' => claims(['sub' => '0']),
    'a sub of -1' => claims(['sub' => '-1']),
    'a sub of 1.5' => claims(['sub' => '1.5']),
    'a sub that is not there' => ['username' => 'ada', 'exp' => time() + 3600],
    'a username that is an integer' => claims(['username' => 7]),
    'a username that is not there' => ['sub' => '1', 'exp' => time() + 3600],
];
foreach ($payloads as $name => $payload) {
    check_case("401 invalid token payload: $name", fn () => expect_error(call('POST', '/posts', $good, token($payload)), 401, 'invalid token payload'));
}

check_case('a token is checked on every request: a good one, a bad one, the good one again', function () use ($good) {
    $token = token(claims());
    return expect_status(call('POST', '/posts', $good, $token), 201)
        ?? expect_error(call('POST', '/posts', $good, $token . 'x'), 401, 'invalid or expired token')
        ?? expect_status(call('POST', '/posts', $good, $token), 201);
});

check_case('auth before body: a bad body without a token is a 401', fn () => expect_error(call('POST', '/posts', '{bad'), 401, 'missing bearer token'));
check_case('auth before id: a bad id without a token is a 401, with one a 400', fn () => expect_error(call('POST', '/posts/abc/like'), 401, 'missing bearer token')
    ?? expect_error(call('POST', '/posts/abc/like', '', token(claims())), 400, 'invalid post id'));

$bodies = [
    ['', 400, 'malformed JSON body'],
    ['{bad json', 400, 'malformed JSON body'],
    ['{"body":"x"} trailing', 400, 'malformed JSON body'],
    ['[]', 400, 'body is required'],
    ['null', 400, 'body is required'],
    ['"hello"', 400, 'body is required'],
    ['123', 400, 'body is required'],
    ['["hello"]', 400, 'body is required'],
    ['{"body":null}', 400, 'body is required'],
    ['{"body":["x"]}', 400, 'body is required'],
    ['{"body":" \t\n "}', 400, 'body is required'],
    ['{"text":"x"}', 400, 'body is required'],
    ['{"body":"' . str_repeat('é', 501) . '"}', 400, 'body must be at most 500 characters'],
    ['{"body":"  ' . str_repeat('a', 501) . '  "}', 400, 'body must be at most 500 characters'],
];
foreach ($bodies as [$raw, $status, $message]) {
    check_case('POST /posts with ' . json_encode(strlen($raw) > 40 ? substr($raw, 0, 40) . '...' : $raw, JSON_UNESCAPED_UNICODE) . ' is a ' . $status . ' ' . $message,
        fn () => expect_error(call('POST', '/posts', $raw, token(claims())), $status, $message));
}

check_case('500 characters of 2 bytes each are accepted (the limit counts characters)', fn () => expect_status(
    call('POST', '/posts', '{"body":"' . str_repeat('é', 500) . '"}', token(claims())), 201));
check_case('500 characters after trimming are accepted', fn () => expect_status(
    call('POST', '/posts', '{"body":"  ' . str_repeat('a', 500) . '  "}', token(claims())), 201));
check_case('a body of / and unicode comes back as it was sent', fn () => expect_status(
    call('POST', '/posts', '{"body":"a/b caf\u00e9"}', token(claims())), 201, fn ($json) => $json['post']['body'] === 'a/b café' ? null : 'the body is ' . $json['post']['body']));

check_case('one like per user and post: 201, then 200, and another user adds its own', function () {
    $ada = token(claims());
    $grace = token(claims(['sub' => '2', 'username' => 'grace']));
    $first = call('POST', '/posts/3/like', '', $ada);
    $again = call('POST', '/posts/3/like', '', $ada);
    $other = call('POST', '/posts/3/like', '', $grace);
    return expect_status($first, 201, fn ($j) => $j === ['liked' => true, 'already_liked' => false, 'post_id' => 3] ? null : "first like: $first[1]")
        ?? expect_status($again, 200, fn ($j) => $j === ['liked' => true, 'already_liked' => true, 'post_id' => 3] ? null : "repeat: $again[1]")
        ?? expect_status($other, 201)
        ?? expect_status(call('GET', '/posts/3'), 200, fn ($j) => $j['post']['like_count'] === 2 ? null : 'like_count is ' . json_encode($j['post']['like_count']));
});
check_case('a like on a post that does not exist is a 404, and leaves no row', function () use ($path) {
    $got = call('POST', '/posts/9999/like', '', token(claims()));
    // Why: foreign keys are off, so a like inserted before the post is looked up would stay in the table.
    $rows = (int) (new PDO('sqlite:' . $path))->query('SELECT COUNT(*) FROM likes WHERE post_id = 9999')->fetchColumn();
    return expect_error($got, 404, 'post not found') ?? ($rows === 0 ? null : "$rows like rows were left for post 9999");
});

check_case('ids: 0, -1, abc, 1.5, empty and a huge one', function () {
    foreach (['0' => 400, '-1' => 400, 'abc' => 400, '1.5' => 400, '' => 400, '99999999999999999999' => 404] as $id => $status) {
        $got = call('GET', "/posts/$id");
        if ($got[0] !== $status) {
            return "GET /posts/$id: got $got[0] $got[1], expected $status";
        }
    }
    return null;
});

check_case('routes: unknown paths and a trailing slash are 404, a query string is cut', function () {
    foreach ([['GET', '/'], ['GET', '/nope'], ['GET', '/posts/1/'], ['GET', '/posts/1/like'], ['POST', '/feed'], ['POST', '/posts/1/like/'], ['DELETE', '/posts/1']] as [$method, $path]) {
        $got = call($method, $path, '', token(claims()));
        if ($got !== [404, '{"error":"not found"}']) {
            return "$method $path: got $got[0] $got[1]";
        }
    }
    return expect_status(call('GET', '/posts/1?x=1'), 200);
});

check_case('health: ok with whole seconds of uptime', fn () => expect_status(call('GET', '/health'), 200,
    fn ($json) => is_int($json['uptime_s']) && $json['status'] === 'ok' && $json['db'] === 'ok' && array_keys($json) === ['status', 'db', 'uptime_s'] ? null : 'the body is ' . json_encode($json)));

// 30 posts share the newest time (the far future, so the posts the cases above made are older): ties go to the highest id.
check_case('feed: 20 newest, ties by id, key order of a post', function () use ($path) {
    $db = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    for ($i = 0; $i < 30; $i++) {
        $db->exec("INSERT INTO posts (user_id, body, created_at) VALUES (2, 'bulk $i', '2099-01-01T00:00:00.000Z')");
    }
    $bulk = $db->query("SELECT id FROM posts WHERE body LIKE 'bulk %' ORDER BY id DESC LIMIT 20")->fetchAll(PDO::FETCH_COLUMN);
    unset($db);
    return expect_status(call('GET', '/feed'), 200, function ($json, $raw) use ($bulk) {
        if (array_column($json['posts'], 'id') !== $bulk) {
            return 'the ids are ' . implode(',', array_column($json['posts'], 'id')) . ', expected ' . implode(',', $bulk);
        }
        return array_keys($json['posts'][0]) === ['id', 'body', 'created_at', 'author', 'like_count'] && $json['posts'][0]['author'] === 'grace' && is_int($json['posts'][0]['like_count'])
            ? null : 'a post is ' . json_encode($json['posts'][0]);
    });
});

// Telemetry (APP_TELEMETRY=1): requests are counted per endpoint, the count starts over each time the telemetry line reads it, and nothing is
// counted before it is switched on.
check_case('telemetry: off by default, requests are not counted', function () {
    global $app_requests;
    call('GET', '/feed');
    return $app_requests === null && app_telemetry_fields()['requests'] == (object) [] ? null : 'something was counted: ' . json_encode($app_requests);
});
check_case('telemetry: on, every endpoint that answers is counted under its own name, a 404 under none', function () {
    app_telemetry_enable();
    call('GET', '/feed');
    call('GET', '/feed');
    call('GET', '/posts/1');
    call('GET', '/health');
    call('POST', '/posts', '{"body":"counted"}', token(claims()));
    call('POST', '/posts/1/like', '', token(claims()));
    call('GET', '/nowhere');
    $got = (array) app_telemetry_fields()['requests'];
    $want = ['GET /feed' => 2, 'GET /posts/:id' => 1, 'GET /health' => 1, 'POST /posts' => 1, 'POST /posts/:id/like' => 1];
    return $got === $want ? null : 'counted ' . json_encode($got) . ', expected ' . json_encode($want);
});
check_case('telemetry: reading the counts starts them over, and the WAL size is in the same fields', function () {
    global $path;
    $first = app_telemetry_fields();
    call('GET', '/feed');
    $second = app_telemetry_fields();
    clearstatcache(true, $path . '-wal');
    return (array) $first['requests'] === [] && (array) $second['requests'] === ['GET /feed' => 1]
        && $second['wal_bytes'] === (@filesize($path . '-wal') ?: 0) ? null : 'got ' . json_encode([$first, $second]);
});

// Last: it breaks the health statement. A query that fails (here, a table dropped after the statement was prepared) is the 503.
check_case('health: a failing SELECT is a 503 with the error', function () use ($path) {
    global $app_db;
    $app_db['db']->exec('CREATE TABLE gone (x)');
    $app_db['health'] = $app_db['db']->prepare('SELECT x FROM gone');
    $app_db['db']->exec('DROP TABLE gone');
    return expect_status(call('GET', '/health'), 503, function ($json) {
        return array_keys($json) === ['status', 'db', 'error'] && $json['status'] === 'degraded' && $json['db'] === 'unreachable' && is_string($json['error']) && $json['error'] !== ''
            ? null : 'the body is ' . json_encode($json);
    });
});

exit($failed ? 1 : 0);
