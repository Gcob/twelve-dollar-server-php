<?php
// The per-second series of a lab run (lab/realistic.sh, lab/macro.sh --per-second), without a clock or a container so that
// lab/check/series-test.php can drive it: readings of the server from outside (the WAL's frames, the page faults), the server's own
// telemetry lines read back from its log, and the merge of those with the aggregator's latency rows into one row per second.
// lab/macro/sampler.php is the process that takes the readings.

/**
 * The frames in use in a SQLite WAL (mxFrame), from the first 96 bytes of its `-shm` file: a 32-bit integer at offset 16, in the byte
 * order of the machine (the wal-index is shared memory, never moved between machines), and the header is written twice, the second
 * copy at offset 48 + 16. Why not the size of the `-wal` file: SQLite starts the WAL over from its first frame after a checkpoint
 * without truncating the file, so the size only grows and the frames show where the writes are in the file.
 *
 * Null when the bytes are too few, or the two copies disagree (a writer is in the middle of updating them: read again).
 */
function wal_header_frames(string $head): ?int
{
    if (strlen($head) < 96) {
        return null;
    }
    $first = unpack('L', $head, 16)[1];
    return $first === unpack('L', $head, 64)[1] ? $first : null;
}

/** wal_header_frames() of a `-shm` file, read again up to $tries times while the two copies disagree; null when the file is unreadable. */
function wal_frames(string $shmPath, int $tries = 5): ?int
{
    for ($i = 0; $i < $tries; $i++) {
        $head = @file_get_contents($shmPath, false, null, 0, 96);
        if ($head === false) {
            return null;
        }
        $frames = wal_header_frames($head);
        if ($frames !== null) {
            return $frames;
        }
    }
    return null;
}

/**
 * The minor and major page faults of a process from the text of its /proc/<pid>/stat: fields 10 and 12, counted from after the last
 * `)` (the process name is field 2 and may hold spaces and parentheses).
 *
 * @return array{int, int}|null [minor, major]
 */
function proc_stat_faults(string $stat): ?array
{
    $close = strrpos($stat, ')');
    if ($close === false) {
        return null;
    }
    $fields = preg_split('/\s+/', trim(substr($stat, $close + 1)));
    // $fields[0] is field 3 (the state): field 10 is $fields[7], field 12 is $fields[9].
    if (!isset($fields[9]) || !ctype_digit($fields[7]) || !ctype_digit($fields[9])) {
        return null;
    }
    return [(int) $fields[7], (int) $fields[9]];
}

/**
 * The server's telemetry lines (`telemetry {json}`, one per second) of its log, by the second each one describes. A server of several
 * processes (APP_WORKERS) prints one line per process per second, each with its `pid`: the lines of one second become one row
 * (telemetry_sum) with a `processes` count and no `pid`. A line without a `pid` is kept as it is.
 *
 * @return array<int, array<string, mixed>>
 */
function telemetry_parse(string $log): array
{
    $out = [];
    foreach (explode("\n", $log) as $line) {
        if (!str_starts_with($line, 'telemetry {')) {
            continue;
        }
        $row = json_decode(substr($line, 10), true);
        if (!is_array($row) || !isset($row['second']) || !is_int($row['second'])) {
            continue;
        }
        if (isset($row['pid'])) {
            $out[$row['second']] = telemetry_sum($out[$row['second']] ?? null, $row);
        } else {
            $out[$row['second']] = $row;
        }
    }
    return $out;
}

/**
 * The line of one process added to what the other processes of the same second printed (null: it is the first). Counts and the
 * connections' numbers are summed (a peak too: the processes' peaks may fall at different moments of the second, so the sum is an upper
 * bound of the connections open at once); the longest callback is the largest; the WAL is one file, read by each process; the mean batch
 * of group commit is weighted by each process's commits.
 *
 * @param array<string, mixed>|null $sum
 * @param array<string, mixed> $row a line with a `pid`
 * @return array<string, mixed>
 */
function telemetry_sum(?array $sum, array $row): array
{
    unset($row['pid']);
    if ($sum === null) {
        $row['processes'] = 1;
        return $row;
    }
    $sum['processes']++;
    $requests = (array) ($sum['requests'] ?? []);
    foreach ((array) ($row['requests'] ?? []) as $endpoint => $count) {
        $requests[$endpoint] = ($requests[$endpoint] ?? 0) + $count;
    }
    $sum['requests'] = $requests;
    foreach (['gc_runs', 'gc_collected', 'minflt', 'majflt'] as $key) {
        $sum[$key] = ($sum[$key] ?? 0) + ($row[$key] ?? 0);
    }
    foreach (['longest_callback_ms', 'wal_bytes'] as $key) {
        $sum[$key] = max($sum[$key] ?? 0, $row[$key] ?? 0);
    }
    if (isset($row['connections'])) {
        foreach (['open_peak', 'limit_closes', 'accept_pauses'] as $key) {
            $sum['connections'][$key] = ($sum['connections'][$key] ?? 0) + $row['connections'][$key];
        }
    }
    if (isset($row['group_commit'])) {
        $a = $sum['group_commit'] ?? ['commits' => 0, 'batch_mean' => 0.0, 'batch_max' => 0];
        $b = $row['group_commit'];
        $commits = $a['commits'] + $b['commits'];
        $sum['group_commit'] = ['commits' => $commits,
            'batch_mean' => $commits === 0 ? 0.0 : round(($a['commits'] * $a['batch_mean'] + $b['commits'] * $b['batch_mean']) / $commits, 2),
            'batch_max' => max($a['batch_max'], $b['batch_max'])];
    }
    return $sum;
}

/**
 * One row per second of the run, from the first sample's second up to (not including) the last one's: a row needs the sample at the
 * start of its second and the one at its end (the CPU and the faults are the difference, the memory and the WAL the reading at the
 * end). A row whose samples are not both there has `server` null: never a delta over two seconds. Latency seconds the aggregator has
 * no request for are rows too (zero requests, no endpoint), and latency seconds outside the sampled run are left out.
 *
 * @param list<array<string, mixed>> $perSecond  the aggregator's rows (agg_per_second), keyed by their `second`
 * @param list<array<string, mixed>> $samples    the sampler's lines: sec (the boundary it aimed at), t_us (when it read), cpu_usec, pss_anon_kb,
 *                                               memory_current, wal_bytes, wal_frames (null when unknown), minflt, majflt, fds
 * @param array<int, array<string, mixed>> $telemetry telemetry_parse()
 * @return list<array<string, mixed>>
 */
function series_merge(array $perSecond, array $samples, array $telemetry): array
{
    if ($samples === []) {
        return [];
    }
    $at = [];
    foreach ($samples as $s) {
        $at[$s['sec']] = $s;
    }
    $latency = [];
    foreach ($perSecond as $p) {
        $latency[$p['second']] = $p;
    }
    $rows = [];
    for ($sec = min(array_keys($at)); $sec < max(array_keys($at)); $sec++) {
        $a = $at[$sec] ?? null;
        $b = $at[$sec + 1] ?? null;
        $server = null;
        if ($a !== null && $b !== null && $b['t_us'] > $a['t_us']) {
            $seconds = ($b['t_us'] - $a['t_us']) / 1e6;
            $server = [
                'cpu_usec' => (int) round(($b['cpu_usec'] - $a['cpu_usec']) / $seconds),
                'pss_anon_kb' => $b['pss_anon_kb'],
                'memory_current' => $b['memory_current'],
                'wal_bytes' => $b['wal_bytes'],
                'wal_frames' => $b['wal_frames'],
                'fds' => $b['fds'],
                'minflt' => $b['minflt'] - $a['minflt'],
                'majflt' => $b['majflt'] - $a['majflt'],
            ];
        }
        $l = $latency[$sec] ?? null;
        $rows[] = [
            'second' => $sec,
            'vus' => $l['vus'] ?? null,
            'requests' => $l['requests'] ?? 0,
            'errors' => $l['errors'] ?? 0,
            'endpoints' => $l['endpoints'] ?? [],
            'server' => $server,
            'telemetry' => $telemetry[$sec] ?? null,
        ];
    }
    return $rows;
}
