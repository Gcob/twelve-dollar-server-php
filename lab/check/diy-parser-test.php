<?php
// The DIY server's HTTP parser, driven through a socket pair: what goes in at the client's end comes out of DiyConnection as
// responses, in order. Run: bash lab/run.sh 8.5 php /lab/check/diy-parser-test.php
//
// Not tested here: a client that sends `Transfer-Encoding: chunked` gets the 400 case below, but no k6 script does.

require __DIR__ . '/diy-lib.php';

const SAMPLE = "POST /echo/1 HTTP/1.1\r\nHost: x\r\nContent-Type: text/plain\r\ncontent-LENGTH: 5\r\n\r\nhello";
const SAMPLE_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 29\r\n\r\n{\"echo\":\"POST /echo/1 hello\"}";
const GET = "GET /noop HTTP/1.1\r\nHost: x\r\n\r\n";
const GET_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 21\r\n\r\n{\"echo\":\"GET /noop \"}";
const BAD_REQUEST = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 23\r\n\r\n{\"error\":\"bad request\"}";

/**
 * Feeds the pieces one by one (one write at the client's end, one onReadable at the server's), then reports what the client
 * received and whether the connection is still open. $peerGone: the client closes its end after the last piece.
 *
 * @param list<string> $pieces
 * @return array{out: string, open: bool, eof: bool}
 */
function diy_run(array $pieces, bool $peerGone = false): array
{
    [$server, $client] = diy_pair();
    $conn = new DiyConnection($server);
    $open = true;
    $out = '';
    foreach ($pieces as $piece) {
        fwrite($client, $piece);
        // A read takes at most 8 KiB: read until the server's end has nothing left, as the event loop does by waking up again.
        do {
            $open = $conn->onReadable();
            $pending = [$server];
            $w = $e = null;
        } while ($open && stream_select($pending, $w, $e, 0) === 1);
        $out .= diy_read_all($client);
        if (!$open) {
            break;
        }
    }
    if ($peerGone && $open) {
        fclose($client);
        $open = $conn->onReadable();
        $client = null;
    }
    $conn->close();
    $eof = false;
    if ($client !== null) {
        $out .= diy_read_all($client);
        $eof = feof($client);
        fclose($client);
    }
    return ['out' => $out, 'open' => $open, 'eof' => $eof];
}

function diy_expect(array $got, string $out, bool $open): ?string
{
    if ($got['out'] !== $out) {
        return 'the client received ' . diy_show($got['out']) . ', expected ' . diy_show($out);
    }
    if ($got['open'] !== $open) {
        return 'the connection is ' . ($got['open'] ? 'open' : 'finished') . ', expected ' . ($open ? 'open' : 'finished');
    }
    return null;
}

diy_case('complete request', fn () => diy_expect(diy_run([SAMPLE]), SAMPLE_RESPONSE, true));

diy_case('cut at every byte position', function () {
    foreach ([SAMPLE => SAMPLE_RESPONSE, GET => GET_RESPONSE] as $request => $response) {
        for ($cut = 1; $cut < strlen($request); $cut++) {
            $why = diy_expect(diy_run([substr($request, 0, $cut), substr($request, $cut)]), $response, true);
            if ($why !== null) {
                return 'cut at ' . $cut . ' of ' . strlen($request) . ' (' . diy_show($request) . '): ' . $why;
            }
        }
    }
    return 'ok:' . (strlen(SAMPLE) - 1 + strlen(GET) - 1) . ' cuts';
});

diy_case('two pipelined in one piece', fn () => diy_expect(diy_run([SAMPLE . GET]), SAMPLE_RESPONSE . GET_RESPONSE, true));

diy_case('two pipelined, cut at every byte position', function () {
    $both = SAMPLE . GET;
    for ($cut = 1; $cut < strlen($both); $cut++) {
        $why = diy_expect(diy_run([substr($both, 0, $cut), substr($both, $cut)]), SAMPLE_RESPONSE . GET_RESPONSE, true);
        if ($why !== null) {
            return 'cut at ' . $cut . ': ' . $why;
        }
    }
    return null;
});

diy_case('body split from its headers', function () {
    $head = substr(SAMPLE, 0, strpos(SAMPLE, "\r\n\r\n") + 4);
    return diy_expect(diy_run([$head, 'he', 'llo']), SAMPLE_RESPONSE, true);
});

diy_case('no answer before the body is whole', function () {
    $head = substr(SAMPLE, 0, strpos(SAMPLE, "\r\n\r\n") + 4);
    return diy_expect(diy_run([$head, 'hell']), '', true);
});

diy_case('Connection: close closes after the response, and ignores what follows', function () {
    $request = "GET /noop HTTP/1.1\r\nConnection: close\r\n\r\n";
    return diy_expect(diy_run([$request . GET]), GET_RESPONSE, false) ?? (diy_run([$request . GET])['eof'] ? null : 'the client did not see the end of the stream');
});

diy_case('HTTP/1.0 closes, unless it asks to keep alive', function () {
    return diy_expect(diy_run(["GET /noop HTTP/1.0\r\n\r\n"]), GET_RESPONSE, false)
        ?? diy_expect(diy_run(["GET /noop HTTP/1.0\r\nConnection: keep-alive\r\n\r\n"]), GET_RESPONSE, true);
});

diy_case('Connection: Keep-Alive on HTTP/1.1 stays open', function () {
    return diy_expect(diy_run(["GET /noop HTTP/1.1\r\nconnection: Keep-Alive\r\n\r\n"]), GET_RESPONSE, true);
});

$bad = [
    'no version' => "GET /noop\r\n\r\n",
    'unknown version' => "GET /noop HTTP/2.0\r\n\r\n",
    'no method' => " /noop HTTP/1.1\r\n\r\n",
    'no target' => "GET  HTTP/1.1\r\n\r\n",
    'garbage' => "\x00\x01\x02\x03\r\n\r\n",
    'header without a colon' => "GET /noop HTTP/1.1\r\nbad header\r\n\r\n",
    'header without a name' => "GET /noop HTTP/1.1\r\n: x\r\n\r\n",
    'Content-Length: abc' => "POST /x HTTP/1.1\r\nContent-Length: abc\r\n\r\n",
    'Content-Length: -1' => "POST /x HTTP/1.1\r\nContent-Length: -1\r\n\r\n",
    'Content-Length: 5x' => "POST /x HTTP/1.1\r\nContent-Length: 5x\r\n\r\nhello",
    'Content-Length empty' => "POST /x HTTP/1.1\r\nContent-Length:\r\n\r\n",
    'two Content-Length' => "POST /x HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 5\r\n\r\nhello",
    'Content-Length over 1 MiB' => "POST /x HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n",
    'Transfer-Encoding: chunked' => "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
    'headers over 8 KiB, terminated' => "GET /x HTTP/1.1\r\nX-Pad: " . str_repeat('a', 9000) . "\r\n\r\n",
];
foreach ($bad as $name => $bytes) {
    diy_case("400 and close: $name", fn () => diy_expect(diy_run([$bytes]), BAD_REQUEST, false));
}

diy_case('400 and close: headers over 8 KiB, never terminated', function () {
    // The 400 comes without waiting for the end of the headers: the last piece is never sent.
    $head = "GET /x HTTP/1.1\r\nX-Pad: " . str_repeat('a', 4000);
    return diy_expect(diy_run([$head, str_repeat('a', 4000), str_repeat('a', 4000), 'never sent']), BAD_REQUEST, false);
});

diy_case('headers of exactly 8 KiB are accepted', function () {
    $pad = 8192 - strlen("GET /noop HTTP/1.1\r\nX-Pad: \r\n\r\n");
    $request = "GET /noop HTTP/1.1\r\nX-Pad: " . str_repeat('a', $pad) . "\r\n\r\n";
    return strlen($request) !== 8192 ? 'the fixture is ' . strlen($request) . ' bytes' : diy_expect(diy_run([$request]), GET_RESPONSE, true);
});

diy_case('a good request, then a bad one: both answered in order, then close', fn () => diy_expect(diy_run([SAMPLE . "GET /x HTTP/9\r\n\r\n"]), SAMPLE_RESPONSE . BAD_REQUEST, false));

diy_case('a client that closes frees the connection', fn () => diy_expect(diy_run([GET], true), GET_RESPONSE, false));

diy_case('a client that closes in the middle of a request frees the connection', fn () => diy_expect(diy_run([substr(SAMPLE, 0, 30)], true), '', false));

diy_case('a client that is gone when the response is written frees the connection', function () {
    [$server, $client] = diy_pair();
    $conn = new DiyConnection($server);
    fwrite($client, GET);
    fclose($client);
    $open = $conn->onReadable();
    $conn->close();
    return $open ? 'the connection is still open' : null;
});

diy_finish();
