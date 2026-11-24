<?php
// APP_DRIVER=ffi (lab/app/sqlite-ffi.php): the feed and the posts are read through PHP's FFI straight to libsqlite3 instead of PDO. Through the
// app's public entry point (handler_handle) on a small database made here, every answer must be what the PDO driver gives for the same
// requests, byte for byte (both drivers run the same SQLite and the same SQL): the feed, each post, a missing post, a feed of fewer than 20
// posts and an empty one, rows full of escapes and a body with a NUL byte, with each APP_JSON value; a literal answer pins the reference;
// a bad value or a combination the driver cannot work with is refused at boot; the connection has the pragmas the PDO one has; the boot
// refuses a libsqlite3 that is not the version PDO runs; no statement is left un-reset.
// Run: bash lab/run.sh 8.5 php /lab/check/app-ffi-test.php

require __DIR__ . '/app-lib.php';

// The driver reads only and boots only for the micro bench's flag.
const FFI_ENV = ['APP_DRIVER' => 'ffi', 'APP_DRIVER_BENCH' => '1'];

$dir = sys_get_temp_dir() . '/app-ffi-' . getmypid();
mkdir($dir);
register_shutdown_function(fn () => array_map('unlink', glob($dir . '/*')) && rmdir($dir));
make_db("$dir/pdo.db", 3);

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

/** A fresh copy of $source with the switches in $env booted on it. */
function boot_copy(string $source, array $env, string $name = 'copy'): string
{
    global $dir, $app_db, $app_ffi;
    $app_db = $app_ffi = null;
    $copy = "$dir/$name.db";
    array_map('unlink', glob($copy . '*'));
    copy($source, $copy);
    app_boot($copy, SECRET, app_variants($env));
    return $copy;
}

/** What the requests below answer on a copy of $source booted with $env, in order (the reads only). */
function read_answers(string $source, array $env, int $posts): array
{
    boot_copy($source, $env);
    $out = ['feed' => handler_handle('GET', '/feed', '', '')];
    for ($id = 0; $id <= $posts + 1; $id++) {
        $out["post $id"] = handler_handle('GET', "/posts/$id", '', '');
    }
    $out['post x'] = handler_handle('GET', '/posts/x', '', '');
    $out['feed again'] = handler_handle('GET', '/feed', '', '');
    return $out;
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

// The driver is a switch: unset it is PDO and nothing of the FFI driver exists.

check_case('unset, empty and the default name are PDO, and no FFI driver is booted', function () use ($dir) {
    global $app_ffi;
    foreach ([[], ['APP_DRIVER' => ''], ['APP_DRIVER' => 'pdo']] as $env) {
        $variants = app_variants($env);
        if (($variants['driver'] ?? null) !== 'pdo') {
            return 'the driver is ' . json_encode($variants['driver'] ?? null) . ' for ' . json_encode($env);
        }
    }
    boot_copy("$dir/pdo.db", []);
    return $app_ffi === null ? null : 'an FFI driver was booted';
});

check_case('APP_DRIVER=ffi boots the FFI driver, on the same SQLite as PDO', function () use ($dir) {
    global $app_ffi;
    boot_copy("$dir/pdo.db", FFI_ENV);
    if (!is_object($app_ffi)) {
        return 'no FFI driver was booted';
    }
    $pdo = (new PDO('sqlite::memory:'))->query('SELECT sqlite_version()')->fetchColumn();
    return $app_ffi->version === $pdo ? null : "the driver says SQLite {$app_ffi->version}, PDO runs $pdo";
});

check_case('APP_DRIVER=ffi is refused without the bench flag: it reads only, and the message says so', function () {
    foreach ([['APP_DRIVER' => 'ffi'], ['APP_DRIVER' => 'ffi', 'APP_DRIVER_BENCH' => '0']] as $env) {
        try {
            app_variants($env);
        } catch (InvalidArgumentException $e) {
            if (!str_contains($e->getMessage(), 'APP_DRIVER_BENCH=1') || !str_contains($e->getMessage(), 'read-only')) {
                return 'the message is: ' . $e->getMessage();
            }
            continue;
        }
        return 'no exception for ' . json_encode($env);
    }
    return null;
});

check_case('APP_DRIVER=jsonb is refused, and the message names the variable, the value and the allowed ones', function () {
    try {
        app_variants(['APP_DRIVER' => 'jsonb']);
    } catch (InvalidArgumentException $e) {
        $message = $e->getMessage();
        return str_contains($message, 'APP_DRIVER') && str_contains($message, 'jsonb') && str_contains($message, 'pdo, ffi') ? null : "the message is: $message";
    }
    return 'no exception';
});

foreach ([['APP_FEED_SQL', 'join'], ['APP_FEED_SQL', 'two-step'], ['APP_FETCH', 'num'], ['APP_FETCH', 'assoc-loop']] as [$name, $value]) {
    check_case("APP_DRIVER=ffi with $name=$value is refused, and the message names both", function () use ($name, $value) {
        try {
            app_variants(FFI_ENV + [$name => $value]);
        } catch (InvalidArgumentException $e) {
            return str_contains($e->getMessage(), 'APP_DRIVER=ffi') && str_contains($e->getMessage(), "$name=$value") ? null : 'the message is: ' . $e->getMessage();
        }
        return 'no exception';
    });
}

check_case('the boot refuses a libsqlite3 that is not the version PDO runs, and says both', function () use ($dir) {
    $copy = "$dir/mismatch.db";
    copy("$dir/pdo.db", $copy);
    try {
        app_boot($copy, SECRET, app_variants(FFI_ENV), '1.2.3');
    } catch (RuntimeException $e) {
        $message = $e->getMessage();
        return str_contains($message, '1.2.3') && preg_match('/\b3\.\d+\.\d+\b/', $message) ? null : "the message is: $message";
    }
    return 'no exception';
});

// The reads: databases of 30 posts (a full feed), 3 posts (fewer than 20) and none.
foreach ([30, 3, 0] as $posts) {
    $source = "$dir/source-$posts.db";
    make_db($source, $posts);
    foreach (['encode', 'concat', 'sqlite'] as $json) {
        check_case("$posts posts, APP_JSON=$json: the FFI driver answers the PDO driver's bytes", fn () => same_answers(
            read_answers($source, FFI_ENV + ['APP_JSON' => $json], $posts),
            read_answers($source, ['APP_JSON' => $json], $posts)));
    }
    foreach (['mmap-off', 'cache-8m'] as $preset) {
        check_case("$posts posts, APP_PRAGMAS=$preset: the FFI driver answers the PDO driver's bytes", fn () => same_answers(
            read_answers($source, FFI_ENV + ['APP_PRAGMAS' => $preset], $posts),
            read_answers($source, ['APP_PRAGMAS' => $preset], $posts)));
    }
}

// The reference's literal bytes, written by hand, with the FFI driver.
check_case('2 posts: the feed and a post are the literal bytes, with each APP_JSON value', function () use ($dir) {
    $path = "$dir/literal.db";
    $db = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
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
    foreach (['encode', 'concat', 'sqlite'] as $json) {
        boot_copy($path, FFI_ENV + ['APP_JSON' => $json], 'literal-copy');
        $got = [handler_handle('GET', '/feed', '', ''), handler_handle('GET', '/posts/1', '', '')];
        if ($got !== [[200, $feed], [200, $post]]) {
            return "$json answered " . json_encode($got);
        }
    }
    return null;
});

// Rows that stress the reading: the escapes of the JSON cases, a text with a NUL byte in it (read by its length, not up to the NUL), and a
// 500 character body with accents.
check_case('rows with escapes, a NUL byte and a long accented body read back as PDO reads them, with each APP_JSON value', function () use ($dir) {
    $path = "$dir/stress.db";
    $db = new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $db->exec("
      CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE, created_at TEXT NOT NULL DEFAULT 'x');
      CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL, body TEXT NOT NULL, created_at TEXT NOT NULL);
      CREATE TABLE likes (user_id INTEGER NOT NULL, post_id INTEGER NOT NULL, created_at TEXT NOT NULL DEFAULT 'x', PRIMARY KEY (user_id, post_id));
      CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);
      CREATE INDEX likes_post_id_idx ON likes (post_id);
      INSERT INTO likes (user_id, post_id) VALUES (1, 1), (1, 2), (2, 2), (3, 3);
    ");
    $db->prepare('INSERT INTO users (id, username) VALUES (1, ?), (2, ?)')->execute(["o\"b\\r/\u{2028}ien", "zoë😀"]);
    $bodies = ["a\0b", "q\" b\\ s/ t\t c\x01\x08\x0c\r\x1f\x7f u\u{2028}\u{2029} e😀 é", str_repeat('é', 500)];
    foreach ($bodies as $i => $body) {
        $db->prepare('INSERT INTO posts (id, user_id, body, created_at) VALUES (?, ?, ?, ?)')->execute([$i + 1, ($i % 2) + 1, $body, sprintf('2025-01-01T00:00:0%d.000Z', $i)]);
    }
    unset($db);
    foreach (['encode', 'concat', 'sqlite'] as $json) {
        $got = read_answers($path, FFI_ENV + ['APP_JSON' => $json], 3);
        $want = read_answers($path, ['APP_JSON' => $json], 3);
        if ($why = same_answers($got, $want)) {
            return "$json: $why";
        }
    }
    // The NUL really is in the answer (a read up to the NUL would have cut it): the keys of the golden are not what pins this.
    boot_copy($path, FFI_ENV, 'nul');
    [$status, $body] = handler_handle('GET', '/posts/1', '', '');
    return $status === 200 && str_contains($body, '"body":"a\u0000b"') ? null : "the post with a NUL answered $status $body";
});

// The connection: the pragmas are the PDO connection's.
$pragmas = ['journal_mode', 'synchronous', 'busy_timeout', 'cache_size', 'mmap_size', 'temp_store', 'locking_mode'];
foreach (['default' => [], 'mmap-off' => ['APP_PRAGMAS' => 'mmap-off'], 'cache-8m' => ['APP_PRAGMAS' => 'cache-8m'], 'exclusive' => ['APP_LOCKING' => 'exclusive']] as $label => $env) {
    check_case("the FFI connection has the PDO connection's pragmas ($label)", function () use ($dir, $pragmas, $env) {
        global $app_db, $app_ffi;
        $read = static function (array $env) use ($dir, $pragmas): array {
            global $app_db, $app_ffi;
            boot_copy("$dir/source-30.db", $env);
            $got = [];
            foreach ($pragmas as $pragma) {
                $got[$pragma] = $app_ffi !== null ? $app_ffi->scalar("PRAGMA $pragma") : (string) $app_db['db']->query("PRAGMA $pragma")->fetchColumn();
            }
            $app_db = $app_ffi = null;
            return $got;
        };
        $want = $read($env);
        $got = $read($env + FFI_ENV);
        return $got === $want && $got['journal_mode'] === 'wal' && $got['busy_timeout'] === '5000' ? null : 'FFI ' . json_encode($got) . ' against PDO ' . json_encode($want);
    });
}

// A statement left un-reset keeps a read transaction open, and a writer on another connection then cannot checkpoint or, in a rollback-journal
// database, cannot commit. Here: after reads, another connection with no wait must be able to write and the WAL must be restartable.
check_case('after the reads, no statement holds a read transaction: another connection writes at once and the WAL checkpoints fully', function () use ($dir) {
    global $app_ffi;
    $copy = boot_copy("$dir/source-30.db", FFI_ENV + ['APP_JSON' => 'sqlite']);
    handler_handle('GET', '/feed', '', '');
    handler_handle('GET', '/posts/5', '', '');
    handler_handle('GET', '/posts/99', '', '');
    $other = new PDO('sqlite:' . $copy, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $other->exec('PRAGMA busy_timeout = 0');
    $other->exec("INSERT INTO posts (user_id, body) VALUES (1, 'from another connection')");
    $result = $other->query('PRAGMA wal_checkpoint(TRUNCATE)')->fetch(PDO::FETCH_NUM);
    return $result[0] === 0 ? null : 'the checkpoint was blocked: ' . json_encode($result);
});

exit($failed ? 1 : 0);
