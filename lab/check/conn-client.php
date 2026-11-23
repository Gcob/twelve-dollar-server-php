<?php
// A small client for the checks of the DIY server's connection limits (lab/check.sh). It runs in a container on the host network and
// prints one JSON object per line.
//
//   php conn-client.php <port> seq <n> [--keep]
//       Opens <n> connections one after the other; each sends GET /health and reads the whole response. A response that says
//       `Connection: close` must be followed by the end of the stream. Without --keep each connection is closed when it is done; with it
//       they all stay open, and the summary tells for each whether the server closed it.
//       Prints {"event":"seq","n","answered","close_header","server_closed","kept_alive","errors":[...]} (and "connections": [...] with --keep).
//   php conn-client.php <port> burst <n> <hold seconds>
//       Opens <n> connections at once, each with one request. After 1.5 s prints {"event":"phase1","answered":k}, holds for <hold> seconds,
//       then closes the answered ones (the server's seats go to the ones still waiting) and reads until all are answered or 15 s have
//       passed. Prints {"event":"done","answered","errors"}.

const REQUEST = "GET /health HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";

function emit(array $event): void
{
    fwrite(STDOUT, json_encode($event, JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE) . "\n");
}

/** Whether $buf holds a whole response: its head, and as many body bytes as Content-Length says. */
function whole_response(string $buf): bool
{
    $end = strpos($buf, "\r\n\r\n");
    if ($end === false) {
        return false;
    }
    $length = preg_match('/^content-length:\s*(\d+)/mi', substr($buf, 0, $end), $m) ? (int) $m[1] : 0;
    return strlen($buf) >= $end + 4 + $length;
}

function says_close(string $buf): bool
{
    return preg_match('/^connection:\s*close\s*$/mi', (string) substr($buf, 0, (int) strpos($buf, "\r\n\r\n"))) === 1;
}

/** Reads one whole response from a blocking stream (2 s timeout). @return array{string, string|null} the bytes and the failure */
function read_response($fp): array
{
    $buf = '';
    while (!whole_response($buf)) {
        $chunk = fread($fp, 8192);
        if ($chunk === false || $chunk === '') {
            return [$buf, stream_get_meta_data($fp)['timed_out'] ? 'no response within 2 s' : 'closed or reset before the response was whole'];
        }
        $buf .= $chunk;
    }
    return [$buf, null];
}

$port = (int) ($argv[1] ?? 0);
$mode = $argv[2] ?? '';
if ($port < 1 || !in_array($mode, ['seq', 'burst'], true)) {
    fwrite(STDERR, "usage: conn-client.php <port> seq <n> [--keep] | burst <n> <hold seconds>\n");
    exit(2);
}

if ($mode === 'seq') {
    $n = (int) ($argv[3] ?? 0);
    $keep = in_array('--keep', $argv, true);
    $summary = ['event' => 'seq', 'n' => $n, 'answered' => 0, 'close_header' => 0, 'server_closed' => 0, 'kept_alive' => 0, 'errors' => []];
    $held = [];
    for ($i = 0; $i < $n; $i++) {
        $fp = @stream_socket_client("tcp://127.0.0.1:$port", $errno, $errstr, 2);
        if ($fp === false) {
            $summary['errors'][] = "connection $i: connect failed: $errstr ($errno)";
            continue;
        }
        stream_set_timeout($fp, 2);
        fwrite($fp, REQUEST);
        [$buf, $failure] = read_response($fp);
        if ($failure !== null || !str_starts_with($buf, 'HTTP/1.1 200 ')) {
            $summary['errors'][] = "connection $i: " . ($failure ?? 'not a 200: ' . substr($buf, 0, 40));
            fclose($fp);
            continue;
        }
        $summary['answered']++;
        $closing = says_close($buf);
        $summary['close_header'] += (int) $closing;
        if ($keep) {
            $held[$i] = [$fp, $closing];
            continue;
        }
        if ($closing) {
            // The end of the stream must follow the response.
            $more = fread($fp, 1);
            if ($more === '' && feof($fp)) {
                $summary['server_closed']++;
            } else {
                $summary['errors'][] = "connection $i: said close, then " . var_export($more, true);
            }
        } else {
            $summary['kept_alive']++;
        }
        fclose($fp);
    }
    if ($keep) {
        usleep(300000);
        $summary['connections'] = [];
        foreach ($held as $i => [$fp, $closing]) {
            stream_set_blocking($fp, false);
            $more = fread($fp, 1);
            $ended = $more === '' && feof($fp);
            $summary['server_closed'] += (int) $ended;
            $summary['kept_alive'] += (int) !$ended;
            $summary['connections'][] = ['close_header' => $closing, 'server_closed' => $ended];
        }
    }
    emit($summary);
    exit($summary['errors'] === [] ? 0 : 1);
}

$n = (int) ($argv[3] ?? 0);
$hold = (float) ($argv[4] ?? 0);
/** @var array<int, resource> $pending connections without a whole response yet */
$pending = [];
/** @var array<int, resource> $answered connections with a whole response, still open */
$answered = [];
$answeredCount = 0;
$errors = [];
$bufs = [];
for ($i = 0; $i < $n; $i++) {
    $fp = @stream_socket_client("tcp://127.0.0.1:$port", $errno, $errstr, 5);
    if ($fp === false) {
        $errors[] = "connection $i: connect failed: $errstr ($errno)";
        continue;
    }
    stream_set_blocking($fp, false);
    fwrite($fp, REQUEST);
    $pending[$i] = $fp;
    $bufs[$i] = '';
}

/** Reads what arrives on the pending connections for up to $seconds; a whole response moves its connection to $answered. */
$pump = function (float $seconds) use (&$pending, &$answered, &$answeredCount, &$errors, &$bufs): void {
    $until = microtime(true) + $seconds;
    while (microtime(true) < $until && $pending !== []) {
        $read = array_values($pending);
        $write = $except = null;
        if (stream_select($read, $write, $except, 0, 100000) < 1) {
            continue;
        }
        foreach ($read as $fp) {
            $i = array_search($fp, $pending, true);
            $chunk = fread($fp, 8192);
            if ($chunk === false || ($chunk === '' && feof($fp))) {
                $errors[] = "connection $i: closed or reset before the response was whole";
                unset($pending[$i]);
                fclose($fp);
                continue;
            }
            $bufs[$i] .= $chunk;
            if (whole_response($bufs[$i])) {
                $answered[$i] = $fp;
                $answeredCount++;
                unset($pending[$i]);
            }
        }
    }
};

$pump(1.5);
emit(['event' => 'phase1', 'answered' => $answeredCount, 'waiting' => count($pending)]);
usleep((int) ($hold * 1e6));
// The seats of the answered connections go to the ones still waiting.
$until = microtime(true) + 15;
while ($pending !== [] && microtime(true) < $until) {
    foreach ($answered as $i => $fp) {
        fclose($fp);
        unset($answered[$i]);
    }
    $pump(0.5);
}
emit(['event' => 'done', 'answered' => $answeredCount, 'still_waiting' => count($pending), 'errors' => $errors]);
exit($answeredCount === $n ? 0 : 1);
