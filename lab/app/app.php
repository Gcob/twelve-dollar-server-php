<?php
// The challenge's five endpoints (reference/twelve-dollar-server-challenge/SPEC.md), written as plainly as possible: the simplest
// variant of every step of a request, one function each, so that a profiler can tell the steps apart.
//
//   parse (DiyConnection)  ->  route (handler_handle)  ->  jwt_verify  ->  id_validate / body_validate  ->  a query function
//   ->  a json function  ->  response  ->  write (DiyConnection)
//
// handler_handle() is what the DIY connection calls: method, request target, body and the Authorization header value in; the HTTP
// status and the JSON body out. Nothing read for one request answers another: no result, response or token check is kept between
// requests (the statements are prepared once, and that is all that lives on).

const APP_JSON_FLAGS = JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE;
const APP_BODY_MAX_CHARS = 500;

// One SELECT for a post and for the feed: the spec's reference query, plus the clause each one needs.
const APP_POST_SELECT = 'SELECT p.id, p.body, p.created_at, u.username AS author,
                                (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
                           FROM posts p JOIN users u ON u.id = p.user_id';

// The variants of S6, each a switch read once at boot (app_variants): unset, the statements and the bytes are the reference's.
//   APP_FEED_SQL  reference  the like count of each post is a correlated subquery
//                 join       the 20 newest posts first (a subquery with the limit), then a LEFT JOIN on likes with GROUP BY
//                 two-step   the 20 posts with their authors, then one statement counting the likes of exactly those 20 ids,
//                            merged here (both statements are this request's own)
//   APP_FETCH     assoc | num: the rows as arrays keyed by column name, or by position (the JSON is then built from positions)
//                 assoc-loop | num-loop: the same, with fetch() in a loop instead of fetchAll()
//   APP_PRAGMAS   a preset of the page cache and the memory map sizes (the other pragmas never change)
// The variant of S8:
//   APP_LOCKING   normal | exclusive: with exclusive the connection keeps its locks and, set before the first WAL access, never makes the
//                 WAL's shared-memory file: the lock calls (fcntl) of every read and write transaction go. Only this process can open the
//                 database while the server runs (a second process, a checkpointer or an `sqlite3` shell, gets "database is locked").
//                 The locks go when the process ends, killed or not.
// The variants of S9 (the loop's own, see lab/servers/diy-server.php):
//   APP_GROUP_COMMIT  1: a write's request queues its statement instead of running it, and the loop commits the writes of one turn together:
//                     one BEGIN IMMEDIATE, each write in its own savepoint (a write that fails rolls back alone and answers 500), one COMMIT,
//                     and only then the responses go out. 0 or unset: every write commits before its own response, as always.
//   APP_CHECKPOINTER  <ms>: the server connection never checkpoints (wal_autocheckpoint = 0) and a second process, started at boot with its own
//                     connection, runs PRAGMA wal_checkpoint(PASSIVE) every <ms> milliseconds (lab/app/checkpointer.php). It ends with the server.
const APP_FEED_SQL_VARIANTS = ['reference', 'join', 'two-step'];
const APP_FETCH_VARIANTS = ['assoc', 'num', 'assoc-loop', 'num-loop'];
const APP_LOCKING_VARIANTS = ['normal', 'exclusive'];
// 64 MiB of cache and a 256 MiB map (the seed is 250 MB) are today's. Why each preset:
//   mmap-off    reads go through pread and the 64 MiB cache: says what the map is worth
//   cache-256m  the whole seed fits in the page cache, the map is off: the cache against the map
//   cache-8m    a cache smaller than the working set of the newest posts and users, the map on: how much the cache matters when the map does the reading
const APP_PRAGMA_PRESETS = [
    'mmap-off' => ['cache_size' => -65536, 'mmap_size' => 0],
    'cache-256m' => ['cache_size' => -262144, 'mmap_size' => 0],
    'cache-8m' => ['cache_size' => -8192, 'mmap_size' => 268435456],
];
const APP_PRAGMA_DEFAULT = ['cache_size' => -65536, 'mmap_size' => 268435456];

/** @var array{resource, array<int, resource>}|null the checkpointer process and the pipe it reads: the pipe closes with this process */
$app_checkpointer = null;
/** @var array{begin: PDOStatement, savepoint: PDOStatement, release: PDOStatement, rollback_to: PDOStatement, commit: PDOStatement}|null group commit's statements; null (the default) when writes commit one by one */
$app_group = null;
/** @var array{commits: int, writes: int, max: int} the commits made since the last telemetry line, and the writes in them */
$app_group_stats = ['commits' => 0, 'writes' => 0, 'max' => 0];
/** @var array{db: PDO, feed: PDOStatement, feed_likes: ?PDOStatement, post: PDOStatement, post_insert: PDOStatement, post_exists: PDOStatement, like_insert: PDOStatement, health: PDOStatement}|null */
$app_db = null;
$app_feed_two_step = false;
$app_fetch_num = false;
$app_fetch_loop = false;
$app_secret = '';
$app_started_at = 0;
$app_path = '';
/** @var array<string, int>|null requests per endpoint since the last telemetry line; null (the default) counts nothing */
$app_requests = null;

/**
 * The S6, S8 and S9 switches from the environment (pass getenv()): unset or empty is the reference's. A value that is not one of the names is refused.
 * Group commit is a bool and the checkpointer's interval is in milliseconds (0: none).
 *
 * @param array<string, mixed> $env
 * @return array{feed_sql: string, fetch: string, pragmas: string, locking: string, group_commit: bool, checkpointer: int}
 */
function app_variants(array $env): array
{
    $pick = static function (string $name, string $default, array $allowed) use ($env): string {
        $value = $env[$name] ?? '';
        if ($value === '') {
            return $default;
        }
        if (!is_string($value) || !in_array($value, $allowed, true)) {
            throw new InvalidArgumentException("$name must be one of " . implode(', ', $allowed) . ', got ' . json_encode($value));
        }
        return $value;
    };
    $checkpointer = $env['APP_CHECKPOINTER'] ?? '';
    if ($checkpointer !== '' && (!is_string($checkpointer) || !ctype_digit($checkpointer) || (int) $checkpointer < 1 || strlen($checkpointer) > 9)) {
        throw new InvalidArgumentException('APP_CHECKPOINTER must be a whole number of milliseconds (1 or more), got ' . json_encode($checkpointer));
    }
    $variants = [
        'feed_sql' => $pick('APP_FEED_SQL', 'reference', APP_FEED_SQL_VARIANTS),
        'fetch' => $pick('APP_FETCH', 'assoc', APP_FETCH_VARIANTS),
        'pragmas' => $pick('APP_PRAGMAS', 'default', ['default', ...array_keys(APP_PRAGMA_PRESETS)]),
        'locking' => $pick('APP_LOCKING', 'normal', APP_LOCKING_VARIANTS),
        'group_commit' => $pick('APP_GROUP_COMMIT', '0', ['0', '1']) === '1',
        'checkpointer' => (int) $checkpointer,
    ];
    if ($variants['checkpointer'] > 0 && $variants['locking'] === 'exclusive') {
        throw new InvalidArgumentException('APP_CHECKPOINTER cannot be set with APP_LOCKING=exclusive: the checkpointer is a second process, and with exclusive locking no second process can open the database');
    }
    return $variants;
}

/** The SQL of the feed for a feed variant (the first statement, for two-step). */
function app_feed_sql(string $feedSql): string
{
    $order = ' ORDER BY p.created_at DESC, p.id DESC LIMIT 20';
    return match ($feedSql) {
        'reference' => APP_POST_SELECT . $order,
        // Why the subquery: SQLite cannot fold a LIMIT into a join, so the 20 posts are picked first and only their likes are counted.
        // Why GROUP BY created_at, id: with the order of the ORDER BY it needs one temporary b-tree, not two (a GROUP BY p.id alone adds one for the order).
        'join' => 'SELECT p.id, p.body, p.created_at, u.username AS author, count(l.post_id) AS like_count
                     FROM (SELECT id, user_id, body, created_at FROM posts ORDER BY created_at DESC, id DESC LIMIT 20) p
                     JOIN users u ON u.id = p.user_id
                     LEFT JOIN likes l ON l.post_id = p.id
                    GROUP BY p.created_at, p.id
                    ORDER BY p.created_at DESC, p.id DESC',
        'two-step' => 'SELECT p.id, p.body, p.created_at, u.username AS author FROM posts p JOIN users u ON u.id = p.user_id' . $order,
    };
}

/** The second statement of the two-step feed: the like counts of exactly the 20 ids it is given (a shorter feed repeats an id, which IN ignores). */
function app_feed_likes_sql(): string
{
    return 'SELECT post_id, count(*) FROM likes WHERE post_id IN (' . implode(', ', array_fill(0, 20, '?')) . ') GROUP BY post_id';
}

/** The SQL of one post by id for a feed variant: the join variant has its own; the others read it as the reference does. */
function app_post_sql(string $feedSql): string
{
    if ($feedSql === 'join') {
        return 'SELECT p.id, p.body, p.created_at, u.username AS author, count(l.post_id) AS like_count
                  FROM posts p JOIN users u ON u.id = p.user_id LEFT JOIN likes l ON l.post_id = p.id
                 WHERE p.id = ? GROUP BY p.id';
    }
    return APP_POST_SELECT . ' WHERE p.id = ?';
}

/** Opens the database at $path (it must exist: SQLite would create an empty one) and prepares every statement once. */
function app_boot(string $path, string $secret, ?array $variants = null): void
{
    global $app_db, $app_secret, $app_started_at, $app_path, $app_feed_two_step, $app_fetch_num, $app_fetch_loop, $app_group, $app_group_stats;
    if (!is_file($path)) {
        throw new RuntimeException("the database file does not exist: $path");
    }
    $variants ??= app_variants(getenv());
    $pragmas = APP_PRAGMA_PRESETS[$variants['pragmas']] ?? APP_PRAGMA_DEFAULT;
    $db = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]);
    if ($variants['locking'] === 'exclusive') {
        // Why first: set before the connection's first WAL access, SQLite keeps the WAL's index in heap memory and never makes the
        // shared-memory file (every lock call of a read or a write goes with it).
        $db->exec('PRAGMA locking_mode = EXCLUSIVE');
    }
    $db->exec('PRAGMA journal_mode = WAL');
    $db->exec('PRAGMA synchronous = NORMAL');
    $db->exec('PRAGMA busy_timeout = 5000');
    $db->exec('PRAGMA cache_size = ' . $pragmas['cache_size']);    // KiB when negative: -65536 is 64 MiB
    $db->exec('PRAGMA mmap_size = ' . $pragmas['mmap_size']);      // bytes: 268435456 is 256 MiB
    $db->exec('PRAGMA temp_store = MEMORY');
    if ($variants['checkpointer'] > 0) {
        // Why: the second process does the checkpoints, so none of them lands in a request.
        $db->exec('PRAGMA wal_autocheckpoint = 0');
    }
    $app_feed_two_step = $variants['feed_sql'] === 'two-step';
    $app_fetch_num = str_starts_with($variants['fetch'], 'num');
    $app_fetch_loop = str_ends_with($variants['fetch'], '-loop');
    $app_db = [
        'db' => $db,
        'feed' => $db->prepare(app_feed_sql($variants['feed_sql'])),
        'feed_likes' => $app_feed_two_step ? $db->prepare(app_feed_likes_sql()) : null,
        'post' => $db->prepare(app_post_sql($variants['feed_sql'])),
        'post_insert' => $db->prepare('INSERT INTO posts (user_id, body) VALUES (?, ?) RETURNING id, created_at'),
        'post_exists' => $db->prepare('SELECT 1 FROM posts WHERE id = ?'),
        'like_insert' => $db->prepare('INSERT INTO likes (user_id, post_id) VALUES (?, ?) ON CONFLICT (user_id, post_id) DO NOTHING'),
        'health' => $db->prepare('SELECT 1'),
    ];
    $app_group = null;
    $app_group_stats = ['commits' => 0, 'writes' => 0, 'max' => 0];
    if ($variants['group_commit']) {
        $app_group = [
            'begin' => $db->prepare('BEGIN IMMEDIATE'),
            'savepoint' => $db->prepare('SAVEPOINT write'),
            'release' => $db->prepare('RELEASE write'),
            'rollback_to' => $db->prepare('ROLLBACK TO write'),
            'commit' => $db->prepare('COMMIT'),
        ];
    }
    $app_secret = $secret;
    $app_started_at = time();
    $app_path = $path;
}

/** Starts counting requests per endpoint (APP_TELEMETRY=1, see lab/servers/diy-telemetry.php). */
function app_telemetry_enable(): void
{
    global $app_requests;
    $app_requests = [];
}

/**
 * The app's part of a telemetry line: the requests of the second per endpoint (and the count starts over) and the WAL's size; with group
 * commit also the commits of the second, the mean and the largest number of writes in one (their count starts over too).
 */
function app_telemetry_fields(): array
{
    global $app_requests, $app_path, $app_group, $app_group_stats;
    $requests = $app_requests ?? [];
    $app_requests = [];
    clearstatcache(true, $app_path . '-wal');
    $fields = ['requests' => (object) $requests, 'wal_bytes' => @filesize($app_path . '-wal') ?: 0];
    if ($app_group !== null) {
        $commits = $app_group_stats['commits'];
        $fields['group_commit'] = ['commits' => $commits, 'batch_mean' => $commits === 0 ? 0.0 : round($app_group_stats['writes'] / $commits, 2), 'batch_max' => $app_group_stats['max']];
        $app_group_stats = ['commits' => 0, 'writes' => 0, 'max' => 0];
    }
    return $fields;
}

/**
 * Group commit: the writes of one loop turn in one transaction, each in its own savepoint, and their responses once the transaction is
 * committed. A write that throws is rolled back to its savepoint and answers 500; the others go on. A transaction that cannot start or
 * commit leaves nothing behind and every write of it answers 500.
 *
 * @param list<Closure(): array{int, string}> $writes what handler_handle() answered with under group commit, in the order of their requests
 * @return list<array{int, string}> one response for each write, in the same order
 */
function app_group_commit(array $writes): array
{
    global $app_db, $app_group, $app_group_stats;
    $statements = $app_group;
    $responses = [];
    try {
        $statements['begin']->execute();
        foreach ($writes as $write) {
            $statements['savepoint']->execute();
            try {
                $responses[] = $write();
                $statements['release']->execute();
            } catch (Throwable $e) {
                fwrite(STDERR, 'app: a write failed inside its group commit: ' . get_class($e) . ': ' . $e->getMessage() . "\n");
                $statements['rollback_to']->execute();
                $statements['release']->execute();
                $responses[] = response_error(500, 'internal server error');
            }
        }
        $statements['commit']->execute();
    } catch (Throwable $e) {
        fwrite(STDERR, 'app: a group commit failed: ' . get_class($e) . ': ' . $e->getMessage() . "\n");
        try {
            $app_db['db']->exec('ROLLBACK');
        } catch (Throwable) {
            // No transaction was open: it never started.
        }
        $responses = array_fill(0, count($writes), response_error(500, 'internal server error'));
    }
    $app_group_stats['commits']++;
    $app_group_stats['writes'] += count($writes);
    $app_group_stats['max'] = max($app_group_stats['max'], count($writes));
    return $responses;
}

/**
 * Starts the checkpointer: a second process with its own connection (lab/app/checkpointer.php) that runs a PASSIVE checkpoint every $ms
 * milliseconds. It reads a pipe whose other end is this process: when this process ends, killed or not, the pipe closes and it ends.
 *
 * @return int the process id of the checkpointer
 */
function app_checkpointer_start(string $path, int $ms): int
{
    global $app_checkpointer;
    $process = proc_open([PHP_BINARY, __DIR__ . '/checkpointer.php', $path, (string) $ms], [0 => ['pipe', 'r'], 1 => STDOUT, 2 => STDERR], $pipes);
    if ($process === false) {
        throw new RuntimeException('cannot start the checkpointer process');
    }
    // Why kept: the process handle waits for the child when it is freed, and the pipe's write end closing is the child's signal to end.
    $app_checkpointer = [$process, $pipes];
    return proc_get_status($process)['pid'];
}

/** Counts a request that reached $endpoint when telemetry is on; hands the response back untouched. */
function app_count(string $endpoint, array|Closure $response): array|Closure
{
    global $app_requests;
    if ($app_requests !== null) {
        $app_requests[$endpoint] = ($app_requests[$endpoint] ?? 0) + 1;
    }
    return $response;
}

// S3, route. A plain match on the method and the path (a `?query` is cut off first).

/**
 * @return array{int, string}|Closure the HTTP status and the JSON body; under group commit a write answers with a Closure instead, which
 *                                     runs its statement and returns that pair once app_group_commit() calls it
 */
function handler_handle(string $method, string $path, string $body, string $authorization): array|Closure
{
    $query = strpos($path, '?');
    if ($query !== false) {
        $path = substr($path, 0, $query);
    }
    if ($method === 'GET') {
        if ($path === '/health') {
            return app_count('GET /health', route_health());
        }
        if ($path === '/feed') {
            return app_count('GET /feed', route_feed());
        }
        if (strncmp($path, '/posts/', 7) === 0 && !str_contains(substr($path, 7), '/')) {
            return app_count('GET /posts/:id', route_post_get(substr($path, 7)));
        }
    } elseif ($method === 'POST') {
        if ($path === '/posts') {
            return app_count('POST /posts', route_post_create($authorization, $body));
        }
        if (strncmp($path, '/posts/', 7) === 0 && str_ends_with($path, '/like') && !str_contains(substr($path, 7, -5), '/')) {
            return app_count('POST /posts/:id/like', route_like($authorization, substr($path, 7, -5)));
        }
    }
    return response_error(404, 'not found');
}

function route_health(): array
{
    global $app_db, $app_started_at;
    try {
        $app_db['health']->execute();
        $app_db['health']->fetchAll();
    } catch (PDOException $e) {
        return response_json(503, health_degraded_json($e->getMessage()));
    }
    return response_json(200, health_json(time() - $app_started_at));
}

function route_feed(): array
{
    global $app_fetch_num;
    $rows = feed_query();
    return response_json(200, $app_fetch_num ? feed_json_positions($rows) : feed_json($rows));
}

function route_post_get(string $id): array
{
    global $app_fetch_num;
    $id = id_validate($id);
    if ($id === null) {
        return response_error(400, 'invalid post id');
    }
    $post = post_query($id);
    if ($post === null) {
        return response_error(404, 'post not found');
    }
    return response_json(200, $app_fetch_num ? post_json_positions($post) : post_json($post));
}

function route_post_create(string $authorization, string $body): array|Closure
{
    global $app_group;
    $user = jwt_verify($authorization);
    if (is_string($user)) {
        return response_error(401, $user);
    }
    $text = body_validate($body);
    if ($text[0] === null) {
        return response_error(400, $text[1]);
    }
    if ($app_group !== null) {
        return static fn (): array => post_create($user, $text[0]);
    }
    return post_create($user, $text[0]);
}

/**
 * The insert of a new post and its 201 response: what route_post_create runs at once, or hands to the group commit.
 *
 * @param array{user_id: int, username: string} $user
 * @return array{int, string}
 */
function post_create(array $user, string $body): array
{
    $row = post_insert($user['user_id'], $body);
    return response_json(201, post_json(['id' => $row['id'], 'body' => $body, 'created_at' => $row['created_at'], 'author' => $user['username'], 'like_count' => 0]));
}

function route_like(string $authorization, string $id): array|Closure
{
    global $app_group;
    // Auth first, then the id: a bad id without a token is a 401.
    $user = jwt_verify($authorization);
    if (is_string($user)) {
        return response_error(401, $user);
    }
    $id = id_validate($id);
    if ($id === null) {
        return response_error(400, 'invalid post id');
    }
    if (!post_exists($id)) {
        return response_error(404, 'post not found');
    }
    if ($app_group !== null) {
        return static fn (): array => like_create($user['user_id'], $id);
    }
    return like_create($user['user_id'], $id);
}

/**
 * The insert of a like and its 201 (or 200 for a repeat) response: what route_like runs at once, or hands to the group commit.
 *
 * @return array{int, string}
 */
function like_create(int $userId, int $postId): array
{
    $liked = like_insert($userId, $postId);
    return response_json($liked ? 201 : 200, like_json($postId, !$liked));
}

// S4, JWT. HS256 only, checked on every request.

/**
 * @return array{user_id: int, username: string}|string the user the token names, or the error message to answer with
 */
function jwt_verify(string $authorization): array|string
{
    global $app_secret;
    if (strncmp($authorization, 'Bearer ', 7) !== 0) {
        return 'missing bearer token';
    }
    $parts = explode('.', substr($authorization, 7));
    if (count($parts) !== 3) {
        return 'invalid or expired token';
    }
    [$header, $payload, $signature] = $parts;
    $header = json_decode(jwt_base64url_decode($header), true);
    if (!is_array($header) || ($header['alg'] ?? null) !== 'HS256') {
        return 'invalid or expired token';
    }
    $expected = hash_hmac('sha256', "{$parts[0]}.{$parts[1]}", $app_secret, true);
    if (!hash_equals($expected, jwt_base64url_decode($signature))) {
        return 'invalid or expired token';
    }
    $payload = json_decode(jwt_base64url_decode($payload), true);
    // A token without `exp` never expires: rejected.
    if (!is_array($payload) || !isset($payload['exp']) || !(is_int($payload['exp']) || is_float($payload['exp'])) || $payload['exp'] <= time()) {
        return 'invalid or expired token';
    }
    $sub = $payload['sub'] ?? null;
    if (!is_string($sub) || !ctype_digit($sub) || (int) $sub < 1 || !is_string($payload['username'] ?? null)) {
        return 'invalid token payload';
    }
    return ['user_id' => (int) $sub, 'username' => $payload['username']];
}

function jwt_base64url_decode(string $value): string
{
    return (string) base64_decode(strtr($value, '-_', '+/'), true);
}

// S5, validation.

/** The id of a post as a positive integer, or null. */
function id_validate(string $id): ?int
{
    if (!ctype_digit($id) || (int) $id < 1) {
        return null;
    }
    return (int) $id;
}

/** @return array{?string, string} the trimmed body and '', or null and the error message */
function body_validate(string $raw): array
{
    $data = json_decode($raw, true);
    if (json_last_error() !== JSON_ERROR_NONE) {
        return [null, 'malformed JSON body'];
    }
    if (!is_array($data) || !is_string($data['body'] ?? null)) {
        return [null, 'body is required'];
    }
    $body = trim($data['body']);
    if ($body === '') {
        return [null, 'body is required'];
    }
    if (mb_strlen($body) > APP_BODY_MAX_CHARS) {
        return [null, 'body must be at most ' . APP_BODY_MAX_CHARS . ' characters'];
    }
    return [$body, ''];
}

// S6, SQLite. Autocommit: each write is its own transaction, committed before the response is built. With APP_GROUP_COMMIT=1 the writes of a
// loop turn share one transaction (app_group_commit), committed before any of their responses.

/** @return list<array<string|int, mixed>> the rows keyed by column name, or by position with APP_FETCH=num (id, body, created_at, author, like_count) */
function feed_query(): array
{
    global $app_db, $app_feed_two_step, $app_fetch_num, $app_fetch_loop;
    $feed = $app_db['feed'];
    $feed->execute();
    if ($app_fetch_loop) {
        $style = $app_fetch_num ? PDO::FETCH_NUM : PDO::FETCH_ASSOC;
        $rows = [];
        while (($row = $feed->fetch($style)) !== false) {
            $rows[] = $row;
        }
    } else {
        $rows = $app_fetch_num ? $feed->fetchAll(PDO::FETCH_NUM) : $feed->fetchAll();
    }
    if ($app_feed_two_step && $rows !== []) {
        $ids = array_column($rows, $app_fetch_num ? 0 : 'id');
        $likes = $app_db['feed_likes'];
        $likes->execute(array_pad($ids, 20, $ids[0]));
        $counts = $likes->fetchAll(PDO::FETCH_KEY_PAIR);
        foreach ($rows as &$row) {
            $count = $counts[$row[$app_fetch_num ? 0 : 'id']] ?? 0;
            if ($app_fetch_num) {
                $row[] = $count;
            } else {
                $row['like_count'] = $count;
            }
        }
        unset($row);
    }
    return $rows;
}

/** @return array<string|int, mixed>|null */
function post_query(int $id): ?array
{
    global $app_db, $app_fetch_num;
    $app_db['post']->execute([$id]);
    $post = $app_fetch_num ? $app_db['post']->fetch(PDO::FETCH_NUM) : $app_db['post']->fetch();
    $app_db['post']->closeCursor();
    return $post === false ? null : $post;
}

/** @return array{id: int, created_at: string} */
function post_insert(int $userId, string $body): array
{
    global $app_db;
    $statement = $app_db['post_insert'];
    try {
        $statement->execute([$userId, $body]);
        return $statement->fetch();
    } finally {
        // Why: a statement that is not finished keeps its write transaction open.
        $statement->closeCursor();
    }
}

function post_exists(int $id): bool
{
    global $app_db;
    $app_db['post_exists']->execute([$id]);
    $found = $app_db['post_exists']->fetch() !== false;
    $app_db['post_exists']->closeCursor();
    return $found;
}

/** @return bool true when the like is new, false when the user had already liked the post */
function like_insert(int $userId, int $postId): bool
{
    global $app_db;
    $app_db['like_insert']->execute([$userId, $postId]);
    return $app_db['like_insert']->rowCount() === 1;
}

// S7, JSON. Arrays in the spec's key order.

/** @param list<array<string, mixed>> $posts */
function feed_json(array $posts): string
{
    return json_encode(['posts' => $posts], APP_JSON_FLAGS);
}

/** @param array<string, mixed> $post */
function post_json(array $post): string
{
    return json_encode(['post' => $post], APP_JSON_FLAGS);
}

// With APP_FETCH=num the rows come by position (id, body, created_at, author, like_count): the same bytes as the keyed arrays give.

/** @param array<int, mixed> $post */
function post_object_json(array $post): string
{
    return '{"id":' . $post[0] . ',"body":' . json_encode($post[1], APP_JSON_FLAGS) . ',"created_at":' . json_encode($post[2], APP_JSON_FLAGS)
        . ',"author":' . json_encode($post[3], APP_JSON_FLAGS) . ',"like_count":' . $post[4] . '}';
}

/** @param array<int, mixed> $post */
function post_json_positions(array $post): string
{
    return '{"post":' . post_object_json($post) . '}';
}

/** @param list<array<int, mixed>> $posts */
function feed_json_positions(array $posts): string
{
    $objects = [];
    foreach ($posts as $post) {
        $objects[] = post_object_json($post);
    }
    return '{"posts":[' . implode(',', $objects) . ']}';
}

function like_json(int $postId, bool $alreadyLiked): string
{
    return json_encode(['liked' => true, 'already_liked' => $alreadyLiked, 'post_id' => $postId], APP_JSON_FLAGS);
}

function health_json(int $uptimeSeconds): string
{
    return json_encode(['status' => 'ok', 'db' => 'ok', 'uptime_s' => $uptimeSeconds], APP_JSON_FLAGS);
}

function health_degraded_json(string $error): string
{
    return json_encode(['status' => 'degraded', 'db' => 'unreachable', 'error' => $error], APP_JSON_FLAGS);
}

// S8, response. DiyConnection adds the status line and the headers.

/** @return array{int, string} */
function response_json(int $status, string $json): array
{
    return [$status, $json];
}

/** @return array{int, string} */
function response_error(int $status, string $message): array
{
    return [$status, json_encode(['error' => $message], APP_JSON_FLAGS)];
}
