<?php
// The profiler of a DIY server (APP_PROFILE=<path> on lab/app/server.php, with `--ext excimer`): an ExcimerProfiler on CPU time, started
// before the first request, whose samples are written to <path> as collapsed stacks ("frame;frame;frame <count>", one line per distinct
// stack, the format lab/profile/fold.php reads).
//
// The servers have no signal handling and are removed with `docker rm -f`, so nothing runs at exit: a timer of the loop writes the file
// every FLUSH_S seconds (the whole count so far, to a temporary file and then renamed, so a reader never sees half a file) and the harness
// reads it from the container once the load is over. The profiler is stopped while the timer writes, so the profile never holds its own
// flush. Off by default; nothing of this file runs without APP_PROFILE.

final class DiyProfile
{
    /** Seconds between two writes of the file. */
    public const FLUSH_S = 2.0;

    private ExcimerProfiler $profiler;
    private ?Event $timer = null;
    /** @var array<string, int> the samples of every flush so far, by collapsed stack */
    private array $counts = [];

    /** @param float $period seconds of CPU time between two samples */
    public function __construct(private readonly string $path, float $period)
    {
        if (!extension_loaded('excimer')) {
            fwrite(STDERR, "diy-profile: APP_PROFILE needs ext-excimer (start with --ext excimer)\n");
            exit(1);
        }
        if (@file_put_contents($path, '') === false) {
            fwrite(STDERR, "diy-profile: cannot write $path\n");
            exit(1);
        }
        $this->profiler = new ExcimerProfiler();
        $this->profiler->setEventType(EXCIMER_CPU);
        $this->profiler->setPeriod($period);
    }

    /** Starts sampling, and writes the file every FLUSH_S seconds from now on (the timer lives on the loop's own base). */
    public function start(EventBase $base): void
    {
        $this->profiler->start();
        $this->timer = new Event($base, -1, Event::TIMEOUT, function (): void {
            $this->write();
            $this->timer->add(self::FLUSH_S);
        });
        $this->timer->add(self::FLUSH_S);
    }

    /** Adds the samples taken since the last call to the total and rewrites the file. */
    public function write(): void
    {
        $this->profiler->stop();
        $this->merge((string) $this->profiler->flush()->formatCollapsed());
        $this->profiler->start();
        $text = '';
        foreach ($this->counts as $stack => $count) {
            $text .= "$stack $count\n";
        }
        file_put_contents($this->path . '.tmp', $text);
        rename($this->path . '.tmp', $this->path);
    }

    /** Adds the lines of a formatCollapsed() text to the counts. */
    private function merge(string $collapsed): void
    {
        foreach (explode("\n", $collapsed) as $line) {
            $space = strrpos($line, ' ');
            if ($space === false) {
                continue;
            }
            $stack = substr($line, 0, $space);
            $this->counts[$stack] = ($this->counts[$stack] ?? 0) + (int) substr($line, $space + 1);
        }
    }
}
