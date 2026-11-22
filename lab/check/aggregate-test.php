<?php
// The aggregator's library (lab/macro/aggregate-lib.php): k6's CSV rows in, per second and per endpoint latency histograms, the
// plateau of a step found from k6's `vus` rows, the step's numbers and its verdict. The rows below are copied from a real k6 run.
// Run: bash lab/run.sh 8.5 php /lab/check/aggregate-test.php

require __DIR__ . '/../macro/aggregate-lib.php';

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

/** One k6 `http_req_duration` row, the way k6 1.8 writes it: the tags after the value are the request's. */
function duration_row(int $ts, float $ms, string $name, bool $expected = true, int $status = 200): string
{
    return sprintf(
        'http_req_duration,%d,%.6f,,,%s,%s,,%s,%s,HTTP/1.1,users,,%d,,,%s,,',
        $ts,
        $ms,
        $expected ? '' : '1404',
        $expected ? 'true' : 'false',
        explode(' ', $name)[0],
        $name,
        $status,
        $name
    );
}

function vus_row(int $ts, int $vus): string
{
    return sprintf('vus,%d,%.6f,,,,,,,,,,,,,,,,', $ts, $vus);
}

// --- the bucket: a latency comes back within 1 % --------------------------------------------------------------------------
foreach ([0.05, 0.5, 1.0, 3.7, 12.0, 99.9, 499.0, 1000.0, 25000.0] as $ms) {
    $back = agg_bucket_value(agg_bucket($ms));
    check("bucket of $ms ms is read back within 1 %", abs($back - $ms) / $ms <= 0.01, "got $back");
}
check('two latencies 0.5 % apart can share a bucket, two 3 % apart never do',
    agg_bucket(100.0) !== agg_bucket(103.0) && agg_bucket(100.0) <= agg_bucket(100.5) && agg_bucket(100.5) - agg_bucket(100.0) <= 1);

// --- percentiles of a known set: 1 ms, 2 ms ... 1000 ms, one each ----------------------------------------------------------
$hist = [];
for ($v = 1; $v <= 1000; $v++) {
    agg_hist_add($hist, (float) $v);
}
foreach ([[0.50, 500], [0.95, 950], [0.99, 990]] as [$q, $want]) {
    $got = agg_quantile($hist, $q);
    check("p" . ($q * 100) . " of 1..1000 ms is $want within 1 %", abs($got - $want) / $want <= 0.01, "got $got");
}
check('the quantile of nothing is null', agg_quantile([], 0.95) === null);

// --- rows in: counts, errors, the endpoints, rows that are not requests ---------------------------------------------------
$a = new Aggregate();
$text = implode("\n", [
    'metric_name,timestamp,metric_value,check,error,error_code,expected_response,group,method,name,proto,scenario,service,status,subproto,tls_version,url,extra_tags,metadata',
    duration_row(1000, 2.0, 'GET /feed'),
    'http_req_blocked,1000,0.267916,,,,true,,GET,GET /feed,HTTP/1.1,users,,200,,,GET /feed,,',
    duration_row(1000, 4.0, 'GET /feed'),
    duration_row(1001, 8.0, 'GET /posts/:id'),
    duration_row(1001, 30.0, 'POST /posts/:id/like', false, 500),
    'iteration_duration,1001,1.954667,,,,,,,,,users,,,,,,,',
    vus_row(1001, 50),
    '',
]);
$ended = $a->feed($text);
check('no end marker, no end', $ended === false);
check('rows counted: every line but the header', $a->rows === 7, "rows={$a->rows}");
check('requests counted from the duration rows only', $a->requests === 4, "requests={$a->requests}");
check('the feed has 2 requests in second 1000', ($a->bins[1000]['GET /feed']['n'] ?? 0) === 2);
check('the post has 1 request in second 1001', ($a->bins[1001]['GET /posts/:id']['n'] ?? 0) === 1);
check('a row with expected_response=false is an error', ($a->bins[1001]['POST /posts/:id/like']['err'] ?? 0) === 1
    && ($a->bins[1000]['GET /feed']['err'] ?? 0) === 0);
check('the vus row is kept by second', ($a->vus[1001] ?? null) === 50);
check('the newest sample time is the newest row', $a->newestTs === 1001, 'got ' . var_export($a->newestTs, true));

// A read can end in the middle of a line: the rest is carried to the next read.
$a = new Aggregate();
$row = duration_row(2000, 5.0, 'GET /feed');
$a->feed(substr($row, 0, 40));
check('half a line is not counted', $a->requests === 0);
$a->feed(substr($row, 40) . "\n" . duration_row(2000, 6.0, 'GET /feed') . "\n");
check('the two halves make one row, and the next line is read', $a->requests === 2 && $a->unparsed === 0, "requests={$a->requests}");

// The end marker stops the reading, and what is before it counts.
$a = new Aggregate();
$ended = $a->feed(duration_row(3000, 1.0, 'GET /feed') . "\n#END\n" . duration_row(3000, 1.0, 'GET /feed') . "\n");
check('the end marker is reported and what follows it is ignored', $ended === true && $a->requests === 1, "requests={$a->requests}");

// A duration row the reader cannot parse is counted, never dropped silently (an error text with a quoted comma).
$a = new Aggregate();
$a->feed('http_req_duration,4000,0.000000,,"Get ""http://x"": dial tcp, refused",1212,false,,GET,GET /feed,HTTP/1.1,users,,0,,,GET /feed,,' . "\n"
    . duration_row(4000, 1.0, 'GET /feed') . "\n");
check('an unparseable duration row is counted as unparsed', $a->unparsed === 1 && $a->requests === 1, "unparsed={$a->unparsed} requests={$a->requests}");

// --- the plateau of a step, from the vus rows ---------------------------------------------------------------------------
// vus at second 100..109: ramp to 30, plateau of 30 from 103 to 106, ramp to 40 at 107. The plateau window leaves out the first
// second with 30 (the ramp may have ended inside it) and the last one (the next ramp may have started in it): seconds 104 and 105.
$a = new Aggregate();
foreach ([100 => 0, 101 => 10, 102 => 20, 103 => 30, 104 => 30, 105 => 30, 106 => 30, 107 => 35, 108 => 40] as $sec => $v) {
    $a->feed(vus_row($sec, $v) . "\n");
}
check('the window of 30 VUs is [104, 106)', agg_window($a->vus, 30) === [104, 106], json_encode(agg_window($a->vus, 30)));
check('a step still running has no window', agg_window($a->vus, 40) === null);
check('a step never reached has no window', agg_window($a->vus, 99) === null);

// --- a step's numbers and verdict ---------------------------------------------------------------------------------------
$limits = ['p95_ms' => 500.0, 'p99_ms' => 1000.0, 'error_rate' => 0.01, 'achieved_ratio' => 0.97];

/** @return Aggregate 2 seconds (10 and 11) with $perSecond requests each: the feed at $feedMs, the post at $postMs. */
function two_seconds(int $perSecond, float $feedMs, float $postMs, int $errors = 0): Aggregate
{
    $a = new Aggregate();
    $lines = [];
    foreach ([10, 11] as $sec) {
        for ($i = 0; $i < $perSecond; $i++) {
            $isFeed = $i % 2 === 0;
            $bad = $errors > 0 && $sec === 10 && $i < $errors;
            $lines[] = duration_row($sec, $isFeed ? $feedMs : $postMs, $isFeed ? 'GET /feed' : 'GET /posts/:id', !$bad, $bad ? 500 : 200);
        }
    }
    $a->feed(implode("\n", $lines) . "\n");
    return $a;
}

$a = two_seconds(100, 3.0, 9.0);
$a->cpu = [10 => [5_000_000, 1000.0], 12 => [5_040_000, 1002.0]];
$s = agg_summarize($a, 10, 12, 190.0, 9.45, $limits);
check('achieved is the requests over the seconds', abs($s['achieved_rps'] - 100.0) < 1e-9, json_encode($s['achieved_rps']));
check('users are 9.45 times the achieved rate', abs($s['users'] - 945.0) < 1e-6, json_encode($s['users']));
check('CPU per request is the usage over the window over the requests', abs($s['cpu_usec_per_request'] - 200.0) < 1e-6, json_encode($s['cpu_usec_per_request']));
check('the overall p95 is the post (half the requests are 9 ms)', abs($s['latency_ms']['overall']['p95'] - 9.0) / 9.0 <= 0.01, json_encode($s['latency_ms']['overall']));
check('the feed is 3 ms, per endpoint', abs($s['latency_ms']['endpoints']['GET /feed']['p99'] - 3.0) / 3.0 <= 0.01);
check('100 req/s against 190 offered fails the 97 % rule, first', $s['pass'] === false && $s['reasons'][0] === 'achieved below 97 % of offered', json_encode($s['reasons']));

$s = agg_summarize($a, 10, 12, 100.0, 9.45, $limits);
check('100 req/s against 100 offered passes', $s['pass'] === true && $s['reasons'] === [], json_encode($s['reasons']));
$s = agg_summarize($a, 10, 12, 102.0, 9.45, $limits);
check('98 % of offered passes, 96.9 % would not', $s['pass'] === true);
$s = agg_summarize($a, 10, 12, 103.2, 9.45, $limits);
check('96.9 % of offered fails', $s['pass'] === false && $s['reasons'][0] === 'achieved below 97 % of offered');

$s = agg_summarize(two_seconds(100, 3.0, 700.0), 10, 12, 100.0, 9.45, $limits);
check('a p95 of 700 ms fails with its reason', $s['pass'] === false && in_array('p95 above 500 ms', $s['reasons'], true), json_encode($s['reasons']));
$s = agg_summarize(two_seconds(100, 600.0, 1500.0), 10, 12, 100.0, 9.45, $limits);
check('a p99 of 1.5 s fails with its reason', in_array('p99 above 1000 ms', $s['reasons'], true), json_encode($s['reasons']));
$s = agg_summarize(two_seconds(100, 3.0, 9.0, 4), 10, 12, 100.0, 9.45, $limits);
check('4 errors in 200 requests (2 %) fail with the error rate', $s['pass'] === false && in_array('errors at or above 1 %', $s['reasons'], true), json_encode($s['reasons']));
check('the error count and rate are in the step', $s['errors'] === 4 && abs($s['error_rate'] - 0.02) < 1e-9);
$s = agg_summarize(new Aggregate(), 10, 12, 100.0, 9.45, $limits);
check('a window with no request fails with a reason, not a division by zero', $s['pass'] === false && $s['reasons'] === ['no request on the plateau'], json_encode($s['reasons']));

// --- the whole run, per endpoint, and per second ---------------------------------------------------------------------------
$a = two_seconds(100, 3.0, 9.0);
$t = agg_run_total($a);
check('the run total counts every request per endpoint', $t['GET /feed']['count'] === 100 && $t['GET /posts/:id']['count'] === 100);
$seconds = agg_per_second($a);
check('the per second table has one entry per second with its requests', count($seconds) === 2 && $seconds[0]['second'] === 10 && $seconds[0]['requests'] === 100, json_encode($seconds));

echo $failures === 0 ? "all ok\n" : "$failures failed\n";
exit($failures === 0 ? 0 : 1);
