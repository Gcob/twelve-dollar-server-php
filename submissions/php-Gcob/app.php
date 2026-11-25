<?php
// The challenge's five endpoints (SPEC.md of the challenge), written as plainly as possible: one function for each step of a request.
//
//   parse (DiyConnection)  ->  route (handler_handle)  ->  jwt_verify  ->  id_validate / body_validate  ->  a query function
//   ->  a json function  ->  response  ->  write (DiyConnection)
//
// handler_handle() is what the connection calls: method, request target, body and the Authorization header value in; the HTTP
// status and the JSON body out. Nothing read for one request answers another: no result, response or token check is kept between
// requests (the statements are prepared once, and that is all that lives on).

const APP_JSON_FLAGS = JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE;
const APP_BODY_MAX_CHARS = 500;

// One SELECT for a post and for the feed: the spec's reference query, plus the clause each one needs.
const APP_POST_SELECT = 'SELECT p.id, p.body, p.created_at, u.username AS author,
                                (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
                           FROM posts p JOIN users u ON u.id = p.user_id';
const APP_FEED_SELECT = APP_POST_SELECT . ' ORDER BY p.created_at DESC, p.id DESC LIMIT 20';
const APP_ONE_POST_SELECT = APP_POST_SELECT . ' WHERE p.id = ?';

// 64 MiB of page cache and no memory map: reads go through pread and the cache.
const APP_CACHE_SIZE = -65536;
const APP_MMAP_SIZE = 0;

/** @var array{db: PDO, feed: PDOStatement, post: PDOStatement, post_insert: PDOStatement, post_exists: PDOStatement, like_insert: PDOStatement, health: PDOStatement}|null */
$app_db = null;
$app_secret = '';
$app_started_at = 0;

/**
 * The statements that set a connection up, in the order they run.
 *
 * @return list<string>
 */
function app_connection_pragmas(): array
{
    return [
        'PRAGMA journal_mode = WAL',
        'PRAGMA synchronous = NORMAL',
        'PRAGMA busy_timeout = 5000',
        'PRAGMA cache_size = ' . APP_CACHE_SIZE,    // KiB when negative: -65536 is 64 MiB
        'PRAGMA mmap_size = ' . APP_MMAP_SIZE,      // bytes
        'PRAGMA temp_store = MEMORY',
    ];
}

/**
 * Opens the database at $path (it must exist: SQLite would create an empty one) and prepares every statement once.
 */
function app_boot(string $path, string $secret): void
{
    global $app_db, $app_secret, $app_started_at;
    if (!is_file($path)) {
        throw new RuntimeException("the database file does not exist: $path");
    }
    $db = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]);
    foreach (app_connection_pragmas() as $statement) {
        $db->exec($statement);
    }
    $app_db = [
        'db' => $db,
        'feed' => $db->prepare(APP_FEED_SELECT),
        'post' => $db->prepare(APP_ONE_POST_SELECT),
        'post_insert' => $db->prepare('INSERT INTO posts (user_id, body) VALUES (?, ?) RETURNING id, created_at'),
        'post_exists' => $db->prepare('SELECT 1 FROM posts WHERE id = ?'),
        'like_insert' => $db->prepare('INSERT INTO likes (user_id, post_id) VALUES (?, ?) ON CONFLICT (user_id, post_id) DO NOTHING'),
        'health' => $db->prepare('SELECT 1'),
    ];
    $app_secret = $secret;
    $app_started_at = time();
}

/** The `sqlite:` boot line: the four settings that matter, as this connection reads them back from SQLite after its setup. */
function app_sqlite_line(): string
{
    global $app_db;
    $read = static fn (string $pragma): string => (string) $app_db['db']->query("PRAGMA $pragma")->fetchColumn();
    return 'sqlite: journal_mode=' . $read('journal_mode') . ' synchronous=' . $read('synchronous') . ' mmap_size=' . $read('mmap_size') . ' cache_size=' . $read('cache_size');
}

// S3 to S8 below are the steps of a request, as this project's lab names them (its table: https://github.com/Gcob/twelve-dollar-server-php/blob/main/lab/README.md).
// S3, route. A plain match on the method and the path (a `?query` is cut off first).

/**
 * @return array{int, string} the HTTP status and the JSON body
 */
function handler_handle(string $method, string $path, string $body, string $authorization): array
{
    $query = strpos($path, '?');
    if ($query !== false) {
        $path = substr($path, 0, $query);
    }
    if ($method === 'GET') {
        if ($path === '/health') {
            return route_health();
        }
        if ($path === '/feed') {
            return route_feed();
        }
        if (strncmp($path, '/posts/', 7) === 0 && !str_contains(substr($path, 7), '/')) {
            return route_post_get(substr($path, 7));
        }
    } elseif ($method === 'POST') {
        if ($path === '/posts') {
            return route_post_create($authorization, $body);
        }
        if (strncmp($path, '/posts/', 7) === 0 && str_ends_with($path, '/like') && !str_contains(substr($path, 7, -5), '/')) {
            return route_like($authorization, substr($path, 7, -5));
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
    return response_json(200, feed_json(feed_query()));
}

function route_post_get(string $id): array
{
    $id = id_validate($id);
    if ($id === null) {
        return response_error(400, 'invalid post id');
    }
    $post = post_query($id);
    if ($post === null) {
        return response_error(404, 'post not found');
    }
    return response_json(200, post_json($post));
}

function route_post_create(string $authorization, string $body): array
{
    $user = jwt_verify($authorization);
    if (is_string($user)) {
        return response_error(401, $user);
    }
    $text = body_validate($body);
    if ($text[0] === null) {
        return response_error(400, $text[1]);
    }
    return post_create($user, $text[0]);
}

/**
 * The insert of a new post and its 201 response.
 *
 * @param array{user_id: int, username: string} $user
 * @return array{int, string}
 */
function post_create(array $user, string $body): array
{
    $row = post_insert($user['user_id'], $body);
    return response_json(201, post_json(['id' => $row['id'], 'body' => $body, 'created_at' => $row['created_at'], 'author' => $user['username'], 'like_count' => 0]));
}

function route_like(string $authorization, string $id): array
{
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
    return like_create($user['user_id'], $id);
}

/**
 * The insert of a like and its 201 (or 200 for a repeat) response.
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

// S6, SQLite. Autocommit: each write is its own transaction, committed before the response is built.

/** @return list<array<string, mixed>> the rows keyed by column name (id, body, created_at, author, like_count) */
function feed_query(): array
{
    global $app_db;
    $feed = $app_db['feed'];
    $feed->execute();
    return $feed->fetchAll();
}

/** @return array<string, mixed>|null */
function post_query(int $id): ?array
{
    global $app_db;
    $app_db['post']->execute([$id]);
    $post = $app_db['post']->fetch();
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
        // Why: autocommit commits when the statement halts. fetchAll() steps it to its end, so a failed commit is an exception (a 500);
        // closeCursor() alone would do it in sqlite3_reset(), whose error pdo_sqlite ignores: the 201 would answer a rolled-back row.
        return $statement->fetchAll()[0];
    } finally {
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
