<?php
// What reading the head of one request costs in the DIY server (lab/servers/diy-connection.php): today's parseHead() against
// a lean parse, on the heads k6 sends. Format: "Micro benchmarks" in lab/README.md.
//
// The heads are k6 1.8.3's own, captured from its requests to a listening socket (realistic.js's GET /feed with no header of its own, and its
// POST /posts/<id>/like with Authorization and Content-Type; k6 adds Host, User-Agent and, on a POST, Content-Length). Only the token is
// not the captured one: it is the seed's first token, 179 characters like every user's of the bench. k6 sends no Connection header.
//
// Both parses are private methods: a closure bound to their object calls each (a call of a few ns, the same for both, inside every number).
// Every case checks, outside the timing, that the two parsers take the head alike (same verdict, method, target, body length,
// authorization, close flag), on its own head and on a battery of heads that includes every refusal of the server's parser.

require_once __DIR__ . '/../../servers/diy-connection.php';

const PARSE_BENCH_FEED = "GET /feed HTTP/1.1\r\nHost: 127.0.0.1:3000\r\nUser-Agent: Grafana k6/1.8.3";
const PARSE_BENCH_LIKE = "POST /posts/42/like HTTP/1.1\r\nHost: 127.0.0.1:3000\r\nUser-Agent: Grafana k6/1.8.3\r\nContent-Length: 0\r\n"
    . "Authorization: Bearer {token}\r\nContent-Type: application/json";
const PARSE_BENCH_CREATE = "POST /posts HTTP/1.1\r\nHost: 127.0.0.1:3000\r\nUser-Agent: Grafana k6/1.8.3\r\nContent-Length: 19\r\n"
    . "Authorization: Bearer {token}\r\nContent-Type: application/json";

/** The candidate: the lean parse, with the properties DiyConnection's parseHead() sets. The server does not use it (see the table in parse-run/). */
final class ParseBenchLean
{
    private string $method = '';
    private string $target = '';
    private string $authorization = '';
    private int $bodyLength = 0;
    private bool $closeAfter = false;

    /**
     * DiyConnection::parseHead() without the array explode() makes of the header lines and the string each line becomes: it walks the head by
     * offsets and only builds the values it keeps. Same rules, same refusals, same properties. The request line is read by offsets too.
     */
    private function parse(string $head): bool
    {
        $length = strlen($head);
        $eol = strpos($head, "\r\n");
        $lineEnd = $eol === false ? $length : $eol;
        $sp1 = strpos($head, ' ');
        if ($sp1 === false || $sp1 === 0 || $sp1 >= $lineEnd) {
            return false;
        }
        $sp2 = $lineEnd - 9;
        if ($sp2 < $sp1 + 2 || $head[$sp2] !== ' ' || substr_compare($head, 'HTTP/1.', $sp2 + 1, 7) !== 0
            || ($head[$lineEnd - 1] !== '1' && $head[$lineEnd - 1] !== '0')) {
            return false;
        }
        $this->method = substr($head, 0, $sp1);
        $this->target = substr($head, $sp1 + 1, $sp2 - $sp1 - 1);
        if (!ctype_alpha($this->method) || str_contains($this->target, ' ')) {
            return false;
        }

        $this->bodyLength = 0;
        $this->authorization = '';
        $close = false;
        $keepAlive = false;
        $hasLength = false;
        // Why: a head that ends in a line break has an empty last header line, which parseHead() refuses; $pos <= $length reaches it too.
        $pos = $eol === false ? $length + 1 : $eol + 2;
        while ($pos <= $length) {
            $end = strpos($head, "\r\n", $pos);
            if ($end === false) {
                $end = $length;
            }
            $colon = strpos($head, ':', $pos);
            // Why: the colon must be in this line, not in a later one (strpos looks past the end of the line).
            if ($colon === false || $colon >= $end || $colon === $pos || $head[$colon - 1] === ' ' || $head[$colon - 1] === "\t" || $head[$pos] === ' ' || $head[$pos] === "\t") {
                return false;
            }
            $name = $colon - $pos;
            if ($name === 14 && substr_compare($head, 'content-length', $pos, 14, true) === 0) {
                $value = trim(substr($head, $colon + 1, $end - $colon - 1), " \t");
                if ($hasLength || !ctype_digit($value) || strlen($value) > 7 || (int) $value > DiyConnection::BODY_LIMIT) {
                    return false;
                }
                $hasLength = true;
                $this->bodyLength = (int) $value;
            } elseif ($name === 10 && substr_compare($head, 'connection', $pos, 10, true) === 0) {
                $value = strtolower(substr($head, $colon + 1, $end - $colon - 1));
                $close = str_contains($value, 'close');
                $keepAlive = str_contains($value, 'keep-alive');
            } elseif ($name === 13 && substr_compare($head, 'authorization', $pos, 13, true) === 0) {
                $this->authorization = trim(substr($head, $colon + 1, $end - $colon - 1), " \t");
            } elseif ($name === 17 && substr_compare($head, 'transfer-encoding', $pos, 17, true) === 0) {
                return false;
            }
            $pos = $end + 2;
        }
        $this->closeAfter = $close || ($head[$lineEnd - 1] === '0' && !$keepAlive);
        return true;
    }
}

/** The seed's first token (lab/data/tokens.json): the length of the bench's own. */
function parse_bench_token(): string
{
    $tokens = json_decode((string) file_get_contents('/lab/data/tokens.json'), true);
    $token = $tokens[0]['token'] ?? '';
    if (!is_string($token) || $token === '') {
        throw new RuntimeException('/lab/data/tokens.json has no token (run lab/seed.sh)');
    }
    return $token;
}

/** The two parsers, each bound to its own object: [today's parseHead, the lean parse, what today's found, what the lean one found]. */
function parse_bench_parsers(): array
{
    $conn = new DiyConnection(fopen('php://memory', 'r'));
    $lean = new ParseBenchLean();
    $found = fn (): array => [$this->method, $this->target, $this->bodyLength, $this->authorization, $this->closeAfter];
    return [
        Closure::bind(fn (string $head): bool => $this->parseHead($head), $conn, DiyConnection::class),
        Closure::bind(fn (string $head): bool => $this->parse($head), $lean, ParseBenchLean::class),
        Closure::bind($found, $conn, DiyConnection::class),
        Closure::bind($found, $lean, ParseBenchLean::class),
    ];
}

/** What a parser made of a head: false, or the five things it hands the handler and the connection. */
function parse_bench_found(Closure $parse, Closure $found, string $head): array|false
{
    // Why: a refused head leaves half of the properties set, so only the verdict is compared for it.
    return $parse($head) ? $found() : false;
}

/** The heads whose verdict matters: every refusal of the parser, and the accepted forms next to them. */
function parse_bench_battery(): array
{
    $heads = [
        'plain' => "GET /noop HTTP/1.1\r\nHost: x",
        'request line only' => 'GET /noop HTTP/1.1',
        'HTTP/1.0' => "GET /noop HTTP/1.0\r\nHost: x",
        'HTTP/1.0 keep-alive' => "GET /noop HTTP/1.0\r\nConnection: Keep-Alive",
        'Connection: close' => "GET /noop HTTP/1.1\r\nConnection: close",
        'Connection: keep-alive, close' => "GET /noop HTTP/1.1\r\nCONNECTION: Keep-Alive, Close",
        'Authorization, any case' => "GET /auth HTTP/1.1\r\nauthorization:   Bearer  a b \t",
        'Authorization empty' => "GET /auth HTTP/1.1\r\nAuthorization:",
        'Content-Length' => "POST /x HTTP/1.1\r\ncontent-LENGTH: 5",
        'Content-Length padded' => "POST /x HTTP/1.1\r\nContent-Length: \t 5 \t",
        'Content-Length 1 MiB' => "POST /x HTTP/1.1\r\nContent-Length: 1048576",
        'a colon in a value' => "GET /x HTTP/1.1\r\nHost: a:b:c\r\nX-A: :",
        'a header name of a length we read, another name' => "GET /x HTTP/1.1\r\nUser-Agent: k6\r\nX-Longer-Header-: y",
        'a bare line break in a value' => "GET /x HTTP/1.1\r\nX-A: a\nb",
        'a carriage return at the end' => "GET /x HTTP/1.1\r\nX-A: b\r",
        'no version' => 'GET /noop',
        'unknown version' => 'GET /noop HTTP/2.0',
        'HTTP/1.2' => 'GET /noop HTTP/1.2',
        'a space after the version' => 'GET /noop HTTP/1.1 ',
        'a letter after the version' => 'GET /noop HTTP/1.1X',
        'a space inside the version' => 'GET /noop HTTP/ 1.1',
        'a version with no target' => 'GET HTTP/1.1',
        'a space in the second line only' => "GET\r\nX-A: b c",
        'no method' => ' /noop HTTP/1.1',
        'no target' => 'GET  HTTP/1.1',
        'a space in the target' => 'GET /a b HTTP/1.1',
        'a method that is not letters' => 'G3T /x HTTP/1.1',
        'garbage' => "\x00\x01\x02\x03",
        'header without a colon' => "GET /noop HTTP/1.1\r\nbad header",
        'header without a colon, a colon in the next line' => "GET /noop HTTP/1.1\r\nbad header\r\nX-A: b",
        'header without a name' => "GET /noop HTTP/1.1\r\n: x",
        'an empty header line' => "GET /noop HTTP/1.1\r\n\r\nX-A: b",
        'the head ends in a line break' => "GET /noop HTTP/1.1\r\nX-A: b\r\n",
        'the request line ends in a line break' => "GET /noop HTTP/1.1\r\n",
        'Content-Length: abc' => "POST /x HTTP/1.1\r\nContent-Length: abc",
        'Content-Length: -1' => "POST /x HTTP/1.1\r\nContent-Length: -1",
        'Content-Length: 5x' => "POST /x HTTP/1.1\r\nContent-Length: 5x",
        'Content-Length empty' => "POST /x HTTP/1.1\r\nContent-Length:",
        'two Content-Length' => "POST /x HTTP/1.1\r\nContent-Length: 5\r\nContent-Length: 5",
        'Content-Length over 1 MiB' => "POST /x HTTP/1.1\r\nContent-Length: 1048577",
        'Content-Length of 8 digits' => "POST /x HTTP/1.1\r\nContent-Length: 00000005",
        'a space before the colon' => "POST /x HTTP/1.1\r\nContent-Length : 5",
        'a tab before the colon' => "POST /x HTTP/1.1\r\nContent-Length\t: 5",
        'a space before the colon, on a header we ignore' => "GET /x HTTP/1.1\r\nX-A : b",
        'an obsolete line fold' => "GET /noop HTTP/1.1\r\nX-A: b\r\n c",
        'an obsolete line fold with a tab' => "GET /noop HTTP/1.1\r\nX-A: b\r\n\tc: d",
        'Transfer-Encoding: chunked' => "POST /x HTTP/1.1\r\nTransfer-Encoding: chunked",
        'Transfer-Encoding after a Content-Length' => "POST /x HTTP/1.1\r\nContent-Length: 5\r\ntransfer-encoding: chunked",
        'Transfer-Encoding, any case' => "POST /x HTTP/1.1\r\nTRANSFER-ENCODING: gzip",
    ];
    foreach (['feed' => PARSE_BENCH_FEED, 'like' => PARSE_BENCH_LIKE, 'create' => PARSE_BENCH_CREATE] as $name => $head) {
        $heads["k6's $name"] = strtr($head, ['{token}' => 'a.b.c']);
    }
    return $heads;
}

/** The first difference between the two parsers on a head, or null. */
function parse_bench_difference(array $parsers, string $head): ?string
{
    [$today, $lean, $todayFound, $leanFound] = $parsers;
    $a = parse_bench_found($today, $todayFound, $head);
    $b = parse_bench_found($lean, $leanFound, $head);
    return $a === $b ? null : 'today ' . json_encode($a) . ', lean ' . json_encode($b) . ' on ' . json_encode($head);
}

/** The case of one head: the timed call is one parser; $expected is what it must find, written out by hand. */
function parse_bench_case(string $head, array $expected, bool $lean): array
{
    return [
        'setup' => function () use ($head, $expected, $lean): array {
            $token = parse_bench_token();
            $expected[3] = strtr($expected[3], ['{token}' => $token]);
            $parsers = parse_bench_parsers();
            return ['head' => strtr($head, ['{token}' => $token]), 'parsers' => $parsers, 'at' => $lean ? 1 : 0, 'expected' => $expected];
        },
        'run' => fn (array $ctx) => ($ctx['parsers'][$ctx['at']])($ctx['head']),
        'check' => function (mixed $result, array $ctx): bool|string {
            $found = $ctx['parsers'][$ctx['at'] + 2]();
            if ($result !== true || $found !== $ctx['expected']) {
                return 'the parser found ' . json_encode([$result, $found]) . ', expected ' . json_encode($ctx['expected']);
            }
            // The two parsers on this head, then on the battery: same verdict, same properties.
            foreach ([$ctx['head'], ...parse_bench_battery()] as $head) {
                $why = parse_bench_difference($ctx['parsers'], $head);
                if ($why !== null) {
                    return $why;
                }
            }
            return true;
        },
    ];
}

// [method, target, body length, authorization, close flag] by hand, from the heads above.
$feed = ['GET', '/feed', 0, '', false];
$like = ['POST', '/posts/42/like', 0, 'Bearer {token}', false];

return [
    "GET /feed head (3 lines), today's parseHead" => parse_bench_case(PARSE_BENCH_FEED, $feed, false),
    'GET /feed head (3 lines), lean' => parse_bench_case(PARSE_BENCH_FEED, $feed, true),
    "POST /posts/42/like head (6 lines), today's parseHead" => parse_bench_case(PARSE_BENCH_LIKE, $like, false),
    'POST /posts/42/like head (6 lines), lean' => parse_bench_case(PARSE_BENCH_LIKE, $like, true),
    "POST /posts head with a body (6 lines), today's parseHead" => parse_bench_case(PARSE_BENCH_CREATE, ['POST', '/posts', 19, 'Bearer {token}', false], false),
    'POST /posts head with a body (6 lines), lean' => parse_bench_case(PARSE_BENCH_CREATE, ['POST', '/posts', 19, 'Bearer {token}', false], true),
];
