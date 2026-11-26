<?php
// The challenge app (lab/app/app.php) on Swoole's coroutine HTTP server (Swoole\Coroutine\Http\Server), one process, one coroutine per
// connection. On a Swoole built with --enable-uring_socket (the php-lab:8.5-uring image) its sockets run on io_uring: accept, receive and send are
// io_uring operations, and the loop's one wait is epoll on the ring's eventfd. On any other Swoole it is the same server on epoll sockets.
//
// Configuration like lab/app/server.php: SQLITE_PATH (the database it opens, never a copy) and JWT_SECRET are required, HOST defaults to 0.0.0.0
// and PORT to 8080. The database is opened by app_boot() before the server listens. It is started with `-d extension=swoole` (`--ext swoole`);
// lab/challenge-test.sh, lab/realistic.sh and lab/steplab.sh start it on a fresh copy of the seed, and the io_uring image needs their
// --seccomp-unconfined (Docker's default filter refuses io_uring).
//
// Boot lines, like the DIY server's: `listening on <host>:<port>`, `socket: ...` (what was asked of the sockets: Swoole cannot be read back) and
// `loop: swoole-co, uring` or `loop: swoole-co, epoll`, which says what the Swoole was built with (`uring_socket => enabled` in `php --ri swoole`).
//
// Every request goes to handler_handle($method, $path, $body, $authorization), the same call as the DIY server's. The answer is the status, a
// Content-Type of application/json and the body; Swoole writes the rest of the head. What differs from the bytes of the DIY server
// (lab/servers/diy-connection.php), and cannot be made to match:
//  - Swoole adds `Server: swoole-http-server`, `Date` and `Connection: keep-alive` to every response, and its reason phrases and header order are its own;
//  - it accepts a chunked request body (the DIY server answers 400) and answers a malformed request with its own 400, and a request over its
//    package_max_length (2 MiB) with a 413;
//  - the listening backlog is Swoole's 512 (it is not a setting of the coroutine server; the DIY server asks for 4,096).
// A connection that is idle is never closed by the server (socket_read_timeout is -1: the default is 60 s), like the DIY server's.
//
// SWOOLE_CO_STACK_SIZE (default unset: Swoole's 2 MiB) sets the C stack of each connection's coroutine, in bytes: Swoole accepts 65536 to 16 MiB. It is
// what lab/conns.sh varies to price a connection in memory. SWOOLE_CO_THP_OFF=1 (default unset) turns transparent huge pages off for the process
// (prctl PR_SET_THP_DISABLE through FFI) before anything else is mapped: where the kernel's setting is `always` (Docker Desktop's VM), each 2 MiB
// -aligned mapping of a coroutine's stack or of PHP's memory is backed by a whole huge page, and a connection costs several times what it needs.
//
// Not supported, refused at boot with exit 1: APP_GROUP_COMMIT=1 (a handler that answers with a Closure waits for the loop's commit, which this
// server has no turn for), and APP_WORKERS above 1 (one process).

use Swoole\Coroutine;
use Swoole\Coroutine\Http\Server;
use Swoole\Http\Request;
use Swoole\Http\Response;

require __DIR__ . '/../app/app.php';

if (!extension_loaded('swoole')) {
    fwrite(STDERR, "swoole-co: the swoole extension is not loaded (start with --ext swoole)\n");
    exit(1);
}
$path = (string) getenv('SQLITE_PATH');
$secret = (string) getenv('JWT_SECRET');
if ($path === '' || $secret === '') {
    fwrite(STDERR, "swoole-co: SQLITE_PATH and JWT_SECRET must be set\n");
    exit(1);
}
$host = (string) (getenv('HOST') ?: '0.0.0.0');
$port = (int) (getenv('PORT') ?: 8080);

try {
    $variants = app_variants(getenv());
    $workers = app_workers(getenv(), $variants);
} catch (InvalidArgumentException $e) {
    fwrite(STDERR, 'swoole-co: ' . $e->getMessage() . "\n");
    exit(1);
}
if ($variants['group_commit']) {
    fwrite(STDERR, "swoole-co: APP_GROUP_COMMIT=1 is not supported: a write that waits for its commit has no turn of the loop to wait for\n");
    exit(1);
}
if ($workers > 1) {
    fwrite(STDERR, "swoole-co: APP_WORKERS=$workers is not supported: this server is one process\n");
    exit(1);
}

if (getenv('SWOOLE_CO_THP_OFF') === '1') {
    // 41 is PR_SET_THP_DISABLE: the flag lives on the process's memory map and applies to every mapping made after it.
    $libc = FFI::cdef('int prctl(int option, unsigned long arg2, unsigned long arg3, unsigned long arg4, unsigned long arg5);', 'libc.so.6');
    if ($libc->prctl(41, 1, 0, 0, 0) !== 0) {
        fwrite(STDERR, "swoole-co: prctl(PR_SET_THP_DISABLE) failed\n");
        exit(1);
    }
}

// The build's own words, read from the extension: the loop line must say what the sockets run on, not what was hoped for.
ob_start();
(new ReflectionExtension('swoole'))->info();
$info = (string) ob_get_clean();
$loop = preg_match('/^uring_socket => enabled$/m', $info) === 1 ? 'uring' : 'epoll';

app_boot($path, $secret, $variants);

$settings = [
    'open_tcp_nodelay' => true,
    'http_parse_post' => false,
    'http_parse_cookie' => false,
    'http_parse_files' => false,
    'http_compression' => false,
];

// Why hook_flags 0: no PHP function is turned into a coroutine one (nothing in the app waits: SQLite is called in process), so a request pays
// for no hook. Why socket_read_timeout here: it is the default of every socket made after it, the accepted connections included, and the only
// place the coroutine server takes it from (a `read_timeout` in the server's own set() is ignored): at 60 s, the connections that sit idle
// would be closed by the server.
$coroutineSettings = ['hook_flags' => 0, 'log_level' => SWOOLE_LOG_WARNING, 'socket_read_timeout' => -1];
$stackSize = (string) getenv('SWOOLE_CO_STACK_SIZE');
if ($stackSize !== '') {
    if (!ctype_digit($stackSize) || (int) $stackSize < 65536 || (int) $stackSize > 16777216) {
        fwrite(STDERR, "swoole-co: SWOOLE_CO_STACK_SIZE must be a whole number of bytes from 65536 to 16777216, got '$stackSize'\n");
        exit(1);
    }
    $coroutineSettings['stack_size'] = (int) $stackSize;
}
Coroutine::set($coroutineSettings);

Coroutine\run(static function () use ($host, $port, $settings, $loop): void {
    $server = new Server($host, $port);
    $server->set($settings);
    $server->handle('/', static function (Request $req, Response $res): void {
        try {
            $answer = handler_handle(
                $req->server['request_method'],
                $req->server['request_uri'],
                (string) $req->rawContent(),
                trim($req->header['authorization'] ?? '', " \t"),
            );
            if (!is_array($answer)) {
                throw new LogicException('handler_handle answered with a Closure: group commit is refused at boot');
            }
            [$status, $body] = $answer;
        } catch (Throwable) {
            [$status, $body] = [500, '{"error":"internal server error"}'];
        }
        $res->status($status);
        $res->header('Content-Type', 'application/json');
        $res->end($body);
    });
    echo "listening on $host:$port\n";
    echo "socket: backlog=512 tcp_nodelay=1\n";
    echo "loop: swoole-co, $loop\n";
    $server->start();
});
