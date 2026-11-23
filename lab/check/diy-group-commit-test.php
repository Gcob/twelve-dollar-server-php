<?php
// The DIY server's loop driven one turn at a time (DiyServer::turn()) and its group commit, over TCP on this machine, with the clients in
// this process: the loop serves a request through a hand-driven LOOP_ONCE; two writes that reach the server in one turn are committed
// together and answered after the commit; a write holds the requests behind it on its connection, so that the responses stay in the order of
// the requests, and two pipelined writes are both answered with no stall; a client that asked for `Connection: close` is closed after its
// write's response. The handler is the stub of diy-lib.php, whose /write/<n> answers with a Closure the way the app's handler does.
// Run: bash lab/run.sh 8.5 php -d extension=sockets -d extension=event /lab/check/diy-group-commit-test.php

require __DIR__ . '/diy-lib.php';
require __DIR__ . '/diy-rig.php';

const PLAIN = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 18\r\n\r\n{\"echo\":\"GET /x \"}";

/** The response of a stub write that left $committed (the list of values it saw committed) behind it. */
function created(array $committed): string
{
    $body = '{"committed":[' . implode(',', $committed) . ']}';
    return "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: " . strlen($body) . "\r\n\r\n" . $body;
}

function read_of(array $committed): string
{
    $body = '{"committed":[' . implode(',', $committed) . ']}';
    return "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: " . strlen($body) . "\r\n\r\n" . $body;
}

function get(string $path): string
{
    return "GET $path HTTP/1.1\r\n\r\n";
}

function write(int $n, string $extra = ''): string
{
    return "POST /write/$n HTTP/1.1\r\n{$extra}Content-Length: 0\r\n\r\n";
}

/**
 * A rig whose commit is the stub's: it records the size of each batch and what the clients had read when it ran, then runs the writes.
 *
 * @return array{DiyRig, object{batches: list<int>, readBeforeCommit: list<string>}}
 */
function grouped_rig(): array
{
    $spy = new class {
        /** @var list<int> */
        public array $batches = [];
        /** @var list<string> the bytes every client had read when the commit ran, one entry a batch */
        public array $readBeforeCommit = [];
    };
    $rig = null;
    $rig = new DiyRig(function (array $writes) use (&$rig, $spy): array {
        $spy->batches[] = count($writes);
        $seen = '';
        foreach ($rig->clients as $i => $client) {
            $bytes = (string) fread($client, 65536);
            $rig->got[$i] .= $bytes;
            $seen .= $bytes;
        }
        $spy->readBeforeCommit[] = $seen;
        return array_map(static fn (Closure $write) => $write(), $writes);
    });
    return [$rig, $spy];
}

diy_case('one request is served through a loop driven by hand, a turn at a time (no group commit)', function () {
    $rig = new DiyRig();
    $c = $rig->connect();
    $rig->send($c, get('/x'));
    $answer = $rig->readFrom($c, strlen(PLAIN));
    $rig->close();
    return $answer === PLAIN ? null : 'got ' . diy_show($answer);
});

diy_case('two writes on two connections that reach the server in one turn: one commit of two, both answered after it', function () {
    global $diy_committed;
    $diy_committed = [];
    [$rig, $spy] = grouped_rig();
    $a = $rig->connect();
    $b = $rig->connect();
    $rig->send($a, write(1));
    $rig->send($b, write(2));
    // Each write answers with what had been committed when it ran: a saw its own, b saw both.
    $gotA = $rig->readFrom($a, strlen(created([1])));
    $gotB = $rig->readFrom($b, strlen(created([1, 2])));
    $rig->close();
    if ($spy->batches !== [2]) {
        return 'the batches were ' . json_encode($spy->batches) . ', expected one of 2';
    }
    if ($spy->readBeforeCommit !== ['']) {
        return 'a client had a response before the commit: ' . diy_show($spy->readBeforeCommit[0]);
    }
    if ($gotA !== created([1]) || $gotB !== created([1, 2])) {
        return 'responses ' . diy_show($gotA) . ' and ' . diy_show($gotB);
    }
    return null;
});

diy_case('a write alone is a batch of one (no wait for company)', function () {
    global $diy_committed;
    $diy_committed = [];
    [$rig, $spy] = grouped_rig();
    $a = $rig->connect();
    $rig->send($a, write(7));
    $got = $rig->readFrom($a, strlen(created([7])));
    $rig->close();
    return $spy->batches === [1] && $got === created([7]) ? null : 'batches ' . json_encode($spy->batches) . ' got ' . diy_show($got);
});

diy_case('a write then a read pipelined on one connection: the write answers first, and the read comes after the commit', function () {
    global $diy_committed;
    $diy_committed = [];
    [$rig, $spy] = grouped_rig();
    $a = $rig->connect();
    $rig->send($a, write(3) . get('/committed'));
    $expected = created([3]) . read_of([3]);
    $got = $rig->readFrom($a, strlen($expected));
    $rig->close();
    return $got === $expected ? null : 'got ' . diy_show($got) . ', expected ' . diy_show($expected);
});

diy_case('two writes pipelined on one connection, with a read after: all three answered in order, each write in its own commit, no stall', function () {
    global $diy_committed;
    $diy_committed = [];
    [$rig, $spy] = grouped_rig();
    $a = $rig->connect();
    $rig->send($a, write(4) . write(5) . get('/committed'));
    $expected = created([4]) . created([4, 5]) . read_of([4, 5]);
    $got = $rig->readFrom($a, strlen($expected));
    $rig->close();
    if ($got !== $expected) {
        return 'got ' . diy_show($got) . ', expected ' . diy_show($expected);
    }
    return $spy->batches === [1, 1] ? null : 'the batches were ' . json_encode($spy->batches);
});

diy_case('a read on another connection is not held by a write waiting for the flush', function () {
    global $diy_committed;
    $diy_committed = [];
    [$rig, $spy] = grouped_rig();
    $a = $rig->connect();
    $b = $rig->connect();
    $rig->send($a, write(8));
    $rig->send($b, get('/x'));
    $gotB = $rig->readFrom($b, strlen(PLAIN));
    $gotA = $rig->readFrom($a, strlen(created([8])));
    $rig->close();
    return $gotB === PLAIN && $gotA === created([8]) ? null : 'b got ' . diy_show($gotB) . ', a got ' . diy_show($gotA);
});

diy_case('a write that said Connection: close is answered and its connection ends', function () {
    global $diy_committed;
    $diy_committed = [];
    [$rig, $spy] = grouped_rig();
    $a = $rig->connect();
    $rig->send($a, write(9, "Connection: close\r\n"));
    $got = $rig->readFrom($a, strlen(created([9])));
    $rig->turns(3);
    $ended = feof($rig->clients[$a]);
    $rig->close();
    return $got === created([9]) && $ended ? null : 'got ' . diy_show($got) . ', the stream ended: ' . var_export($ended, true);
});

diy_case('requests behind a write arrive later, in a second packet: they are parsed after the write is answered', function () {
    global $diy_committed;
    $diy_committed = [];
    [$rig, $spy] = grouped_rig();
    $a = $rig->connect();
    $rig->send($a, write(6));
    $rig->readFrom($a, strlen(created([6])));
    $rig->send($a, get('/committed'));
    $expected = created([6]) . read_of([6]);
    $got = $rig->readFrom($a, strlen($expected));
    $rig->close();
    return $got === $expected ? null : 'got ' . diy_show($got);
});

diy_case('a connection holding a write answers nothing behind it, whatever event reaches it, and is not read until it is resumed (a socket pair, no loop)', function () {
    global $diy_committed;
    $diy_committed = [];
    [$server, $client] = diy_pair();
    $conn = new DiyConnection($server);
    fwrite($client, write(1) . get('/committed'));
    if (!$conn->onReadable()) {
        return 'the connection ended';
    }
    $write = $conn->takePending();
    if (!($write instanceof Closure) || $conn->takePending() !== null) {
        return 'the write was not handed over once';
    }
    // The write event of the same turn: the requests behind the write must not be answered before it.
    if (!$conn->onWritable() || $conn->wantsRead() || diy_read_all($client) !== '') {
        return 'a held connection answered or wanted to read: ' . diy_show(diy_read_all($client));
    }
    if ($diy_committed !== []) {
        return 'the write ran before its turn to commit';
    }
    $response = $write();
    if (!$conn->resume($response)) {
        return 'the connection ended on resume';
    }
    $expected = created([1]) . read_of([1]);
    $got = diy_read_all($client);
    if ($got !== $expected) {
        return 'got ' . diy_show($got) . ', expected ' . diy_show($expected);
    }
    return $conn->wantsRead() && $conn->takePending() === null ? null : 'the connection did not read again after resume';
});

diy_finish();
