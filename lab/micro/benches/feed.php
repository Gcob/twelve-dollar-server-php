<?php
// The S6 variants of the feed (lab/app/app.php): what one GET /feed costs in the app, per variant, on a warm copy of the seed. The
// cases that end in a route run route_feed(), the query and the JSON of the answer; the "query" cases stop at the rows. Format:
// "Micro benchmarks" in lab/README.md. The EXPLAIN QUERY PLAN of each variant: lab/micro/feed-plans.php.
//
// Every case checks its answer against the reference's, computed in the same process by the unset variant: the same rows, the same bytes.
// The 20 newest posts get 0 to 50 more likes first (the bench's likes go to the newest posts, as a feed's readers see them): the same
// likes for every case, added once to the copy.

require_once __DIR__ . '/../../app/app.php';

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
 *
 * @param array<string, string> $env
 */
function feed_bench_case(array $env, Closure $run): array
{
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
        'check' => fn ($result, array $ctx) => $result === $ctx['expected'] ? true : 'the answer differs from the reference variant\'s: ' . json_encode($result) . ' against ' . json_encode($ctx['expected']),
    ];
}

$cases = [];
$feed = static fn () => route_feed();
foreach (APP_FEED_SQL_VARIANTS as $sql) {
    foreach (APP_FETCH_VARIANTS as $fetch) {
        $cases["feed/$sql/$fetch"] = feed_bench_case(['APP_FEED_SQL' => $sql, 'APP_FETCH' => $fetch], $feed);
    }
}
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
return $cases;
