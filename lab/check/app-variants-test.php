<?php
// The switches of the S6 variants (APP_FEED_SQL, APP_FETCH, APP_PRAGMAS), through the app's public entry point (handler_handle) on a
// small database made here: every combination of SQL and fetch must answer the same bytes as the unset one (the feed, each post, a
// missing post, the feed again after likes), including a feed of fewer than 20 posts and an empty one; a literal answer pins the
// reference; a bad value is refused at boot; a pragma preset really changes the connection.
// Run: bash lab/run.sh 8.5 php /lab/check/app-variants-test.php

require __DIR__ . '/../app/app.php';

const SECRET = 'a-secret-for-this-test';

$dir = sys_get_temp_dir() . '/app-variants-' . getmypid();
mkdir($dir);
register_shutdown_function(fn () => array_map('unlink', glob($dir . '/*')) && rmdir($dir));

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

/** Boots the app on a fresh copy of $source with the switches in $env, and returns what the requests below answer, in order. */
function answers(string $source, array $env, int $posts): array
{
    global $dir;
    $copy = $dir . '/copy.db';
    array_map('unlink', glob($copy . '*'));
    copy($source, $copy);
    app_boot($copy, SECRET, app_variants($env));
    $out = [];
    $out['feed'] = handler_handle('GET', '/feed', '', '');
    for ($id = 0; $id <= $posts + 1; $id++) {
        $out["post $id"] = handler_handle('GET', "/posts/$id", '', '');
    }
    // The newest posts get likes (a new one, then a repeat), and the feed and the posts are read again: nothing is kept from before.
    $user = token(8, 'barbara');
    $other = token(1, 'ada');
    foreach ([$posts, $posts - 1, $posts] as $i => $id) {
        $out["like $i"] = handler_handle('POST', "/posts/$id/like", '', "Bearer $user");
    }
    $out['like ada'] = handler_handle('POST', "/posts/$posts/like", '', "Bearer $other");
    $out['feed again'] = handler_handle('GET', '/feed', '', '');
    $out['post again'] = handler_handle('GET', "/posts/$posts", '', '');
    return $out;
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

/** Null when every answer of $got is $want's; else the first one that differs. */
function same_answers(array $got, array $want): ?string
{
    foreach ($want as $name => $answer) {
        if (($got[$name] ?? null) !== $answer) {
            return "$name: got " . json_encode($got[$name] ?? null) . ', expected ' . json_encode($answer);
        }
    }
    return null;
}

$fetches = ['assoc', 'num', 'assoc-loop', 'num-loop'];
$sqls = ['reference', 'join', 'two-step'];

// Databases of 30 posts (a full feed), 3 posts (fewer than 20) and none.
foreach ([30, 3, 0] as $posts) {
    $source = "$dir/source-$posts.db";
    make_db($source, $posts);
    $want = answers($source, [], $posts);
    foreach ($sqls as $sql) {
        foreach ($fetches as $fetch) {
            check_case("$posts posts, APP_FEED_SQL=$sql APP_FETCH=$fetch: the same answers as unset", fn () => same_answers(
                answers($source, ['APP_FEED_SQL' => $sql, 'APP_FETCH' => $fetch], $posts), $want));
        }
    }
    foreach (APP_PRAGMA_PRESETS as $preset => $values) {
        check_case("$posts posts, APP_PRAGMAS=$preset: the same answers as unset", fn () => same_answers(
            answers($source, ['APP_PRAGMAS' => $preset], $posts), $want));
    }
}

// The reference itself, against a literal answer written by hand (its keys in the spec's order, ids, counts, escapes).
check_case('2 posts: the feed and a post are the literal bytes, with every variant', function () use ($dir, $sqls, $fetches) {
    $db = new PDO('sqlite:' . $dir . '/literal.db', null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $db->exec("
      CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL DEFAULT 'x');
      CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, body TEXT NOT NULL, created_at TEXT NOT NULL);
      CREATE TABLE likes (user_id INTEGER NOT NULL, post_id INTEGER NOT NULL, created_at TEXT NOT NULL DEFAULT 'x', PRIMARY KEY (user_id, post_id));
      CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);
      CREATE INDEX likes_post_id_idx ON likes (post_id);
      INSERT INTO users (id, username) VALUES (1, 'ada'), (2, 'grace');
      INSERT INTO posts (id, user_id, body, created_at) VALUES (1, 1, 'first', '2025-01-01T00:00:00.000Z'), (2, 2, 'a \"q\" é/', '2025-01-01T00:00:00.000Z');
      INSERT INTO likes (user_id, post_id) VALUES (1, 1), (2, 1);
    ");
    unset($db);
    $feed = '{"posts":[{"id":2,"body":"a \"q\" é/","created_at":"2025-01-01T00:00:00.000Z","author":"grace","like_count":0},'
        . '{"id":1,"body":"first","created_at":"2025-01-01T00:00:00.000Z","author":"ada","like_count":2}]}';
    $post = '{"post":{"id":1,"body":"first","created_at":"2025-01-01T00:00:00.000Z","author":"ada","like_count":2}}';
    foreach ($sqls as $sql) {
        foreach ($fetches as $fetch) {
            app_boot($dir . '/literal.db', SECRET, app_variants(['APP_FEED_SQL' => $sql, 'APP_FETCH' => $fetch]));
            $got = [handler_handle('GET', '/feed', '', ''), handler_handle('GET', '/posts/1', '', '')];
            if ($got !== [[200, $feed], [200, $post]]) {
                return "$sql/$fetch answered " . json_encode($got);
            }
        }
    }
    return null;
});

check_case('unset, empty and the default names are the same switches', function () {
    $default = ['feed_sql' => 'reference', 'fetch' => 'assoc', 'pragmas' => 'default'];
    foreach ([[], ['APP_FEED_SQL' => '', 'APP_FETCH' => '', 'APP_PRAGMAS' => ''], ['APP_FEED_SQL' => 'reference', 'APP_FETCH' => 'assoc', 'APP_PRAGMAS' => 'default']] as $env) {
        if (app_variants($env) !== $default) {
            return 'got ' . json_encode(app_variants($env)) . ' for ' . json_encode($env);
        }
    }
    return null;
});

foreach (['APP_FEED_SQL' => ['joins', 'two-step'], 'APP_FETCH' => ['both', 'num-loop'], 'APP_PRAGMAS' => ['huge', 'mmap-off']] as $name => [$value, $allowed]) {
    check_case("$name=$value is refused, and the message names the variable, the value and one allowed value ($allowed)", function () use ($name, $value, $allowed) {
        try {
            app_variants([$name => $value]);
        } catch (InvalidArgumentException $e) {
            $message = $e->getMessage();
            return str_contains($message, $name) && str_contains($message, $value) && str_contains($message, $allowed) ? null : "the message is: $message";
        }
        return 'no exception';
    });
}

// A preset really reaches the connection: the cache and the memory map sizes are read back from it.
$expected = ['default' => [-65536, 268435456]] + array_map(fn ($values) => [$values['cache_size'], $values['mmap_size']], APP_PRAGMA_PRESETS);
foreach ($expected as $preset => [$cache, $mmap]) {
    check_case("APP_PRAGMAS=$preset sets cache_size $cache and mmap_size $mmap", function () use ($preset, $cache, $mmap, $dir) {
        global $app_db;
        app_boot($dir . '/source-30.db', SECRET, app_variants(['APP_PRAGMAS' => $preset]));
        $got = [(int) $app_db['db']->query('PRAGMA cache_size')->fetchColumn(), (int) $app_db['db']->query('PRAGMA mmap_size')->fetchColumn()];
        return $got === [$cache, $mmap] ? null : 'got ' . json_encode($got);
    });
}

// The join variant puts the limit before the likes are counted: the likes table is never scanned for a post that is not in the feed's 20.
check_case('APP_FEED_SQL=join: the likes index is searched, never scanned', function () use ($dir) {
    global $app_db;
    app_boot($dir . '/source-30.db', SECRET, app_variants(['APP_FEED_SQL' => 'join']));
    $plan = implode(' | ', array_column($app_db['db']->query('EXPLAIN QUERY PLAN ' . app_feed_sql('join'))->fetchAll(PDO::FETCH_ASSOC), 'detail'));
    return str_contains($plan, 'likes_post_id_idx') && !preg_match('/SCAN (l|likes)\b/', $plan) ? null : "the plan is: $plan";
});

exit($failed ? 1 : 0);
