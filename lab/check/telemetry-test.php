<?php
// The DIY server's telemetry line (lab/servers/diy-telemetry.php): what one line holds and how the numbers move from one second to the
// next. The timer, the loop and the app's own counters are covered by lab/check.sh's run against the real server.
// Run: bash lab/run.sh 8.5 php /lab/check/telemetry-test.php

require __DIR__ . '/../servers/diy-telemetry.php';
require __DIR__ . '/../macro/series-lib.php';

$failures = 0;
function check(string $name, bool $ok, string $detail = ''): void
{
    global $failures;
    if ($ok) {
        echo "ok    $name\n";
    } else {
        $failures++;
        echo "FAIL  $name" . ($detail === '' ? '' : ": $detail") . "\n";
    }
}

$extra = ['requests' => ['GET /feed' => 3], 'wal_bytes' => 4096];
$t = new DiyTelemetry(static function () use (&$extra): array {
    $fields = $extra;
    $extra = ['requests' => [], 'wal_bytes' => 4096];
    return $fields;
});

// A callback that takes 20 ms is the longest of its second; the timed callback still gets its arguments and runs.
$seen = null;
$timed = $t->timed(static function ($fd, int $what, string $peer) use (&$seen): void {
    $seen = [$fd, $what, $peer];
    usleep(20_000);
});
$timed(7, 2, 'peer');
$fast = $t->timed(static function (): void {
});
$fast();
check('the wrapped callback gets its arguments', $seen === [7, 2, 'peer'], json_encode($seen));

$line = $t->tick(500);
check('a line starts with `telemetry ` and the telemetry parser reads it back', (telemetry_parse($line . "\n")[500]['second'] ?? null) === 500);
$row = telemetry_parse($line . "\n")[500];
check('the longest callback of the second is the 20 ms one, not the fast one', $row['longest_callback_ms'] >= 20.0 && $row['longest_callback_ms'] < 80.0, (string) $row['longest_callback_ms']);
check('the app\'s fields come in the line', $row['requests'] === ['GET /feed' => 3] && $row['wal_bytes'] === 4096, json_encode($row));

$row = telemetry_parse($t->tick(501) . "\n")[501];
check('the longest callback starts over each second', $row['longest_callback_ms'] < 5.0, (string) $row['longest_callback_ms']);
check('the app\'s counters start over each second (its closure reset them)', $row['requests'] === []);

// GC runs and collected are deltas of gc_status(): a cycle collected between two lines shows in the second line only.
$before = telemetry_parse($t->tick(502) . "\n")[502];
$a = new stdClass();
$b = new stdClass();
$a->other = $b;
$b->other = $a;
unset($a, $b);
gc_collect_cycles();
$after = telemetry_parse($t->tick(503) . "\n")[503];
check('no collection, no GC run in the second line', $before['gc_runs'] === 0 && $before['gc_collected'] === 0, json_encode($before));
check('one cycle collected shows as one run and two collected', $after['gc_runs'] === 1 && $after['gc_collected'] === 2, json_encode($after));

// Page faults are deltas of /proc/self/stat: touching new memory shows as minor faults, and a quiet second as a small number.
$quiet = telemetry_parse($t->tick(504) . "\n")[504];
$blob = str_repeat('x', 40 * 1024 * 1024);
$touched = telemetry_parse($t->tick(505) . "\n")[505];
// Why not thousands: the VM maps 40 MiB with huge pages, a couple of dozen faults.
check('40 MiB of new memory shows as minor faults in the next line, a quiet second as almost none', $touched['minflt'] >= $quiet['minflt'] + 10 && $quiet['minflt'] < 10, "quiet={$quiet['minflt']} touched={$touched['minflt']}");
check('and no major fault (the memory was not read from disk)', $touched['majflt'] === 0 && strlen($blob) > 0);

// The line's second is the boundary the timer was set for, not the clock when it fired: a timer that fires a fraction of a millisecond
// early (the loop's clock is not the wall clock) must not give two lines the same second, and a stalled loop skips boundaries.
check('a tick on time is followed by the next second', DiyTelemetry::nextBoundary(1000, 1000.003) === 1001);
check('a tick fired 0.5 ms early is still followed by the next second, not the same one', DiyTelemetry::nextBoundary(1000, 999.9995) === 1001);
check('a tick fired 3.4 s late skips the seconds the loop missed', DiyTelemetry::nextBoundary(1000, 1003.4) === 1004);
check('a tick 1.5 ms after the boundary (inside the margin) still goes to the next second', DiyTelemetry::nextBoundary(1000, 1000.0015) === 1001);

echo $failures === 0 ? "all ok\n" : "$failures failed\n";
exit($failures === 0 ? 0 : 1);
