<?php
// The micro benchmark harness, run inside a lab image by lab/micro.sh (never by hand: the ini flags matter).
//
// Two modes of the same file:
//   orchestrator  php micro.php <bench> --image .. --jit on|off ..   starts one worker per case, prints the rows,
//                                                                    writes the JSON of this (image, JIT) run
//   worker        php -d <ini flags> micro.php --worker ..           times ONE case in a fresh process
//
// Why one process per case: the tracing JIT compiles the timing loop for the closure it saw first. Timing the next
// case in the same process would re-trace the same loop and could blacklist it, so a case's number would depend on
// the cases before it. A fresh process per case costs about 30 ms and keeps every number independent.

declare(strict_types=1);

const EMPTY_LOOP = '(empty loop)';

/** Parses `--name value` and `--flag` options; the first non-option argument is "bench". */
function micro_args(array $argv): array
{
    $flags = ['--quick', '--header', '--worker'];
    $args = [];
    for ($i = 1; $i < count($argv); $i++) {
        $a = $argv[$i];
        if (!str_starts_with($a, '--')) {
            $args['bench'] ??= $a;
        } elseif (in_array($a, $flags, true)) {
            $args[substr($a, 2)] = true;
        } else {
            $args[substr($a, 2)] = $argv[++$i] ?? '';
        }
    }
    return $args;
}

/** The ini settings the harness cares about: set on the worker's command line, read back in the JSON. */
function micro_ini_flags(string $jit, string $jitBufferSize): array
{
    return [
        // OPcache on for the CLI, and no "file changed less than 2 s ago, do not cache it" rule.
        'opcache.enable_cli=1',
        'opcache.file_update_protection=0',
        'opcache.memory_consumption=128',
        // Only this one setting differs between JIT on and off: the buffer stays the same.
        'opcache.jit=' . ($jit === 'on' ? 'tracing' : 'disable'),
        'opcache.jit_buffer_size=' . $jitBufferSize,
        // The source images ship no php.ini and Ubuntu's does: pin what a bench can feel.
        'memory_limit=512M',
        'display_errors=stderr',
        'error_reporting=-1',
    ];
}

const INI_REPORTED = [
    'opcache.enable_cli', 'opcache.jit', 'opcache.jit_buffer_size', 'opcache.memory_consumption',
    'opcache.file_cache', 'opcache.validate_timestamps', 'opcache.file_update_protection', 'opcache.optimization_level',
    'opcache.jit_hot_loop', 'opcache.jit_hot_func', 'memory_limit', 'serialize_precision',
];

// ---------------------------------------------------------------------------------------------------------------
// Worker

function micro_fail(string $message, int $code = 2): int
{
    fwrite(STDERR, "micro: $message\n");
    return $code;
}

/** Path of a per-container copy of the seed database, made on first use. Reads on it never touch lab/data/feed.db. */
function micro_feed_copy(): string
{
    $copy = sys_get_temp_dir() . '/micro-feed.db';
    if (!is_file($copy)) {
        $source = '/lab/data/feed.db';
        if (!is_file($source)) {
            throw new RuntimeException("$source is missing (run lab/seed.sh)");
        }
        // Why: the seed is in WAL mode, and opening it in place leaves -wal/-shm files in lab/data/.
        if (!copy($source, $copy . '.part') || !rename($copy . '.part', $copy)) {
            throw new RuntimeException("cannot copy $source to $copy");
        }
    }
    return $copy;
}

function micro_time_loop(Closure $run, mixed $ctx, int $n): int
{
    $sink = null;
    $start = hrtime(true);
    for ($i = 0; $i < $n; $i++) {
        $sink = $run($ctx);
    }
    $elapsed = hrtime(true) - $start;
    // Why: the result is used after the clock stops, so no optimizer can drop the work being timed.
    $GLOBALS['micro_sink'] = $sink;
    return $elapsed;
}

/** Warms up for at least $warmupNs, and returns how many iterations make one repeat last about $targetNs. */
function micro_calibrate(Closure $run, mixed $ctx, int $warmupNs, int $targetNs): int
{
    $n = 1;
    $perOp = 1.0;
    $start = hrtime(true);
    do {
        $elapsed = micro_time_loop($run, $ctx, $n);
        if ($elapsed < 5_000_000) {
            $n *= 2; // a batch under 5 ms is too short to read the clock on
            continue;
        }
        $perOp = $elapsed / $n;
    } while (hrtime(true) - $start < $warmupNs || $elapsed < 5_000_000);
    return max(1, (int)round($targetNs / $perOp));
}

function micro_median(array $sorted): float
{
    $c = count($sorted);
    return $c % 2 ? $sorted[intdiv($c, 2)] : ($sorted[$c / 2 - 1] + $sorted[$c / 2]) / 2;
}

function micro_worker(array $argv): int
{
    $a = micro_args($argv);
    $want = $a['jit'] ?? '';
    $status = function_exists('opcache_get_status') ? @opcache_get_status(false) : false;
    if (!is_array($status)) {
        return micro_fail('OPcache is not enabled in the CLI (opcache.enable_cli=' . var_export(ini_get('opcache.enable_cli'), true) . ')');
    }
    $jitOn = (bool)($status['jit']['on'] ?? false);
    if (($want === 'on') !== $jitOn) {
        return micro_fail("JIT requested $want but it is " . ($jitOn ? 'on' : 'off')
            . ' (opcache.jit=' . ini_get('opcache.jit') . ', opcache.jit_buffer_size=' . ini_get('opcache.jit_buffer_size') . ')');
    }
    // OPcache here is the in-process shared memory (no opcache.file_cache): a script is cached once this process has
    // compiled it, and only cached scripts are JIT-compiled. Both files that matter must be in it.
    $bench = $a['bench'];
    $cases = require $bench;
    foreach ([__FILE__, realpath($bench)] as $file) {
        if (!opcache_is_script_cached($file)) {
            return micro_fail("OPcache did not cache $file: its code would not be JIT-compiled");
        }
    }

    $index = (int)($a['case-index'] ?? -1);
    $names = array_keys($cases);
    $name = $index < 0 ? EMPTY_LOOP : (string)$names[$index];
    $case = $index < 0 ? ['run' => static fn() => null] : $cases[$names[$index]];

    $out = ['case' => $name, 'status' => 'ok'];
    try {
        foreach (['run', 'check'] as $required) {
            if ($index >= 0 && !($case[$required] ?? null) instanceof Closure) {
                throw new LogicException("the case has no '$required' closure");
            }
        }
        $ctx = isset($case['setup']) ? ($case['setup'])() : null;
        if (isset($case['check'])) {
            $verdict = ($case['check'])(($case['run'])($ctx), $ctx);
            if ($verdict !== true) {
                $out['status'] = 'check_failed';
                $out['message'] = is_string($verdict) ? $verdict : 'check returned ' . var_export($verdict, true);
            }
        }
        if ($out['status'] === 'ok') {
            $iterations = micro_calibrate($case['run'], $ctx, (int)$a['warmup-ms'] * 1_000_000, (int)$a['target-ms'] * 1_000_000);
            $repeats = [];
            for ($r = 0; $r < (int)$a['repeats']; $r++) {
                gc_collect_cycles();
                $repeats[] = micro_time_loop($case['run'], $ctx, $iterations) / $iterations;
            }
            sort($repeats);
            $out += [
                'median_ns' => round(micro_median($repeats), 2),
                'min_ns' => round($repeats[0], 2),
                'max_ns' => round($repeats[count($repeats) - 1], 2),
                'iterations' => $iterations,
                'repeats_ns' => array_map(static fn($v) => round($v, 2), $repeats),
            ];
        }
    } catch (Throwable $e) {
        $out['status'] = 'error';
        $out['message'] = get_class($e) . ': ' . $e->getMessage();
    }

    $ini = [];
    foreach (INI_REPORTED as $key) {
        $ini[$key] = ini_get($key);
    }
    $status = opcache_get_status(false);
    $out['env'] = [
        'php_version' => PHP_VERSION,
        'ini' => $ini,
        'jit' => $status['jit'],
        'opcache_cache' => 'shared memory of this process (no opcache.file_cache); micro.php and the bench file are cached',
    ];
    echo json_encode($out, JSON_UNESCAPED_SLASHES), "\n";
    return 0;
}

// ---------------------------------------------------------------------------------------------------------------
// Orchestrator

function micro_orchestrator(array $argv): int
{
    $a = micro_args($argv);
    foreach (['bench', 'image', 'jit', 'out'] as $required) {
        if (($a[$required] ?? '') === '') {
            return micro_fail("missing --$required (this file is started by lab/micro.sh)", 1);
        }
    }
    $quick = isset($a['quick']);
    $timing = [
        'warmup_ms' => $quick ? 100 : 1000,
        'target_ms' => $quick ? 10 : 100,
        'repeats' => 10,
        'quick' => $quick,
    ];
    $cases = require $a['bench'];
    if (!is_array($cases)) {
        return micro_fail("{$a['bench']} must return an array of cases", 1);
    }

    $workerBase = [PHP_BINARY];
    foreach (micro_ini_flags($a['jit'], $a['jit-buffer-size'] ?? '64M') as $flag) {
        array_push($workerBase, '-d', $flag);
    }
    array_push($workerBase, __FILE__, '--worker', $a['bench'], '--jit', $a['jit'],
        '--warmup-ms', (string)$timing['warmup_ms'], '--target-ms', (string)$timing['target_ms'],
        '--repeats', (string)$timing['repeats']);

    if (isset($a['header'])) {
        micro_row('image', 'php', 'jit', 'case', 'median ns/op', 'spread (min .. max)', 'iterations');
    }

    $results = [];
    $env = null;
    $skipped = 0;
    foreach ([-1, ...array_keys(array_values($cases))] as $index) {
        $process = proc_open([...$workerBase, '--case-index', (string)$index], [1 => ['pipe', 'w'], 2 => STDERR], $pipes);
        $stdout = stream_get_contents($pipes[1]);
        $code = proc_close($process);
        if ($code !== 0) {
            return $code; // the worker already said why on stderr (a JIT state that is not the requested one, for example)
        }
        $result = json_decode($stdout, true);
        if (!is_array($result)) {
            return micro_fail("a worker printed something that is not JSON: $stdout");
        }
        $env ??= $result['env'];
        unset($result['env']);
        $results[] = $result;

        $php = $env['php_version'];
        if ($result['status'] === 'ok') {
            micro_row($a['image'], $php, $a['jit'], $result['case'], number_format($result['median_ns'], 1, '.', ''),
                number_format($result['min_ns'], 1, '.', '') . ' .. ' . number_format($result['max_ns'], 1, '.', ''), (string)$result['iterations']);
        } else {
            $skipped++;
            $why = $result['status'] === 'check_failed' ? 'check failed' : 'error';
            micro_row($a['image'], $php, $a['jit'], $result['case'], '-', "SKIPPED, $why: {$result['message']}", '-');
        }
    }
    if ($skipped > 0) {
        fwrite(STDERR, "micro: $skipped case(s) skipped on {$a['image']} (JIT {$a['jit']}), see the rows above\n");
    }

    $run = [
        'image' => $a['image'],
        'image_id' => $a['image-id'] ?? null,
        'php_version' => $env['php_version'],
        'jit' => $a['jit'],
        'jit_state' => $env['jit'],
        'ini' => $env['ini'],
        'opcache_cache' => $env['opcache_cache'],
        'timing' => $timing,
        'cases' => $results,
    ];
    file_put_contents($a['out'], json_encode($run, JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES) . "\n");
    return 0;
}

function micro_row(string ...$cols): void
{
    echo sprintf('%-7s %-8s %-4s %-34s %13s  %-26s %11s', ...$cols), "\n";
}

// Why last: the constants above must be defined before the first function runs.
exit(in_array('--worker', $argv, true) ? micro_worker($argv) : micro_orchestrator($argv));
