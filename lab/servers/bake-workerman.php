<?php
// The Workerman server of the runtime bake-off: one HTTP worker on the Event loop (ext-event), answering through handler.php
// (GET /noop and GET /posts/:id). Reads PORT (default 8080) and WORKERMAN_TREE: `nocache` (default), Workerman with its 5 request
// caches patched out, or `stock`, Workerman as released. Two processes run: Workerman's master and its one worker, both in the
// container's cgroup.
//
// lab/macro.sh, lab/conformance.sh and lab/conns.sh start it with the extensions loaded in this order:
//   --ext pcntl --ext sockets --ext event
// (sockets before event, which depends on it; sockets also lets Workerman set TCP_NODELAY on its listening socket).

require __DIR__ . '/handler.php';

$tree = getenv('WORKERMAN_TREE') ?: 'nocache';
if (!in_array($tree, ['stock', 'nocache'], true)) {
    fwrite(STDERR, "bake-workerman: WORKERMAN_TREE must be 'stock' or 'nocache', got '$tree'\n");
    exit(1);
}
// Why: Workerman falls back to the select() loop when event is missing, and a bake-off number measured on it would be taken for
// the Event loop's.
if (!extension_loaded('event')) {
    fwrite(STDERR, "bake-workerman: ext-event is not loaded (start with --ext pcntl --ext sockets --ext event); refusing to run on Workerman's select() fallback\n");
    exit(1);
}
require "/opt/workerman/$tree/autoload.php";

use Workerman\Events\Event;
use Workerman\Protocols\Http\Response;
use Workerman\Worker;

$port = (int) (getenv('PORT') ?: 8080);
$backlog = 4096;

// Why: Workerman reads `start` from argv (the harnesses run `php <file>`), and /lab is mounted read-only, so its pid, status and
// log files go to /tmp.
$argv = [__FILE__, 'start'];
Worker::$pidFile = '/tmp/workerman.pid';
Worker::$statusFile = '/tmp/workerman.status';
Worker::$logFile = '/tmp/workerman.log';
Worker::$eventLoopClass = Event::class;

// The seed is copied once, here, before Workerman forks: a SQLite handle does not survive a fork, so each worker opens it itself.
handler_copy_db();

$worker = new Worker("http://0.0.0.0:$port", ['socket' => ['backlog' => $backlog]]);
$worker->count = 1;

$worker->onWorkerStart = function (Worker $worker) use ($tree, $backlog): void {
    handler_open_db();
    // What the kernel says about the listening socket Workerman made (the backlog cannot be read back, so it is what was asked).
    $socket = socket_import_stream($worker->getMainSocket());
    $nodelay = (int) (bool) socket_get_option($socket, SOL_TCP, TCP_NODELAY);
    echo "tree: $tree\n";
    echo 'loop: ' . Worker::$eventLoopClass . "\n";
    echo "socket: backlog=$backlog tcp_nodelay=$nodelay\n";
};

// A Response object, as Workerman's documentation does it: it carries the status and the Content-Type, and Workerman adds
// Content-Length and Connection: keep-alive (Workerman 5.2.4 sends no Server header with a Response object). Sending a plain string would always answer 200 text/html.
$worker->onMessage = function ($connection, $request): void {
    [$status, $body] = handler_handle($request->method(), $request->uri(), $request->rawBody());
    $connection->send(new Response($status, ['Content-Type' => 'application/json'], $body));
};

Worker::runAll();
