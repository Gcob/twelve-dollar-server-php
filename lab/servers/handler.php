<?php
// The request handler every runtime of the bake-off calls, so that runtimes differ by what they do around it and not by what it
// does. No runtime code in here: a server adapter passes the method, the path and the body in, and sends the status and the body
// that come back, with its own headers (Content-Type: application/json, and whatever else its runtime adds).
//
//   handler_boot();                                     once, before the first request (in each process that serves)
//   [$status, $body] = handler_handle('GET', '/noop', '');
//
// Routes, from the challenge's SPEC.md:
//   GET /noop        200 {"status":"ok"}, no database
//   GET /posts/:id   200 {"post":{"id":..,"body":..,"created_at":..,"author":..,"like_count":..}}, one indexed read;
//                    404 post not found; 400 invalid post id (not a positive integer: 0, -1, abc, 1.5, empty)
//   anything else    404 not found
// Every error body is {"error":"<message>"}.
//
// The database is a copy of the seed. The seed (/lab/data/feed.db, mounted read-only) is in WAL mode, and opening it would
// leave -wal and -shm files in lab/data/: the first boot copies it to the container's own disk and opens the copy. The pragmas
// are the ones of the php-swoole-mattsplat entry's server.php (see lab/NOTICE.md).

const HANDLER_DB_SOURCE = '/lab/data/feed.db';
const HANDLER_DB_COPY = '/tmp/feed.db';

const HANDLER_NOOP = '{"status":"ok"}';
const HANDLER_NOT_FOUND = '{"error":"not found"}';
const HANDLER_INVALID_ID = '{"error":"invalid post id"}';
const HANDLER_POST_NOT_FOUND = '{"error":"post not found"}';

$handler_stmt = null;

/** Copies the seed to HANDLER_DB_COPY, replacing a copy left by an earlier boot (and its -wal and -shm files). */
function handler_copy_db(): void
{
    foreach (['', '-wal', '-shm'] as $suffix) {
        if (file_exists(HANDLER_DB_COPY . $suffix)) {
            unlink(HANDLER_DB_COPY . $suffix);
        }
    }
    if (!copy(HANDLER_DB_SOURCE, HANDLER_DB_COPY)) {
        throw new RuntimeException('cannot copy ' . HANDLER_DB_SOURCE . ' to ' . HANDLER_DB_COPY);
    }
}

/** Opens the copy and prepares the post query once. Never fork after this: a SQLite handle does not survive a fork. */
function handler_open_db(): void
{
    global $handler_stmt;
    $db = new PDO('sqlite:' . HANDLER_DB_COPY, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $db->exec('PRAGMA journal_mode = WAL');
    $db->exec('PRAGMA synchronous = NORMAL');
    $db->exec('PRAGMA busy_timeout = 5000');
    $db->exec('PRAGMA cache_size = -65536');      // 64 MiB page cache
    $db->exec('PRAGMA mmap_size = 268435456');    // 256 MiB
    $db->exec('PRAGMA temp_store = MEMORY');
    $handler_stmt = $db->prepare(
        'SELECT p.id, p.body, p.created_at, u.username AS author,
                (SELECT count(*) FROM likes l WHERE l.post_id = p.id) AS like_count
           FROM posts p JOIN users u ON u.id = p.user_id
          WHERE p.id = ?'
    );
}

/** The copy, then the open. A runtime that forks workers calls handler_copy_db() once before it forks and handler_open_db() in each worker. */
function handler_boot(): void
{
    handler_copy_db();
    handler_open_db();
}

/** @return array{int, string} the HTTP status and the JSON body */
function handler_handle(string $method, string $path, string $body): array
{
    global $handler_stmt;

    if ($method !== 'GET') {
        return [404, HANDLER_NOT_FOUND];
    }
    $query = strpos($path, '?');
    if ($query !== false) {
        $path = substr($path, 0, $query);
    }
    if ($path === '/noop') {
        return [200, HANDLER_NOOP];
    }
    if (strncmp($path, '/posts/', 7) !== 0) {
        return [404, HANDLER_NOT_FOUND];
    }
    $id = substr($path, 7);
    if (str_contains($id, '/')) {
        return [404, HANDLER_NOT_FOUND];
    }
    if (!ctype_digit($id) || (int) $id < 1) {
        return [400, HANDLER_INVALID_ID];
    }
    $handler_stmt->execute([(int) $id]);
    $post = $handler_stmt->fetch(PDO::FETCH_ASSOC);
    $handler_stmt->closeCursor();
    if ($post === false) {
        return [404, HANDLER_POST_NOT_FOUND];
    }
    return [200, json_encode(['post' => $post], JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE)];
}
