<?php
// The sampler of lab/realistic.sh and lab/macro.sh --per-second: ONE loop, in the probe container (--cgroupns host --pid host, CPUs 0 and
// 1), that reads the server from outside once a second and appends one JSON line per reading to a file. Never one `docker exec` a second:
// runc and dockerd work would land on CPUs the server may share. Each line is for a whole-second boundary:
//
//   {"sec": <the boundary it aimed at>, "t_us": <when it read>, "cpu_usec", "pss_anon_kb", "memory_current", "wal_bytes", "wal_frames",
//    "minflt", "majflt", "fds"}      (cumulative readings except the gauges; lab/macro/series-lib.php turns them into rows)
//
//   php sampler.php <server cgroup id> <server pid> <database path in the server's container, or -> <stop file> <out file> <max seconds>
//
// The first line is read at once, whatever the time, for the second already running; the others are at whole seconds.
// It stops when the stop file exists (the harness creates it) or after <max seconds>, whichever comes first.

require __DIR__ . '/series-lib.php';

[, $cgroupId, $pid, $dbPath, $stopFile, $outFile, $maxSeconds] = $argv + array_fill(0, 7, '');
if ($cgroupId === '' || !ctype_digit($pid) || $stopFile === '' || $outFile === '' || !ctype_digit($maxSeconds)) {
    fwrite(STDERR, "sampler: usage: sampler.php <cgroup id> <pid> <db path or -> <stop file> <out file> <max seconds>\n");
    exit(2);
}
$cgroup = "/sys/fs/cgroup/docker/$cgroupId";
$root = "/proc/$pid/root";
$out = fopen($outFile, 'a');
if ($out === false || !is_dir($cgroup)) {
    fwrite(STDERR, "sampler: cannot open $outFile or no cgroup $cgroup\n");
    exit(1);
}

function read_sample(string $cgroup, string $root, string $dbPath, int $sec): array
{
    $t = (int) round(microtime(true) * 1e6);
    $cpu = preg_match('/^usage_usec (\d+)$/m', (string) @file_get_contents("$cgroup/cpu.stat"), $m) ? (int) $m[1] : 0;
    $pss = 0;
    $minflt = 0;
    $majflt = 0;
    $fds = 0;
    foreach (preg_split('/\s+/', trim((string) @file_get_contents("$cgroup/cgroup.procs"))) ?: [] as $p) {
        if ($p === '') {
            continue;
        }
        if (preg_match('/^Pss_Anon:\s+(\d+) kB$/m', (string) @file_get_contents("/proc/$p/smaps_rollup"), $m)) {
            $pss += (int) $m[1];
        }
        $fds += count(@scandir("/proc/$p/fd") ?: []) - 2;
        $faults = proc_stat_faults((string) @file_get_contents("/proc/$p/stat"));
        if ($faults !== null) {
            $minflt += $faults[0];
            $majflt += $faults[1];
        }
    }
    $walBytes = null;
    $walFrames = null;
    if ($dbPath !== '-') {
        clearstatcache(true, "$root$dbPath-wal");
        $size = @filesize("$root$dbPath-wal");
        $walBytes = $size === false ? null : $size;
        // Why `head` and not fopen(): PHP resolves /proc/<pid>/root to "/" before it opens a file, and opens the probe's own /tmp.
        for ($try = 0; $try < 3 && $walFrames === null; $try++) {
            $walFrames = wal_header_frames((string) shell_exec('head -c 96 ' . escapeshellarg("$root$dbPath-shm") . ' 2>/dev/null'));
        }
    }
    return ['sec' => $sec, 't_us' => $t, 'cpu_usec' => $cpu, 'pss_anon_kb' => $pss,
        'memory_current' => (int) trim((string) @file_get_contents("$cgroup/memory.current")), 'wal_bytes' => $walBytes,
        'wal_frames' => $walFrames, 'minflt' => $minflt, 'majflt' => $majflt, 'fds' => max(0, $fds)];
}

$deadline = microtime(true) + (int) $maxSeconds;
// One reading at once, for the second that is already running: the load starts a moment after the sampler, and a row needs the reading at the
// start of its second (the CPU and the faults of that first, partial second are read over the time that is left of it).
fwrite($out, json_encode(read_sample($cgroup, $root, $dbPath, (int) floor(microtime(true)))) . "\n");
fflush($out);
$boundary = (int) ceil(microtime(true));
while (true) {
    // A few ms after the boundary: whatever the server did in the second that just ended is in the readings.
    $wait = $boundary + 0.005 - microtime(true);
    if ($wait > 0) {
        usleep((int) ($wait * 1e6));
    }
    fwrite($out, json_encode(read_sample($cgroup, $root, $dbPath, $boundary)) . "\n");
    fflush($out);
    if (file_exists($stopFile) || microtime(true) > $deadline) {
        break;
    }
    // A reading that took longer than a second skips the boundaries it missed instead of reading twice in a row.
    $boundary = max($boundary + 1, (int) ceil(microtime(true) - 0.005));
}
