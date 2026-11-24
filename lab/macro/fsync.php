<?php
// The disk probe of lab/macro/probe.sh: appends <count> blocks of 4 KiB to <file>, each followed by fdatasync (what a database's write-ahead log
// asks of the disk), and prints the median of the times in milliseconds as `host fsync_ms <n>`. The file is removed. It runs before a run's
// warm-up, once, so it does not load the plateau.
//
//   php fsync.php <file> [count]
declare(strict_types=1);

$file = $argv[1] ?? null;
$count = (int) ($argv[2] ?? 20);
if ($file === null || $count < 1) {
    fwrite(STDERR, "usage: php fsync.php <file> [count]\n");
    exit(2);
}
$handle = fopen($file, 'wb');
if ($handle === false) {
    fwrite(STDERR, "fsync: cannot open $file\n");
    exit(1);
}
$block = random_bytes(4096);
$times = [];
$failed = false;
for ($i = 0; $i < $count && !$failed; $i++) {
    $start = hrtime(true);
    $failed = fwrite($handle, $block) !== 4096 || !fflush($handle) || !fdatasync($handle);
    $times[] = (hrtime(true) - $start) / 1e6;
}
fclose($handle);
unlink($file);
if ($failed) {
    fwrite(STDERR, "fsync: a write or its fdatasync failed on $file\n");
    exit(1);
}
sort($times);
$middle = intdiv($count, 2);
$median = $count % 2 === 1 ? $times[$middle] : ($times[$middle - 1] + $times[$middle]) / 2;
printf("host fsync_ms %.3f\n", $median);
