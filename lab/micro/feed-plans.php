<?php
// The EXPLAIN QUERY PLAN of every statement of the S6 variants (lab/app/app.php), on a copy of the seed (the plan depends on the schema's
// indexes and on SQLite's version, not on the likes). Run: bash lab/run.sh 8.5 php /lab/micro/feed-plans.php

require __DIR__ . '/../app/app.php';

$copy = sys_get_temp_dir() . '/plans-feed.db';
if (!copy('/lab/data/feed.db', $copy)) {
    fwrite(STDERR, "cannot copy /lab/data/feed.db (run lab/seed.sh)\n");
    exit(1);
}
$db = new PDO('sqlite:' . $copy, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]);
echo 'SQLite ', $db->query('SELECT sqlite_version()')->fetchColumn(), "\n";

/** Prints the plan of $sql, the nesting of its rows shown by indentation. */
function plan(PDO $db, string $title, string $sql): void
{
    echo "\n== $title\n";
    $rows = $db->query('EXPLAIN QUERY PLAN ' . $sql)->fetchAll();
    $depth = [0 => 0];
    foreach ($rows as $row) {
        $depth[$row['id']] = ($depth[$row['parent']] ?? 0) + 1;
        echo str_repeat('  ', $depth[$row['id']] - 1), $row['detail'], "\n";
    }
}

foreach (APP_FEED_SQL_VARIANTS as $variant) {
    plan($db, "GET /feed, APP_FEED_SQL=$variant" . ($variant === 'two-step' ? ' (statement 1 of 2)' : ''), app_feed_sql($variant));
}
plan($db, 'GET /feed, APP_FEED_SQL=two-step (statement 2 of 2)', app_feed_likes_sql());
foreach (['reference', 'join'] as $variant) {
    plan($db, "GET /posts/:id, APP_FEED_SQL=$variant", app_post_sql($variant));
}
plan($db, 'GET /feed, APP_JSON=sqlite', app_feed_json_sql());
plan($db, 'GET /posts/:id, APP_JSON=sqlite', app_post_json_sql());
