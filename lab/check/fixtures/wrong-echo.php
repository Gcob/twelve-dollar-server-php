<?php
// Fixture of lab/check.sh: a server that echoes the id of `GET /noop?id=<n>` as <n> + 1, to see lab/stress.sh find the mismatches, exit
// 1 and remove its containers. One process, stream_select, no parsing beyond the request line; one request per read is enough for it
// (the stress client's first requests are one per connection).
$port = (int) (getenv('PORT') ?: 8080);
$server = stream_socket_server("tcp://0.0.0.0:$port", $errno, $errstr);
if ($server === false) {
    fwrite(STDERR, "cannot listen: $errstr\n");
    exit(1);
}
echo "listening on 0.0.0.0:$port\n";
$clients = [];
while (true) {
    $read = [$server, ...$clients];
    $write = $except = null;
    stream_select($read, $write, $except, 1);
    foreach ($read as $fp) {
        if ($fp === $server) {
            $clients[] = stream_socket_accept($server);
            continue;
        }
        $data = fread($fp, 65536);
        if ($data === '' || $data === false) {
            $clients = array_filter($clients, static fn ($c) => $c !== $fp);
            fclose($fp);
            continue;
        }
        $out = '';
        preg_match_all('#GET /noop\?id=(\d+) #', $data, $m);
        foreach ($m[1] as $id) {
            $body = '{"status":"ok","id":' . ((int) $id + 1) . '}';
            $out .= "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " . strlen($body) . "\r\n\r\n" . $body;
        }
        fwrite($fp, $out);
    }
}
