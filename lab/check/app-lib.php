<?php
// Shared by the tests that boot the challenge app on a small database made here (app-variants-test.php, app-group-commit-test.php): the
// app, a database with the challenge's schema, and a token the app accepts.

require __DIR__ . '/../app/app.php';

const SECRET = 'a-secret-for-this-test';

/** A database with the challenge's schema (and its indexes) and the given number of posts: ties on created_at, quotes, slashes, accents, an emoji. */
function make_db(string $path, int $posts): void
{
    $db = new PDO($path === '' ? 'sqlite::memory:' : 'sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $db->exec("
      CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));
      CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id), body TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500),
                          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));
      CREATE TABLE likes (user_id INTEGER NOT NULL REFERENCES users(id), post_id INTEGER NOT NULL REFERENCES posts(id),
                          created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')), PRIMARY KEY (user_id, post_id));
      CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);
      CREATE INDEX posts_user_id_idx ON posts (user_id);
      CREATE INDEX likes_post_id_idx ON likes (post_id);
    ");
    $usernames = ['ada', 'grace', 'o"brien/é', 'zoë😀', 'linus', 'ken', 'dennis', 'barbara'];
    foreach ($usernames as $i => $username) {
        $db->prepare('INSERT INTO users (id, username) VALUES (?, ?)')->execute([$i + 1, $username]);
    }
    $bodies = ['plain', 'a "quoted" word', 'back\\slash and a/slash', 'café ☕ 日本語', "two\nlines\ttabbed", '😀 only an emoji', '<b>&amp;</b>'];
    for ($id = 1; $id <= $posts; $id++) {
        // Posts 6 and 7 share a created_at, 20 and 21 too: the order falls back on id.
        $minute = in_array($id, [7, 21], true) ? $id - 1 : $id;
        $db->prepare('INSERT INTO posts (id, user_id, body, created_at) VALUES (?, ?, ?, ?)')
            ->execute([$id, ($id % 8) + 1, $bodies[$id % 7] . " $id", sprintf('2025-01-01T00:%02d:00.%03dZ', $minute, $id)]);
        // 0 to 7 likes: post 3, 10, ... have none.
        for ($u = 1; $u <= $id % 8; $u++) {
            $db->prepare('INSERT INTO likes (user_id, post_id) VALUES (?, ?)')->execute([$u, $id]);
        }
    }
}

function b64url(string $bytes): string
{
    return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
}

function token(int $userId, string $username): string
{
    $h = b64url(json_encode(['alg' => 'HS256', 'typ' => 'JWT']));
    $p = b64url(json_encode(['sub' => (string) $userId, 'username' => $username, 'exp' => time() + 3600]));
    return "$h.$p." . b64url(hash_hmac('sha256', "$h.$p", SECRET, true));
}
