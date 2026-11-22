<?php
// Shared by the DIY server's two tests (diy-parser-test.php, diy-partial-write-test.php): a stub handler, a socket pair that
// stands in for a client, and the one-line-per-case output of the lab's other tests (`ok    <case>` / `FAIL  <case>: <why>`).
//
// The stub is defined here and handler.php is not loaded: DiyConnection calls the global handler_handle() like every adapter, and
// a stub that echoes what the parser extracted shows what reached the handler.

require __DIR__ . '/../servers/diy-connection.php';

/**
 * /big/<n> answers n bytes (n a multiple of 16) of counters, so that a byte lost, repeated or moved shows in a comparison;
 * /boom throws, like a handler whose database read fails; anything else echoes `<method> <path> <body>`.
 *
 * @return array{int, string}
 */
function handler_handle(string $method, string $path, string $body): array
{
    if (str_starts_with($path, '/big/')) {
        return [200, diy_body((int) substr($path, 5))];
    }
    if ($path === '/boom') {
        throw new RuntimeException('the database is locked');
    }
    return [200, '{"echo":"' . $method . ' ' . $path . ' ' . $body . '"}'];
}

function diy_body(int $bytes): string
{
    $body = '';
    for ($i = 0; $i < intdiv($bytes, 16); $i++) {
        $body .= sprintf('%015d,', $i);
    }
    return $body;
}

/** @return array{resource, resource} the server's end and the client's end, both non-blocking */
function diy_pair(): array
{
    $pair = stream_socket_pair(STREAM_PF_UNIX, STREAM_SOCK_STREAM, STREAM_IPPROTO_IP);
    if ($pair === false) {
        throw new RuntimeException('cannot make a socket pair');
    }
    stream_set_blocking($pair[0], false);
    stream_set_blocking($pair[1], false);
    return $pair;
}

/** Everything the peer can read right now. */
function diy_read_all($peer): string
{
    $all = '';
    while (($chunk = fread($peer, 65536)) !== false && $chunk !== '') {
        $all .= $chunk;
    }
    return $all;
}

$diy_failed = false;

/** Runs one case: $fn returns null when it holds, or the reason it does not. */
function diy_case(string $name, callable $fn): void
{
    global $diy_failed;
    try {
        $why = $fn();
    } catch (Throwable $e) {
        $why = get_class($e) . ': ' . $e->getMessage();
    }
    if ($why === null || str_starts_with($why, 'ok:')) {
        echo "ok    $name" . ($why === null ? '' : ' (' . substr($why, 3) . ')') . "\n";
    } else {
        echo "FAIL  $name: $why\n";
        $diy_failed = true;
    }
}

function diy_finish(): never
{
    global $diy_failed;
    exit($diy_failed ? 1 : 0);
}

/** A short printable form of bytes for a failure message. */
function diy_show(string $bytes): string
{
    return json_encode(strlen($bytes) > 200 ? substr($bytes, 0, 200) . '...(' . strlen($bytes) . ' bytes)' : $bytes, JSON_INVALID_UTF8_SUBSTITUTE);
}
