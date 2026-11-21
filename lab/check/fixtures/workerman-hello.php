<?php
// A throwaway Workerman HTTP server for lab/check.sh: it only proves that Workerman boots on one of the image's two trees
// with pcntl, sockets and ext-event loaded, and answers one request. Reads PORT and WORKERMAN_TREE (stock or nocache).
//
//   php -d extension=pcntl -d extension=sockets -d extension=event lab/check/fixtures/workerman-hello.php
require '/opt/workerman/' . getenv('WORKERMAN_TREE') . '/autoload.php';

use Workerman\Protocols\Http\Response;
use Workerman\Worker;

// Why: Workerman reads `start` from argv, and /lab is mounted read-only, so its pid, status and log files go to /tmp.
$argv = [__FILE__, 'start'];
Worker::$pidFile = '/tmp/workerman.pid';
Worker::$statusFile = '/tmp/workerman.status';
Worker::$logFile = '/tmp/workerman.log';
Worker::$eventLoopClass = Workerman\Events\Event::class;

$worker = new Worker('http://0.0.0.0:' . getenv('PORT'));
$worker->count = 1;
// Why: the check reads the answer with PHP's http wrapper, which waits for the server to close. Workerman keeps a connection alive
// for 60 s whatever the request or the response header says, so the handler closes it after sending.
$worker->onMessage = function ($connection, $request): void {
    $connection->close(new Response(200, ['Content-Type' => 'text/plain'], 'hello ' . Worker::$eventLoopClass . ' ' . getenv('WORKERMAN_TREE')));
};
Worker::runAll();
