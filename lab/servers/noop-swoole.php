<?php
// The cheapest Swoole HTTP server the challenge allows: 200 {"status":"ok"} to every request, no route, no database.
// It sets the floor of the macro harness (what a request costs before any application code) and checks the harness.
// Swoole settings are the ones both Swoole entries use; the port is PORT (default 8080).
//
//   php -d extension=swoole -d memory_limit=-1 -d opcache.enable_cli=1 -d opcache.jit=tracing \
//       -d opcache.jit_buffer_size=32M lab/servers/noop-swoole.php

use Swoole\Http\Request;
use Swoole\Http\Response;
use Swoole\Http\Server;

$port = (int) (getenv('PORT') ?: 8080);

$server = new Server('0.0.0.0', $port, SWOOLE_BASE);
$server->set([
    'worker_num' => 1,
    'enable_coroutine' => false,
    'max_connection' => 65535,
    'backlog' => 4096,
    'http_parse_post' => false,
    'http_parse_cookie' => false,
    'http_parse_files' => false,
    'http_compression' => false,
    'log_level' => SWOOLE_LOG_WARNING,
]);

$server->on('request', function (Request $req, Response $res) {
    $res->header('Content-Type', 'application/json');
    $res->end('{"status":"ok"}');
});

echo "listening on 0.0.0.0:$port\n";
$server->start();
