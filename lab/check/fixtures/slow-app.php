<?php
// A stand-in for the challenge app that spends 4 ms of wall time on every request before it answers, in the one thread of the DIY
// loop: it serves about 250 requests per second at most, so a harness check can put a load step above its capacity while the whole
// check stays at a few hundred requests per second. Same environment as lab/app/server.php (PORT, HOST); the database is not opened.
// Answers what the bench's journey reads: a feed with two posts, a post, a like, a new post.

require __DIR__ . '/../../servers/diy-server.php';

const SLOW_APP_US = 4000;

function handler_handle(string $method, string $path, string $body, string $authorization = ''): array
{
    usleep(SLOW_APP_US);
    if ($method === 'GET' && $path === '/health') {
        return [200, '{"status":"ok"}'];
    }
    if ($method === 'GET' && $path === '/feed') {
        return [200, '{"posts":[{"id":1},{"id":2}]}'];
    }
    if ($method === 'GET' && str_starts_with($path, '/posts/')) {
        return [200, '{"post":{"id":1}}'];
    }
    if ($method === 'POST' && $path === '/posts') {
        return [201, '{"post":{"id":3}}'];
    }
    if ($method === 'POST' && str_ends_with($path, '/like')) {
        return [201, '{"liked":true}'];
    }
    return [404, '{"error":"not found"}'];
}

$host = (string) (getenv('HOST') ?: '0.0.0.0');
$port = (int) (getenv('PORT') ?: 8080);
$backlog = 4096;
$listener = diy_listen($host, $port, $backlog);
$server = new DiyServer($listener);
echo "listening on $host:$port\n";
echo 'loop: ' . $server->loopMethod() . "\n";
echo diy_socket_line($listener, $backlog) . "\n";
$server->run();
