<?php
// The client of lab/stress.sh: sends requests that each carry an id and checks that every response is the one of the request it answers,
// in order on its connection (raw sockets, no HTTP library). The test covers the loop's bookkeeping (user_data, buffer ids, connection
// slots, send slots), so a response paired with the wrong request, a response lost or a response sent twice all show. Two paths:
// `/noop?id={id}` (default; lab/servers/uring-noop.php echoes `{"status":"ok","id":<digits>}`, the ids are unique and the bytes exact) and
// `/posts/{id}` (the challenge app or the bake-off's handler: the ids are random posts of the seed, 1 to 500,000, and a response must be a 200
// whose `{"post":{"id":<id>,` is the request's: only that is checked of the post, the rest is the app's).
//
//   php stress.php <port> [--connections 1000] [--requests 2000000] [--procs 4] [--pipeline 1] [--seed 1] [--path /noop?id={id}]
//
// --pipeline N: a connection sends bursts of 1 to N requests in one write (random sizes, so reads split and merge), and sends the next
// burst once the whole burst is answered; 1 is one request at a time. The work is split over --procs processes (the PHP client is
// the slow side), each with its own connections (stream_select, so at most about 1,000 per process) and its own range of ids.
// Prints one JSON object (the totals) and exits 0 when there are 0 mismatches and 0 lost, 1 otherwise, 2 on a usage error.

const RESPONSE_HEAD = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ";
const IDLE_LIMIT_S = 15;
const ID_RANGE = 100000000;
const SEED_POSTS = 500000;
const PATH_NOOP = '/noop?id={id}';
const PATH_POSTS = '/posts/{id}';

function expected_response(int $id): string
{
    $body = '{"status":"ok","id":' . $id . '}';
    return RESPONSE_HEAD . strlen($body) . "\r\n\r\n" . $body;
}

/**
 * How much of $buf, from $pos, is the response of the post $id: its length when it is whole and right, 0 when what is there so far is
 * the beginning of it, -1 when it is not (a wrong status, a wrong id, a Content-Length that does not fit the body).
 */
function post_response_length(string $buf, int $pos, int $id): int
{
    $have = strlen($buf) - $pos;
    $headLength = strlen(RESPONSE_HEAD);
    if (substr_compare($buf, RESPONSE_HEAD, $pos, min($have, $headLength)) !== 0) {
        return -1;
    }
    $end = strpos($buf, "\r\n\r\n", $pos);
    if ($end === false) {
        return $have > 256 ? -1 : 0;
    }
    $digits = substr($buf, $pos + $headLength, $end - $pos - $headLength);
    if (!ctype_digit($digits) || strlen($digits) > 8) {
        return -1;
    }
    $bodyStart = $end + 4;
    $prefix = '{"post":{"id":' . $id . ',';
    $bodyHave = strlen($buf) - $bodyStart;
    if ($bodyHave > 0 && substr_compare($buf, $prefix, $bodyStart, min($bodyHave, strlen($prefix))) !== 0) {
        return -1;
    }
    $bodyLength = (int) $digits;
    if ($bodyLength < strlen($prefix)) {
        return -1;
    }
    return $bodyHave >= $bodyLength ? $bodyStart - $pos + $bodyLength : 0;
}

/** One shard: $connections connections, $requests requests, ids from $idBase up (or random posts for /posts/{id}). @return array<string, mixed> */
function run_shard(int $port, int $shard, int $connections, int $requests, int $pipeline, int $seed, string $path = PATH_NOOP): array
{
    $posts = $path === PATH_POSTS;
    mt_srand($seed * 1000 + $shard);
    $idBase = ($shard + 1) * ID_RANGE;
    $streams = [];
    $byId = [];
    $conn = [];
    for ($c = 0; $c < $connections; $c++) {
        $fp = @stream_socket_client("tcp://127.0.0.1:$port", $errno, $errstr, 10);
        if ($fp === false) {
            return ['error' => "connection $c of shard $shard failed: $errstr"];
        }
        stream_set_blocking($fp, false);
        $streams[$c] = $fp;
        $byId[(int) $fp] = $c;
        // out: bytes not written yet; want: ids sent and not answered, in order; rbuf: bytes read and not consumed.
        $conn[$c] = ['out' => '', 'want' => [], 'wantHead' => 0, 'rbuf' => '', 'dead' => false];
    }
    $nextId = $idBase;
    $remaining = $requests;
    $matched = 0;
    $mismatches = 0;
    $firstErrors = [];
    $lastProgress = time();

    $fill = function (int $c) use (&$conn, &$nextId, &$remaining, $pipeline, $port, $posts, $path): void {
        if ($remaining === 0 || $conn[$c]['dead'] || $conn[$c]['wantHead'] < count($conn[$c]['want']) || $conn[$c]['out'] !== '') {
            return;
        }
        $burst = min($remaining, $pipeline === 1 ? 1 : mt_rand(1, $pipeline));
        $bytes = '';
        for ($k = 0; $k < $burst; $k++) {
            $id = $posts ? mt_rand(1, SEED_POSTS) : $nextId;
            $nextId++;
            $bytes .= 'GET ' . str_replace('{id}', (string) $id, $path) . " HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nAccept: */*\r\n\r\n";
            $conn[$c]['want'][] = $id;
        }
        $remaining -= $burst;
        $conn[$c]['out'] = $bytes;
    };

    for ($c = 0; $c < $connections; $c++) {
        $fill($c);
    }
    while (true) {
        $pending = 0;
        $read = [];
        $write = [];
        foreach ($streams as $c => $fp) {
            if ($conn[$c]['dead']) {
                continue;
            }
            $outstanding = count($conn[$c]['want']) - $conn[$c]['wantHead'];
            $pending += $outstanding;
            if ($outstanding > 0) {
                $read[] = $fp;
            }
            if ($conn[$c]['out'] !== '') {
                $write[] = $fp;
            }
        }
        if ($pending === 0 && $remaining === 0) {
            break;
        }
        if (time() - $lastProgress > IDLE_LIMIT_S) {
            break;
        }
        if ($read === [] && $write === []) {
            break; // every connection is gone (a mismatch or the server closed them): what is left is lost
        }
        $except = null;
        if (stream_select($read, $write, $except, 1) === false) {
            return ['error' => 'stream_select failed'];
        }
        foreach ($write as $fp) {
            $c = $byId[(int) $fp];
            $written = @fwrite($fp, $conn[$c]['out']);
            if ($written === false) {
                $conn[$c]['dead'] = true;
                continue;
            }
            $conn[$c]['out'] = (string) substr($conn[$c]['out'], $written);
            $lastProgress = time();
        }
        foreach ($read as $fp) {
            $c = $byId[(int) $fp];
            $data = fread($fp, 65536);
            if ($data === false || ($data === '' && feof($fp))) {
                $conn[$c]['dead'] = true;
                continue;
            }
            if ($data === '') {
                continue;
            }
            $lastProgress = time();
            $st = &$conn[$c];
            $st['rbuf'] .= $data;
            $pos = 0;
            $length = strlen($st['rbuf']);
            while ($st['wantHead'] < count($st['want'])) {
                $id = $st['want'][$st['wantHead']];
                if ($posts) {
                    $need = post_response_length($st['rbuf'], $pos, $id);
                    if ($need < 0) {
                        $mismatches++;
                        $firstErrors[] = "id $id: got " . json_encode(substr($st['rbuf'], $pos, 120));
                        $st['dead'] = true;
                    } elseif ($need > 0) {
                        $matched++;
                        $pos += $need;
                        $st['wantHead']++;
                        continue;
                    }
                    break;
                }
                $exp = expected_response($id);
                $have = $length - $pos;
                $need = strlen($exp);
                if ($have < $need) {
                    // A short read: what is here must still be the beginning of the right answer.
                    if ($have > 0 && substr_compare($st['rbuf'], $exp, $pos, $have) !== 0) {
                        $mismatches++;
                        $firstErrors[] = "id $id: got " . json_encode(substr($st['rbuf'], $pos, 120));
                        $st['dead'] = true;
                    }
                    break;
                }
                if (substr_compare($st['rbuf'], $exp, $pos, $need) !== 0) {
                    $mismatches++;
                    $firstErrors[] = "id $id: got " . json_encode(substr($st['rbuf'], $pos, 120));
                    $st['dead'] = true;
                    break;
                }
                $matched++;
                $pos += $need;
                $st['wantHead']++;
            }
            $st['rbuf'] = $pos >= $length ? '' : substr($st['rbuf'], $pos);
            if ($st['wantHead'] === count($st['want'])) {
                $st['want'] = [];
                $st['wantHead'] = 0;
            }
            unset($st);
            $fill($c);
        }
        // Connections that finished their burst but got no new one (it was written in full, nothing is pending on them) are refilled here.
        foreach ($streams as $c => $fp) {
            if (!$conn[$c]['dead'] && $conn[$c]['want'] === [] && $conn[$c]['out'] === '') {
                $fill($c);
            }
        }
    }
    $lost = $remaining;
    foreach ($conn as $st) {
        $lost += count($st['want']) - $st['wantHead'];
    }
    foreach ($streams as $fp) {
        fclose($fp);
    }
    return ['sent' => $nextId - $idBase, 'matched' => $matched, 'mismatches' => $mismatches, 'lost' => $lost, 'first_errors' => array_slice($firstErrors, 0, 5)];
}

$args = $argv;
array_shift($args);
if (($args[0] ?? '') === 'shard') {
    [, $port, $shard, $connections, $requests, $pipeline, $seed, $path] = $args;
    fwrite(STDOUT, json_encode(run_shard((int) $port, (int) $shard, (int) $connections, (int) $requests, (int) $pipeline, (int) $seed, $path)) . "\n");
    exit(0);
}

$port = (int) ($args[0] ?? 0);
if ($port < 1) {
    fwrite(STDERR, "usage: php stress.php <port> [--connections 1000] [--requests 2000000] [--procs 4] [--pipeline 1] [--seed 1] [--path /noop?id={id}]\n");
    exit(2);
}
$opt = ['connections' => 1000, 'requests' => 2000000, 'procs' => 4, 'pipeline' => 1, 'seed' => 1, 'path' => PATH_NOOP];
for ($i = 1; $i < count($args); $i += 2) {
    $name = ltrim($args[$i], '-');
    $isPath = $name === 'path' && isset($args[$i + 1]) && in_array($args[$i + 1], [PATH_NOOP, PATH_POSTS], true);
    if (!isset($opt[$name]) || !isset($args[$i + 1]) || (!$isPath && (!ctype_digit($args[$i + 1]) || (int) $args[$i + 1] < 1))) {
        fwrite(STDERR, "bad option: {$args[$i]}" . ($name === 'path' ? ' (the paths are ' . PATH_NOOP . ' and ' . PATH_POSTS . ')' : '') . "\n");
        exit(2);
    }
    $opt[$name] = $isPath ? $args[$i + 1] : (int) $args[$i + 1];
}
if ($opt['procs'] > $opt['connections'] || $opt['connections'] / $opt['procs'] > 1000) {
    fwrite(STDERR, "--procs must be at most --connections, and each process holds at most 1,000 connections\n");
    exit(2);
}

$started = microtime(true);
$children = [];
for ($shard = 0; $shard < $opt['procs']; $shard++) {
    // The shares add up exactly: the first shards take the remainder.
    $conns = intdiv($opt['connections'], $opt['procs']) + ($shard < $opt['connections'] % $opt['procs'] ? 1 : 0);
    $reqs = intdiv($opt['requests'], $opt['procs']) + ($shard < $opt['requests'] % $opt['procs'] ? 1 : 0);
    $cmd = [PHP_BINARY, '-d', 'memory_limit=-1', __FILE__, 'shard', (string) $port, (string) $shard, (string) $conns, (string) $reqs,
        (string) $opt['pipeline'], (string) $opt['seed'], $opt['path']];
    $proc = proc_open($cmd, [1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    $children[] = [$proc, $pipes];
}
$total = ['sent' => 0, 'matched' => 0, 'mismatches' => 0, 'lost' => 0];
$errors = [];
$failed = false;
foreach ($children as [$proc, $pipes]) {
    $out = stream_get_contents($pipes[1]);
    $err = stream_get_contents($pipes[2]);
    $code = proc_close($proc);
    $r = json_decode(trim($out), true);
    if ($code !== 0 || !is_array($r) || isset($r['error'])) {
        $failed = true;
        $errors[] = 'a shard failed: ' . ($r['error'] ?? trim($err) ?: "exit code $code");
        continue;
    }
    foreach ($total as $k => $_) {
        $total[$k] += $r[$k];
    }
    array_push($errors, ...$r['first_errors']);
}
$seconds = microtime(true) - $started;
$result = $total + ['requests_asked' => $opt['requests'], 'connections' => $opt['connections'], 'pipeline' => $opt['pipeline'], 'path' => $opt['path'],
    'seconds' => round($seconds, 1), 'req_per_s' => (int) round($total['matched'] / $seconds), 'errors' => array_slice($errors, 0, 5)];
echo json_encode($result, JSON_UNESCAPED_SLASHES), "\n";
exit($failed || $total['mismatches'] > 0 || $total['lost'] > 0 || $total['sent'] !== $opt['requests'] ? 1 : 0);
