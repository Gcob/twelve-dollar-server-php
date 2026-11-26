<?php
// Reads the plan of the submission's single-post query, without timing anything (lab/post-plan.sh runs this in a lab image).
//
//   php -d ffi.enable=1 post-plan.php <database copy> <the submission's app.php> [--force-reprepare]
//
// SQLite re-prepares a prepared statement when a bound value could change its plan (only when it was built with ENABLE_STAT4) and when
// the schema changes. Each re-prepare costs the statement's whole compile, on every request that triggers it. This script reads the
// counter SQLITE_STMTSTATUS_REPREPARE after 10,000 executions, for the submission's `p.id = ?` and for the same SQL with `p.id = +?`
// (the form that made another entry's re-prepared plan cheaper), through FFI the way the app's FFI driver runs a statement (prepared once
// with the persistent hint, the id bound as text like PDO's execute([...]), stepped to the end, reset). It also prints both
// EXPLAIN QUERY PLANs. The last line is `post-plan: closed` or `post-plan: timing needed (<why>)`.
//
// --force-reprepare is the check's fixture: a schema change halfway through the executions, which expires the statements, so the counter
// has to move. Exit 0 when it reports, 1 on an error (no FFI, no database, no SQL found).

const POST_PLAN_EXECUTIONS = 10000;
const POST_PLAN_SQLITE_ROW = 100;
const POST_PLAN_SQLITE_DONE = 101;
const POST_PLAN_PREPARE_PERSISTENT = 0x1;
const POST_PLAN_OPEN_READWRITE = 0x2;
const POST_PLAN_STMTSTATUS_REPREPARE = 5;
const POST_PLAN_STMTSTATUS_RUN = 6;

// Why: the last parameter of sqlite3_bind_text is SQLITE_TRANSIENT, the pointer value -1 ("copy the text now"). It is declared as an
// integer so that FFI passes -1 as it is: the register is the same on x86-64 and arm64, and a NULL there would leave SQLite pointing at
// a string PHP frees as soon as the call returns.
const POST_PLAN_CDEF = '
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;
    const char *sqlite3_libversion(void);
    int sqlite3_compileoption_used(const char *name);
    int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
    int sqlite3_close_v2(sqlite3 *db);
    int sqlite3_busy_timeout(sqlite3 *db, int ms);
    int sqlite3_exec(sqlite3 *db, const char *sql, void *callback, void *arg, char **errmsg);
    int sqlite3_prepare_v3(sqlite3 *db, const char *sql, int nByte, unsigned int prepFlags, sqlite3_stmt **ppStmt, const char **pzTail);
    int sqlite3_step(sqlite3_stmt *stmt);
    int sqlite3_reset(sqlite3_stmt *stmt);
    int sqlite3_finalize(sqlite3_stmt *stmt);
    int sqlite3_bind_text(sqlite3_stmt *stmt, int index, const char *text, int nBytes, intptr_t destructor);
    int sqlite3_stmt_status(sqlite3_stmt *stmt, int op, int resetFlag);
    const char *sqlite3_column_text(sqlite3_stmt *stmt, int column);
    const char *sqlite3_errmsg(sqlite3 *db);
';

function post_plan_fail(string $message): never
{
    fwrite(STDERR, "post-plan: $message\n");
    exit(1);
}

/** The submission's single-post SQL, read from its source: the two constants are evaluated, not retyped. */
function post_plan_submission_sql(string $appFile): string
{
    $source = @file_get_contents($appFile);
    if ($source === false) {
        post_plan_fail("cannot read $appFile");
    }
    if (preg_match_all('/^const APP_(?:POST|ONE_POST)_SELECT = [^;]*;$/m', $source, $matches) !== 2) {
        post_plan_fail("$appFile does not declare APP_POST_SELECT and APP_ONE_POST_SELECT as constants of its own");
    }
    eval(implode("\n", $matches[0]));
    return APP_ONE_POST_SELECT;
}

final class PostPlanDb
{
    public readonly FFI $ffi;
    private mixed $db;

    public function __construct(string $path)
    {
        try {
            $this->ffi = FFI::cdef(POST_PLAN_CDEF, PHP_OS_FAMILY === 'Darwin' ? 'libsqlite3.dylib' : 'libsqlite3.so.0');
        } catch (Throwable $e) {
            post_plan_fail('FFI cannot load libsqlite3 (is ffi.enable on?): ' . $e->getMessage());
        }
        $handle = $this->ffi->new('sqlite3*');
        if ($this->ffi->sqlite3_open_v2($path, FFI::addr($handle), POST_PLAN_OPEN_READWRITE, null) !== 0) {
            post_plan_fail("cannot open $path: " . $this->ffi->sqlite3_errmsg($handle));
        }
        $this->db = $handle;
        $this->ffi->sqlite3_busy_timeout($this->db, 60000);
    }

    public function exec(string $sql): void
    {
        if ($this->ffi->sqlite3_exec($this->db, $sql, null, null, null) !== 0) {
            post_plan_fail("$sql failed: " . $this->ffi->sqlite3_errmsg($this->db));
        }
    }

    public function prepare(string $sql): mixed
    {
        $handle = $this->ffi->new('sqlite3_stmt*');
        if ($this->ffi->sqlite3_prepare_v3($this->db, $sql, strlen($sql), POST_PLAN_PREPARE_PERSISTENT, FFI::addr($handle), null) !== 0) {
            post_plan_fail('cannot prepare the statement: ' . $this->ffi->sqlite3_errmsg($this->db));
        }
        return $handle;
    }

    /** One execution as the app's FFI driver does it: bind the id as text, step to the end, reset. Returns the number of rows. */
    public function run(mixed $statement, int $id): int
    {
        $ffi = $this->ffi;
        $text = (string) $id;
        $ffi->sqlite3_bind_text($statement, 1, $text, strlen($text), -1);
        $rows = 0;
        while (($rc = $ffi->sqlite3_step($statement)) === POST_PLAN_SQLITE_ROW) {
            $rows++;
        }
        $ffi->sqlite3_reset($statement);
        if ($rc !== POST_PLAN_SQLITE_DONE) {
            post_plan_fail('a step failed: ' . $ffi->sqlite3_errmsg($this->db));
        }
        return $rows;
    }

    /** The detail column of each row of the statement's EXPLAIN QUERY PLAN, in order. */
    public function plan(string $sql, int $id): array
    {
        $ffi = $this->ffi;
        $statement = $this->prepare('EXPLAIN QUERY PLAN ' . $sql);
        $text = (string) $id;
        $ffi->sqlite3_bind_text($statement, 1, $text, strlen($text), -1);
        $details = [];
        while ($ffi->sqlite3_step($statement) === POST_PLAN_SQLITE_ROW) {
            $details[] = $ffi->sqlite3_column_text($statement, 3);
        }
        $ffi->sqlite3_finalize($statement);
        return $details;
    }

    public function status(mixed $statement, int $op): int
    {
        return $this->ffi->sqlite3_stmt_status($statement, $op, 0);
    }
}

[$script, $copy, $appFile] = $argv + [null, null, null];
$forceReprepare = in_array('--force-reprepare', $argv, true);
if ($copy === null || $appFile === null) {
    post_plan_fail('usage: post-plan.php <database copy> <the submission\'s app.php> [--force-reprepare]');
}
if (!extension_loaded('FFI')) {
    post_plan_fail('this PHP has no FFI extension: the script needs it to read the statement counters');
}
if (!is_file($copy)) {
    post_plan_fail("$copy is missing");
}

$reference = post_plan_submission_sql($appFile);
$forms = [
    'p.id = ?' => $reference,
    'p.id = +?' => str_replace('p.id = ?', 'p.id = +?', $reference),
];
if ($forms['p.id = +?'] === $reference) {
    post_plan_fail('the submission\'s single-post SQL has no `p.id = ?` to turn into `p.id = +?`');
}

// Existing post ids, picked at random with a fixed seed: the same executions on every run.
$pdo = new PDO('sqlite:' . $copy, null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$ids = $pdo->query('SELECT id FROM posts')->fetchAll(PDO::FETCH_COLUMN);
unset($pdo);
if ($ids === []) {
    post_plan_fail('the database has no post');
}
mt_srand(8);
$picked = [];
for ($i = 0; $i < POST_PLAN_EXECUTIONS; $i++) {
    $picked[] = (int) $ids[mt_rand(0, count($ids) - 1)];
}
unset($ids);

$db = new PostPlanDb($copy);
$version = $db->ffi->sqlite3_libversion();
$stat4 = $db->ffi->sqlite3_compileoption_used('ENABLE_STAT4') === 1;
echo "sqlite: $version\n";
echo 'ENABLE_STAT4: ' . ($stat4 ? 'yes' : 'no') . "\n";

$counts = [];
$plans = [];
foreach ($forms as $label => $sql) {
    $statement = $db->prepare($sql);
    $found = 0;
    foreach ($picked as $n => $id) {
        $found += $db->run($statement, $id);
        if ($forceReprepare && $n === intdiv(POST_PLAN_EXECUTIONS, 2)) {
            // Why: any schema change expires every prepared statement; a table of its own leaves the plans as they are.
            $db->exec('CREATE TABLE post_plan_fixture (x)');
        }
    }
    $counts[$label] = $db->status($statement, POST_PLAN_STMTSTATUS_REPREPARE);
    $plans[$label] = $db->plan($sql, $picked[0]);
    echo "\nform: $label\n";
    echo '  executions: ' . POST_PLAN_EXECUTIONS . " ($found rows)\n";
    echo '  SQLITE_STMTSTATUS_RUN: ' . $db->status($statement, POST_PLAN_STMTSTATUS_RUN) . "\n";
    echo '  SQLITE_STMTSTATUS_REPREPARE: ' . $counts[$label] . "\n";
    echo "  EXPLAIN QUERY PLAN:\n";
    foreach ($plans[$label] as $detail) {
        echo "    $detail\n";
    }
    $forceReprepare = false;
}
echo "\n";

$reasons = [];
foreach ($counts as $label => $count) {
    if ($count !== 0) {
        $reasons[] = "$label re-prepared $count times in " . POST_PLAN_EXECUTIONS . ' executions';
    }
}
if ($plans['p.id = ?'] !== $plans['p.id = +?']) {
    $reasons[] = 'the two forms have different plans';
}
echo $reasons === [] ? "post-plan: closed\n" : 'post-plan: timing needed (' . implode('; ', $reasons) . ")\n";
