<?php
// A stand-in for the challenge app that closes every connection that sat idle for 2 seconds, like a server with a short keep-alive
// timeout: lab/realistic.sh --idle must fail on it, because the idle connections it holds are closed by the server. A plain select loop
// (no ext-event) answering what the bench's journey reads, the same answers as slow-app.php. Same environment as lab/app/server.php.

const IDLE_TIMEOUT_S = 2.0;

function answer(string $method, string $path): string
{
    return match (true) {
        $method === 'GET' && $path === '/health' => '200 OK|{"status":"ok","db":"ok","uptime_s":0}',
        $method === 'GET' && $path === '/feed' => '200 OK|{"posts":[{"id":1},{"id":2}]}',
        $method === 'GET' && str_starts_with($path, '/posts/') => '200 OK|{"post":{"id":1}}',
        $method === 'POST' && $path === '/posts' => '201 Created|{"post":{"id":3}}',
        $method === 'POST' && str_ends_with($path, '/like') => '201 Created|{"liked":true}',
        default => '404 Not Found|{"error":"not found"}',
    };
}

$port = (int) (getenv('PORT') ?: 8080);
$listener = stream_socket_server("tcp://0.0.0.0:$port", $errno, $errstr, STREAM_SERVER_BIND | STREAM_SERVER_LISTEN, stream_context_create(['socket' => ['backlog' => 4096]]));
if ($listener === false) {
    fwrite(STDERR, "idle-timeout-app: cannot listen on $port: $errstr\n");
    exit(1);
}
echo "listening on 0.0.0.0:$port\n";
/** @var array<int, resource> $clients */
$clients = [];
$buffers = [];
$lastSeen = [];
while (true) {
    $read = array_merge([$listener], $clients);
    $write = $except = null;
    if (stream_select($read, $write, $except, 0, 200_000) > 0) {
        foreach ($read as $stream) {
            if ($stream === $listener) {
                while (($c = @stream_socket_accept($listener, 0)) !== false) {
                    stream_set_blocking($c, false);
                    $clients[(int) $c] = $c;
                    $buffers[(int) $c] = '';
                    $lastSeen[(int) $c] = microtime(true);
                }
                continue;
            }
            $id = (int) $stream;
            $data = @fread($stream, 8192);
            if ($data === false || ($data === '' && feof($stream))) {
                fclose($stream);
                unset($clients[$id], $buffers[$id], $lastSeen[$id]);
                continue;
            }
            $lastSeen[$id] = microtime(true);
            $buffers[$id] .= $data;
            while (($end = strpos($buffers[$id], "\r\n\r\n")) !== false) {
                $length = preg_match('/^content-length:\s*(\d+)/mi', substr($buffers[$id], 0, $end), $m) ? (int) $m[1] : 0;
                if (strlen($buffers[$id]) < $end + 4 + $length) {
                    break;
                }
                [$method, $path] = explode(' ', $buffers[$id], 3);
                [$status, $body] = explode('|', answer($method, $path), 2);
                $buffers[$id] = substr($buffers[$id], $end + 4 + $length);
                fwrite($stream, "HTTP/1.1 $status\r\nContent-Type: application/json\r\nContent-Length: " . strlen($body) . "\r\n\r\n$body");
            }
        }
    }
    $now = microtime(true);
    foreach ($lastSeen as $id => $seen) {
        if ($now - $seen > IDLE_TIMEOUT_S) {
            fclose($clients[$id]);
            unset($clients[$id], $buffers[$id], $lastSeen[$id]);
        }
    }
}
