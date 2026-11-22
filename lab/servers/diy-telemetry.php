<?php
// The telemetry of a DIY server (APP_TELEMETRY=1 on lab/app/server.php): one line a second on stdout, so that a later measurement can tell
// where a latency stall comes from (a long callback of the loop, a garbage collection, page faults on the mapped database, a WAL
// checkpoint). Off by default; when on it costs two hrtime() calls around each callback of the loop and one timer a second.
//
//   telemetry {"second":1764000000,"requests":{...},"longest_callback_ms":1.234,"gc_runs":0,"gc_collected":0,"wal_bytes":4096,
//              "minflt":12,"majflt":0}
//
// `second` is the second the line describes (the one that just ended); the counts are that second's, not running totals. `requests` and
// `wal_bytes` come from the closure the app gives (and it resets its own counters); the loop's own numbers are made here.

final class DiyTelemetry
{
    private int $longestNs = 0;
    private int $gcRuns;
    private int $gcCollected;
    /** @var array{int, int} */
    private array $faults;
    private ?Event $timer = null;
    private int $boundary = 0;
    /** The timer is set a little after the whole second, so that what the server did in the second that ended is in the counters. */
    private const MARGIN_S = 0.002;

    /** @param Closure(): array<string, mixed> $fields what the app adds to every line; it resets its own counters when called */
    public function __construct(private readonly Closure $fields)
    {
        $gc = gc_status();
        $this->gcRuns = $gc['runs'];
        $this->gcCollected = $gc['collected'];
        $this->faults = self::faults();
    }

    /** The same callback, timed: the longest one of the second is what a stalled loop shows. */
    public function timed(Closure $callback): Closure
    {
        return function (mixed ...$args) use ($callback): void {
            $start = hrtime(true);
            $callback(...$args);
            $took = hrtime(true) - $start;
            if ($took > $this->longestNs) {
                $this->longestNs = $took;
            }
        };
    }

    /** Prints a line at the start of every second, from now on (the timer lives on the loop's own base). */
    public function start(EventBase $base): void
    {
        $this->boundary = (int) floor(microtime(true)) + 1;
        $this->timer = new Event($base, -1, Event::TIMEOUT, function (): void {
            echo $this->tick($this->boundary - 1) . "\n";
            $this->boundary = self::nextBoundary($this->boundary, microtime(true));
            $this->timer->add(max(0.001, $this->boundary + self::MARGIN_S - microtime(true)));
        });
        $this->timer->add(max(0.001, $this->boundary + self::MARGIN_S - microtime(true)));
    }

    /**
     * The whole second the timer is set for next, after it fired for $boundary at wall-clock time $now: the one after $boundary, or later
     * when the loop was stalled past it. Why not floor($now): the timer runs on the loop's clock, which can be a fraction of a millisecond
     * ahead of the wall clock, and a line that fired early would take the second of the line before it.
     */
    public static function nextBoundary(int $boundary, float $now): int
    {
        return max($boundary + 1, (int) floor($now - self::MARGIN_S) + 1);
    }

    /** The line for the second that just ended, and the counters that start over. */
    public function tick(int $second): string
    {
        $gc = gc_status();
        $faults = self::faults();
        $line = ['second' => $second] + ($this->fields)() + [
            'longest_callback_ms' => round($this->longestNs / 1e6, 3),
            'gc_runs' => $gc['runs'] - $this->gcRuns,
            'gc_collected' => $gc['collected'] - $this->gcCollected,
            'minflt' => $faults[0] - $this->faults[0],
            'majflt' => $faults[1] - $this->faults[1],
        ];
        $this->longestNs = 0;
        $this->gcRuns = $gc['runs'];
        $this->gcCollected = $gc['collected'];
        $this->faults = $faults;
        return 'telemetry ' . json_encode($line, JSON_UNESCAPED_SLASHES);
    }

    /** @return array{int, int} the minor and major page faults of this process so far */
    private static function faults(): array
    {
        $stat = (string) @file_get_contents('/proc/self/stat');
        $close = strrpos($stat, ')');
        $fields = $close === false ? [] : preg_split('/\s+/', trim(substr($stat, $close + 1)));
        return [(int) ($fields[7] ?? 0), (int) ($fields[9] ?? 0)];
    }
}
