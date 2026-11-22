<?php
// One client connection of the DIY server: reads bytes, parses HTTP/1.1 requests out of them, calls handler_handle() (a global
// function, like in every adapter) and writes the responses. The call is handler_handle($method, $target, $body, $authorization):
// the bake-off's handler takes the first three and ignores the fourth, the challenge app's takes all four. It works on any non-blocking stream and knows
// nothing about the event loop: the loop calls onReadable() / onWritable() when the stream is ready, and asks wantsRead() /
// wantsWrite() which events to wait for. That is also what lets the tests drive it on a socket pair.
//
// What it parses: the request line (method, target, HTTP/1.1 or HTTP/1.0), the headers (only Content-Length, Connection,
// Transfer-Encoding and Authorization are read; every other header line only has to have a name and a colon), a body of
// Content-Length bytes. The Authorization value is handed over without its surrounding spaces and tabs, and is '' when the request
// has none (a request never sees the one before it). What it does not parse: chunked bodies (400), absolute-form targets (the handler answers 404), lines
// ended by a bare \n (the request never completes, and a client that sends 8 KiB of it gets a 400). A header name with
// whitespace before the colon, or a line fold, gets a 400. A handler that throws gets a 500 and the connection serves on.
//
// A response is `HTTP/1.1 <status> <reason>`, Content-Type, Content-Length and the body: nothing else, whatever the request's
// version. An HTTP/1.0 client that asks for keep-alive gets it (the connection stays open) without a `Connection: keep-alive`
// header in the answer, so most of them will close on their own.

final class DiyConnection
{
    /** Reading pauses, and requests already received are not answered, while this many response bytes wait for the client. */
    public const WRITE_LIMIT = 1048576;
    /** The request line and the headers, with their blank line. */
    public const HEADER_LIMIT = 8192;
    /** Largest accepted Content-Length. The challenge's POST bodies are tiny; this only bounds the memory of one connection. */
    public const BODY_LIMIT = 1048576;
    // Why: PHP reads at most 8192 bytes from a socket per fread() whatever the length asked for.
    private const READ_SIZE = 8192;

    private const HEAD = [
        200 => "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ",
        201 => "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: ",
        400 => "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: ",
        401 => "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: ",
        404 => "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: ",
        500 => "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: ",
        503 => "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: ",
    ];
    private const INTERNAL_ERROR = '{"error":"internal server error"}';
    private const BAD_REQUEST = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 23\r\n\r\n{\"error\":\"bad request\"}";

    private string $rbuf = '';
    private string $wbuf = '';
    /** The connection closes once wbuf is empty: nothing more is read or parsed. */
    private bool $closing = false;

    // What parseHead() found in the request it just read: properties, so no array comes back from the call. A request still
    // allocates its strings (head, request line, method, target, body), the array explode() makes of its header lines, and
    // its response; nothing is allocated per request that outlives it.
    private string $method = '';
    private string $target = '';
    private string $authorization = '';
    private int $bodyLength = 0;
    private bool $closeAfter = false;

    /** @param resource $stream a non-blocking stream */
    public function __construct(private $stream)
    {
    }

    /** The stream has bytes. Returns false when the connection is finished and the caller must dispose of it. */
    public function onReadable(): bool
    {
        $data = @fread($this->stream, self::READ_SIZE);
        if ($data === false) {
            return false;
        }
        if ($data === '') {
            // '' before the end of the stream is EAGAIN (a wake-up with nothing to read); at the end it is the client leaving.
            return !feof($this->stream);
        }
        $this->rbuf .= $data;
        return $this->advance();
    }

    /** The stream takes bytes again. Returns false when the connection is finished. */
    public function onWritable(): bool
    {
        return $this->advance();
    }

    public function wantsRead(): bool
    {
        return !$this->closing && strlen($this->wbuf) < self::WRITE_LIMIT;
    }

    public function wantsWrite(): bool
    {
        return $this->wbuf !== '';
    }

    public function pendingBytes(): int
    {
        return strlen($this->wbuf);
    }

    /** Closes the stream. The loop calls it after it has freed the events that watch the stream. */
    public function close(): void
    {
        if (is_resource($this->stream)) {
            fclose($this->stream);
        }
    }

    private function advance(): bool
    {
        do {
            $stoppedAtLimit = $this->parse();
            if ($this->wbuf !== '') {
                $written = @fwrite($this->stream, $this->wbuf);
                if ($written === false) {
                    return false;
                }
                if ($written > 0) {
                    $this->wbuf = $written === strlen($this->wbuf) ? '' : substr($this->wbuf, $written);
                }
            }
            // Everything went out and requests were waiting behind the limit: answer them now.
        } while ($stoppedAtLimit && $this->wbuf === '');
        return !($this->closing && $this->wbuf === '');
    }

    /** Answers every complete request in rbuf. Returns true when it stopped because wbuf reached the limit. */
    private function parse(): bool
    {
        $rbuf = $this->rbuf;
        $length = strlen($rbuf);
        $pos = 0;
        $stoppedAtLimit = false;
        while (!$this->closing) {
            if (strlen($this->wbuf) >= self::WRITE_LIMIT) {
                $stoppedAtLimit = true;
                break;
            }
            $end = strpos($rbuf, "\r\n\r\n", $pos);
            if ($end === false) {
                if ($length - $pos > self::HEADER_LIMIT) {
                    $this->reject();
                }
                break;
            }
            if ($end + 4 - $pos > self::HEADER_LIMIT || !$this->parseHead(substr($rbuf, $pos, $end - $pos))) {
                $this->reject();
                break;
            }
            $bodyStart = $end + 4;
            if ($length - $bodyStart < $this->bodyLength) {
                break; // the body is not whole yet
            }
            $body = $this->bodyLength === 0 ? '' : substr($rbuf, $bodyStart, $this->bodyLength);
            $pos = $bodyStart + $this->bodyLength;
            // Why: an exception that escaped here would leave the ext-event callback and stop the loop for every connection.
            try {
                [$status, $payload] = handler_handle($this->method, $this->target, $body, $this->authorization);
            } catch (Throwable $e) {
                fwrite(STDERR, 'diy-connection: the handler failed: ' . get_class($e) . ': ' . $e->getMessage() . "\n");
                [$status, $payload] = [500, self::INTERNAL_ERROR];
            }
            $this->wbuf .= self::HEAD[$status] . strlen($payload) . "\r\n\r\n" . $payload;
            if ($this->closeAfter) {
                $this->closing = true;
            }
        }
        $this->rbuf = $this->closing || $pos >= $length ? '' : ($pos === 0 ? $rbuf : substr($rbuf, $pos));
        return $stoppedAtLimit;
    }

    private function reject(): void
    {
        $this->wbuf .= self::BAD_REQUEST;
        $this->closing = true;
    }

    /** Reads the request line and the headers (without their final blank line) into the properties. False: it cannot be parsed. */
    private function parseHead(string $head): bool
    {
        $eol = strpos($head, "\r\n");
        $line = $eol === false ? $head : substr($head, 0, $eol);
        $sp1 = strpos($line, ' ');
        $sp2 = strrpos($line, ' ');
        if ($sp1 === false || $sp1 === 0 || $sp2 < $sp1 + 2) {
            return false;
        }
        $version = substr($line, $sp2 + 1);
        if ($version !== 'HTTP/1.1' && $version !== 'HTTP/1.0') {
            return false;
        }
        $this->method = substr($line, 0, $sp1);
        $this->target = substr($line, $sp1 + 1, $sp2 - $sp1 - 1);
        if (!ctype_alpha($this->method) || str_contains($this->target, ' ')) {
            return false;
        }

        $this->bodyLength = 0;
        $this->authorization = '';
        $close = false;
        $keepAlive = false;
        $hasLength = false;
        if ($eol !== false) {
            foreach (explode("\r\n", substr($head, $eol + 2)) as $header) {
                $colon = strpos($header, ':');
                // Why: a space or a tab before the colon (`Content-Length : 5`) would make a server that skips it and one that reads it
                // disagree on where the body ends (RFC 9112, 5.1: answer 400); a line that starts with one is an obsolete line fold.
                if ($colon === false || $colon === 0 || $header[$colon - 1] === ' ' || $header[$colon - 1] === "\t" || $header[0] === ' ' || $header[0] === "\t") {
                    return false;
                }
                if ($colon === 14 && strncasecmp($header, 'content-length', 14) === 0) {
                    $value = trim(substr($header, 15), " \t");
                    // Why: two Content-Length headers, or one that is not plain digits, are how requests get smuggled.
                    if ($hasLength || !ctype_digit($value) || strlen($value) > 7 || (int) $value > self::BODY_LIMIT) {
                        return false;
                    }
                    $hasLength = true;
                    $this->bodyLength = (int) $value;
                } elseif ($colon === 10 && strncasecmp($header, 'connection', 10) === 0) {
                    $value = strtolower(substr($header, 11));
                    $close = str_contains($value, 'close');
                    $keepAlive = str_contains($value, 'keep-alive');
                } elseif ($colon === 13 && strncasecmp($header, 'authorization', 13) === 0) {
                    $this->authorization = trim(substr($header, 14), " \t");
                } elseif ($colon === 17 && strncasecmp($header, 'transfer-encoding', 17) === 0) {
                    // Chunked bodies are not supported: k6 never sends one, and the challenge's clients send Content-Length.
                    return false;
                }
            }
        }
        $this->closeAfter = $close || ($version === 'HTTP/1.0' && !$keepAlive);
        return true;
    }
}
