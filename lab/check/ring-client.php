<?php
// The client of the checks of the app on a ring (lab/servers/ring-server.php, lab/check.sh `check_ring_*`). It runs in the server's own
// container, on the host network, and talks to the app over raw sockets. Every command prints one line, `ok    <name>` or
// `FAIL  <name>: <why>`, and exits 1 when one fails. Needs `-d extension=sockets` (TCP_NODELAY, so that a split request is really split).
//
//   php ring-client.php <port> split      a request cut in two at every byte boundary of its first 64 bytes (a GET, and a POST with a body)
//                                         gets the answer the whole request gets, and no answer before the second part is sent
//   php ring-client.php <port> pipeline   16 requests in one packet are answered in order, and so is a mix of statuses
//   php ring-client.php <port> big        makes the feed larger than a send slot (20 posts of 500 characters), reads it whole, then
//                                         8 pipelined feeds read in small pieces, then 300 pipelined feeds (6 MB of answers, more than
//                                         the server keeps for one connection) read slowly: all in order, all the same bytes
//   php ring-client.php <port> midclose   1,000 pipelined feeds, a client that reads a little and closes with the rest unread, then a
//                                         fresh connection that is answered
//   php ring-client.php <port> many       300 connections that each send 3 requests at once (for a server started with 2 receive buffers
//                                         and 1 send slot): every answer is there, in order
//   php ring-client.php <port> compare <other port>
//                                         the same raw requests (valid, refused, malformed, HTTP/1.0, Connection: close, pipelined behind a
//                                         close, an oversized head) to this server and to the DIY server on the other port: the same bytes
//                                         back and the same connections closed
//
// The expected values come from the data, not from the server: the posts this client sends, and the seed's post ids.

const HEAD_LIMIT = 65536;

function say(string $name, ?string $failure): void
{
    echo $failure === null ? "ok    $name\n" : "FAIL  $name: $failure\n";
    if ($failure !== null) {
        $GLOBALS['failed'] = true;
    }
}

/** @return resource a blocking connection with TCP_NODELAY and a 10 s read timeout */
function connect_to(int $port)
{
    $fp = stream_socket_client("tcp://127.0.0.1:$port", $errno, $errstr, 5);
    if ($fp === false) {
        throw new RuntimeException("cannot connect: $errstr");
    }
    socket_set_option(socket_import_stream($fp), SOL_TCP, TCP_NODELAY, 1);
    stream_set_timeout($fp, 10);
    return $fp;
}

function get(string $path, string $extra = ''): string
{
    return "GET $path HTTP/1.1\r\nHost: 127.0.0.1\r\nUser-Agent: ring-check\r\nAccept: */*\r\n$extra\r\n";
}

/** Writes all of $bytes to a blocking stream, whatever it takes. */
function write_all($fp, string $bytes): void
{
    while ($bytes !== '') {
        $n = fwrite($fp, $bytes);
        if ($n === false || $n === 0) {
            throw new RuntimeException('the write failed');
        }
        $bytes = substr($bytes, $n);
    }
}

/**
 * Reads $count whole responses. $chunk is how much one fread asks for, $pauseUs a pause between reads (a slow reader).
 *
 * @return list<array{status: int, head: string, body: string}>
 */
function read_responses($fp, int $count, int $chunk = 65536, int $pauseUs = 0): array
{
    $buf = '';
    $out = [];
    while (count($out) < $count) {
        $end = strpos($buf, "\r\n\r\n");
        if ($end !== false) {
            $head = substr($buf, 0, $end);
            if (!preg_match('/^content-length: (\d+)$/mi', $head, $m)) {
                throw new RuntimeException('a response without Content-Length: ' . json_encode(substr($head, 0, 120)));
            }
            $total = $end + 4 + (int) $m[1];
            if (strlen($buf) >= $total) {
                $out[] = ['status' => (int) substr($head, 9, 3), 'head' => $head, 'body' => substr($buf, $end + 4, (int) $m[1])];
                $buf = substr($buf, $total);
                continue;
            }
        } elseif (strlen($buf) > HEAD_LIMIT) {
            throw new RuntimeException('no end of head in ' . HEAD_LIMIT . ' bytes');
        }
        $data = fread($fp, $chunk);
        if ($data === false || $data === '') {
            $why = stream_get_meta_data($fp)['timed_out'] ? 'no data for 10 s' : 'the connection ended';
            throw new RuntimeException("$why after " . count($out) . " of $count responses");
        }
        $buf .= $data;
        if ($pauseUs > 0) {
            usleep($pauseUs);
        }
    }
    if ($buf !== '') {
        throw new RuntimeException('bytes after the last response: ' . json_encode(substr($buf, 0, 80)));
    }
    return $out;
}

function post_id_of(array $response): ?int
{
    return preg_match('/^\{"post":\{"id":(\d+),/', $response['body'], $m) ? (int) $m[1] : null;
}

function cmd_split(int $port): void
{
    $json = '{"body":"hello!!"}';
    $post = "POST /posts HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\nContent-Length: " . strlen($json) . "\r\n\r\n$json";
    $requests = ['GET /posts/7 with 4 headers' => [get('/posts/7', "Authorization: Bearer x\r\nX-Padding: 0123456789\r\n"), 200],
        'POST /posts with a body, no token' => [$post, 401]];
    foreach ($requests as $name => [$request, $status]) {
        $fp = connect_to($port);
        write_all($fp, $request);
        $reference = read_responses($fp, 1)[0];
        fclose($fp);
        if ($reference['status'] !== $status) {
            say("split $name", "the whole request got {$reference['status']}, expected $status");
            continue;
        }
        $failure = null;
        for ($k = 1; $k <= 64 && $failure === null; $k++) {
            $fp = connect_to($port);
            write_all($fp, substr($request, 0, $k));
            usleep(4000);
            $read = [$fp];
            $none = null;
            $early = stream_select($read, $none, $none, 0, 20000);
            if ($early !== 0) {
                $failure = "an answer came after $k bytes, before the request was whole";
            } else {
                write_all($fp, substr($request, $k));
                try {
                    $got = read_responses($fp, 1)[0];
                    if ($got !== $reference) {
                        $failure = "cut after $k bytes the answer is not the whole request's";
                    }
                } catch (RuntimeException $e) {
                    $failure = "cut after $k bytes: " . $e->getMessage();
                }
            }
            fclose($fp);
        }
        say("split $name at every boundary of its first 64 bytes", $failure);
    }
}

function cmd_pipeline(int $port): void
{
    $fp = connect_to($port);
    $bytes = '';
    for ($i = 1; $i <= 16; $i++) {
        $bytes .= get("/posts/$i");
    }
    write_all($fp, $bytes);
    $ids = array_map('post_id_of', read_responses($fp, 16));
    say('16 pipelined requests in one packet, answered in order', $ids === range(1, 16) ? null : 'the ids came back as ' . json_encode($ids));
    $mix = ['/health' => 200, '/posts/3' => 200, '/posts/abc' => 400, '/nope' => 404, '/posts/99999999' => 404, '/posts/2' => 200];
    write_all($fp, implode('', array_map(static fn (string $path): string => get($path), array_keys($mix))));
    $statuses = array_column(read_responses($fp, count($mix)), 'status');
    say('a pipelined mix of statuses, in order', $statuses === array_values($mix) ? null : 'got ' . json_encode($statuses));
    fclose($fp);
}

/** Posts 20 bodies of 500 characters of 2 bytes each as user 1 (the seed's token), so that the feed is over 20 KB. @return list<string> */
function make_big_feed(int $port): array
{
    $token = json_decode((string) file_get_contents('/lab/data/tokens.json'), true)[0]['token'];
    $bodies = [];
    $fp = connect_to($port);
    for ($i = 0; $i < 20; $i++) {
        $bodies[$i] = str_repeat(chr(0xC3) . chr(0xA9), 498) . sprintf('%02x', $i);
        $json = json_encode(['body' => $bodies[$i]], JSON_UNESCAPED_UNICODE);
        write_all($fp, "POST /posts HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer $token\r\nContent-Type: application/json\r\nContent-Length: " . strlen($json) . "\r\n\r\n$json");
        $created = read_responses($fp, 1)[0];
        if ($created['status'] !== 201) {
            throw new RuntimeException("POST /posts answered {$created['status']}: " . substr($created['body'], 0, 100));
        }
    }
    fclose($fp);
    return $bodies;
}

function cmd_big(int $port): void
{
    $bodies = make_big_feed($port);
    $fp = connect_to($port);
    write_all($fp, get('/feed'));
    $feed = read_responses($fp, 1)[0];
    $posts = json_decode($feed['body'], true)['posts'] ?? [];
    $newest = array_reverse($bodies);
    $same = count($posts) === 20 && array_column($posts, 'body') === $newest;
    say('the feed over one send slot (' . strlen($feed['body']) . ' bytes of body) comes whole', strlen($feed['body']) > 16384 && $same ? null
        : 'body of ' . strlen($feed['body']) . ' bytes, ' . count($posts) . ' posts, the bodies ' . ($same ? 'match' : 'do not match what was posted'));
    $one = $feed['head'] . "\r\n\r\n" . $feed['body'];

    write_all($fp, str_repeat(get('/feed'), 8));
    $bad = 0;
    foreach (read_responses($fp, 8, 1000, 500) as $r) {
        $bad += $r['head'] . "\r\n\r\n" . $r['body'] === $one ? 0 : 1;
    }
    say('8 pipelined feeds read in pieces of 1,000 bytes', $bad === 0 ? null : "$bad of 8 differ from the first answer");

    write_all($fp, str_repeat(get('/feed'), 300));
    usleep(300000);
    $bad = 0;
    foreach (read_responses($fp, 300, 16384, 100) as $r) {
        $bad += $r['head'] . "\r\n\r\n" . $r['body'] === $one ? 0 : 1;
    }
    say('300 pipelined feeds (' . round(300 * strlen($one) / 1048576, 1) . ' MiB of answers) read slowly, in order', $bad === 0 ? null : "$bad of 300 differ from the first answer");
    fclose($fp);
}

function cmd_midclose(int $port): void
{
    $fp = connect_to($port);
    write_all($fp, str_repeat(get('/feed'), 1000));
    fread($fp, 100000);
    fclose($fp);
    sleep(1);
    $fp = connect_to($port);
    write_all($fp, get('/posts/5'));
    $answer = read_responses($fp, 1)[0];
    fclose($fp);
    say('a client that left with 1,000 feeds unread, and the next one is answered', post_id_of($answer) === 5 ? null : 'the next answer is ' . json_encode(substr($answer['body'], 0, 60)));
}

function cmd_many(int $port): void
{
    $connections = [];
    for ($c = 0; $c < 300; $c++) {
        $connections[$c] = connect_to($port);
        write_all($connections[$c], get('/posts/' . (3 * $c + 1)) . get('/posts/' . (3 * $c + 2)) . get('/posts/' . (3 * $c + 3)));
    }
    $failure = null;
    foreach ($connections as $c => $fp) {
        try {
            $ids = array_map('post_id_of', read_responses($fp, 3));
        } catch (RuntimeException $e) {
            $failure = "connection $c: " . $e->getMessage();
            break;
        }
        if ($ids !== [3 * $c + 1, 3 * $c + 2, 3 * $c + 3]) {
            $failure = "connection $c got " . json_encode($ids);
            break;
        }
        fclose($fp);
    }
    say('300 connections with 3 requests each, answered in order', $failure);
}

/** What a server sends back for raw bytes: everything it sends until it is quiet for 150 ms or ends the connection. @return array{string, bool} */
function raw_exchange(int $port, string $bytes): array
{
    $fp = connect_to($port);
    stream_set_blocking($fp, false);
    $written = 0;
    while ($written < strlen($bytes)) {
        $n = @fwrite($fp, substr($bytes, $written));
        if ($n === false) {
            break; // the server ended the connection (a reset): what it sent is still to be read
        }
        $written += $n;
        if ($n === 0) {
            usleep(1000);
        }
    }
    $got = '';
    $closed = false;
    while (true) {
        $read = [$fp];
        $none = null;
        if (stream_select($read, $none, $none, 0, 150000) === 0) {
            break;
        }
        $data = @fread($fp, 65536);
        if ($data === false || ($data === '' && feof($fp))) {
            $closed = true;
            break;
        }
        $got .= $data;
    }
    fclose($fp);
    return [$got, $closed];
}

function cmd_compare(int $port, int $other): void
{
    $token = json_decode((string) file_get_contents('/lab/data/tokens.json'), true)[0]['token'];
    $line = static fn (string $target, string $headers = '', string $version = 'HTTP/1.1'): string => "GET $target $version\r\nHost: 127.0.0.1\r\n$headers\r\n";
    $post = static fn (string $headers, string $body): string => "POST /posts HTTP/1.1\r\nHost: 127.0.0.1\r\n$headers" . 'Content-Length: ' . strlen($body) . "\r\n\r\n$body";
    $cases = [
        'a post' => $line('/posts/1'),
        'the last post of the seed' => $line('/posts/500000'),
        'a post that does not exist' => $line('/posts/500001'),
        'ids that are not ids' => $line('/posts/0') . $line('/posts/abc') . $line('/posts/1.5') . $line('/posts/-1') . $line('/posts/1/2') . $line('/posts/'),
        'an unknown route' => $line('/nope'),
        'the feed' => $line('/feed'),
        'a query string' => $line('/posts/2?x=1'),
        'a POST without a token' => $post('', '{"body":"x"}'),
        'a POST with a bad token' => $post("Authorization: Bearer a.b.c\r\n", '{"body":"x"}'),
        'a POST with a token and a body that is not JSON' => $post("Authorization: Bearer $token\r\n", 'nope'),
        'a POST with a token and an empty body' => $post("Authorization: Bearer $token\r\n", '{"body":"  "}'),
        'a POST with a body of 501 characters' => $post("Authorization: Bearer $token\r\n", json_encode(['body' => str_repeat('a', 501)])),
        'a POST whose token has spaces around it' => $post("Authorization:  \tBearer $token \r\n", '{"body":""}'),
        'HTTP/1.0 without keep-alive' => $line('/posts/1', '', 'HTTP/1.0'),
        'HTTP/1.0 with keep-alive' => $line('/posts/1', "Connection: keep-alive\r\n", 'HTTP/1.0') . $line('/posts/2', "Connection: keep-alive\r\n", 'HTTP/1.0'),
        'Connection: close' => $line('/posts/1', "Connection: close\r\n"),
        'two requests behind a Connection: close' => $line('/posts/1', "Connection: Close\r\n") . $line('/posts/2') . $line('/posts/3'),
        'a request line with no version' => "GET /posts/1\r\n\r\n",
        'a bad version' => $line('/posts/1', '', 'HTTP/2.0'),
        'a method that is not letters' => "G3T /posts/1 HTTP/1.1\r\n\r\n",
        'a space before the colon of a header' => $line('/posts/1', "X-A : b\r\n"),
        'a folded header line' => $line('/posts/1', "X-A: b\r\n c\r\n"),
        'a header without a colon' => $line('/posts/1', "Nonsense\r\n"),
        'Transfer-Encoding' => $post("Transfer-Encoding: chunked\r\n", "0\r\n\r\n"),
        'two Content-Length headers' => "POST /posts HTTP/1.1\r\nContent-Length: 2\r\nContent-Length: 2\r\n\r\n{}",
        'a Content-Length that is not digits' => "POST /posts HTTP/1.1\r\nContent-Length: 2x\r\n\r\n{}",
        'a Content-Length over the body limit' => "POST /posts HTTP/1.1\r\nContent-Length: 1048577\r\n\r\n",
        'a head over 8 KiB' => $line('/posts/1', str_repeat("X-Padding: " . str_repeat('a', 100) . "\r\n", 90)),
        'more than 8 KiB with no end of head' => 'GET /posts/1 HTTP/1.1' . str_repeat("\r\nX-Padding: aaaaaaaaaaaaaaaaaaaaaaaa", 300),
        'a request after a bad one' => "BAD\r\n\r\n" . $line('/posts/1'),
        'a request line cut before its end' => "GET /posts/1 HTT",
    ];
    $different = [];
    foreach ($cases as $name => $bytes) {
        $mine = raw_exchange($port, $bytes);
        $theirs = raw_exchange($other, $bytes);
        if ($mine !== $theirs) {
            $different[] = $name . ' (' . strlen($mine[0]) . ' bytes' . ($mine[1] ? ', closed' : '') . ' against ' . strlen($theirs[0]) . ' bytes' . ($theirs[1] ? ', closed' : '') . ')';
        }
    }
    say(count($cases) . ' raw requests answered byte for byte like the DIY server, with the same connections closed',
        $different === [] ? null : 'different: ' . implode('; ', $different));
}

$failed = false;
$port = (int) ($argv[1] ?? 0);
$command = $argv[2] ?? '';
if ($port < 1 || !function_exists('cmd_' . $command) || ($command === 'compare' && (int) ($argv[3] ?? 0) < 1)) {
    fwrite(STDERR, "usage: php ring-client.php <port> split|pipeline|big|midclose|many|compare <other port>\n");
    exit(2);
}
try {
    ('cmd_' . $command)($port, ...array_map('intval', array_slice($argv, 3)));
} catch (Throwable $e) {
    say($command, get_class($e) . ': ' . $e->getMessage());
}
exit($failed ? 1 : 0);
