<?php
// Several processes on one port (server.php: two of them; needs ext-pcntl and ext-posix).
//
// The parent reads and checks the configuration, forks the children, and opens nothing: no database, no socket, no event loop. Each child
// opens its own connection to the database, its own listening socket on the same host and port (SO_REUSEPORT: the kernel splits the new
// connections between them by a hash of the client's address and port) and its own loop, and tells the parent it is listening. The parent
// then prints the boot lines and waits.
//
// The parent never restarts a child: when one ends, however it ends, the parent stops the others and exits 1, so that a crash is seen.
// SIGTERM or SIGINT to the parent stops the children and exits 0. A container is stopped by removing it, which ends every process of
// it, so nothing here runs on SIGKILL of the parent; a child's loop does not watch its parent.

/**
 * Forks $count children and supervises them until one ends or the parent is told to stop.
 *
 * Each child has a socket pair of its own to the parent: it writes one line when it listens and keeps its end open for its whole life, so
 * the parent's stream_select() wakes when a child reports and when one ends, with nothing to poll. A signal for the parent writes a byte
 * to one more pipe that the same select watches (pcntl_wait() would go on waiting after a handler ran, and a signal arriving between two
 * checks of a flag would be missed).
 *
 * @param int $count number of children
 * @param Closure(Closure(string): void): never $worker runs in a child: it boots, listens, calls the given function with one line of text
 *                                                      (what the parent prints about the child's loop, socket and database settings: three
 *                                                      values separated by tabs) and serves
 * @param Closure(list<int>, string, string, string): void $announce called in the parent once every child listens: the children's process
 *                                                                   ids, and the loop, socket and database lines of the first child to report
 * @return int the parent's exit code
 */
function app_workers_supervise(int $count, Closure $worker, Closure $announce): int
{
    $wake = stream_socket_pair(STREAM_PF_UNIX, STREAM_SOCK_STREAM, STREAM_IPPROTO_IP);
    if ($wake === false) {
        fwrite(STDERR, "server: cannot make the pipe the parent wakes on\n");
        return 1;
    }
    [$wakeRead, $wakeWrite] = $wake;
    stream_set_blocking($wakeWrite, false);
    $stopping = false;
    $stop = static function () use (&$stopping, $wakeWrite): void {
        $stopping = true;
        @fwrite($wakeWrite, 'x');
    };
    pcntl_async_signals(true);
    pcntl_signal(SIGTERM, $stop);
    pcntl_signal(SIGINT, $stop);

    /** @var array<int, resource> $reads the parent's end of each child's socket pair, by the child's process id */
    $reads = [];
    for ($i = 0; $i < $count; $i++) {
        $pair = stream_socket_pair(STREAM_PF_UNIX, STREAM_SOCK_STREAM, STREAM_IPPROTO_IP);
        $pid = $pair === false ? -1 : pcntl_fork();
        if ($pid === -1) {
            fwrite(STDERR, 'server: cannot fork worker ' . ($i + 1) . " of $count\n");
            app_workers_stop(array_fill_keys(array_keys($reads), true));
            return 1;
        }
        if ($pid === 0) {
            // Why: the handlers are the parent's; a child stops on the signal like any process.
            pcntl_signal(SIGTERM, SIG_DFL);
            pcntl_signal(SIGINT, SIG_DFL);
            foreach ([$wakeRead, $wakeWrite, $pair[0], ...$reads] as $inherited) {
                fclose($inherited);
            }
            $worker(static function (string $line) use ($pair): void {
                fwrite($pair[1], str_replace(["\n", "\r"], ' ', $line) . "\n");
            });
            exit(0);
        }
        // Why closed here: a child that inherited another child's end would keep it open after that child ended.
        fclose($pair[1]);
        $reads[$pid] = $pair[0];
    }

    $lines = [];
    $buffers = array_fill_keys(array_keys($reads), '');
    $announced = false;
    $deadline = microtime(true) + 60;
    while (true) {
        if ($stopping) {
            app_workers_stop(array_fill_keys(array_keys($reads), true));
            return 0;
        }
        $read = [$wakeRead, ...$reads];
        $write = $except = null;
        // Why a timeout only until every child listens: a child stuck in its boot must not hold the parent for ever.
        $ready = @stream_select($read, $write, $except, $announced ? null : max(1, (int) ceil($deadline - microtime(true))));
        pcntl_signal_dispatch();
        if ($ready === false) {
            continue;
        }
        if ($ready === 0 && !$announced) {
            fwrite(STDERR, 'server: only ' . count($lines) . " of $count workers started listening, stopping the others\n");
            app_workers_stop(array_fill_keys(array_keys($reads), true));
            return 1;
        }
        foreach ($read as $stream) {
            if ($stream === $wakeRead) {
                fread($wakeRead, 64);
                continue;
            }
            $pid = (int) array_search($stream, $reads, true);
            $chunk = fread($stream, 4096);
            if ($chunk !== '' && $chunk !== false) {
                $buffers[$pid] .= $chunk;
                if (!isset($lines[$pid]) && ($end = strpos($buffers[$pid], "\n")) !== false) {
                    $lines[$pid] = substr($buffers[$pid], 0, $end);
                }
                continue;
            }
            // The child's end of the pair is closed: it ended, however it ended.
            pcntl_waitpid($pid, $status);
            unset($reads[$pid]);
            $how = pcntl_wifsignaled($status) ? 'was killed by signal ' . pcntl_wtermsig($status) : 'exited with status ' . pcntl_wexitstatus($status);
            fwrite(STDERR, "server: worker $pid $how, stopping the others\n");
            app_workers_stop(array_fill_keys(array_keys($reads), true));
            return 1;
        }
        if (!$announced && count($lines) === $count) {
            $announced = true;
            [$loop, $socket, $sqlite] = explode("\t", reset($lines)) + ['', '', ''];
            $announce(array_keys($reads), $loop, $socket, $sqlite);
        }
    }
}

/**
 * Ends the children it is given: SIGTERM, then SIGKILL for the ones still there after 5 s, and waits for every one of them.
 *
 * @param array<int, true> $children by process id
 */
function app_workers_stop(array $children): void
{
    foreach (array_keys($children) as $pid) {
        posix_kill($pid, SIGTERM);
    }
    $deadline = microtime(true) + 5;
    while ($children !== []) {
        foreach (array_keys($children) as $pid) {
            if (pcntl_waitpid($pid, $status, WNOHANG) !== 0) {
                unset($children[$pid]);
            }
        }
        if ($children !== [] && microtime(true) > $deadline) {
            foreach (array_keys($children) as $pid) {
                posix_kill($pid, SIGKILL);
            }
            $deadline = INF;
        }
        if ($children !== []) {
            usleep(10000);
        }
    }
}
