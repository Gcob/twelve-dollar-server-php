<?php
// The Swoole server of the runtime bake-off: the settings of noop-swoole.php (the floor) plus open_tcp_nodelay, answering through
// handler.php (GET /noop and GET /posts/:id). Port: PORT (default 8080). The database copy takes a few seconds, so the server
// listens only once it is done.
//
// Adapted from submissions/php-swoole-mattsplat/server.php of the twelve-dollar-server-challenge repository
// (MIT License, Copyright (c) 2026 arjaythedev and the challenge contributors; the license text is in lab/NOTICE.md).
//
// lab/macro.sh and lab/conformance.sh start it with LAB_SERVER_PHP_FLAGS (lab/lib.sh) and -d extension=swoole.

use Swoole\Http\Request;
use Swoole\Http\Response;
use Swoole\Http\Server;

require __DIR__ . '/handler.php';

$port = (int) (getenv('PORT') ?: 8080);

// In BASE mode with one worker and no task worker, Swoole serves from this process and forks nothing (the container runs one
// php process), so the SQLite handle opened here is the one that serves.
handler_boot();

$settings = [
    'worker_num' => 1,
    'enable_coroutine' => false,
    'max_connection' => 65535,
    'backlog' => 4096,
    'open_tcp_nodelay' => true,
    'http_parse_post' => false,
    'http_parse_cookie' => false,
    'http_parse_files' => false,
    'http_compression' => false,
    'log_level' => SWOOLE_LOG_WARNING,
];
$server = new Server('0.0.0.0', $port, SWOOLE_BASE);
$server->set($settings);

$server->on('request', function (Request $req, Response $res) {
    [$status, $body] = handler_handle($req->server['request_method'], $req->server['request_uri'], (string) $req->rawContent());
    $res->status($status);
    $res->header('Content-Type', 'application/json');
    $res->end($body);
});

echo "listening on 0.0.0.0:$port\n";
// What was asked of the sockets, as the server was given it: the images' Swoole is built without sockets support, so it cannot
// be read back from the kernel. lab/macro.sh and lab/conformance.sh copy this line.
echo 'socket: backlog=' . $settings['backlog'] . ' tcp_nodelay=' . (int) $settings['open_tcp_nodelay'] . "\n";
$server->start();
