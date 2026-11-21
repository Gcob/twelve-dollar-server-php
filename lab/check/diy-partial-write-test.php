<?php
// The DIY server's write path, on a socket pair whose client end does not read: a response larger than the pair's buffer is
// only partly written, the rest waits in the connection, and the client gets every byte, whole and in order, once it reads.
// (On loopback the kernel's buffers grow to megabytes, so this path would never run in an end-to-end test.)
// Run: bash lab/run.sh 8.5 php /lab/check/diy-partial-write-test.php

require __DIR__ . '/diy-lib.php';

const HEAD = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ";

function response(int $bytes): string
{
    return HEAD . $bytes . "\r\n\r\n" . diy_body($bytes);
}

/** How many bytes the pair takes from a writer before a write is refused. */
function diy_pair_capacity(): int
{
    [$server, $client] = diy_pair();
    $total = 0;
    while (($n = fwrite($server, str_repeat('x', 16384))) > 0) {
        $total += $n;
    }
    fclose($server);
    fclose($client);
    return $total;
}

/**
 * The client reads what is there, the server writes the rest, until $expected bytes arrived or nothing moves.
 *
 * @return array{string, bool} what arrived, and whether the connection is still open
 */
function diy_drain(DiyConnection $conn, $client, int $expected): array
{
    $got = '';
    $open = true;
    for ($round = 0; $round < 100000 && strlen($got) < $expected; $round++) {
        $got .= diy_read_all($client);
        if ($open) {
            $open = $conn->onWritable();
        }
    }
    return [$got . diy_read_all($client), $open];
}

diy_case('a response larger than the pair is written in part, the rest is buffered, all of it arrives in order', function () {
    $capacity = diy_pair_capacity();
    $expected = response(640000);
    if ($capacity >= strlen($expected)) {
        return "the pair takes $capacity bytes, no smaller than the response (" . strlen($expected) . ')';
    }
    [$server, $client] = diy_pair();
    $conn = new DiyConnection($server);
    fwrite($client, "GET /big/640000 HTTP/1.1\r\n\r\n");
    if (!$conn->onReadable()) {
        return 'the connection finished before the response was written';
    }
    $pending = $conn->pendingBytes();
    if ($pending <= 0 || $pending >= strlen($expected)) {
        return "expected a partial write, $pending of " . strlen($expected) . ' bytes are still buffered (the pair takes ' . $capacity . ')';
    }
    if (!$conn->wantsWrite() || !$conn->wantsRead()) {
        return 'a partial write should ask for a write event and keep reading (under the buffer limit)';
    }
    [$got, $open] = diy_drain($conn, $client, strlen($expected));
    if ($got !== $expected) {
        return 'the client received ' . strlen($got) . ' bytes, expected ' . strlen($expected) . ($got === substr($expected, 0, strlen($got)) ? ' (a prefix)' : ' (not the same bytes)');
    }
    if (!$open || $conn->wantsWrite() || $conn->pendingBytes() !== 0) {
        return 'after the last byte the connection should be open with nothing buffered';
    }
    return 'ok:pair takes ' . $capacity . ' bytes, ' . $pending . ' of ' . strlen($expected) . ' buffered after the first write';
});

diy_case('over the buffer limit, reading pauses and the queued requests wait; all three responses arrive in order', function () {
    $big = response(2000000);
    $small = response(160);
    $expected = $big . $big . $small;
    [$server, $client] = diy_pair();
    $conn = new DiyConnection($server);
    fwrite($client, "GET /big/2000000 HTTP/1.1\r\n\r\nGET /big/2000000 HTTP/1.1\r\n\r\nGET /big/160 HTTP/1.1\r\n\r\n");
    if (!$conn->onReadable()) {
        return 'the connection finished before the responses were written';
    }
    if ($conn->wantsRead()) {
        return 'reading should be paused with more than ' . DiyConnection::WRITE_LIMIT . ' bytes buffered (' . $conn->pendingBytes() . ' are)';
    }
    if ($conn->pendingBytes() > strlen($big)) {
        return 'the second response was built while the first one was still over the limit (' . $conn->pendingBytes() . ' bytes buffered)';
    }
    [$got, $open] = diy_drain($conn, $client, strlen($expected));
    if ($got !== $expected) {
        return 'the client received ' . strlen($got) . ' bytes, expected ' . strlen($expected) . ($got === substr($expected, 0, strlen($got)) ? ' (a prefix)' : ' (not the same bytes)');
    }
    if (!$open || !$conn->wantsRead()) {
        return 'once drained the connection should be open and reading again';
    }
    return null;
});

diy_case('Connection: close after a partial write closes only once the last byte is out', function () {
    $expected = response(640000);
    [$server, $client] = diy_pair();
    $conn = new DiyConnection($server);
    fwrite($client, "GET /big/640000 HTTP/1.1\r\nConnection: close\r\n\r\n");
    if (!$conn->onReadable()) {
        return 'the connection finished while bytes were still buffered (' . $conn->pendingBytes() . ')';
    }
    if ($conn->wantsRead()) {
        return 'a connection that will close should not read any more';
    }
    [$got, $open] = diy_drain($conn, $client, strlen($expected));
    if ($got !== $expected) {
        return 'the client received ' . strlen($got) . ' bytes, expected ' . strlen($expected);
    }
    return $open ? 'the connection is still open after the last byte' : null;
});

diy_case('a client that never reads cannot make the buffer grow past the limit and one response', function () {
    [$server, $client] = diy_pair();
    $conn = new DiyConnection($server);
    $max = 0;
    for ($i = 0; $i < 20 && $conn->wantsRead(); $i++) {
        fwrite($client, "GET /big/2000000 HTTP/1.1\r\n\r\n");
        $conn->onReadable();
        $max = max($max, $conn->pendingBytes());
    }
    if ($conn->wantsRead()) {
        return 'the connection still reads after 20 requests the client never read the answers of';
    }
    if ($max > DiyConnection::WRITE_LIMIT + 2000100) {
        return "the buffer reached $max bytes";
    }
    return 'ok:stopped reading after ' . $i . ' request(s), at most ' . $max . ' bytes buffered';
});

diy_finish();
