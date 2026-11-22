<?php
// Where Excimer's samples land. Excimer takes a sample at the next VM interrupt check, and an internal function is never a frame of its
// own: this script measures what that means, so that the rules of lab/profile/steps.rules rest on a measurement and not on a reading of
// the docs.
//
//   php -d extension=excimer [-d opcache.jit=tracing|disable ...] lab/profile/calibrate.php hash [--seconds 8] [--tolerance 5]
//   php -d extension=excimer -d extension=sockets -d extension=event lab/profile/calibrate.php loop [--seconds 4]
//
// hash: one PHP function (calib_hash_step) whose time is all in an internal function, hash('sha256'), and one (calib_loop_step) that
//   is plain PHP. Without the profiler, hrtime() times each over many rounds: that gives the share of the CPU the hash takes, whatever
//   the JIT does. Then the same rounds run under the profiler (CPU time, 1 ms) and the samples are counted by innermost frame. Exit 1
//   when the share of calib_hash_step is further than --tolerance points from the measured share (the time of the internal function is
//   then the calling function's), or when a `hash` frame exists.
// loop: the event loop's own time. A persistent timer of 0 s makes libevent spin (epoll_wait with no wait, the timer heap, the callback
//   call) around a callback with no code of its own, and a socket pair makes libevent wake a callback that does one fread and one fwrite
//   (the kernel's socket path). The samples are counted by innermost frame, and compared with the CPU the process really used
//   (getrusage: user and system), which says how much of the kernel's time the profiler sees. Exit 1 when the samples are further than
//   10 % from the CPU the process used, or when more than 10 % of them land outside the callbacks (on the function that called dispatch()).

if (!extension_loaded('excimer')) {
    fwrite(STDERR, "calibrate: start with -d extension=excimer\n");
    exit(1);
}

const CALIB_HASH_CALLS = 3000;

function calib_hash_step(): void
{
    for ($i = 0; $i < CALIB_HASH_CALLS; $i++) {
        hash('sha256', 'twelve dollars');
    }
}

function calib_loop_step(int $iterations): int
{
    $x = 0;
    for ($i = 0; $i < $iterations; $i++) {
        $x = ($x * 31 + $i) % 1000003;
    }
    return $x;
}

function calib_round(int $iterations): void
{
    calib_hash_step();
    calib_loop_step($iterations);
}

/** The collapsed stacks of a log, as [innermost frame => samples]. */
function calib_leaves(string $collapsed): array
{
    $leaves = [];
    foreach (explode("\n", $collapsed) as $line) {
        $space = strrpos($line, ' ');
        if ($space === false) {
            continue;
        }
        $frames = explode(';', substr($line, 0, $space));
        $leaf = $frames[count($frames) - 1];
        $leaves[$leaf] = ($leaves[$leaf] ?? 0) + (int) substr($line, $space + 1);
    }
    return $leaves;
}

/** All the frames of every stack, as [frame => samples in which it appears]. */
function calib_inclusive(string $collapsed): array
{
    $frames = [];
    foreach (explode("\n", $collapsed) as $line) {
        $space = strrpos($line, ' ');
        if ($space === false) {
            continue;
        }
        foreach (array_unique(explode(';', substr($line, 0, $space))) as $frame) {
            $frames[$frame] = ($frames[$frame] ?? 0) + (int) substr($line, $space + 1);
        }
    }
    return $frames;
}

function calib_option(array $argv, string $name, float $default): float
{
    $i = array_search($name, $argv, true);
    return $i === false ? $default : (float) ($argv[$i + 1] ?? $default);
}

function calib_jit(): string
{
    $status = function_exists('opcache_get_status') ? opcache_get_status(false) : false;
    return ($status['jit']['on'] ?? false) ? 'on' : 'off';
}

function calib_profiler(float $period): ExcimerProfiler
{
    $profiler = new ExcimerProfiler();
    $profiler->setEventType(EXCIMER_CPU);
    $profiler->setPeriod($period);
    return $profiler;
}

function calib_hash_mode(array $argv): int
{
    $seconds = calib_option($argv, '--seconds', 8);
    $tolerance = calib_option($argv, '--tolerance', 5);
    // Warm up (the JIT compiles the loops), then time each step over 400 rounds, no profiler. The loop step is sized so that it takes about
    // 2.3 times the hash step: the expected share of the hash is then near 30 %, a number the samples cannot reach by landing evenly.
    for ($i = 0; $i < 50; $i++) {
        calib_hash_step();
        calib_loop_step(200000);
    }
    $t = hrtime(true);
    for ($i = 0; $i < 100; $i++) {
        calib_hash_step();
    }
    $hashNs = (hrtime(true) - $t) / 100;
    $t = hrtime(true);
    for ($i = 0; $i < 20; $i++) {
        calib_loop_step(200000);
    }
    $probeNs = (hrtime(true) - $t) / 20;
    $iterations = max(1000, (int) (200000 * 2.3 * $hashNs / $probeNs));
    for ($i = 0; $i < 50; $i++) {
        calib_loop_step($iterations);
    }
    $hashTotal = 0;
    $loopTotal = 0;
    for ($i = 0; $i < 400; $i++) {
        $t0 = hrtime(true);
        calib_hash_step();
        $t1 = hrtime(true);
        calib_loop_step($iterations);
        $t2 = hrtime(true);
        $hashTotal += $t1 - $t0;
        $loopTotal += $t2 - $t1;
    }
    $expected = $hashTotal / ($hashTotal + $loopTotal) * 100;

    $profiler = calib_profiler(0.001);
    $profiler->start();
    $end = hrtime(true) + (int) ($seconds * 1e9);
    while (hrtime(true) < $end) {
        calib_round($iterations);
    }
    $profiler->stop();
    $collapsed = $profiler->getLog()->formatCollapsed();
    $leaves = calib_leaves($collapsed);
    $inclusive = calib_inclusive($collapsed);
    $samples = array_sum($leaves);
    if ($samples === 0) {
        fwrite(STDERR, "calibrate: no sample was taken\n");
        return 1;
    }
    $share = static fn(string $frame): float => ($leaves[$frame] ?? 0) / $samples * 100;
    $named = ['calib_hash_step', 'calib_loop_step', 'calib_round', 'hash'];
    $other = 100 - array_sum(array_map($share, $named));
    printf("jit: %s\n", calib_jit());
    printf("without the profiler (hrtime, 400 rounds): hash step %.1f us, loop step %.1f us per round: the hash is %.1f%% of the CPU\n",
        $hashTotal / 400 / 1000, $loopTotal / 400 / 1000, $expected);
    printf("profiled (CPU time, 1 ms, %d s): %d samples, by innermost frame\n", (int) $seconds, $samples);
    printf("  calib_hash_step %.1f%%   calib_loop_step %.1f%%   calib_round %.1f%%   hash (the internal function) %.1f%%   other %.1f%%\n",
        $share('calib_hash_step'), $share('calib_loop_step'), $share('calib_round'), $share('hash'), $other);
    printf("  frames named hash in the profile: %d\n", $inclusive['hash'] ?? 0);
    $off = abs($share('calib_hash_step') - $expected);
    printf("calib_hash_step is %.1f points from the measured share of the hash (tolerance %.1f): %s\n", $off, $tolerance, $off <= $tolerance ? 'ok' : 'FAIL');
    printf("conclusion: the internal function's samples land on %s\n", ($inclusive['hash'] ?? 0) === 0 ? 'the PHP function that called it (no frame of its own)' : 'a frame of its own');
    return $off <= $tolerance && ($inclusive['hash'] ?? 0) === 0 ? 0 : 1;
}

function calib_tick(): void
{
}

function calib_cpu_us(): array
{
    $u = getrusage();
    return [$u['ru_utime.tv_sec'] * 1000000 + $u['ru_utime.tv_usec'], $u['ru_stime.tv_sec'] * 1000000 + $u['ru_stime.tv_usec']];
}

/** Runs $setup($base) to arm the events, dispatches until $seconds are over, and prints where the samples landed and the CPU the process used. */
function calib_loop_case(string $title, float $seconds, callable $setup): int
{
    $base = new EventBase();
    $keep = $setup($base);
    $stop = new Event($base, -1, Event::TIMEOUT, static function () use ($base): void {
        $base->stop();
    });
    $stop->add($seconds);
    $profiler = calib_profiler(0.001);
    [$u0, $s0] = calib_cpu_us();
    $profiler->start();
    calib_dispatch($base);
    $profiler->stop();
    [$u1, $s1] = calib_cpu_us();
    $leaves = calib_leaves($profiler->getLog()->formatCollapsed());
    $samples = array_sum($leaves);
    if ($samples === 0) {
        fwrite(STDERR, "calibrate: no sample was taken ($title)\n");
        return 1;
    }
    $user = $u1 - $u0;
    $system = $s1 - $s0;
    printf("%s: %d samples (%.1f ms of CPU at 1 ms each) against %.1f ms of CPU used by the process (user %.1f, system %.1f: %.0f%% in the kernel)\n",
        $title, $samples, $samples * 1.0, ($user + $system) / 1000, $user / 1000, $system / 1000, $system / max(1, $user + $system) * 100);
    arsort($leaves);
    foreach ($leaves as $frame => $n) {
        printf("  %5.1f%%  %s\n", $n / $samples * 100, $frame);
    }
    unset($keep);
    $coverage = $samples / (($user + $system) / 1000);
    $inCallbacks = 1 - ($leaves['calib_dispatch'] ?? 0) / $samples;
    $ok = abs($coverage - 1) <= 0.1 && $inCallbacks >= 0.9;
    printf("  samples over CPU used: %.3f, share of the samples inside the callbacks (not on the function that called dispatch): %.1f%%: %s\n",
        $coverage, $inCallbacks * 100, $ok ? 'ok' : 'FAIL');
    return $ok ? 0 : 1;
}

function calib_dispatch(EventBase $base): void
{
    $base->dispatch();
}

function calib_loop_mode(array $argv): int
{
    if (!extension_loaded('event') || !extension_loaded('sockets')) {
        fwrite(STDERR, "calibrate: loop needs -d extension=sockets -d extension=event\n");
        return 1;
    }
    $seconds = calib_option($argv, '--seconds', 4);
    printf("jit: %s\n", calib_jit());
    $rc = calib_loop_case('spinning timer (libevent and epoll_wait(0), an empty callback)', $seconds, static function (EventBase $base) {
        $timer = new Event($base, -1, Event::TIMEOUT, static function () use (&$timer): void {
            calib_tick();
            $timer->add(0);
        });
        $timer->add(0);
        return $timer;
    });
    $rc |= calib_loop_case('socket pair ping-pong (libevent, epoll_wait, one fread and one fwrite per callback)', $seconds, static function (EventBase $base) {
        [$a, $b] = stream_socket_pair(STREAM_PF_UNIX, STREAM_SOCK_STREAM, STREAM_IPPROTO_IP);
        stream_set_blocking($a, false);
        stream_set_blocking($b, false);
        $events = [];
        $echo = static function ($fd, int $what, $peer): void {
            calib_echo($fd, $peer);
        };
        $events[] = new Event($base, $a, Event::READ | Event::PERSIST, $echo, $b);
        $events[] = new Event($base, $b, Event::READ | Event::PERSIST, $echo, $a);
        foreach ($events as $event) {
            $event->add();
        }
        fwrite($a, 'x');
        return $events;
    });
    return $rc;
}

function calib_echo($from, $to): void
{
    $data = fread($from, 8192);
    if ($data !== false && $data !== '') {
        fwrite($to, $data);
    }
}

$mode = $argv[1] ?? '';
exit(match ($mode) {
    'hash' => calib_hash_mode($argv),
    'loop' => calib_loop_mode($argv),
    default => (function (): int {
        fwrite(STDERR, "usage: php calibrate.php hash|loop [--seconds n] [--tolerance points]\n");
        return 1;
    })(),
});
