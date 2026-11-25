<?php
// post_insert() of the submission (submissions/php-Gcob/app.php): a new post is committed when the function returns, and a commit that fails
// is an exception (the route answers 500), never a row that was rolled back.
//
// A deferred foreign key is how a commit is made to fail on purpose: SQLite checks it at the commit, after the row was inserted.
//
// Run: LAB_RUN_SUBMISSIONS=1 bash lab/run.sh 8.5 php /lab/check/post-insert-test.php

require __DIR__ . '/../../submissions/php-Gcob/app.php';

$dir = sys_get_temp_dir() . '/post-insert-test-' . getmypid();
mkdir($dir);
register_shutdown_function(fn () => array_map('unlink', glob($dir . '/*')) && rmdir($dir));

$setup = new PDO("sqlite:$dir/feed.db", null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$setup->exec("
  CREATE TABLE users (id INTEGER PRIMARY KEY, username TEXT NOT NULL UNIQUE);
  CREATE TABLE posts (id INTEGER PRIMARY KEY, user_id INTEGER NOT NULL REFERENCES users(id) DEFERRABLE INITIALLY DEFERRED,
                      body TEXT NOT NULL, created_at TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')));
  CREATE TABLE likes (user_id INTEGER NOT NULL, post_id INTEGER NOT NULL, PRIMARY KEY (user_id, post_id));
  INSERT INTO users (id, username) VALUES (1, 'ada');
");
$setup->exec('PRAGMA journal_mode = wal');
unset($setup);

app_boot("$dir/feed.db", 'a-secret');
global $app_db;
$app_db['db']->exec('PRAGMA foreign_keys = ON');

// A second connection to the same file: it sees only what is committed.
$reader = new PDO("sqlite:$dir/feed.db", null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]);
$failed = false;

function check_case(string $name, callable $fn): void
{
    global $failed;
    try {
        $why = $fn();
    } catch (Throwable $e) {
        $why = get_class($e) . ': ' . $e->getMessage();
    }
    echo $why === null ? "ok    $name\n" : "FAIL  $name: $why\n";
    $failed = $failed || $why !== null;
}

check_case('a new post is committed when post_insert returns: a second connection reads it', function () use ($reader) {
    $row = post_insert(1, 'hello');
    $seen = $reader->query('SELECT id, body FROM posts WHERE id = ' . (int) $row['id'])->fetch();
    return $seen === ['id' => $row['id'], 'body' => 'hello'] ? null : 'the second connection reads ' . json_encode($seen) . ' for the row ' . json_encode($row);
});

check_case('a commit that fails is an exception, and nothing is left behind', function () use ($reader) {
    $before = (int) $reader->query('SELECT COUNT(*) FROM posts')->fetchColumn();
    try {
        $row = post_insert(999, 'no such user');
        return 'it returned ' . json_encode($row) . ' for a post whose commit failed';
    } catch (PDOException) {
        // The expected path.
    }
    $after = (int) $reader->query('SELECT COUNT(*) FROM posts')->fetchColumn();
    $next = post_insert(1, 'the connection still works');
    return $after === $before && isset($next['id']) ? null : "posts went from $before to $after, or the next insert did not work";
});

exit($failed ? 1 : 0);
