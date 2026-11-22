<?php
// The per-second series (lab/macro/series-lib.php): the WAL's frames in use read from the -shm header of a real SQLite database, the
// server's telemetry lines read back from a log, and the merge of the latency rows, the sampler's readings and the telemetry into
// one row per second. Run: bash lab/run.sh 8.5 php /lab/check/series-test.php

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

// --- mxFrame, read from the -shm file of a real WAL ---------------------------------------------------------------------------
// The independent source is the WAL file itself: a 32-byte header, then frames of one page plus 24 bytes each.
$dir = sys_get_temp_dir() . '/series-test-' . getmypid();
mkdir($dir);
$db = new PDO("sqlite:$dir/t.db", null, null, [PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION]);
$db->exec('PRAGMA journal_mode = WAL');
$db->exec('PRAGMA wal_autocheckpoint = 0');
$db->exec('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
$pageSize = (int) $db->query('PRAGMA page_size')->fetchColumn();
function frames_of_wal_file(string $wal, int $pageSize): int
{
    clearstatcache(true, $wal);
    return intdiv(filesize($wal) - 32, $pageSize + 24);
}
check('a database that was never opened has no frames to read', wal_frames("$dir/nothing.db-shm") === null);
$before = wal_frames("$dir/t.db-shm");
check('the frames of a fresh table are what the WAL file holds', $before !== null && $before === frames_of_wal_file("$dir/t.db-wal", $pageSize) && $before > 0, var_export($before, true));

$db->exec('BEGIN');
for ($i = 0; $i < 400; $i++) {
    $db->exec("INSERT INTO t (v) VALUES ('" . str_repeat('x', 200) . "')");
}
$db->exec('COMMIT');
$grown = wal_frames("$dir/t.db-shm");
check('400 rows later the frames are the WAL file\'s, and more than before', $grown === frames_of_wal_file("$dir/t.db-wal", $pageSize) && $grown > $before + 10, "before=$before after=$grown");
$bytesBefore = filesize("$dir/t.db-wal");

$db->query('PRAGMA wal_checkpoint(RESTART)')->fetchAll();
$db->exec("INSERT INTO t (v) VALUES ('after the checkpoint')");
clearstatcache(true, "$dir/t.db-wal");
$restarted = wal_frames("$dir/t.db-shm");
check('after a checkpoint the next write restarts the WAL: a few frames', $restarted !== null && $restarted >= 1 && $restarted <= 3, var_export($restarted, true));
check('while the WAL file keeps its size (only the frames show the checkpoint)', filesize("$dir/t.db-wal") === $bytesBefore, filesize("$dir/t.db-wal") . " vs $bytesBefore");
unset($db);

check('an -shm file shorter than its header reads as null', (file_put_contents("$dir/short-shm", 'abc') !== false) && wal_frames("$dir/short-shm") === null);
// The two copies of the header differ while a writer is in the middle of updating it: the reader tries again, then gives up.
$hdr = str_repeat("\0", 96);
file_put_contents("$dir/torn-shm", substr_replace(substr_replace($hdr, pack('L', 7), 16, 4), pack('L', 9), 64, 4));
check('two copies of the header that never agree read as null', wal_frames("$dir/torn-shm", 3) === null);
file_put_contents("$dir/same-shm", substr_replace(substr_replace($hdr, pack('L', 1234), 16, 4), pack('L', 1234), 64, 4));
check('two copies that agree give the frames', wal_frames("$dir/same-shm") === 1234);
array_map('unlink', glob("$dir/*") ?: []);
rmdir($dir);

// --- /proc/<pid>/stat: faults, even when the process name holds spaces and parentheses -------------------------------------------
$stat = '1234 (php (my server)) S 1 1234 1234 0 -1 4194560 5678 0 91 0 100 50 0 0 20 0 1 0 12345 1000000 500 18446744073709551615';
check('minor and major faults are fields 10 and 12, found after the last parenthesis', proc_stat_faults($stat) === [5678, 91], json_encode(proc_stat_faults($stat)));
check('an unreadable stat gives null', proc_stat_faults('garbage') === null);

// --- the telemetry lines of the server's log ------------------------------------------------------------------------------------
$log = implode("\n", [
    'listening on 0.0.0.0:18080',
    'telemetry {"second":100,"requests":{"GET /feed":5,"GET /posts/:id":7},"longest_callback_ms":1.5,"gc_runs":2,"gc_collected":10,"wal_bytes":4096,"minflt":30,"majflt":1}',
    'accepted socket: tcp_nodelay=1',
    'telemetry {"second":101,"requests":{},"longest_callback_ms":0.1,"gc_runs":0,"gc_collected":0,"wal_bytes":4096,"minflt":0,"majflt":0}',
    'telemetry {not json',
    '',
]);
$tel = telemetry_parse($log);
check('the telemetry lines are keyed by their second, the other lines are ignored', array_keys($tel) === [100, 101], json_encode(array_keys($tel)));
check('a line keeps its numbers', $tel[100]['requests'] === ['GET /feed' => 5, 'GET /posts/:id' => 7] && $tel[100]['longest_callback_ms'] === 1.5 && $tel[100]['gc_runs'] === 2);

// --- the merge ----------------------------------------------------------------------------------------------------------------------
// Samples at the boundaries 200 to 204; latency for seconds 200, 201 and 203 (nothing at 202); telemetry for 200 and 202.
$samples = [];
foreach ([200 => 0, 201 => 1, 202 => 2, 203 => 3, 204 => 4] as $sec => $k) {
    $samples[] = ['sec' => $sec, 't_us' => $sec * 1_000_000 + 4000, 'cpu_usec' => 1_000_000 + $k * 300_000, 'pss_anon_kb' => 5000 + $k * 10,
        'memory_current' => 100_000_000 + $k, 'wal_bytes' => 8192 * $k, 'wal_frames' => 10 * $k, 'minflt' => 100 * $k, 'majflt' => $k, 'fds' => 60000 + $k];
}
$perSecond = [
    ['second' => 200, 'vus' => 5, 'requests' => 3, 'errors' => 0, 'endpoints' => ['GET /feed' => ['count' => 3, 'p50' => 1.0, 'p99' => 2.0, 'max' => 2.5]]],
    ['second' => 201, 'vus' => 5, 'requests' => 1, 'errors' => 0, 'endpoints' => ['GET /feed' => ['count' => 1, 'p50' => 1.0, 'p99' => 1.0, 'max' => 1.0]]],
    ['second' => 203, 'vus' => 6, 'requests' => 2, 'errors' => 1, 'endpoints' => ['GET /posts/:id' => ['count' => 2, 'p50' => 4.0, 'p99' => 9.0, 'max' => 9.5]]],
    ['second' => 300, 'vus' => 0, 'requests' => 1, 'errors' => 0, 'endpoints' => []],
];
$telemetry = [200 => ['requests' => ['GET /feed' => 3], 'longest_callback_ms' => 2.0], 202 => ['requests' => [], 'longest_callback_ms' => 0.2]];
$rows = series_merge($perSecond, $samples, $telemetry);
check('one row per second from the first sample to the last boundary, none missing', array_column($rows, 'second') === [200, 201, 202, 203], json_encode(array_column($rows, 'second')));
check('a latency second outside the sampled run is left out', !in_array(300, array_column($rows, 'second'), true));
check('a second with no request has no endpoint and zero requests', $rows[2]['requests'] === 0 && $rows[2]['endpoints'] === [] && $rows[2]['vus'] === null);
check('the latency of a second is the one of that second', $rows[0]['endpoints']['GET /feed']['p99'] === 2.0 && $rows[3]['endpoints']['GET /posts/:id']['max'] === 9.5 && $rows[3]['errors'] === 1);
check('the CPU of a second is the usage delta over the sample interval, in us a second', $rows[0]['server']['cpu_usec'] === 300000, json_encode($rows[0]['server']));
check('the faults of a second are deltas', $rows[1]['server']['minflt'] === 100 && $rows[1]['server']['majflt'] === 1);
check('the gauges are the readings at the end of the second', $rows[0]['server']['fds'] === 60001 && $rows[0]['server']['pss_anon_kb'] === 5010 && $rows[0]['server']['wal_frames'] === 10 && $rows[0]['server']['wal_bytes'] === 8192 && $rows[0]['server']['memory_current'] === 100_000_001);
check('the telemetry of the second is attached, a second without a line has null', $rows[0]['telemetry']['longest_callback_ms'] === 2.0 && $rows[1]['telemetry'] === null && $rows[2]['telemetry']['longest_callback_ms'] === 0.2);

// The sampler missed a boundary (202): the two rows around it have no CPU, and the others are untouched.
$gappy = array_values(array_filter($samples, static fn(array $s): bool => $s['sec'] !== 202));
$rows = series_merge($perSecond, $gappy, $telemetry);
check('a missed sample leaves null readings in the two rows that needed it, not a wrong delta', $rows[1]['server'] === null && $rows[2]['server'] === null && $rows[0]['server']['cpu_usec'] === 300000 && $rows[3]['server']['cpu_usec'] === 300000, json_encode(array_column($rows, 'server')));
check('the run still has one row for every second', array_column($rows, 'second') === [200, 201, 202, 203]);
check('no sample at all gives no row', series_merge($perSecond, [], $telemetry) === []);

echo $failures === 0 ? "all ok\n" : "$failures failed\n";
exit($failures === 0 ? 0 : 1);
