<?php
// The client of lab/stress.sh: sends requests that each carry a unique id and checks that every response echoes the id of the request
// it answers, byte for byte, in order on its connection (raw sockets, no HTTP library). Meant for lab/servers/uring-noop.php, which echoes
// `GET /noop?id=<digits>` as `{"status":"ok","id":<digits>}`: the test covers the loop's bookkeeping (user_data, buffer ids, connection
// slots, send slots), so a response paired with the wrong request, a response lost or a response sent twice all show.
//
//   php stress.php <port> [--connections 1000] [--requests 2000000] [--procs 4] [--pipeline 1] [--seed 1]
//
// --pipeline N: a connection sends bursts of 1 to N requests in one write (random sizes, so reads split and merge), and sends the next
// burst once the whole burst is answered; 1 is one request at a time. The work is split over --procs processes (the PHP client is
// the slow side), each with its own connections (stream_select, so at most about 1,000 per process) and its own range of ids.
// Prints one JSON object (the totals) and exits 0 when there are 0 mismatches and 0 lost, 1 otherwise, 2 on a usage error.

const RESPONSE_HEAD = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ";
const IDLE_LIMIT_S = 15;
const ID_RANGE = 100000000;

function expected_response(int $id): string
{
    $body = '{"status":"ok","id":' . $id . '}';
    return RESPONSE_HEAD . strlen($body) . "\r\n\r\n" . $body;
}

/** One shard: $connections connections, $requests requests, ids from $idBase up. @return array<string, mixed> */
function run_shard(int $port, int $shard, int $connections, int $requests, int $pipeline, int $seed): array
{
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

    $fill = function (int $c) use (&$conn, &$nextId, &$remaining, $pipeline, $port): void {
        if ($remaining === 0 || $conn[$c]['dead'] || $conn[$c]['wantHead'] < count($conn[$c]['want']) || $conn[$c]['out'] !== '') {
            return;
        }
        $burst = min($remaining, $pipeline === 1 ? 1 : mt_rand(1, $pipeline));
        $bytes = '';
        for ($k = 0; $k < $burst; $k++) {
            $id = $nextId++;
            $bytes .= "GET /noop?id=$id HTTP/1.1\r\nHost: 127.0.0.1:$port\r\nAccept: */*\r\n\r\n";
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
    [, $port, $shard, $connections, $requests, $pipeline, $seed] = $args;
    fwrite(STDOUT, json_encode(run_shard((int) $port, (int) $shard, (int) $connections, (int) $requests, (int) $pipeline, (int) $seed)) . "\n");
    exit(0);
}

$port = (int) ($args[0] ?? 0);
if ($port < 1) {
    fwrite(STDERR, "usage: php stress.php <port> [--connections 1000] [--requests 2000000] [--procs 4] [--pipeline 1] [--seed 1]\n");
    exit(2);
}
$opt = ['connections' => 1000, 'requests' => 2000000, 'procs' => 4, 'pipeline' => 1, 'seed' => 1];
for ($i = 1; $i < count($args); $i += 2) {
    $name = ltrim($args[$i], '-');
    if (!isset($opt[$name]) || !isset($args[$i + 1]) || !ctype_digit($args[$i + 1]) || (int) $args[$i + 1] < 1) {
        fwrite(STDERR, "bad option: {$args[$i]}\n");
        exit(2);
    }
    $opt[$name] = (int) $args[$i + 1];
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
        (string) $opt['pipeline'], (string) $opt['seed']];
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
$result = $total + ['requests_asked' => $opt['requests'], 'connections' => $opt['connections'], 'pipeline' => $opt['pipeline'],
    'seconds' => round($seconds, 1), 'req_per_s' => (int) round($total['matched'] / $seconds), 'errors' => array_slice($errors, 0, 5)];
echo json_encode($result, JSON_UNESCAPED_SLASHES), "\n";
exit($failed || $total['mismatches'] > 0 || $total['lost'] > 0 || $total['sent'] !== $opt['requests'] ? 1 : 0);
