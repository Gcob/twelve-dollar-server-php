<?php
// The client of lab/conformance.sh: raw sockets (no curl, no HTTP library), so what a server sends is what is checked.
//
//   php client.php poll <port>   one try: exit 0 if something accepts connections on 127.0.0.1:<port>, 1 if not
//   php client.php run <port>    run the cases, one line each: `ok    <case>` or `FAIL  <case>: <why>`; exit 1 if any fails
//
// Env for `run`: EXPECTED_POST_1, the JSON object SQLite gives for post 1 (computed outside, from the seed).

const POST_KEYS = ['id', 'body', 'created_at', 'author', 'like_count'];

final class Conn
{
    /** @var resource */
    private $fp;
    private string $buf = '';

    public function __construct(int $port)
    {
        $fp = @stream_socket_client("tcp://127.0.0.1:$port", $errno, $errstr, 5);
        if ($fp === false) {
            throw new RuntimeException("cannot connect: $errstr");
        }
        stream_set_timeout($fp, 5);
        $this->fp = $fp;
    }

    public function write(string $bytes): void
    {
        if (@fwrite($this->fp, $bytes) !== strlen($bytes)) {
            throw new RuntimeException('the server closed the connection before the request was written');
        }
    }

    public function get(string $path, int $port): void
    {
        $this->write("GET $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\n\r\n");
    }

    private function fill(): void
    {
        $chunk = fread($this->fp, 65536);
        if ($chunk === false || $chunk === '') {
            $meta = stream_get_meta_data($this->fp);
            throw new RuntimeException($meta['timed_out'] ? 'no answer within 5 s' : 'the server closed the connection');
        }
        $this->buf .= $chunk;
    }

    /** @return array{status: int, headers: array<string, string>, body: string, raw: string} */
    public function response(): array
    {
        while (($end = strpos($this->buf, "\r\n\r\n")) === false) {
            $this->fill();
        }
        $head = substr($this->buf, 0, $end);
        $lines = explode("\r\n", $head);
        if (!preg_match('#^HTTP/1\.1 (\d{3}) #', $lines[0], $m)) {
            throw new RuntimeException('bad status line: ' . json_encode($lines[0]));
        }
        $headers = [];
        foreach (array_slice($lines, 1) as $line) {
            [$name, $value] = array_pad(explode(':', $line, 2), 2, '');
            $headers[strtolower(trim($name))] = trim($value);
        }
        $bodyStart = $end + 4;
        if (isset($headers['content-length'])) {
            $length = (int) $headers['content-length'];
            while (strlen($this->buf) < $bodyStart + $length) {
                $this->fill();
            }
            $body = substr($this->buf, $bodyStart, $length);
            $consumed = $bodyStart + $length;
        } elseif (strtolower($headers['transfer-encoding'] ?? '') === 'chunked') {
            $body = '';
            $pos = $bodyStart;
            while (true) {
                while (($eol = strpos($this->buf, "\r\n", $pos)) === false) {
                    $this->fill();
                }
                $size = (int) hexdec(substr($this->buf, $pos, $eol - $pos));
                while (strlen($this->buf) < $eol + 2 + $size + 2) {
                    $this->fill();
                }
                $body .= substr($this->buf, $eol + 2, $size);
                $pos = $eol + 2 + $size + 2;
                if ($size === 0) {
                    break;
                }
            }
            $consumed = $pos;
        } else {
            throw new RuntimeException('no Content-Length and not chunked: the end of the body is unknown');
        }
        $raw = substr($this->buf, 0, $consumed);
        $this->buf = substr($this->buf, $consumed);
        return ['status' => (int) $m[1], 'headers' => $headers, 'body' => $body, 'raw' => $raw];
    }

    public function close(): void
    {
        fclose($this->fp);
    }
}

function expect_json(array $r, int $status, array $json, string $what): void
{
    if ($r['status'] !== $status) {
        throw new RuntimeException("$what: status {$r['status']}, expected $status (body " . json_encode($r['body']) . ')');
    }
    $got = json_decode($r['body'], true);
    if ($got !== $json) {
        throw new RuntimeException("$what: body " . json_encode($r['body']) . ' is not ' . json_encode($json));
    }
}

function expect_post_1(array $r, string $what): void
{
    $expected = json_decode((string) getenv('EXPECTED_POST_1'), true);
    if (!is_array($expected)) {
        throw new RuntimeException('EXPECTED_POST_1 is not a JSON object');
    }
    if ($r['status'] !== 200) {
        throw new RuntimeException("$what: status {$r['status']}, expected 200");
    }
    $got = json_decode($r['body'], true);
    if (!is_array($got) || array_keys($got) !== ['post'] || !is_array($got['post'])) {
        throw new RuntimeException("$what: body is not {\"post\":{...}}: " . substr($r['body'], 0, 200));
    }
    if (array_keys($got['post']) !== POST_KEYS) {
        throw new RuntimeException("$what: keys are " . implode(',', array_keys($got['post'])) . ', expected ' . implode(',', POST_KEYS));
    }
    // Same keys in the same order, so === compares the values and their types (an int stays an int).
    if ($got['post'] !== $expected) {
        throw new RuntimeException("$what: post is " . json_encode($got['post']) . ', SQLite gives ' . json_encode($expected));
    }
}

function expect_content_type_json(array $r): void
{
    $type = $r['headers']['content-type'] ?? '(none)';
    if (!preg_match('#^application/json(;\s*charset=utf-8)?$#i', $type)) {
        throw new RuntimeException("Content-Type is '$type', expected application/json");
    }
}

/** @return array<string, callable(int): ?string> a case returns text to print after its `ok`, or null */
function cases(): array
{
    return [
        'noop' => function (int $port): ?string {
            $c = new Conn($port);
            $c->get('/noop', $port);
            $r = $c->response();
            expect_json($r, 200, ['status' => 'ok'], 'GET /noop');
            if ($r['body'] !== '{"status":"ok"}') {
                throw new RuntimeException('GET /noop: body is ' . json_encode($r['body']) . ', expected {"status":"ok"} byte for byte');
            }
            expect_content_type_json($r);
            return null;
        },
        'post 1' => function (int $port): ?string {
            $c = new Conn($port);
            $c->get('/posts/1', $port);
            expect_post_1($c->response(), 'GET /posts/1');
            return null;
        },
        'errors' => function (int $port): ?string {
            $c = new Conn($port);
            $expected = [
                ['/posts/999999999', 404, 'post not found'],
                ['/posts/abc', 400, 'invalid post id'],
                ['/posts/0', 400, 'invalid post id'],
                ['/posts/-1', 400, 'invalid post id'],
                ['/posts/1.5', 400, 'invalid post id'],
                ['/posts/', 400, 'invalid post id'],
                ['/nope', 404, 'not found'],
                ['/posts/1/like', 404, 'not found'],
            ];
            foreach ($expected as [$path, $status, $message]) {
                $c->get($path, $port);
                $r = $c->response();
                expect_json($r, $status, ['error' => $message], "GET $path");
                expect_content_type_json($r);
            }
            return null;
        },
        'keep-alive' => function (int $port): ?string {
            $c = new Conn($port);
            $c->get('/noop', $port);
            expect_json($c->response(), 200, ['status' => 'ok'], 'first request');
            $c->get('/posts/1', $port);
            expect_post_1($c->response(), 'second request on the same connection');
            return null;
        },
        'pipelining' => function (int $port): ?string {
            $c = new Conn($port);
            $request = static fn (string $path): string => "GET $path HTTP/1.1\r\nHost: 127.0.0.1:$port\r\n\r\n";
            $c->write($request('/noop') . $request('/posts/1') . $request('/nope'));
            expect_json($c->response(), 200, ['status' => 'ok'], 'first pipelined request');
            expect_post_1($c->response(), 'second pipelined request');
            expect_json($c->response(), 404, ['error' => 'not found'], 'third pipelined request');
            return null;
        },
        'split request' => function (int $port): ?string {
            $c = new Conn($port);
            $c->write("GET /posts/1 HTTP/1.1\r\nHo");
            usleep(50000);
            $c->write("st: 127.0.0.1:$port\r\n\r\n");
            expect_post_1($c->response(), 'request split in the middle of the headers');
            return null;
        },
        'body then reuse' => function (int $port): ?string {
            $c = new Conn($port);
            $c->write("POST /nope HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nContent-Type: application/json\r\nContent-Length: 11\r\n\r\nhello world");
            expect_json($c->response(), 404, ['error' => 'not found'], 'POST /nope');
            $c->get('/noop', $port);
            expect_json($c->response(), 200, ['status' => 'ok'], 'GET /noop on the connection that carried the body');
            return null;
        },
        'response bytes' => function (int $port): ?string {
            $c = new Conn($port);
            $c->get('/noop', $port);
            $r = $c->response();
            $lines = explode("\r\n", $r['raw']);
            $last = count($lines) - 1;
            $out = [];
            foreach ($lines as $i => $line) {
                $out[] = '    ' . $line . ($i < $last ? '\r\n' : '');
            }
            return "GET /noop answers, byte for byte:\n" . implode("\n", $out);
        },
    ];
}

$mode = $argv[1] ?? '';
$port = (int) ($argv[2] ?? 0);
if ($port < 1) {
    fwrite(STDERR, "usage: php client.php poll|run <port>\n");
    exit(2);
}

if ($mode === 'poll') { // one try, for the readiness check that has to look at the server container between tries
    $fp = @stream_socket_client("tcp://127.0.0.1:$port", $errno, $errstr, 1);
    if ($fp === false) {
        exit(1);
    }
    fclose($fp);
    exit(0);
}
if ($mode !== 'run') {
    fwrite(STDERR, "usage: php client.php poll|run <port>\n");
    exit(2);
}

$failed = false;
foreach (cases() as $name => $case) {
    try {
        $note = $case($port);
        echo "ok    $name\n";
        if ($note !== null) {
            echo $note, "\n";
        }
    } catch (Throwable $e) {
        $failed = true;
        echo "FAIL  $name: ", $e->getMessage(), "\n";
    }
}
exit($failed ? 1 : 0);
