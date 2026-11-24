<?php
// APP_DRIVER=ffi: the app's reads run through PHP's FFI straight to the system's libsqlite3, instead of PDO (pdo_sqlite is a core
// extension that calls the same library). No C is compiled: FFI::cdef() is given the library's prototypes and nothing else.
//
// What PDO does that this has to do too:
// - the connection is opened for reading and writing, with the 60 s busy timeout pdo_sqlite sets at connect (the app's own
//   PRAGMA busy_timeout then replaces it), and the app's pragmas are the same statements in the same order (app_connection_pragmas);
// - every statement is prepared once at boot, with the hint that it will live as long as the connection;
// - a statement that is not finished keeps its transaction open: every use ends with sqlite3_reset, an error included;
// - an error is a PDOException with the message PDO gives (`SQLSTATE[HY000]: General error: 5 database is locked`), so the code that
//   catches PDO's (the connection's 500) is the same.
// The text of a column is read by its length (sqlite3_column_blob then sqlite3_column_bytes: the text's own bytes, no conversion), never up to
// a NUL byte. The one exception is the JSON SQLite builds: it never holds a raw NUL (JSON escapes it), so FFI's own string conversion of
// sqlite3_column_text (up to the NUL) gives all of it in one call. A number is bound with sqlite3_bind_int64
// (PDO's execute([...]) binds text and lets the column's affinity convert it: the stored value is the same).
//
// It reads only: the feed and the posts (the statements APP_JSON=encode and sqlite use). A micro bench priced it against PDO first
// (lab/micro/benches/feed.php, lab/micro/driver-run/README.md) and it saves nothing, so the writes, health and the group commit are not
// written, and the app boots it only for that bench (APP_DRIVER_BENCH=1).

const SQLITE_FFI_CDEF = '
    typedef struct sqlite3 sqlite3;
    typedef struct sqlite3_stmt sqlite3_stmt;
    const char *sqlite3_libversion(void);
    int sqlite3_open_v2(const char *filename, sqlite3 **ppDb, int flags, const char *zVfs);
    int sqlite3_close_v2(sqlite3 *db);
    int sqlite3_busy_timeout(sqlite3 *db, int ms);
    int sqlite3_exec(sqlite3 *db, const char *sql, void *callback, void *arg, char **errmsg);
    int sqlite3_prepare_v3(sqlite3 *db, const char *sql, int nByte, unsigned int prepFlags, sqlite3_stmt **ppStmt, const char **pzTail);
    int sqlite3_step(sqlite3_stmt *stmt);
    int sqlite3_reset(sqlite3_stmt *stmt);
    int sqlite3_finalize(sqlite3_stmt *stmt);
    int sqlite3_bind_int64(sqlite3_stmt *stmt, int index, int64_t value);
    int64_t sqlite3_column_int64(sqlite3_stmt *stmt, int column);
    const char *sqlite3_column_text(sqlite3_stmt *stmt, int column);
    const void *sqlite3_column_blob(sqlite3_stmt *stmt, int column);
    int sqlite3_column_bytes(sqlite3_stmt *stmt, int column);
    int sqlite3_errcode(sqlite3 *db);
    const char *sqlite3_errmsg(sqlite3 *db);
';

/** The system's libsqlite3 through FFI: only the prototypes above are declared. */
function sqlite_ffi_load(): FFI
{
    if (!extension_loaded('FFI')) {
        throw new RuntimeException('APP_DRIVER=ffi needs the FFI extension');
    }
    return FFI::cdef(SQLITE_FFI_CDEF, PHP_OS_FAMILY === 'Darwin' ? 'libsqlite3.dylib' : 'libsqlite3.so.0');
}

final class SqliteFfi
{
    private const OPEN_READWRITE = 0x2;
    private const PREPARE_PERSISTENT = 0x1;
    private const ROW = 100;
    private const DONE = 101;
    private const CONSTRAINT = 19;

    public readonly string $version;
    private readonly FFI $ffi;
    private mixed $db;
    /** @var list<mixed> every statement prepared on the connection, to finalize them before the close */
    private array $prepared = [];
    private mixed $feed;
    private mixed $post;

    /**
     * @param list<string> $pragmas the statements that set the connection up (app_connection_pragmas)
     * @param array{feed: string, post: string} $sql
     * @param string|null $pdoVersion the version PDO's SQLite says (read from a PDO connection when null); the two must be the same engine
     */
    public function __construct(string $path, array $pragmas, array $sql, ?string $pdoVersion = null)
    {
        $this->ffi = sqlite_ffi_load();
        $this->version = $this->ffi->sqlite3_libversion();
        $pdoVersion ??= (string) (new PDO('sqlite::memory:'))->query('SELECT sqlite_version()')->fetchColumn();
        if ($this->version !== $pdoVersion) {
            throw new RuntimeException("APP_DRIVER=ffi: libsqlite3 is SQLite {$this->version} but PDO runs SQLite $pdoVersion: the two drivers would not run the same engine");
        }
        $handle = $this->ffi->new('sqlite3*');
        $rc = $this->ffi->sqlite3_open_v2($path, FFI::addr($handle), self::OPEN_READWRITE, null);
        $this->db = $handle;
        if ($rc !== 0) {
            $error = $this->error();
            $this->ffi->sqlite3_close_v2($handle);
            $this->db = null;
            throw $error;
        }
        // Why: pdo_sqlite sets 60 s at connect, and the boot's first statements (the journal mode, with several processes opening the same
        // file) rely on it before the app's own busy_timeout pragma runs.
        $this->ffi->sqlite3_busy_timeout($this->db, 60000);
        foreach ($pragmas as $statement) {
            $this->exec($statement);
        }
        $this->feed = $this->prepare($sql['feed']);
        $this->post = $this->prepare($sql['post']);
    }

    public function __destruct()
    {
        if ($this->db === null) {
            return;
        }
        foreach ($this->prepared as $statement) {
            $this->ffi->sqlite3_finalize($statement);
        }
        $this->ffi->sqlite3_close_v2($this->db);
        $this->db = null;
    }

    /** Runs SQL that returns nothing we want (a pragma). */
    public function exec(string $sql): void
    {
        $rc = $this->ffi->sqlite3_exec($this->db, $sql, null, null, null);
        if ($rc !== 0) {
            throw $this->error();
        }
    }

    /** The first column of the first row as text, null when there is none: what a test reads a pragma with. */
    public function scalar(string $sql): ?string
    {
        $statement = $this->prepare($sql);
        $rc = $this->ffi->sqlite3_step($statement);
        $value = null;
        if ($rc === self::ROW) {
            $value = $this->text($statement, 0);
        }
        $this->ffi->sqlite3_reset($statement);
        if ($rc !== self::ROW && $rc !== self::DONE) {
            throw $this->error();
        }
        return $value;
    }

    /** APP_JSON=sqlite: the JSON array of the feed's posts, as SQLite built it. */
    public function feedJson(): string
    {
        $ffi = $this->ffi;
        $rc = $ffi->sqlite3_step($this->feed);
        if ($rc !== self::ROW) {
            $this->fail($this->feed);
        }
        $json = $ffi->sqlite3_column_text($this->feed, 0);
        $ffi->sqlite3_reset($this->feed);
        return $json;
    }

    /** The rows of the feed, keyed as PDO's FETCH_ASSOC keys them. */
    public function feedRows(): array
    {
        $ffi = $this->ffi;
        $statement = $this->feed;
        $rows = [];
        while (($rc = $ffi->sqlite3_step($statement)) === self::ROW) {
            $rows[] = [
                'id' => $ffi->sqlite3_column_int64($statement, 0),
                'body' => $this->text($statement, 1),
                'created_at' => $this->text($statement, 2),
                'author' => $this->text($statement, 3),
                'like_count' => $ffi->sqlite3_column_int64($statement, 4),
            ];
        }
        if ($rc !== self::DONE) {
            $this->fail($statement);
        }
        $ffi->sqlite3_reset($statement);
        return $rows;
    }

    /** APP_JSON=sqlite: the JSON object of one post, null when there is no such post. */
    public function postJson(int $id): ?string
    {
        $ffi = $this->ffi;
        $ffi->sqlite3_bind_int64($this->post, 1, $id);
        $rc = $ffi->sqlite3_step($this->post);
        if ($rc === self::ROW) {
            $json = $ffi->sqlite3_column_text($this->post, 0);
        } elseif ($rc === self::DONE) {
            $json = null;
        } else {
            $this->fail($this->post);
        }
        $ffi->sqlite3_reset($this->post);
        return $json;
    }

    /** @return array{id: int, body: string, created_at: string, author: string, like_count: int}|null */
    public function postRow(int $id): ?array
    {
        $ffi = $this->ffi;
        $statement = $this->post;
        $ffi->sqlite3_bind_int64($statement, 1, $id);
        $rc = $ffi->sqlite3_step($statement);
        if ($rc === self::ROW) {
            $row = [
                'id' => $ffi->sqlite3_column_int64($statement, 0),
                'body' => $this->text($statement, 1),
                'created_at' => $this->text($statement, 2),
                'author' => $this->text($statement, 3),
                'like_count' => $ffi->sqlite3_column_int64($statement, 4),
            ];
        } elseif ($rc === self::DONE) {
            $row = null;
        } else {
            $this->fail($statement);
        }
        $ffi->sqlite3_reset($statement);
        return $row;
    }

    private function prepare(string $sql): mixed
    {
        $handle = $this->ffi->new('sqlite3_stmt*');
        $rc = $this->ffi->sqlite3_prepare_v3($this->db, $sql, strlen($sql), self::PREPARE_PERSISTENT, FFI::addr($handle), null);
        if ($rc !== 0) {
            throw $this->error();
        }
        return $this->prepared[] = $handle;
    }

    private function text(mixed $statement, int $column): string
    {
        $text = $this->ffi->sqlite3_column_blob($statement, $column);
        return FFI::string($text, $this->ffi->sqlite3_column_bytes($statement, $column));
    }

    /** Resets the statement (it must not keep its transaction open) and throws what the step failed with. */
    private function fail(mixed $statement): never
    {
        $error = $this->error();
        $this->ffi->sqlite3_reset($statement);
        throw $error;
    }

    /** The exception PDO raises for the connection's last error: its class, and its message `SQLSTATE[..]: <class of error>: <code> <text>`. */
    private function error(): PDOException
    {
        $code = $this->ffi->sqlite3_errcode($this->db);
        $text = $this->ffi->sqlite3_errmsg($this->db);
        $state = $code === self::CONSTRAINT ? ['23000', 'Integrity constraint violation'] : ['HY000', 'General error'];
        return new PDOException("SQLSTATE[$state[0]]: $state[1]: $code $text");
    }
}
