<?php
// The loop presets of the DIY server (diy_loop_presets() in lab/servers/diy-server.php): the base each one builds, what the boot line says,
// a server on it serving requests, and a name that is not a preset refused.
// Run: bash lab/run.sh 8.5 php -d extension=sockets -d extension=event /lab/check/diy-loop-test.php

require __DIR__ . '/diy-lib.php';
require __DIR__ . '/diy-rig.php';

const LOOP_GET = "GET /x HTTP/1.1\r\n\r\n";
const LOOP_GET_RESPONSE = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 18\r\n\r\n{\"echo\":\"GET /x \"}";

// What each preset's boot line says, written by hand. The method text is libevent's own: it says `(with changelist)` only when the flag
// reached the base, and `poll` only when epoll was avoided.
const LOOP_LINES = [
    'nolock' => 'epoll, preset nolock (flags NOLOCK)',
    'changelist' => 'epoll (with changelist), preset changelist (flags EPOLL_USE_CHANGELIST)',
    'poll' => 'poll, preset poll (avoids epoll)',
];

diy_case('the presets are the three that are named', fn () => array_keys(diy_loop_presets()) === ['nolock', 'changelist', 'poll'] ? null : 'got ' . json_encode(array_keys(diy_loop_presets())));

diy_case('no preset: the loop line is the method alone, as it always was', function () {
    $rig = new DiyRig();
    $line = $rig->server->loopLine();
    $rig->close();
    return $line === 'epoll' ? null : "got '$line'";
});

foreach (LOOP_LINES as $preset => $line) {
    diy_case("preset $preset: the base is built from it and the boot line says so", function () use ($preset, $line) {
        $rig = new DiyRig(null, $preset);
        $got = $rig->server->loopLine();
        $rig->close();
        return $got === $line ? null : "got '$got', expected '$line'";
    });

    diy_case("preset $preset: a server serves a request, the next one on the same connection, and a connection that leaves", function () use ($preset) {
        $rig = new DiyRig(null, $preset);
        $a = $rig->connect();
        $rig->send($a, LOOP_GET);
        $first = $rig->readFrom($a, strlen(LOOP_GET_RESPONSE));
        $rig->got[$a] = '';
        $rig->send($a, LOOP_GET . LOOP_GET);
        $next = $rig->readFrom($a, 2 * strlen(LOOP_GET_RESPONSE));
        $b = $rig->connect();
        $rig->send($b, LOOP_GET);
        $other = $rig->readFrom($b, strlen(LOOP_GET_RESPONSE));
        fclose($rig->clients[$a]);
        unset($rig->clients[$a]);
        $rig->turns(3);
        $rig->close();
        if ($first !== LOOP_GET_RESPONSE || $next !== LOOP_GET_RESPONSE . LOOP_GET_RESPONSE || $other !== LOOP_GET_RESPONSE) {
            return 'got ' . diy_show($first) . ' then ' . diy_show($next) . ' and ' . diy_show($other);
        }
        return null;
    });
}

diy_case('a name that is not a preset is refused, and says which are', function () {
    try {
        diy_loop_config('epoll');
    } catch (InvalidArgumentException $e) {
        return $e->getMessage() === 'the loop preset must be one of nolock, changelist, poll, got "epoll"' ? null : 'the message is: ' . $e->getMessage();
    }
    return 'no exception';
});

diy_finish();
