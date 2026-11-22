<?php
// The challenge app on the DIY loop (lab/servers/diy-server.php, lab/servers/diy-connection.php), the way a challenge submission is
// configured: SQLITE_PATH (the database it opens, never a copy), JWT_SECRET, HOST (default 0.0.0.0) and PORT (default 8080).
//
// It starts with the extensions loaded in this order: `--ext sockets --ext event`. It listens only once the database is open.
// lab/challenge-test.sh starts it on a fresh copy of the seed.

require __DIR__ . '/app.php';
require __DIR__ . '/../servers/diy-server.php';

$path = (string) getenv('SQLITE_PATH');
$secret = (string) getenv('JWT_SECRET');
if ($path === '' || $secret === '') {
    fwrite(STDERR, "server: SQLITE_PATH and JWT_SECRET must be set\n");
    exit(1);
}
$host = (string) (getenv('HOST') ?: '0.0.0.0');
$port = (int) (getenv('PORT') ?: 8080);
$backlog = 4096;

app_boot($path, $secret);

$listener = diy_listen($host, $port, $backlog);
$server = new DiyServer($listener);
echo "listening on $host:$port\n";
echo 'loop: ' . $server->loopMethod() . "\n";
echo diy_socket_line($listener, $backlog) . "\n";
$server->run();
