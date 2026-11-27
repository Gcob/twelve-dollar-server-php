<?php
// A CPU-only micro for the score boxes: the same fixed loop on every box, nothing but PHP's core (no SQLite, no network, no extension), so a
// difference between two boxes' ns per iteration is the CPU (or the kernel), not the submission. Run by `server-setup.sh --check` with the box's
// own php; nothing reads the number but people.
//
//   php lab/score/cpu-micro.php [iterations]     one line: ns per iteration, the iterations, the seconds, the checksum, the CPU model
//
// The default count is about 7 s on a laptop's Docker VM and a little more on a c5 vCPU. The checksum is the same for the same count on any box:
// a different one means the loop changed, and the numbers are no longer comparable with earlier runs.
const DEFAULT_ITERATIONS = 70000000;

// One iteration: an integer step (a linear congruential generator), a write and a read in a 64-slot array, a short string built and measured, a
// division. The kinds of work a request does between its system calls, in miniature.
function micro(int $iterations): int
{
    $acc = 0;
    $x = 12345;
    $slots = array_fill(0, 64, 0);
    for ($i = 0; $i < $iterations; $i++) {
        $x = ($x * 1103515245 + 12345) & 0x7fffffff;
        $k = $x & 63;
        $slots[$k] = ($slots[$k] + $x) & 0xffff;
        $s = 'p' . $k . ':' . ($x >> 8);
        $acc = ($acc + strlen($s) + $slots[$k] + intdiv($x, 7)) & 0x7fffffff;
    }
    return $acc;
}

function cpu_model(): string
{
    $file = getenv('SCORE_CPUINFO') ?: '/proc/cpuinfo';
    foreach (@file($file) ?: [] as $line) {
        if (str_starts_with($line, 'model name')) {
            return trim(substr($line, strpos($line, ':') + 1));
        }
    }
    return 'unknown CPU';
}

$arg = $argv[1] ?? (string) DEFAULT_ITERATIONS;
if (count($argv) > 2 || (string) (int) $arg !== $arg || (int) $arg < 1) {
    fwrite(STDERR, "usage: cpu-micro.php [iterations]\n");
    exit(2);
}
$iterations = (int) $arg;

$began = hrtime(true);
$checksum = micro($iterations);
$ns = hrtime(true) - $began;

printf("%.1f ns per iteration (%d iterations, %.1f s, checksum %d), %s\n", $ns / $iterations, $iterations, $ns / 1e9, $checksum, cpu_model());
