<?php
// Feeds a recorded k6 CSV to the aggregator's FIFO at a given row rate, to see whether the aggregator keeps up with k6 at the rate of
// a bench. The rows of the recording are repeated, each second's with that second's timestamp (so the aggregator's lag means
// something), and a `vus` row is added once a second. At the end it writes the `#END` line.
//
//   php lab/macro/replay.php <recording.csv> <fifo> <rows per second> <seconds>
//
// Prints one line: `fed rows=<n> requests=<n> seconds=<n> behind_max_s=<n>`. behind_max_s is how late the feeder itself was against its
// schedule (a feeder that blocks on a full FIFO is late): a replay whose feeder is late proved nothing about the aggregator.

[, $file, $fifoPath, $rate, $seconds] = $argv + [null, null, null, null, null];
if ($file === null || $seconds === null) {
    fwrite(STDERR, "usage: replay.php <recording.csv> <fifo> <rows per second> <seconds>\n");
    exit(2);
}
$rate = (int) $rate;
$seconds = (int) $seconds;

$rows = [];
$requestsPerBlock = 0;
foreach (file($file, FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES) as $line) {
    if (str_starts_with($line, 'metric_name,') || str_starts_with($line, 'vus')) {
        continue;
    }
    [$metric, , $rest] = explode(',', $line, 3);
    $rows[] = [$metric, $rest];
    if ($metric === 'http_req_duration') {
        $requestsPerBlock++;
    }
}
$blockRows = count($rows);
if ($blockRows === 0 || $requestsPerBlock === 0) {
    fwrite(STDERR, "replay: no http_req_duration row in $file\n");
    exit(1);
}

$fifo = fopen($fifoPath, 'r+');
$start = microtime(true);
$written = 0;
$requests = 0;
$block = '';
$blockSecond = null;
$behindMax = 0.0;
$vusSecond = null;
while (true) {
    $now = microtime(true);
    $elapsed = $now - $start;
    if ($elapsed >= $seconds) {
        break;
    }
    $should = (int) ($elapsed * $rate);
    $second = (int) floor($now);
    if ($second !== $blockSecond) {
        $block = '';
        foreach ($rows as [$metric, $rest]) {
            $block .= $metric . ',' . $second . ',' . $rest . "\n";
        }
        $blockSecond = $second;
    }
    if ($vusSecond !== $second) {
        fwrite($fifo, "vus,$second,50.000000,,,,,,,,,,,,,,,,\n");
        $vusSecond = $second;
    }
    $repeats = intdiv($should - $written, $blockRows);
    if ($repeats < 1) {
        usleep(2000);
        continue;
    }
    // At most 100 blocks at a time, so the second's timestamp stays the second it is written in.
    $repeats = min($repeats, 100);
    fwrite($fifo, str_repeat($block, $repeats));
    $written += $repeats * $blockRows;
    $requests += $repeats * $requestsPerBlock;
    $behindMax = max($behindMax, ($should - $written) / $rate);
}
fwrite($fifo, "#END\n");
printf("fed rows=%d requests=%d seconds=%d behind_max_s=%.3f\n", $written, $requests, $seconds, $behindMax);
