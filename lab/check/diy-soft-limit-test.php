<?php
// The DIY server's soft connection limit (DiyConnectionCount), on socket pairs and on one TCP pair, with no event loop: past the limit a
// response says `Connection: close` and the connection ends once it is written; below it nothing changes, byte for byte. The test plays
// the loop's part: it counts a connection when it opens and when it closes, as DiyServer does.
// Run: bash lab/run.sh 8.5 php /lab/check/diy-soft-limit-test.php

require __DIR__ . '/diy-lib.php';

const GET = "GET /x HTTP/1.1\r\n\r\n";
// What a connection answers today, with no limit set: the body is 18 bytes.
const PLAIN = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 18\r\n\r\n{\"echo\":\"GET /x \"}";
const WITH_CLOSE = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 18\r\nConnection: close\r\n\r\n{\"echo\":\"GET /x \"}";

/**
 * A client that is open and has sent $request: the connection, the client's end, and what the loop would do next.
 *
 * @return array{DiyConnection, resource}
 */
function open_client(DiyConnectionCount $count, string $request = GET): array
{
    [$server, $client] = diy_pair();
    $count->opened();
    $conn = new DiyConnection($server, $count);
    fwrite($client, $request);
    return [$conn, $client];
}

/** The loop's callback on a readable stream: false (and the count down, the stream closed) when the connection is finished. */
function serve(DiyConnection $conn, DiyConnectionCount $count): bool
{
    $alive = $conn->onReadable();
    if (!$alive) {
        $count->closed();
        $conn->close();
    }
    return $alive;
}

diy_case('soft limit 2: the first two connections answer as today and stay open, the third says close and ends after its response', function () {
    $count = new DiyConnectionCount(2);
    $answers = [];
    $alive = [];
    $clients = [];
    $conns = [];
    foreach ([1, 2, 3] as $i) {
        [$conns[$i], $client] = open_client($count);
        $alive[$i] = serve($conns[$i], $count);
        $answers[$i] = diy_read_all($client);
        $clients[$i] = $client;
    }
    if ($answers[1] !== PLAIN || $answers[2] !== PLAIN) {
        return 'the first two should answer as today: ' . diy_show($answers[1]) . ' and ' . diy_show($answers[2]);
    }
    if ($answers[3] !== WITH_CLOSE) {
        return 'the third should carry Connection: close: ' . diy_show($answers[3]);
    }
    if ($alive !== [1 => true, 2 => true, 3 => false]) {
        return 'the first two stay open and the third ends: ' . json_encode($alive);
    }
    if (!feof($clients[3]) || feof($clients[1]) || feof($clients[2])) {
        return 'the client of the third should see the end of the stream, the first two should not';
    }
    if ($count->open !== 2 || $count->limitCloses !== 1) {
        return "open {$count->open} (expected 2), limit closes {$count->limitCloses} (expected 1)";
    }
    return null;
});

diy_case('the limit equals the idle count: 50 idle connections keep alive, 20 more each close after one response, the 50 answer again', function () {
    $count = new DiyConnectionCount(50);
    $idle = [];
    for ($i = 0; $i < 50; $i++) {
        [$conn, $client] = open_client($count);
        if (!serve($conn, $count) || diy_read_all($client) !== PLAIN) {
            return "idle connection $i was closed or answered with something else";
        }
        $idle[] = [$conn, $client];
    }
    for ($i = 0; $i < 20; $i++) {
        [$conn, $client] = open_client($count);
        if (serve($conn, $count) || diy_read_all($client) !== WITH_CLOSE || !feof($client)) {
            return "new connection $i should say close and end";
        }
    }
    if ($count->open !== 50 || $count->limitCloses !== 20) {
        return "open {$count->open} (expected 50), limit closes {$count->limitCloses} (expected 20)";
    }
    foreach ($idle as $i => [$conn, $client]) {
        fwrite($client, GET);
        if (!serve($conn, $count) || diy_read_all($client) !== PLAIN) {
            return "idle connection $i did not answer a second request as today";
        }
    }
    return null;
});

diy_case('limit 0: every response says close and the connection ends', function () {
    $count = new DiyConnectionCount(0);
    for ($i = 0; $i < 3; $i++) {
        [$conn, $client] = open_client($count);
        if (serve($conn, $count) || diy_read_all($client) !== WITH_CLOSE) {
            return "connection $i should say close and end";
        }
    }
    return null;
});

diy_case('a request pipelined behind the closing response is not answered', function () {
    $count = new DiyConnectionCount(0);
    [$conn, $client] = open_client($count, GET . GET . GET);
    if (serve($conn, $count)) {
        return 'the connection should end';
    }
    return diy_read_all($client) === WITH_CLOSE ? null : 'the client should get one response only: ' . diy_show(diy_read_all($client));
});

diy_case('a client that asked for close is not counted as a close the limit caused', function () {
    $count = new DiyConnectionCount(0);
    [$conn, $client] = open_client($count, "GET /x HTTP/1.1\r\nConnection: close\r\n\r\n");
    if (serve($conn, $count) || diy_read_all($client) !== WITH_CLOSE) {
        return 'the connection should end with one Connection: close header';
    }
    return $count->limitCloses === 0 ? null : "limit closes {$count->limitCloses}, expected 0";
});

diy_case('without a limit the connection is as today, whatever the count', function () {
    [$server, $client] = diy_pair();
    $conn = new DiyConnection($server);
    fwrite($client, GET);
    return $conn->onReadable() && diy_read_all($client) === PLAIN ? null : 'the response should be today\'s bytes and the connection should stay open';
});

diy_case('the count tracks the most connections open at once, and starts over from what is open', function () {
    $count = new DiyConnectionCount(null);
    $count->opened();
    $count->opened();
    $count->opened();
    $count->closed();
    $count->closed();
    if ($count->open !== 1 || $count->peak !== 3) {
        return "open {$count->open} (expected 1), peak {$count->peak} (expected 3)";
    }
    $count->resetPeak();
    return $count->peak === 1 ? null : "after a reset the peak should be what is open (1), got {$count->peak}";
});

/** One TCP connection on loopback: the server's end (non-blocking, as the loop has it) and the client's. @return array{resource, resource} */
function tcp_pair(): array
{
    $listener = stream_socket_server('tcp://127.0.0.1:0', $errno, $errstr);
    $client = stream_socket_client('tcp://' . stream_socket_get_name($listener, false), $errno, $errstr);
    $server = stream_socket_accept($listener, 2);
    fclose($listener);
    stream_set_blocking($server, false);
    stream_set_blocking($client, false);
    return [$server, $client];
}

diy_case('unread bytes in the receive buffer at the close: the client still reads the whole response, then the end, never a reset', function () {
    // The request is followed by more than one read's worth (8 KiB) of a next request: the connection answers the first, says close, and
    // closes with bytes it never read. Without care the kernel answers that close with a reset, which can throw away the response.
    [$server, $client] = tcp_pair();
    $count = new DiyConnectionCount(0);
    $count->opened();
    $conn = new DiyConnection($server, $count);
    fwrite($client, GET . "POST /x HTTP/1.1\r\nContent-Length: 200000\r\n\r\n" . str_repeat('x', 150000));
    usleep(100000);
    if ($conn->onReadable()) {
        return 'the connection should end';
    }
    $conn->close();
    stream_set_blocking($client, true);
    stream_set_timeout($client, 2);
    $got = '';
    while (($chunk = fread($client, 65536)) !== false && $chunk !== '') {
        $got .= $chunk;
    }
    // Why the last value: a reset ends the reads with false, the end of the stream with ''.
    if ($got !== WITH_CLOSE || $chunk !== '') {
        return 'the client read ' . diy_show($got) . ', and its last read gave ' . var_export($chunk, true) . ' (a reset, not the end of the stream)';
    }
    return null;
});

diy_finish();
