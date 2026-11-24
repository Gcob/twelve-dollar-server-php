<?php
// The S6 variants of the feed (lab/app/app.php): what one GET /feed costs in the app, per variant, on a warm copy of the seed. The
// cases that end in a route run route_feed(), the query and the JSON of the answer; the "query" cases stop at the rows. Format:
// "Micro benchmarks" in lab/README.md. The EXPLAIN QUERY PLAN of each variant: lab/micro/feed-plans.php.
//
// Every case checks its answer against the reference's, computed in the same process by the unset variant: the same rows, the same bytes
// (APP_JSON=sqlite: the same decoded value, its bytes can differ from PHP's on U+2028 and U+2029, which the seed's rows don't hold).
// The 20 newest posts get 0 to 50 more likes first (the bench's likes go to the newest posts, as a feed's readers see them): the same
// likes for every case, added once to the copy.

require_once __DIR__ . '/../../app/app.php';
require_once __DIR__ . '/../../app/sqlite-ffi.php';

const FEED_BENCH_SECRET = 'bench-secret';
// Extra likes of the 20 newest posts, newest first (the seed's own 0 to 18 are still there).
const FEED_BENCH_LIKES = [0, 50, 25, 3, 12, 40, 7, 31, 0, 18, 44, 9, 27, 50, 1, 36, 15, 22, 5, 48];

/** Gives the 20 newest posts of the copy their likes (idempotent: a like that is there is ignored) and settles the WAL into the file. */
function feed_bench_likes(string $copy): void
{
    $db = new PDO('sqlite:' . $copy, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
    $ids = $db->query('SELECT id FROM posts ORDER BY created_at DESC, id DESC LIMIT 20')->fetchAll(PDO::FETCH_COLUMN);
    $insert = $db->prepare('INSERT OR IGNORE INTO likes (user_id, post_id) VALUES (?, ?)');
    $db->beginTransaction();
    foreach ($ids as $rank => $postId) {
        for ($user = 1; $user <= FEED_BENCH_LIKES[$rank]; $user++) {
            $insert->execute([$user, $postId]);
        }
    }
    $db->commit();
    $db->exec('PRAGMA wal_checkpoint(TRUNCATE)');
}

function feed_bench_boot(string $copy, array $env): void
{
    app_boot($copy, FEED_BENCH_SECRET, app_variants($env));
}

/**
 * One case: the variant's switches in $env, $run the timed call on the booted app, $reference what the unset variant answers to the same call.
 * With $decoded the answer is compared as [status, decoded body] instead of byte for byte (a route's answer only).
 *
 * @param array<string, string> $env
 */
function feed_bench_case(array $env, Closure $run, bool $decoded = false): array
{
    $same = static fn (mixed $a, mixed $b): bool => $decoded ? [$a[0], json_decode($a[1], true)] === [$b[0], json_decode($b[1], true)] : $a === $b;
    return [
        'setup' => function () use ($env, $run): array {
            $copy = micro_feed_copy();
            feed_bench_likes($copy);
            feed_bench_boot($copy, []);
            $expected = $run();
            feed_bench_boot($copy, $env);
            return ['expected' => $expected];
        },
        'run' => fn (array $ctx) => $run(),
        'check' => fn ($result, array $ctx) => $same($result, $ctx['expected']) ? true : 'the answer differs from the reference variant\'s: ' . json_encode($result) . ' against ' . json_encode($ctx['expected']),
    ];
}

/**
 * The statement of APP_JSON=sqlite run straight on libsqlite3 through FFI, with no class and no route around it: $read false steps it and resets it and
 * reads nothing (SQLite's own work, and the least any driver costs), true reads the text as well (what a driver adds at least). A fresh handle with the
 * app's pragmas on the same copy; the read's answer is checked against PDO's.
 */
function feed_bench_raw(bool $post, bool $read): array
{
    return [
        'setup' => function () use ($post): array {
            $copy = micro_feed_copy();
            feed_bench_likes($copy);
            feed_bench_boot($copy, ['APP_JSON' => 'sqlite']);
            $expected = $post ? post_query_json(500000) : feed_query_json();
            $ffi = sqlite_ffi_load();
            $db = $ffi->new('sqlite3*');
            $ffi->sqlite3_open_v2($copy, FFI::addr($db), 0x2, null);
            foreach (app_connection_pragmas(app_variants([]), APP_PRAGMA_DEFAULT) as $pragma) {
                $ffi->sqlite3_exec($db, $pragma, null, null, null);
            }
            $sql = $post ? app_post_json_sql() : app_feed_json_sql();
            $statement = $ffi->new('sqlite3_stmt*');
            $ffi->sqlite3_prepare_v3($db, $sql, strlen($sql), 1, FFI::addr($statement), null);
            return ['expected' => $expected, 'ffi' => $ffi, 'db' => $db, 'statement' => $statement];
        },
        'run' => function (array $ctx) use ($post, $read) {
            $ffi = $ctx['ffi'];
            $statement = $ctx['statement'];
            if ($post) {
                $ffi->sqlite3_bind_int64($statement, 1, 500000);
            }
            $rc = $ffi->sqlite3_step($statement);
            $json = $read ? $ffi->sqlite3_column_text($statement, 0) : $rc;
            $ffi->sqlite3_reset($statement);
            return $json;
        },
        'check' => fn ($result, array $ctx) => ($read ? $result === $ctx['expected'] : $result === 100) ? true : 'the raw read answered ' . json_encode($result),
    ];
}

$cases = [];
$feed = static fn () => route_feed();
foreach (APP_FEED_SQL_VARIANTS as $sql) {
    foreach (APP_FETCH_VARIANTS as $fetch) {
        $cases["feed/$sql/$fetch"] = feed_bench_case(['APP_FEED_SQL' => $sql, 'APP_FETCH' => $fetch], $feed);
    }
}
// The JSON built by concatenation and by SQLite, on the reference's SQL and the keyed rows (encode is the case above).
$cases['feed/reference/assoc, APP_JSON=concat'] = feed_bench_case(['APP_JSON' => 'concat'], $feed);
$cases['feed/reference/assoc, APP_JSON=sqlite'] = feed_bench_case(['APP_JSON' => 'sqlite'], $feed, true);
foreach (APP_PRAGMA_PRESETS as $preset => $values) {
    $cases["feed/reference/assoc, APP_PRAGMAS=$preset"] = feed_bench_case(['APP_PRAGMAS' => $preset], $feed);
}
// The query alone, rows as PDO gives them, without the JSON.
foreach (APP_FEED_SQL_VARIANTS as $sql) {
    $cases["feed query only/$sql/assoc"] = feed_bench_case(['APP_FEED_SQL' => $sql], static fn () => feed_query());
}
// One post by id (the newest, with the likes above): the join variant has its own statement, two-step reads it as the reference does.
$post = static fn () => route_post_get('500000');
$cases['post/reference/assoc'] = feed_bench_case([], $post);
$cases['post/join/assoc'] = feed_bench_case(['APP_FEED_SQL' => 'join'], $post);
$cases['post/reference/num'] = feed_bench_case(['APP_FETCH' => 'num'], $post);
$cases['post/reference/assoc, APP_JSON=concat'] = feed_bench_case(['APP_JSON' => 'concat'], $post);
$cases['post/reference/assoc, APP_JSON=sqlite'] = feed_bench_case(['APP_JSON' => 'sqlite'], $post, true);
// The driver: the same routes with PHP's FFI calling libsqlite3 instead of PDO (lab/app/sqlite-ffi.php), with the JSON of encode and of sqlite. The
// reference's answer is PDO's, so a driver that read a row differently would fail its check (the same bytes: both run the same SQLite and the same SQL).
$cases['feed/reference/assoc, APP_DRIVER=ffi'] = feed_bench_case(['APP_DRIVER' => 'ffi', 'APP_DRIVER_BENCH' => '1'], $feed);
$cases['feed/reference/assoc, APP_JSON=sqlite, APP_DRIVER=ffi'] = feed_bench_case(['APP_JSON' => 'sqlite', 'APP_DRIVER' => 'ffi', 'APP_DRIVER_BENCH' => '1'], $feed, true);
$cases['post/reference/assoc, APP_DRIVER=ffi'] = feed_bench_case(['APP_DRIVER' => 'ffi', 'APP_DRIVER_BENCH' => '1'], $post);
$cases['post/reference/assoc, APP_JSON=sqlite, APP_DRIVER=ffi'] = feed_bench_case(['APP_JSON' => 'sqlite', 'APP_DRIVER' => 'ffi', 'APP_DRIVER_BENCH' => '1'], $post, true);
// What the driver can save at most: the statement on libsqlite3 with nothing read, and with the text read, no class and no route around either.
$cases['feed/APP_JSON=sqlite statement on raw FFI, step and reset only'] = feed_bench_raw(false, false);
$cases['feed/APP_JSON=sqlite statement on raw FFI, text read'] = feed_bench_raw(false, true);
$cases['post/APP_JSON=sqlite statement on raw FFI, step and reset only'] = feed_bench_raw(true, false);
$cases['post/APP_JSON=sqlite statement on raw FFI, text read'] = feed_bench_raw(true, true);
return $cases;
