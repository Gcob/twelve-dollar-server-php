<?php
// The aggregator's library: what lab/realistic.sh does with k6's CSV stream, without a clock, a socket or a container (so that
// lab/check/aggregate-test.php can drive it). lab/macro/aggregate.php is the process around it.
//
// k6 writes one row per metric sample: about 13 per request (http_req_duration, http_req_blocked, http_reqs, checks ...). The
// reader keeps only two kinds: `http_req_duration` (one per request: its latency in ms, its second, its name tag, whether the status
// was expected) and `vus` (k6's gauge of running VUs, once a second). Nothing else is parsed. The request count is the number of
// duration rows (k6's `http_reqs` has the same count).
//
// Per second and per endpoint it keeps a latency histogram with log buckets (bucket b holds [g^b, g^(b+1)) ms, g = 1.015): a
// latency is read back within 0.75 %, so a percentile merged from the histograms of many seconds is within 1 % of the exact one.

const AGG_GAMMA = 1.015;
const AGG_MIN_MS = 0.001;

function agg_bucket(float $ms): int
{
    return (int) floor(log(max($ms, AGG_MIN_MS)) / log(AGG_GAMMA));
}

/** The latency a bucket stands for: the geometric middle of its bounds. */
function agg_bucket_value(int $bucket): float
{
    return AGG_GAMMA ** ($bucket + 0.5);
}

/** @param array<int, int> $hist */
function agg_hist_add(array &$hist, float $ms): void
{
    $b = agg_bucket($ms);
    $hist[$b] = ($hist[$b] ?? 0) + 1;
}

/**
 * @param array<int, int> $into
 * @param array<int, int> $from
 */
function agg_hist_merge(array &$into, array $from): void
{
    foreach ($from as $b => $n) {
        $into[$b] = ($into[$b] ?? 0) + $n;
    }
}

/**
 * The latency (ms) under which a share $q of the requests fall: the bucket that holds the ceil(q * n)-th request.
 *
 * @param array<int, int> $hist
 */
function agg_quantile(array $hist, float $q): ?float
{
    $n = array_sum($hist);
    if ($n === 0) {
        return null;
    }
    $rank = max(1, (int) ceil($q * $n));
    ksort($hist);
    $seen = 0;
    foreach ($hist as $b => $count) {
        $seen += $count;
        if ($seen >= $rank) {
            return agg_bucket_value($b);
        }
    }
    return null;
}

final class Aggregate
{
    /** @var array<int, array<string, array{n: int, err: int, max: float, h: array<int, int>}>> second => endpoint => counts, slowest latency, histogram */
    public array $bins = [];
    /** @var array<string, int> k6's error_code of the failed requests => how many */
    public array $errorCodes = [];
    /** @var array<int, int> second => k6's `vus` gauge */
    public array $vus = [];
    /** @var array<int, array{0: int, 1: float}> second boundary => [the server's usage_usec, the time it was read] */
    public array $cpu = [];
    public int $rows = 0;
    public int $requests = 0;
    public int $unparsed = 0;
    public ?int $newestTs = null;
    private string $carry = '';

    /**
     * @param bool $normalizeNames name an endpoint by the path of its URL with the numbers as `:id` (`/posts/:id`): a script that does
     *                             not name its requests (lab/macro.sh's) has the URL for name, a different one for every post
     */
    public function __construct(private readonly bool $normalizeNames = false)
    {
    }

    /**
     * Reads what came from the stream: any number of complete rows, and maybe the start of the next one (kept for the next call).
     * Returns true once the end marker line (`#END`) has been read; what follows it is ignored.
     */
    public function feed(string $data): bool
    {
        $data = $this->carry . $data;
        $end = false;
        $mark = strpos($data, "#END\n");
        while ($mark !== false && $mark > 0 && $data[$mark - 1] !== "\n") {
            $mark = strpos($data, "#END\n", $mark + 1);
        }
        if ($mark !== false) {
            $data = substr($data, 0, $mark);
            $end = true;
        }
        $cut = strrpos($data, "\n");
        if ($cut === false) {
            $this->carry = $end ? '' : $data;
            return $end;
        }
        $this->carry = $end ? '' : substr($data, $cut + 1);
        $chunk = substr($data, 0, $cut + 1);
        $this->ingest($chunk);
        return $end;
    }

    private function ingest(string $chunk): void
    {
        $rows = substr_count($chunk, "\n");
        $this->rows += $rows - substr_count($chunk, "metric_name,timestamp,");

        // `http_req_duration,<ts>,<ms>,<check>,<error>,<error_code>,<expected_response>,<group>,<method>,<name>,...`
        $matched = preg_match_all(
            '/^http_req_duration,(\d+),([^,]+),[^,]*,[^,]*,([^,]*),(true|false),[^,]*,[^,]*,([^,]+),/m',
            $chunk,
            $m,
            PREG_SET_ORDER
        );
        $seen = substr_count($chunk, "\nhttp_req_duration,") + (str_starts_with($chunk, 'http_req_duration,') ? 1 : 0);
        $this->unparsed += $seen - (int) $matched;
        foreach ($m as [, $ts, $ms, $errorCode, $expected, $name]) {
            $sec = (int) $ts;
            if ($this->normalizeNames) {
                $name = preg_replace(['~^https?://[^/]+~', '~\?.*$~', '~/\d+(?=/|$)~'], ['', '', '/:id'], $name);
            }
            $bin = &$this->bins[$sec][$name];
            $bin ??= ['n' => 0, 'err' => 0, 'max' => 0.0, 'h' => []];
            $bin['n']++;
            if ($expected === 'false') {
                $bin['err']++;
            }
            if ($errorCode !== '') {
                $this->errorCodes[$errorCode] = ($this->errorCodes[$errorCode] ?? 0) + 1;
            }
            $latency = (float) $ms;
            if ($latency > $bin['max']) {
                $bin['max'] = $latency;
            }
            $b = agg_bucket($latency);
            $bin['h'][$b] = ($bin['h'][$b] ?? 0) + 1;
            unset($bin);
            if ($this->newestTs === null || $sec > $this->newestTs) {
                $this->newestTs = $sec;
            }
        }
        $this->requests += (int) $matched;

        if (preg_match_all('/^vus,(\d+),([\d.]+),/m', $chunk, $v, PREG_SET_ORDER)) {
            foreach ($v as [, $ts, $n]) {
                $this->vus[(int) $ts] = (int) $n;
                if ($this->newestTs === null || (int) $ts > $this->newestTs) {
                    $this->newestTs = (int) $ts;
                }
            }
        }
        // Any other row (k6 writes the samples of a flush in time order) is as new as the last line of the chunk.
        $last = strrpos($chunk, "\n", -2);
        $line = substr($chunk, $last === false ? 0 : $last + 1, 64);
        $parts = explode(',', $line, 3);
        if (isset($parts[1]) && ctype_digit($parts[1]) && ($this->newestTs === null || (int) $parts[1] > $this->newestTs)) {
            $this->newestTs = (int) $parts[1];
        }
    }
}

/**
 * The seconds of a step's plateau, [from, to) in whole seconds, from the `vus` gauge: the step is the run of seconds where the gauge
 * reads $target. The first second with that value is left out (the ramp may have ended inside it) and so is the last (the next
 * ramp may have started inside it). Null while the step is still running (no later second reads another value), or when the gauge
 * never read $target.
 *
 * @param array<int, int> $vus second => gauge
 * @return array{0: int, 1: int}|null
 */
function agg_window(array $vus, int $target): ?array
{
    ksort($vus);
    $first = null;
    $last = null;
    foreach ($vus as $sec => $n) {
        if ($n === $target) {
            $first ??= $sec;
            $last = $sec;
        } elseif ($first !== null) {
            return [$first + 1, $last];
        }
    }
    return null;
}

/**
 * The numbers of the seconds [$from, $to) and the verdict: the requests and errors, the rate they make, the users that rate stands for,
 * the server's CPU per request, the percentiles per endpoint and overall, and why the step fails when it does.
 *
 * @param array{p95_ms: float, p99_ms: float, error_rate: float, achieved_ratio: float} $limits
 * @return array<string, mixed>
 */
function agg_summarize(Aggregate $a, int $from, int $to, float $offered, float $usersPerRps, array $limits): array
{
    $seconds = max(0, $to - $from);
    $overall = [];
    $perEndpoint = [];
    $counts = [];
    $errors = 0;
    for ($sec = $from; $sec < $to; $sec++) {
        foreach ($a->bins[$sec] ?? [] as $name => $bin) {
            $perEndpoint[$name] ??= [];
            agg_hist_merge($perEndpoint[$name], $bin['h']);
            agg_hist_merge($overall, $bin['h']);
            $counts[$name] = ($counts[$name] ?? 0) + $bin['n'];
            $errors += $bin['err'];
        }
    }
    $requests = array_sum($counts);
    $achieved = $seconds > 0 ? $requests / $seconds : 0.0;

    $cpu = null;
    if (isset($a->cpu[$from], $a->cpu[$to]) && $requests > 0 && $a->cpu[$to][1] > $a->cpu[$from][1]) {
        // The two readings are a few ms off the second boundaries: scale to the nominal window.
        $usec = ($a->cpu[$to][0] - $a->cpu[$from][0]) * ($seconds / ($a->cpu[$to][1] - $a->cpu[$from][1]));
        $cpu = $usec / $requests;
    }

    $stats = static fn(array $hist, int $n): array => [
        'count' => $n,
        'p50' => agg_round(agg_quantile($hist, 0.50)),
        'p95' => agg_round(agg_quantile($hist, 0.95)),
        'p99' => agg_round(agg_quantile($hist, 0.99)),
    ];
    $endpoints = [];
    ksort($perEndpoint);
    foreach ($perEndpoint as $name => $hist) {
        $endpoints[$name] = $stats($hist, $counts[$name]);
    }
    $latency = ['overall' => $stats($overall, $requests), 'endpoints' => $endpoints];

    $errorRate = $requests > 0 ? $errors / $requests : 0.0;
    $reasons = [];
    if ($requests === 0) {
        $reasons[] = 'no request on the plateau';
    } else {
        if ($achieved < $limits['achieved_ratio'] * $offered) {
            $reasons[] = sprintf('achieved below %s %% of offered', rtrim(rtrim(sprintf('%.1f', $limits['achieved_ratio'] * 100), '0'), '.'));
        }
        if ($latency['overall']['p95'] >= $limits['p95_ms']) {
            $reasons[] = sprintf('p95 above %d ms', $limits['p95_ms']);
        }
        if ($latency['overall']['p99'] >= $limits['p99_ms']) {
            $reasons[] = sprintf('p99 above %d ms', $limits['p99_ms']);
        }
        if ($errorRate >= $limits['error_rate']) {
            $reasons[] = sprintf('errors at or above %s %%', rtrim(rtrim(sprintf('%.1f', $limits['error_rate'] * 100), '0'), '.'));
        }
    }

    return [
        'window' => [$from, $to],
        'seconds' => $seconds,
        'offered_rps' => $offered,
        'requests' => $requests,
        'achieved_rps' => $achieved,
        'users' => $usersPerRps * $achieved,
        'cpu_usec_per_request' => $cpu,
        'latency_ms' => $latency,
        'errors' => $errors,
        'error_rate' => $errorRate,
        'pass' => $reasons === [],
        'reasons' => $reasons,
    ];
}

function agg_round(?float $ms): ?float
{
    return $ms === null ? null : round($ms, 3);
}

/**
 * The whole run, ramps included, per endpoint: what k6's own summary can be compared with.
 *
 * @return array<string, array{count: int, p50: ?float, p95: ?float, p99: ?float}>
 */
function agg_run_total(Aggregate $a): array
{
    $hists = [];
    $counts = [];
    foreach ($a->bins as $perName) {
        foreach ($perName as $name => $bin) {
            $hists[$name] ??= [];
            agg_hist_merge($hists[$name], $bin['h']);
            $counts[$name] = ($counts[$name] ?? 0) + $bin['n'];
        }
    }
    ksort($hists);
    $out = [];
    foreach ($hists as $name => $hist) {
        $out[$name] = [
            'count' => $counts[$name],
            'p50' => agg_round(agg_quantile($hist, 0.50)),
            'p95' => agg_round(agg_quantile($hist, 0.95)),
            'p99' => agg_round(agg_quantile($hist, 0.99)),
        ];
    }
    return $out;
}

/** How many of the failed requests failed on the connection: k6's codes 1200 to 1299 (dial, reset by the peer, broken pipe ...). */
function agg_connection_errors(array $errorCodes): int
{
    $n = 0;
    foreach ($errorCodes as $code => $count) {
        if ((int) $code >= 1200 && (int) $code <= 1299) {
            $n += $count;
        }
    }
    return $n;
}

/**
 * One entry per second that has a request: its requests, errors, percentiles overall, VUs and server CPU, and for each endpoint its
 * count, p50, p99 and slowest latency (exact). A second with no request has no entry.
 *
 * @return list<array<string, mixed>>
 */
function agg_per_second(Aggregate $a): array
{
    $secs = array_keys($a->bins);
    sort($secs);
    $out = [];
    foreach ($secs as $sec) {
        $hist = [];
        $n = 0;
        $err = 0;
        $endpoints = [];
        $names = array_keys($a->bins[$sec]);
        sort($names);
        foreach ($names as $name) {
            $bin = $a->bins[$sec][$name];
            agg_hist_merge($hist, $bin['h']);
            $n += $bin['n'];
            $err += $bin['err'];
            $endpoints[$name] = [
                'count' => $bin['n'],
                'p50' => agg_round(agg_quantile($bin['h'], 0.50)),
                'p99' => agg_round(agg_quantile($bin['h'], 0.99)),
                'max' => round($bin['max'], 3),
            ];
        }
        $cpu = isset($a->cpu[$sec], $a->cpu[$sec + 1]) && $a->cpu[$sec + 1][1] > $a->cpu[$sec][1]
            ? ($a->cpu[$sec + 1][0] - $a->cpu[$sec][0]) / ($a->cpu[$sec + 1][1] - $a->cpu[$sec][1])
            : null;
        $out[] = [
            'second' => $sec,
            'vus' => $a->vus[$sec] ?? null,
            'requests' => $n,
            'errors' => $err,
            'endpoints' => $endpoints,
            'p95' => agg_round(agg_quantile($hist, 0.95)),
            'p99' => agg_round(agg_quantile($hist, 0.99)),
            'server_cpu_usec_per_s' => $cpu === null ? null : round($cpu),
        ];
    }
    return $out;
}
