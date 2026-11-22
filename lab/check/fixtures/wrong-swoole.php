<?php
// Fixture of lab/check.sh: a Swoole server that gets the /noop body wrong ("ok" as text) and answers everything else 404, to see
// lab/conformance.sh name the cases that fail and still remove its containers.
use Swoole\Http\Request;
use Swoole\Http\Response;
use Swoole\Http\Server;

$port = (int) (getenv('PORT') ?: 8080);
$server = new Server('0.0.0.0', $port, SWOOLE_BASE);
$server->set(['worker_num' => 1, 'enable_coroutine' => false, 'log_level' => SWOOLE_LOG_WARNING]);
$server->on('request', function (Request $req, Response $res) {
    $res->header('Content-Type', 'text/plain');
    $res->end('ok');
});
echo "listening on 0.0.0.0:$port\n";
$server->start();
