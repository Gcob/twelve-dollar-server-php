<?php
// The training of the SQLite that install.sh builds: it makes a database with the challenge's schema at the seed's sizes, then runs the
// app's own statements on it, so that the profile the compiler reads describes the work of this server and nothing else. The seed
// database is never read.
//
//   php sqlite-train.php generate <database> [--scale 1]
//   php sqlite-train.php run <app.php> <database> [--loops 30000]
//
// The two steps are two processes on purpose: the library is instrumented while it runs, so everything it does before exit lands in the
// profile. install.sh deletes the profile between the two, and the bulk inserts of `generate` (2.5 million rows) never reach it.
//
// generate: 50,000 users, 500,000 posts, about 2,000,000 likes (the seed's sizes and shapes, from the same kind of generator: one PRNG with
// a fixed seed, authors skewed toward low ids, likes per post exponential with 1 % popular posts), then ANALYZE (the seed has sqlite_stat1).
// The schema is the challenge's schema.sql, copied below: the bench clones this folder, and nothing guarantees where the challenge's
// own folder is when install.sh runs.
//
// run: opens the database with the app's pragmas, prepares the app's statements once as the app does, and runs one loop of the bench's
// journey `--loops` times: GET /feed, GET /posts/:id of one post of that feed, a like with 15 % chance (the existence check, then the
// insert ON CONFLICT DO NOTHING, a fifth of them on a pair that is already there), a new post with 2 % chance. Writes are 0.17 of 2.17
// requests, 7.8 %. A GET /health every 50 loops, so that its path is not cold. The SQL is read from app.php, never retyped.
// It prints one line, `training: <n> statements (...)`, and exits 1 when n is 0: a profile of nothing would optimise nothing.
//
// Exit 0 when it did its step, 1 on an error.

const TRAIN_SEED = 42;
const TRAIN_USERS = 50000;
const TRAIN_POSTS = 500000;
const TRAIN_LIKES = 2000000;
const TRAIN_DEFAULT_LOOPS = 30000;
const TRAIN_LIKE_PROBABILITY = 0.15;
const TRAIN_POST_PROBABILITY = 0.02;
const TRAIN_REPEATED_LIKE_PROBABILITY = 0.2;
const TRAIN_HEALTH_EVERY = 50;
const TRAIN_DAY_MS = 86400000;

const TRAIN_SCHEMA = <<<'SQL'
-- The database every submission uses (SQLite). seed/make-seed.sh builds seed/feed.db from it.
-- The schema is fixed: submissions may not add or change tables, columns, indexes or triggers.
-- Timestamps are TEXT in the exact wire format (YYYY-MM-DDTHH:MM:SS.mmmZ, UTC), which also sorts correctly.
CREATE TABLE users (
  id          INTEGER PRIMARY KEY,
  username    TEXT NOT NULL UNIQUE,
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE posts (
  id          INTEGER PRIMARY KEY,
  user_id     INTEGER NOT NULL REFERENCES users(id),
  body        TEXT NOT NULL CHECK (length(body) BETWEEN 1 AND 500),
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now'))
);

CREATE TABLE likes (
  user_id     INTEGER NOT NULL REFERENCES users(id),
  post_id     INTEGER NOT NULL REFERENCES posts(id),
  created_at  TEXT NOT NULL DEFAULT (strftime('%Y-%m-%dT%H:%M:%fZ', 'now')),
  PRIMARY KEY (user_id, post_id)
);

CREATE INDEX posts_created_at_id_idx ON posts (created_at DESC, id DESC);
CREATE INDEX posts_user_id_idx       ON posts (user_id);
CREATE INDEX likes_post_id_idx       ON likes (post_id);
SQL;

function train_fail(string $message): never
{
    fwrite(STDERR, "sqlite-train: $message\n");
    exit(1);
}

/** A float in [0, 1) from PHP's seeded Mt19937. */
function train_rand(): float
{
    return mt_rand() / (mt_getrandmax() + 1);
}

function train_timestamp(int $ms): string
{
    return gmdate('Y-m-d\TH:i:s', intdiv($ms, 1000)) . sprintf('.%03dZ', $ms % 1000);
}

function train_post_body(): string
{
    static $words = ['the', 'a', 'and', 'but', 'so', 'because', 'just', 'really', 'very', 'maybe', 'server', 'database', 'request', 'latency',
        'cache', 'index', 'query', 'benchmark', 'cpu', 'memory', 'disk', 'network', 'users', 'coffee', 'morning', 'project', 'deploy',
        'release', 'bug', 'feature', 'test', 'rewrite', 'refactor', 'commit', 'thinking', 'building', 'shipping', 'learning', 'debugging',
        'measuring', 'fast', 'slow', 'small', 'big', 'cheap', 'simple', 'boring', 'weird', 'honest', 'careful', 'today', 'tomorrow', 'never'];
    $sentences = [];
    for ($s = mt_rand(1, 3); $s > 0; $s--) {
        $picked = [];
        for ($w = mt_rand(4, 14); $w > 0; $w--) {
            $picked[] = $words[mt_rand(0, count($words) - 1)];
        }
        $sentences[] = ucfirst(implode(' ', $picked)) . '.';
    }
    return implode(' ', $sentences);
}

function train_open(string $path): PDO
{
    return new PDO('sqlite:' . $path, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE => PDO::FETCH_ASSOC]);
}

function train_generate(string $path, float $scale): void
{
    foreach ([$path, "$path-wal", "$path-shm"] as $stale) {
        if (is_file($stale)) {
            unlink($stale);
        }
    }
    $users = max(1, (int) round(TRAIN_USERS * $scale));
    $posts = max(1, (int) round(TRAIN_POSTS * $scale));
    $likes = (int) round(TRAIN_LIKES * $scale);
    mt_srand(TRAIN_SEED);

    $db = train_open($path);
    $db->exec('PRAGMA journal_mode = WAL');
    $db->exec('PRAGMA synchronous = OFF');
    $db->exec('PRAGMA cache_size = -262144');
    $db->exec(TRAIN_SCHEMA);

    $end = 1767225600000; // 2026-01-01T00:00:00Z
    $adjectives = ['quiet', 'brave', 'clever', 'sunny', 'rusty', 'swift', 'lazy', 'mellow', 'sharp', 'wild'];
    $nouns = ['otter', 'falcon', 'badger', 'comet', 'river', 'maple', 'pixel', 'walrus', 'ember', 'glacier'];
    $db->beginTransaction();
    $insert = $db->prepare('INSERT INTO users (id, username, created_at) VALUES (?, ?, ?)');
    for ($id = 1; $id <= $users; $id++) {
        $name = $adjectives[mt_rand(0, 9)] . '_' . $nouns[mt_rand(0, 9)] . '_' . $id;
        $insert->execute([$id, $name, train_timestamp($end - 730 * TRAIN_DAY_MS + (int) (train_rand() * 365 * TRAIN_DAY_MS))]);
    }
    $db->commit();

    // Posts are spread evenly over 2025 in id order, with a small jitter; authorship is skewed toward low user ids.
    $step = 365 * TRAIN_DAY_MS / $posts;
    $start = $end - 365 * TRAIN_DAY_MS;
    $db->beginTransaction();
    $insert = $db->prepare('INSERT INTO posts (id, user_id, body, created_at) VALUES (?, ?, ?, ?)');
    for ($id = 1; $id <= $posts; $id++) {
        $author = 1 + (int) ($users * train_rand() * train_rand());
        $insert->execute([$id, $author, train_post_body(), train_timestamp((int) ($start + ($id - 1) * $step + train_rand() * $step * 0.9))]);
    }
    $db->commit();

    // Likes per post: exponential around the mean, 1 % of the posts "popular" at 20 times it. Distinct users for a post.
    $mean = $likes / $posts;
    $popularMean = $mean * 20;
    $normalMean = max(0.05, ($mean - 0.01 * $popularMean + 0.5) / 0.99);
    $cap = min($users, max(50, (int) round($popularMean * 10)));
    $db->beginTransaction();
    $insert = $db->prepare('INSERT INTO likes (user_id, post_id) VALUES (?, ?)');
    $total = 0;
    for ($post = 1; $post <= $posts; $post++) {
        $n = min($cap, (int) (-(train_rand() < 0.01 ? $popularMean : $normalMean) * log(1 - train_rand())));
        $seen = [];
        while (count($seen) < $n) {
            $seen[mt_rand(1, $users)] = true;
        }
        foreach ($seen as $user => $_) {
            $insert->execute([$user, $post]);
        }
        $total += $n;
    }
    $db->commit();

    $db->exec('ANALYZE');
    $db->exec('PRAGMA wal_checkpoint(TRUNCATE)');
    echo "generated: $users users, $posts posts, $total likes\n";
}

/**
 * The submission's SQL and pragmas, read from its source: the constants and the pragma function are evaluated, the six statements are
 * the strings of its app_boot(). Fails clearly when the file changes shape.
 *
 * @return array{pragmas: list<string>, sql: array<string, string>}
 */
function train_read_app(string $appFile): array
{
    $source = @file_get_contents($appFile);
    if ($source === false) {
        train_fail("cannot read $appFile");
    }
    if (preg_match_all('/^const APP_(?:POST_SELECT|FEED_SELECT|ONE_POST_SELECT|CACHE_SIZE|MMAP_SIZE) = [^;]*;$/m', $source, $constants) !== 5) {
        train_fail("$appFile does not declare its five SQL and pragma constants as expected");
    }
    if (preg_match('/^function app_connection_pragmas\(\): array\n\{.*?^\}$/ms', $source, $function) !== 1) {
        train_fail("$appFile has no app_connection_pragmas()");
    }
    eval(implode("\n", $constants[0]) . "\n" . $function[0]);
    $sql = ['feed' => APP_FEED_SELECT, 'post' => APP_ONE_POST_SELECT];
    foreach (['post_insert', 'post_exists', 'like_insert', 'health'] as $key) {
        if (preg_match("/'$key' => \\\$db->prepare\\('([^']*)'\\)/", $source, $match) !== 1) {
            train_fail("$appFile does not prepare '$key' as expected");
        }
        $sql[$key] = $match[1];
    }
    return ['pragmas' => app_connection_pragmas(), 'sql' => $sql];
}

function train_run(string $appFile, string $path, int $loops): void
{
    if (!is_file($path)) {
        train_fail("the database $path does not exist (run the generate step first)");
    }
    $app = train_read_app($appFile);
    mt_srand(TRAIN_SEED + 1);
    $db = train_open($path);
    foreach ($app['pragmas'] as $pragma) {
        $db->exec($pragma);
    }
    $statements = array_map(static fn (string $sql): PDOStatement => $db->prepare($sql), $app['sql']);
    $users = (int) $db->query('SELECT max(id) FROM users')->fetchColumn();
    $count = ['feed' => 0, 'post' => 0, 'post_exists' => 0, 'like_insert' => 0, 'post_insert' => 0, 'health' => 0];
    $lastLike = [1, 1];

    for ($loop = 1; $loop <= $loops; $loop++) {
        $statements['feed']->execute();
        $feed = $statements['feed']->fetchAll();
        $count['feed']++;
        if ($feed === []) {
            train_fail('the feed is empty: the database has no posts');
        }
        $id = $feed[mt_rand(0, count($feed) - 1)]['id'];

        $statements['post']->execute([$id]);
        $statements['post']->fetch();
        $statements['post']->closeCursor();
        $count['post']++;

        if (train_rand() < TRAIN_LIKE_PROBABILITY) {
            $pair = train_rand() < TRAIN_REPEATED_LIKE_PROBABILITY ? $lastLike : [mt_rand(1, $users), $id];
            $statements['post_exists']->execute([$pair[1]]);
            $statements['post_exists']->fetch();
            $statements['post_exists']->closeCursor();
            $statements['like_insert']->execute($pair);
            $statements['like_insert']->rowCount();
            $count['post_exists']++;
            $count['like_insert']++;
            $lastLike = $pair;
        }

        if (train_rand() < TRAIN_POST_PROBABILITY) {
            try {
                $statements['post_insert']->execute([mt_rand(1, $users), train_post_body()]);
                $statements['post_insert']->fetchAll();
            } finally {
                $statements['post_insert']->closeCursor();
            }
            $count['post_insert']++;
        }

        if ($loop % TRAIN_HEALTH_EVERY === 0) {
            $statements['health']->execute();
            $count['health']++;
        }
    }

    $total = array_sum($count);
    $parts = [];
    foreach ($count as $name => $n) {
        $parts[] = "$name $n";
    }
    echo "training: $total statements (" . implode(', ', $parts) . ")\n";
    if ($total === 0) {
        train_fail('the training ran no statement: a profile of nothing would optimise nothing');
    }
}

$args = array_slice($argv, 1);
$step = array_shift($args);
if ($step === 'generate' && count($args) >= 1) {
    $scale = 1.0;
    if (count($args) === 3 && $args[1] === '--scale') {
        $scale = (float) $args[2];
    } elseif (count($args) !== 1) {
        train_fail('usage: sqlite-train.php generate <database> [--scale 1]');
    }
    if ($scale <= 0) {
        train_fail('--scale must be above 0');
    }
    train_generate($args[0], $scale);
} elseif ($step === 'run' && count($args) >= 2) {
    $loops = TRAIN_DEFAULT_LOOPS;
    if (count($args) === 4 && $args[2] === '--loops') {
        $loops = (int) $args[3];
    } elseif (count($args) !== 2) {
        train_fail('usage: sqlite-train.php run <app.php> <database> [--loops 30000]');
    }
    if ($loops < 0) {
        train_fail('--loops must be 0 or more');
    }
    train_run($args[0], $args[1], $loops);
} else {
    train_fail("usage: sqlite-train.php generate <database> [--scale 1]\n       sqlite-train.php run <app.php> <database> [--loops 30000]");
}
