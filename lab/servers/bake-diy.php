<?php
// The DIY server of the runtime bake-off: our own event loop (ext-event, one process; diy-server.php) and our own HTTP/1.1 parser
// (diy-connection.php), answering through handler.php (GET /noop and GET /posts/:id). Port: PORT (default 8080).
//
// lab/macro.sh, lab/conformance.sh and lab/conns.sh start it with the extensions loaded in this order:
//   --ext sockets --ext event

require __DIR__ . '/handler.php';
require __DIR__ . '/diy-server.php';

$port = (int) (getenv('PORT') ?: 8080);
$backlog = 4096;

// The database copy takes a few seconds, so the server listens only once it is done.
handler_boot();

$listener = diy_listen('0.0.0.0', $port, $backlog);
$server = new DiyServer($listener);
echo "listening on 0.0.0.0:$port\n";
echo 'loop: ' . $server->loopMethod() . "\n";
echo diy_socket_line($listener, $backlog) . "\n";
$server->run();
