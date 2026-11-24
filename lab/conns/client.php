<?php
// The client of lab/conns.sh: opens idle keep-alive connections to a server, one at a time, and holds them.
//
//   php client.php <port>
//   php client.php <port> --hold <n> [--path <path>] [--body-regex <pcre>] [--end-file <file>]
//
// Without --hold it is driven through stdin and answers on stdout, one JSON object per line (lab/conns.sh reads them). Commands on stdin:
//   step <total>   open connections until <total> are held, then sweep the held ones for a close by the server
//   quit           close everything and exit
// Events on stdout: log (a message for the person running the lab), baseline_ready (one request done on one connection, now
// closed), step, harness_error (the client itself failed, exit 1: a bind that fails, no file descriptor left, no free port).
//
// With --hold <n> (lab/realistic.sh --idle) it takes no command: it opens <n> connections one at a time, each with one request
// (GET <path>, default /noop; the answer must be a 200 whose body is the exact `{"status":"ok"}`, or matches --body-regex), sweeps
// them once and prints the `held` event, then holds them until <end-file> exists (checked every 200 ms), sweeps them again and prints
// the `ended` event, with how many the server closed in between: a connection the server closed is the run's failure, whatever the
// reason. Both events carry the client's own memory (VmRSS and VmHWM in kB).
//
// Why one at a time: the server's accept queue never fills, so a connection that does not get an answer is the server's limit
// (its fds, its max_connection, its memory) and not a burst the kernel dropped.
//
// Why a rotation of source addresses: a client address has about 10 000 to 28 000 ephemeral ports (read from
// /proc/sys/net/ipv4/ip_local_port_range), so more than that many connections to one server address and port need several
// 127.x addresses (loopback accepts the whole 127.0.0.0/8). The next address is one nothing uses, whichever end of a socket it
// is on, TIME_WAIT sockets of an earlier run included, so a second run right after a first one starts on addresses that are free.
//
// Why a retry: a connection is bound to a random port of its address (bind to port 0), and a port whose 4-tuple matches a TIME_WAIT
// socket fails at connect with `Cannot assign requested address` (EADDRNOTAVAIL). That is not a limit of the server: the client
// binds again (another random port), and after a few failures in a row moves to the next free address.

const DEFAULT_PATH = '/noop';
const DEFAULT_BODY = '{"status":"ok"}';
const TIMEOUT_S = 2.0;
// Ports of an address kept free: the baseline's connection, and what other processes may take.
const PORT_MARGIN = 500;
const FIRST_OCTET = 2;
const LAST_OCTET = 254;
const TIME_WAIT_MAX_S = 70;
// Failures of one connection with EADDRNOTAVAIL before the client gives up, and how many in a row before it leaves the address.
const BIND_RETRIES_MAX = 200;
const BIND_RETRIES_BEFORE_NEW_ADDRESS = 25;

const ECONNRESET = 104;
const EPIPE = 32;
const ETIMEDOUT = 110;
const ECONNREFUSED = 111;
const EADDRNOTAVAIL = 99;
const EMFILE = 24;
const ENFILE = 23;

/** Messages of the PHP notices of a failed read or write, so the errno behind them can be read. */
$notices = [];
set_error_handler(function (int $no, string $msg) use (&$notices): bool {
    $notices[] = $msg;
    return true;
});

function emit(array $event): void
{
    // Why the flags: an error message with a byte that is not UTF-8 would make json_encode return false, and a blank line.
    fwrite(STDOUT, json_encode($event, JSON_UNESCAPED_SLASHES | JSON_INVALID_UTF8_SUBSTITUTE | JSON_PARTIAL_OUTPUT_ON_ERROR) . "\n");
}

function log_line(string $message): void
{
    emit(['event' => 'log', 'message' => $message]);
}

function harness_error(string $message): never
{
    emit(['event' => 'harness_error', 'message' => $message]);
    exit(1);
}

/** The errno of the last notices (`... failed with errno=104 Connection reset by peer`), 0 when there is none. */
function notice_errno(): int
{
    global $notices;
    $errno = 0;
    foreach ($notices as $msg) {
        if (preg_match('/errno=(\d+)/', $msg, $m)) {
            $errno = (int) $m[1];
        }
    }
    $notices = [];
    return $errno;
}

/** @return array{int, int} the ephemeral port range of this network namespace */
function port_range(): array
{
    $raw = trim((string) file_get_contents('/proc/sys/net/ipv4/ip_local_port_range'));
    if (!preg_match('/^(\d+)\s+(\d+)$/', $raw, $m)) {
        harness_error("cannot read the ephemeral port range: '$raw'");
    }
    return [(int) $m[1], (int) $m[2]];
}

/** @return array<string, array<string, int>> for each 127.x address that is at either end of a socket: its sockets by state */
function used_addresses(): array
{
    $used = [];
    $lines = file('/proc/net/tcp', FILE_IGNORE_NEW_LINES) ?: [];
    array_shift($lines);
    foreach ($lines as $line) {
        $cols = preg_split('/\s+/', trim($line));
        $state = $cols[3];
        // Why both columns: the side that closes first keeps the TIME_WAIT socket, so after a server that closed first the port that
        // blocks a connection is a socket whose local address is the server's and whose remote address is the one the client would use.
        $seen = [];
        foreach ([$cols[1], $cols[2]] as $endpoint) {
            [$hexAddr] = explode(':', $endpoint);
            // A little-endian hex word: 0200007F is 127.0.0.2.
            $ip = implode('.', array_reverse(array_map('hexdec', str_split($hexAddr, 2))));
            if (str_starts_with($ip, '127.') && !isset($seen[$ip])) {
                $seen[$ip] = true;
                $used[$ip][$state] = ($used[$ip][$state] ?? 0) + 1;
            }
        }
    }
    return $used;
}

final class Source
{
    /** @var list<string> */
    public array $used = [];
    private ?string $current = null;
    private int $opened = 0;
    /** @var resource|null */
    private $context = null;
    private int $perAddress;
    /** How many connects failed with EADDRNOTAVAIL and were tried again. */
    public int $retries = 0;

    public function __construct(int $portsInRange)
    {
        $this->perAddress = $portsInRange - PORT_MARGIN;
        if ($this->perAddress < 1000) {
            harness_error("the ephemeral port range holds only $portsInRange ports");
        }
    }

    public function perAddress(): int
    {
        return $this->perAddress;
    }

    /** @return resource the stream context that binds the next connection to the current source address */
    public function context()
    {
        if ($this->current === null || $this->opened >= $this->perAddress) {
            $this->current = $this->nextFreeAddress();
            $this->used[] = $this->current;
            $this->opened = 0;
            $this->context = stream_context_create(['socket' => ['bindto' => $this->current . ':0']]);
        }
        $this->opened++;
        return $this->context;
    }

    /** The current address is not worth more tries: the next context() takes another one. */
    public function leaveAddress(): void
    {
        $this->opened = $this->perAddress;
    }

    private function nextFreeAddress(): string
    {
        $waited = 0;
        while (true) {
            $busy = used_addresses();
            for ($octet = FIRST_OCTET; $octet <= LAST_OCTET; $octet++) {
                $ip = "127.0.0.$octet";
                if (!isset($busy[$ip]) && !in_array($ip, $this->used, true)) {
                    return $ip;
                }
            }
            if ($waited >= TIME_WAIT_MAX_S) {
                harness_error('no free source address in 127.0.0.2 to 127.0.0.254 after ' . TIME_WAIT_MAX_S . ' s: sockets of an earlier run still hold them');
            }
            log_line('every source address still has sockets (TIME_WAIT of an earlier run), waiting');
            sleep(5);
            $waited += 5;
        }
    }
}

/**
 * Opens a connection, sends GET <path> and reads the whole answer.
 *
 * @return array{resource|null, string|null, string|null} the connection (null when it failed), the failure and its detail
 */
function open_and_request(int $port, Source $source, string $path, ?string $bodyRegex): array
{
    $ctx = $source->context();
    $failures = 0;
    while (true) {
        $fp = @stream_socket_client("tcp://127.0.0.1:$port", $errno, $errstr, TIMEOUT_S, STREAM_CLIENT_CONNECT, $ctx);
        if ($fp !== false || $errno !== EADDRNOTAVAIL || $failures >= BIND_RETRIES_MAX) {
            break;
        }
        $failures++;
        $source->retries++;
        if ($failures % BIND_RETRIES_BEFORE_NEW_ADDRESS === 0) {
            log_line("$failures connects in a row failed with 'Cannot assign requested address' on " . end($source->used) . ' (sockets of an earlier run), moving to another address');
            $source->leaveAddress();
            $ctx = $source->context();
        }
    }
    if ($fp === false) {
        return match (true) {
            $errno === ETIMEDOUT || ($errno === 0 && stripos($errstr, 'timed out') !== false) => [null, 'connect timeout', $errstr],
            $errno === ECONNRESET => [null, 'connection reset', $errstr],
            $errno === ECONNREFUSED => [null, 'connection refused', $errstr],
            default => harness_error("the client could not connect (errno $errno, '$errstr'); its limit is " .
                (posix_getrlimit()['soft openfiles'] ?? '?') . ' open files, source address ' . end($source->used)),
        };
    }
    stream_set_timeout($fp, (int) TIMEOUT_S);
    // Why: a read buffer would hold 8 KiB per connection in the client, 500 MiB for 65 000 of them.
    stream_set_read_buffer($fp, 0);
    notice_errno();
    $request = 'GET ' . $path . " HTTP/1.1\r\nHost: 127.0.0.1:$port\r\n\r\n";
    if (fwrite($fp, $request) !== strlen($request)) {
        $errno = notice_errno();
        fclose($fp);
        return [null, $errno === ECONNRESET ? 'connection reset' : 'connection closed by the server (EOF)', 'write failed, errno ' . $errno];
    }
    $buf = '';
    while (true) {
        $chunk = fread($fp, 8192);
        if ($chunk === false || $chunk === '') {
            $timedOut = stream_get_meta_data($fp)['timed_out'];
            $errno = notice_errno();
            fclose($fp);
            if ($timedOut) {
                return [null, 'request timeout', 'no answer within ' . (int) TIMEOUT_S . ' s'];
            }
            return [null, $errno === ECONNRESET ? 'connection reset' : 'connection closed by the server (EOF)', 'read failed, errno ' . $errno];
        }
        $buf .= $chunk;
        $end = strpos($buf, "\r\n\r\n");
        if ($end === false) {
            continue;
        }
        $length = preg_match('/^content-length:\s*(\d+)/mi', substr($buf, 0, $end), $m) ? (int) $m[1] : 0;
        if (strlen($buf) >= $end + 4 + $length) {
            break;
        }
    }
    $body = substr($buf, $end + 4);
    $bodyOk = $bodyRegex === null ? $body === DEFAULT_BODY : preg_match($bodyRegex, $body) === 1;
    if (!str_starts_with($buf, 'HTTP/1.1 200 ') || !$bodyOk) {
        fclose($fp);
        return [null, 'bad answer', json_encode(substr($buf, 0, 200))];
    }
    return [$fp, null, null];
}

/**
 * Non-blocking reads on every held connection: an EOF or a reset means the server closed it, data means it sent something
 * nobody asked for.
 *
 * @param array<int, resource> $held
 * @return int how many were closed or spoiled (they are removed from $held)
 */
function sweep(array &$held): int
{
    $gone = 0;
    foreach ($held as $i => $fp) {
        stream_set_blocking($fp, false);
        $data = fread($fp, 1);
        if ($data !== '' && $data !== false) {
            $gone++;
            fclose($fp);
            unset($held[$i]);
            continue;
        }
        $errno = notice_errno();
        if ($errno === ECONNRESET || $errno === EPIPE || feof($fp)) {
            $gone++;
            fclose($fp);
            unset($held[$i]);
        }
    }
    return $gone;
}

/** One request on one connection, then close it: what the server allocates for its first request is in the baseline. */
function baseline(int $port, Source $source): void
{
    [$fp, $failure, $detail] = open_and_request($port, $source, DEFAULT_PATH, null);
    if ($fp === null) {
        harness_error("the baseline request failed ($failure: $detail)");
    }
    fclose($fp);
    // The server sees the close a moment later.
    usleep(300_000);
}

/** The client's own memory in kB from /proc/self/status: [VmRSS, VmHWM]. */
function own_memory_kb(): array
{
    $status = (string) @file_get_contents('/proc/self/status');
    return [
        preg_match('/^VmRSS:\s+(\d+) kB$/m', $status, $m) ? (int) $m[1] : null,
        preg_match('/^VmHWM:\s+(\d+) kB$/m', $status, $m) ? (int) $m[1] : null,
    ];
}

$port = (int) ($argv[1] ?? 0);
if ($port < 1) {
    harness_error('usage: client.php <port> [--hold <n> [--path <path>] [--body-regex <pcre>] [--end-file <file>]]');
}
$options = ['hold' => null, 'path' => DEFAULT_PATH, 'body-regex' => null, 'end-file' => null];
for ($i = 2; $i < count($argv); $i += 2) {
    $key = ltrim($argv[$i], '-');
    if (!array_key_exists($key, $options) || !isset($argv[$i + 1])) {
        harness_error('unknown option or missing value: ' . $argv[$i]);
    }
    $options[$key] = $argv[$i + 1];
}
$holdMode = $options['hold'] !== null;
if ($holdMode && (!ctype_digit($options['hold']) || (int) $options['hold'] < 1 || $options['end-file'] === null)) {
    harness_error('--hold wants a whole number above 0 and --end-file');
}
$bodyRegex = null;
if ($options['body-regex'] !== null) {
    $bodyRegex = '~' . str_replace('~', '\\~', $options['body-regex']) . '~';
    if (@preg_match($bodyRegex, '') === false) {
        harness_error('--body-regex is not a valid pattern: ' . $options['body-regex']);
    }
}
[$low, $high] = port_range();
$source = new Source($high - $low + 1);
$nofile = function_exists('posix_getrlimit') ? (posix_getrlimit()['soft openfiles'] ?? null) : null;

/** @var array<int, resource> $held */
$held = [];

if ($holdMode) {
    $target = (int) $options['hold'];
    $failure = $detail = null;
    $started = microtime(true);
    while (count($held) < $target) {
        [$fp, $failure, $detail] = open_and_request($port, $source, $options['path'], $bodyRegex);
        if ($fp === null) {
            break;
        }
        $held[] = $fp;
    }
    $closed = sweep($held);
    [$rss, $hwm] = own_memory_kb();
    emit([
        'event' => 'held',
        'target' => $target,
        'held' => count($held),
        'closed_by_server' => $closed,
        'failure' => $failure,
        'detail' => $detail,
        'seconds' => round(microtime(true) - $started, 2),
        'source_addresses' => $source->used,
        'ports_per_address' => $source->perAddress(),
        'bind_retries' => $source->retries,
        'nofile' => $nofile,
        'rss_kb' => $rss,
        'hwm_kb' => $hwm,
    ]);
    while (!file_exists($options['end-file'])) {
        usleep(200_000);
    }
    $closed = sweep($held);
    [$rss, $hwm] = own_memory_kb();
    emit(['event' => 'ended', 'held' => count($held), 'closed_by_server' => $closed, 'rss_kb' => $rss, 'hwm_kb' => $hwm]);
    exit(0);
}

baseline($port, $source);
emit(['event' => 'baseline_ready']);

while (($line = fgets(STDIN)) !== false) {
    $cmd = preg_split('/\s+/', trim($line));
    if ($cmd[0] === 'quit') {
        break;
    }
    if ($cmd[0] !== 'step' || !isset($cmd[1]) || !ctype_digit($cmd[1])) {
        harness_error('unknown command: ' . trim($line));
    }
    $target = (int) $cmd[1];
    $failure = $detail = null;
    $started = microtime(true);
    while (count($held) < $target) {
        [$fp, $failure, $detail] = open_and_request($port, $source, DEFAULT_PATH, null);
        if ($fp === null) {
            break;
        }
        $held[] = $fp;
    }
    // The sweep follows the step so that a close by the server shows up in this step's count.
    $closed = sweep($held);
    emit([
        'event' => 'step',
        'target' => $target,
        'held' => count($held),
        'closed_by_server' => $closed,
        'failure' => $failure,
        'detail' => $detail,
        'seconds' => round(microtime(true) - $started, 2),
        'source_addresses' => $source->used,
        'ports_per_address' => $source->perAddress(),
        'bind_retries' => $source->retries,
        'nofile' => $nofile,
        'port_range' => [$low, $high],
    ]);
}
