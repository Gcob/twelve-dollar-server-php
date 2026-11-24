<?php
// The switches of the S6 variants (APP_FEED_SQL, APP_FETCH, APP_JSON, APP_PRAGMAS) and of APP_LOCKING, through the app's public entry point
// (handler_handle) on a small database made here: every combination of SQL and fetch must answer the same bytes as the unset one (the
// feed, each post, a missing post, the feed again after likes), including a feed of fewer than 20 posts and an empty one; a literal
// answer pins the reference; a bad value is refused at boot; a pragma preset really changes the connection; APP_LOCKING=exclusive keeps
// the database to the one process (another process cannot open it while it runs) and a new process opens it again once that one is
// gone, killed or not.
// Run: bash lab/run.sh 8.5 php /lab/check/app-variants-test.php

require __DIR__ . '/app-lib.php';

// A child process of this test: boots the app on the database with APP_LOCKING=<mode>, likes post 5 as user 8, tells its status, and
// then waits to be killed ('hold') or exits ('exit'). Its Authorization header comes from the parent.
if (($argv[1] ?? '') === 'child') {
    [, , $childPath, $childLocking, $childAuth, $childEnd] = $argv;
    app_boot($childPath, SECRET, app_variants(['APP_LOCKING' => $childLocking]));
    echo handler_handle('POST', '/posts/5/like', '', $childAuth)[0] . "\n";
    fflush(STDOUT);
    if ($childEnd === 'hold') {
        sleep(120);
    }
    exit(0);
}

$dir = sys_get_temp_dir() . '/app-variants-' . getmypid();
mkdir($dir);
register_shutdown_function(fn () => array_map('unlink', glob($dir . '/*')) && rmdir($dir));

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

/** What another connection to $path gets when it reads the likes without waiting: 'read' or the error SQLite gives. */
function another_connection_reads(string $path): string
{
    try {
        $db = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
        $db->exec('PRAGMA busy_timeout = 0');
        $db->query('SELECT count(*) FROM likes')->fetchColumn();
        return 'read';
    } catch (PDOException $e) {
        return $e->getMessage();
    }
}

/** Starts the child above on $path; returns [process, its status line]. $end is 'hold' (the child waits) or 'exit'. */
function start_child(string $path, string $locking, string $end): array
{
    $process = proc_open([PHP_BINARY, __FILE__, 'child', $path, $locking, 'Bearer ' . token(8, 'barbara'), $end], [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    stream_set_timeout($pipes[1], 30);
    $line = trim((string) fgets($pipes[1]));
    return [$process, $line, $pipes];
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

/** Every answer as [status, decoded body]: what APP_JSON=sqlite must keep (its bytes may differ from encode's where SQLite escapes less). */
function decoded(array $answers): array
{
    return array_map(static fn (array $answer): array => [$answer[0], json_decode($answer[1], true, 512, JSON_THROW_ON_ERROR)], $answers);
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
    foreach ($sqls as $sql) {
        check_case("$posts posts, APP_JSON=concat APP_FEED_SQL=$sql: the same bytes as unset", fn () => same_answers(
            answers($source, ['APP_JSON' => 'concat', 'APP_FEED_SQL' => $sql], $posts), $want));
    }
    check_case("$posts posts, APP_JSON=sqlite: the same status and the same decoded bodies as unset", fn () => same_answers(
        decoded(answers($source, ['APP_JSON' => 'sqlite'], $posts)), decoded($want)));
    check_case("$posts posts, APP_JSON=sqlite: the same bytes as unset (no U+2028 or U+2029 in these rows)", fn () => same_answers(
        answers($source, ['APP_JSON' => 'sqlite'], $posts), $want));
    foreach (['concat', 'sqlite'] as $json) {
        check_case("$posts posts, APP_JSON=$json APP_PRAGMAS=mmap-off: the same decoded answers as unset", fn () => same_answers(
            decoded(answers($source, ['APP_JSON' => $json, 'APP_PRAGMAS' => 'mmap-off'], $posts)), decoded($want)));
    }
    foreach (APP_PRAGMA_PRESETS as $preset => $values) {
        check_case("$posts posts, APP_PRAGMAS=$preset: the same answers as unset", fn () => same_answers(
            answers($source, ['APP_PRAGMAS' => $preset], $posts), $want));
    }
    check_case("$posts posts, APP_LOCKING=exclusive: the same answers as unset", fn () => same_answers(
        answers($source, ['APP_LOCKING' => 'exclusive'], $posts), $want));
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
    $default = ['feed_sql' => 'reference', 'fetch' => 'assoc', 'json' => 'encode', 'pragmas' => 'default', 'locking' => 'normal', 'group_commit' => false, 'checkpointer' => 0];
    foreach ([[], ['APP_FEED_SQL' => '', 'APP_FETCH' => '', 'APP_JSON' => '', 'APP_PRAGMAS' => '', 'APP_LOCKING' => '', 'APP_GROUP_COMMIT' => '', 'APP_CHECKPOINTER' => ''],
              ['APP_FEED_SQL' => 'reference', 'APP_FETCH' => 'assoc', 'APP_JSON' => 'encode', 'APP_PRAGMAS' => 'default', 'APP_LOCKING' => 'normal', 'APP_GROUP_COMMIT' => '0']] as $env) {
        if (app_variants($env) !== $default) {
            return 'got ' . json_encode(app_variants($env)) . ' for ' . json_encode($env);
        }
    }
    return null;
});

foreach (['APP_FEED_SQL' => ['joins', 'two-step'], 'APP_FETCH' => ['both', 'num-loop'], 'APP_JSON' => ['jsonb', 'concat'], 'APP_PRAGMAS' => ['huge', 'mmap-off'], 'APP_LOCKING' => ['shared', 'exclusive']] as $name => [$value, $allowed]) {
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

// APP_JSON on the rows that stress an encoder: a quote, a backslash, a slash, a tab and other control characters, U+2028 and U+2029, an
// emoji, in the body and in the author's name. The reference's bytes are written here by hand (PHP's escapes with the app's flags).
// concat must give them exactly. sqlite must decode to the same values; its bytes differ only where SQLite writes U+2028 and U+2029 raw.
const STRESS_BODY = "q\" b\\ s/ t\t c\x01\x08\x0c\r\x1f\x7f u\u{2028}\u{2029} e😀 é";
const STRESS_BODY_JSON = '"q\" b\\\\ s/ t\t c\u0001\b\f\r\u001f' . "\x7f" . ' u\u2028\u2029 e😀 é"';
const STRESS_AUTHOR = "o\"b\\r/\u{2028}ien";
const STRESS_AUTHOR_JSON = '"o\"b\\\\r/\u2028ien"';
function stress_db(string $path): void
{
    $db = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $db->exec("
      CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL DEFAULT 'x');
      CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, body TEXT NOT NULL, created_at TEXT NOT NULL);
      CREATE TABLE likes (user_id INTEGER NOT NULL, post_id INTEGER NOT NULL, created_at TEXT NOT NULL DEFAULT 'x', PRIMARY KEY (user_id, post_id));
      CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);
      CREATE INDEX likes_post_id_idx ON likes (post_id);
      INSERT INTO likes (user_id, post_id) VALUES (1, 2), (2, 2), (3, 2);
    ");
    $db->prepare('INSERT INTO users (id, username) VALUES (1, ?), (2, \'plain\')')->execute([STRESS_AUTHOR]);
    $db->prepare('INSERT INTO posts (id, user_id, body, created_at) VALUES (1, 2, \'plain\', \'2025-01-01T00:00:00.000Z\'), (2, 1, ?, \'2025-01-01T00:00:01.000Z\')')->execute([STRESS_BODY]);
}
check_case('APP_JSON: concat gives the hand-written bytes of a row full of escapes; sqlite the same values, and only U+2028 and U+2029 written raw', function () use ($dir) {
    stress_db("$dir/stress.db");
    $object = '{"id":2,"body":' . STRESS_BODY_JSON . ',"created_at":"2025-01-01T00:00:01.000Z","author":' . STRESS_AUTHOR_JSON . ',"like_count":3}';
    $first = '{"id":1,"body":"plain","created_at":"2025-01-01T00:00:00.000Z","author":"plain","like_count":0}';
    $feed = '{"posts":[' . $object . ',' . $first . ']}';
    $post = '{"post":' . $object . '}';
    foreach (['encode', 'concat', 'sqlite'] as $json) {
        app_boot("$dir/stress.db", SECRET, app_variants(['APP_JSON' => $json]));
        $got = [handler_handle('GET', '/feed', '', ''), handler_handle('GET', '/posts/2', '', '')];
        if ($json !== 'sqlite') {
            if ($got !== [[200, $feed], [200, $post]]) {
                return "$json answered " . json_encode($got, JSON_UNESCAPED_SLASHES);
            }
            continue;
        }
        $raw = ["\u{2028}", "\u{2029}"];
        $escaped = ['\u2028', '\u2029'];
        $bytes = [[$got[0][0], str_replace($raw, $escaped, $got[0][1])], [$got[1][0], str_replace($raw, $escaped, $got[1][1])]];
        if ($bytes !== [[200, $feed], [200, $post]]) {
            return 'sqlite answered ' . json_encode($got, JSON_UNESCAPED_SLASHES) . ' (after writing U+2028 and U+2029 as PHP does)';
        }
        if (decoded($got) !== decoded([[200, $feed], [200, $post]])) {
            return 'sqlite decodes to other values';
        }
        if (!str_contains($got[0][1], "\u{2028}") || !str_contains($got[1][1], "\u{2029}")) {
            return 'sqlite no longer writes U+2028 and U+2029 raw: the difference this case names is gone, update the case and the comments';
        }
    }
    return null;
});

check_case('APP_JSON: an empty feed is {"posts":[]} with each value, and a missing post is the same 404', function () use ($dir) {
    foreach (['encode', 'concat', 'sqlite'] as $json) {
        app_boot("$dir/source-0.db", SECRET, app_variants(['APP_JSON' => $json]));
        $got = [handler_handle('GET', '/feed', '', ''), handler_handle('GET', '/posts/1', '', ''), handler_handle('GET', '/posts/x', '', '')];
        if ($got !== [[200, '{"posts":[]}'], [404, '{"error":"post not found"}'], [400, '{"error":"invalid post id"}']]) {
            return "$json answered " . json_encode($got);
        }
    }
    return null;
});

// Combinations the app refuses at boot, with the reason in the message.
foreach ([
    [['APP_JSON' => 'sqlite', 'APP_FEED_SQL' => 'join'], 'APP_FEED_SQL=join'],
    [['APP_JSON' => 'sqlite', 'APP_FEED_SQL' => 'two-step'], 'APP_FEED_SQL=two-step'],
    [['APP_JSON' => 'sqlite', 'APP_FETCH' => 'num'], 'APP_FETCH=num'],
    [['APP_JSON' => 'concat', 'APP_FETCH' => 'num-loop'], 'APP_FETCH=num-loop'],
    [['APP_JSON' => 'concat', 'APP_FETCH' => 'assoc-loop'], 'APP_FETCH=assoc-loop'],
] as [$env, $named]) {
    check_case(implode(' ', array_map(fn ($k, $v) => "$k=$v", array_keys($env), $env)) . ' is refused, and the message names ' . $named, function () use ($env, $named) {
        try {
            app_variants($env);
        } catch (InvalidArgumentException $e) {
            return str_contains($e->getMessage(), 'APP_JSON=' . $env['APP_JSON']) && str_contains($e->getMessage(), $named) ? null : 'the message is: ' . $e->getMessage();
        }
        return 'no exception';
    });
}
check_case('APP_JSON=encode and concat are accepted with every APP_FEED_SQL and APP_FETCH they can work with', function () {
    foreach (['encode' => [['reference', 'join', 'two-step'], ['assoc', 'num', 'assoc-loop', 'num-loop']], 'concat' => [['reference', 'join', 'two-step'], ['assoc']]] as $json => [$sqls, $fetches]) {
        foreach ($sqls as $sql) {
            foreach ($fetches as $fetch) {
                app_variants(['APP_JSON' => $json, 'APP_FEED_SQL' => $sql, 'APP_FETCH' => $fetch]);
            }
        }
    }
    return null;
});

check_case('APP_JSON reaches the app: the value is the one booted, and sqlite prepares SQLite\'s own JSON statements', function () use ($dir) {
    global $app_db, $app_json;
    foreach (['encode', 'concat', 'sqlite'] as $json) {
        app_boot("$dir/source-30.db", SECRET, app_variants(['APP_JSON' => $json]));
        if ($app_json !== $json) {
            return "booted $json, the app says '$app_json'";
        }
        $builds = str_contains($app_db['feed']->queryString, 'json_group_array') && str_contains($app_db['post']->queryString, 'json_object');
        if ($builds !== ($json === 'sqlite')) {
            return "$json: the statements " . ($builds ? 'build' : 'do not build') . ' the JSON in SQLite';
        }
    }
    return null;
});

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

// APP_LOCKING: what the connection says, and what another process sees. The database starts in rollback-journal mode here (make_db):
// the app turns on the WAL, and exclusive locking must be in place before that first WAL access.
foreach (['normal' => 'unset', 'exclusive' => 'exclusive'] as $locking => $label) {
    check_case("APP_LOCKING $label: locking_mode reads $locking, journal_mode wal, " . ($locking === 'normal' ? 'a' : 'no') . " shared-memory file", function () use ($dir, $locking) {
        global $app_db;
        copy("$dir/source-30.db", "$dir/locking.db");
        app_boot("$dir/locking.db", SECRET, app_variants($locking === 'normal' ? [] : ['APP_LOCKING' => $locking]));
        $got = [$app_db['db']->query('PRAGMA locking_mode')->fetchColumn(), $app_db['db']->query('PRAGMA journal_mode')->fetchColumn()];
        $shm = file_exists("$dir/locking.db-shm");
        $app_db = null;
        if ($shm !== ($locking === 'normal')) {
            return 'the WAL shared-memory file ' . ($shm ? 'exists' : 'does not exist');
        }
        return $got === [$locking, 'wal'] ? null : 'got ' . json_encode($got);
    });
}

$lockingPath = "$dir/locking-child.db";
foreach (['normal' => 'unset', 'exclusive' => 'exclusive'] as $locking => $label) {
    foreach (['hold' => 'killed with SIGKILL', 'exit' => 'exits'] as $end => $how) {
        check_case("APP_LOCKING $label: a process that liked a post and then $how leaves a database a new boot opens, with the like in it", function () use ($dir, $lockingPath, $locking, $end) {
            global $app_db;
            array_map('unlink', glob($lockingPath . '*'));
            copy("$dir/source-30.db", $lockingPath);
            [$process, $status, $pipes] = start_child($lockingPath, $locking === 'normal' ? '' : $locking, $end);
            if ($status !== '201') {
                proc_terminate($process, 9);
                return "the child's like answered '$status': " . trim((string) stream_get_contents($pipes[2]));
            }
            $while = $end === 'hold' ? another_connection_reads($lockingPath) : null;
            if ($end === 'hold') {
                proc_terminate($process, 9);
            }
            proc_close($process);
            $expected = $locking === 'normal' ? 'read' : 'database is locked';
            if ($while !== null && !str_contains($while, $expected)) {
                return "another process, while the child ran: '$while', expected '$expected'";
            }
            app_boot($lockingPath, SECRET, app_variants([]));
            $likes = (int) $app_db['db']->query('SELECT count(*) FROM likes WHERE user_id = 8 AND post_id = 5')->fetchColumn();
            $app_db = null;
            return $likes === 1 ? null : "$likes likes of user 8 on post 5 after the child";
        });
    }
}

exit($failed ? 1 : 0);
