<?php
// The aggregator of lab/realistic.sh: reads k6's CSV output from a FIFO while k6 runs, keeps per second and per endpoint a latency
// histogram (aggregate-lib.php) and nothing raw on disk, judges each step as it ends, and tells the harness how far it is behind.
//
// It runs in its own container on k6's CPUs. Configuration: the environment variable AGG_CONFIG, a JSON object:
//   fifo, status, result       paths (the FIFO is read; the status is rewritten every second, the result once at the end)
//   steps                      [{"vus": <the step's VUs>, "offered": <req/s>}, ...] in the order k6 runs them
//   stop_on_fail               true: the first failing step ends the judging and is reported in the status (the harness stops k6)
//   users_per_rps, limits      the mapping and the pass rule (see agg_summarize)
//   server_cgroup, k6_cgroup   cgroup directories whose cpu.stat is read on every whole second (null: not read)
// The stream ends with the line `#END` that the harness writes after k6 exits (the FIFO is opened read-write, so the reader never
// sees an end of file by itself, and a second keeps ticking while k6 starts).
//
// The lag in the status is the clock against the newest sample's second: k6 does not slow down when this reader falls behind, it
// buffers samples in its own memory, so the harness refuses a run whose lag grows.

require __DIR__ . '/aggregate-lib.php';

$config = json_decode((string) getenv('AGG_CONFIG'), true);
if (!is_array($config)) {
    fwrite(STDERR, "aggregate: AGG_CONFIG must be a JSON object\n");
    exit(1);
}

/** The `usage_usec` line of a cpu.stat file, or null. */
function usage_usec(?string $cgroup): ?int
{
    if ($cgroup === null) {
        return null;
    }
    $text = @file_get_contents($cgroup . '/cpu.stat');
    return $text !== false && preg_match('/^usage_usec (\d+)$/m', $text, $m) ? (int) $m[1] : null;
}

function write_json(string $path, array $data): void
{
    $tmp = $path . '.tmp';
    file_put_contents($tmp, json_encode($data, JSON_UNESCAPED_SLASHES));
    rename($tmp, $path);
}

$fifo = fopen($config['fifo'], 'r+');
if ($fifo === false) {
    fwrite(STDERR, "aggregate: cannot open {$config['fifo']}\n");
    exit(1);
}
stream_set_blocking($fifo, false);
stream_set_read_buffer($fifo, 0);

$agg = new Aggregate();
$steps = $config['steps'];
$done = [];            // judged steps, in order
$failed = null;
$k6Usage = [];         // second boundary => [usage_usec, time]
$lagMax = null;
$lag = null;
$bytes = 0;
$ended = false;
$next = (int) ceil(microtime(true));
$serverCgroup = $config['server_cgroup'] ?? null;
$k6Cgroup = $config['k6_cgroup'] ?? null;

/** Judges the steps whose plateau is over, in order. At the end of the stream, a step that never saw a later VU count ends there. */
$judge = function (bool $final) use (&$agg, &$steps, &$done, &$failed, &$k6Usage, $config): void {
    while ($failed === null && count($done) < count($steps)) {
        $i = count($done);
        $vus = $agg->vus;
        if ($final) {
            $vus[PHP_INT_MAX] = -1;
        }
        $w = agg_window($vus, $steps[$i]['vus']);
        if ($w === null) {
            return;
        }
        // The plateau's last bin is final once a sample of the next second has arrived, and the server's CPU has been read on its edges.
        if (!$final && (($agg->newestTs ?? 0) < $w[1] + 1
            || (($config['server_cgroup'] ?? null) !== null && !isset($agg->cpu[$w[0]], $agg->cpu[$w[1]])))) {
            return;
        }
        $s = agg_summarize($agg, $w[0], $w[1], (float) $steps[$i]['offered'], (float) $config['users_per_rps'], $config['limits']);
        $s['step'] = $i + 1;
        $s['vus'] = $steps[$i]['vus'];
        $s['k6_cpu_percent_of_one_cpu'] = null;
        if (isset($k6Usage[$w[0]], $k6Usage[$w[1]]) && $k6Usage[$w[1]][1] > $k6Usage[$w[0]][1]) {
            $s['k6_cpu_percent_of_one_cpu'] = round(($k6Usage[$w[1]][0] - $k6Usage[$w[0]][0]) / (($k6Usage[$w[1]][1] - $k6Usage[$w[0]][1]) * 1e6) * 100, 2);
        }
        $done[] = $s;
        if (!$s['pass'] && ($config['stop_on_fail'] ?? false)) {
            $failed = ['step' => $i + 1, 'vus' => $s['vus'], 'reasons' => $s['reasons']];
        }
    }
};

$status = function () use (&$agg, &$done, &$failed, &$lag, &$lagMax, &$ended, $config): void {
    $vusNow = $agg->vus === [] ? null : $agg->vus[max(array_keys($agg->vus))];
    write_json($config['status'], [
        'time' => microtime(true),
        'rows' => $agg->rows,
        'requests' => $agg->requests,
        'unparsed' => $agg->unparsed,
        'newest_ts' => $agg->newestTs,
        'vus_now' => $vusNow,
        'lag_s' => $lag,
        'lag_max_s' => $lagMax,
        'steps_done' => count($done),
        'failed' => $failed,
        'ended' => $ended,
    ]);
};

while (!$ended) {
    $now = microtime(true);
    if ($now >= $next) {
        $key = $next;
        $server = usage_usec($serverCgroup);
        $k6 = usage_usec($k6Cgroup);
        $t = microtime(true);
        if ($server !== null) {
            $agg->cpu[$key] = [$server, $t];
        }
        if ($k6 !== null) {
            $k6Usage[$key] = [$k6, $t];
        }
        $next = max($next + 1, (int) floor($t) + 1);
        if ($agg->newestTs !== null) {
            $lag = round($t - $agg->newestTs, 3);
            $lagMax = max($lagMax ?? 0.0, $lag);
        }
        $judge(false);
        $status();
        continue;
    }
    $read = [$fifo];
    $write = $except = null;
    $wait = (int) min(50000, max(0, ($next - $now) * 1e6));
    if (stream_select($read, $write, $except, 0, $wait) === 1) {
        $data = fread($fifo, 1 << 20);
        if ($data !== false && $data !== '') {
            $bytes += strlen($data);
            $ended = $agg->feed($data);
            if ($agg->newestTs !== null) {
                $lag = round(microtime(true) - $agg->newestTs, 3);
                $lagMax = max($lagMax ?? 0.0, $lag);
            }
            $judge(false);
        }
    }
}

$judge(true);
$status();
write_json($config['result'], [
    'steps' => $done,
    'failed' => $failed,
    'per_second' => agg_per_second($agg),
    'run_total' => agg_run_total($agg),
    'rows' => $agg->rows,
    'requests' => $agg->requests,
    'unparsed' => $agg->unparsed,
    'bytes' => $bytes,
    'lag_max_s' => $lagMax,
    'vus_by_second' => $agg->vus,
]);
