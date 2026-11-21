# What the other PHP submissions already measured

Read from the challenge repo at `162699a`, cloned in `reference/twelve-dollar-server-challenge/` (ignored by git).
Their numbers are theirs: we re-measure what we reuse.

## The 71,000 ceiling, explained (LEADERBOARD.md, footnote ᶠ and around line 991)

- **Cause:** `LimitNOFILE=65535` is per process. A server that keeps every keep-alive connection open serves
  65,535 users. The rest wait in the listen queue until k6 times out after 60 s: about 21,900 timeouts, 0.93 % of
  requests, just under the 1 % rule. So 71,000 is "full fd table plus 1 % slack", at any CPU usage (31 % to 96 %).
- **How entries get above it:** they close idle keep-alive connections so the client reconnects (`Connection: close`
  or a reset near the limit), or they use io_uring fixed files (no fd per connection, up to ~524k slots). io_uring
  fixed files aren't reachable from PHP.
- **The trap:** closing a socket that's merely idle kills the next request if it's a POST. k6 retries a GET sent on a
  closed socket, not a POST. Two entries closed sockets idle for 1 s or 3 s and scored **0** (about 7 % EOF errors, all
  on POSTs). A safe close tells the client first: `Connection: close` in a response header.

## php-swoole-mattsplat (#24): 71,000, 66 % CPU, 94 µs/req, 1,025 MB

- Swoole 6.2.3 built from the source tarball (sha256 pinned), PHP 8.3.6 from apt, `pdo_sqlite`, no Composer.
- `SWOOLE_BASE`, `worker_num => 1`, `enable_coroutine => false`, no heartbeat: one process, so capped at 65,535 fds.
- **Memory:** Swoole keeps a 64 KiB receive buffer per connection from PHP's heap, so `memory_limit=-1` (840 MB RSS at
  20,000 connections locally).
- `http_parse_post`, `http_parse_cookie`, `http_parse_files`, `http_compression` off.
- JSON: `json_encode` of the fetched rows for feed and post, strings for like and health.
- Like in one statement: `INSERT INTO likes ... SELECT ?, ? WHERE EXISTS (post) ON CONFLICT DO NOTHING`, and the
  existence check only when nothing was inserted (200 versus 404).
- Trim: a regex with JavaScript's `trim()` whitespace (NBSP and Unicode spaces), length with `mb_strlen`, which counts
  like SQLite's `length()`.
- Pragmas: 64 MiB cache, 256 MiB mmap, `temp_store=MEMORY`.
- **A telling number:** closed loop with 64 connections, no think time: 54k req/s on 1 Apple Silicon core, about
  18 µs/req. The leaderboard measured 94 µs/req with 65k connections on the Xeon. The gap is the many open connections
  plus a slower core.

## php-swoole-tzimpel (#28): 71,000, 71 % CPU, 101 µs/req, 325 MB

Measured every optimization as CPU µs/req at a fixed 6,000 req/s with the real mix, variants interleaved because the
host drifted by ~10 %. That's exactly our method.

- Swoole 6.2.3 compiled in `build.sh`, **patched**: frees the 64 KiB receive buffer once a request is done. 10k
  connections went from 184 MB RSS and 700 MB PHP heap to 23 MB and 3 MB. Without it, the worker died at about 38k
  connections.
- `SWOOLE_BASE`, 1 worker, no coroutines, `gc_disable()`.
- **2 workers: 27 % more CPU per request** on one core (context switches, SQLite write-lock contention). Rejected.
- **Background checkpointer** (`Server::addProcess`, own connection, `wal_checkpoint(PASSIVE)` every second,
  `TRUNCATE` when the WAL is big), `wal_autocheckpoint=0` in the worker: **p99 4 to 5 ms instead of 43 ms**.
- **Group commit** with `Swoole\Event::defer` and `BEGIN IMMEDIATE`: 10 % less CPU per write on likes only, neutral
  on the real mix.
- **PDO beats the `SQLite3` extension:** `SQLite3Stmt::execute()` steps once, resets, and `fetchArray()` steps again.
  Every SELECT pays its first step twice, and `INSERT ... RETURNING` **inserts the post twice**. PDO: 4 to 8 %
  cheaper on reads, and correct.
- **JSON in PHP beats JSON in SQLite:** `json_object` and `group_concat` cost 11 to 13 % more CPU than fetching rows
  and concatenating strings, with `json_encode` only on the strings.
- OPcache tracing JIT: roughly neutral, most of the time is in C.
- Pragmas: 512 MiB mmap, 32 MiB cache, cursors closed right after use so no read transaction blocks the checkpointer.
- Locally: 50 to 60 µs/req at a fixed rate on Apple Silicon, 101 µs/req on the leaderboard. **Expect about 1.8x
  between our Mac container and the bench VM.**

## php-pype-dayne-valourite (#337, OpenSwoole + framework): 37,000, 90 % CPU, 231 µs/req

Not read in detail: the framework cost dominates, it says nothing about the raw runtime.

## holyphp-io-uring-elifoxcoder (#490): 270,000

PHP syntax compiled to C, with its own io_uring and SQLite B-tree runtime. Most of its wins aren't reachable from
Swoole, but its README is a measured journal, and some lessons carry over.

**Its path, on the bench VM, direct mode, 0 errors each time:**

| Stage                                   | Users   | req/s  | CPU  | µs/req |
|-----------------------------------------|---------|--------|------|--------|
| B-tree feed (classic epoll)             | 110,000 | 10,637 | 83 % | 73     |
| send-path fix (EAGAIN was fatal: 64k)   | 130,000 | 12,618 | 93 % | 69     |
| idle sweep rate limit                   | 135,000 | 13,117 | 92 % | 65     |
| io_uring backend                        | 145,000 | 14,093 | 91 % | 60     |
| ring-owned descriptors, batched wakeups | 260,000 | n/a    | 79 % | 29     |

**What carries over to us:**

- **Shed before the fd limit, politely:** in classic mode it starts shedding at 61,439 fds, and the shed replies carry
  `Connection: close`, so no user is refused and no POST lands on a dead socket. That's how a plain epoll server got
  to 110k to 145k: past the fd ceiling, the limit becomes CPU.
- **Holding more connections costs CPU:** keeping the overflow open in epoll cost 57 instead of 31 µs/req locally
  (76 instead of 60 on the VM). Churning some connections can be cheaper than holding them all. "At 120k connections,
  network processing dominates."
- **Smaller receive buffers:** 1 KB instead of 4 KB per connection, 60 MB instead of 240 MB at 60k connections, about
  3 % CPU. Same lesson as tzimpel's Swoole patch.
- **Fewer response headers:** dropping `Connection: keep-alive` and `Content-Encoding: identity` was part of a round
  worth about 9 % locally.
- **Background checkpoints:** `wal_autocheckpoint=0` plus a checkpoint thread: peak WAL from 211 to 260 MB down to
  18 MB. Their 5-minute holds failing after passing 2-minute probes looked like WAL growth then a blocking checkpoint
  (their words: not proven).
- **Group commit:** all writes of one loop pass in one `BEGIN IMMEDIATE ... COMMIT`, replies after the commit.
- **`unix-excl` VFS** (no `fcntl` locks): 43.0 to 40.2 µs/req. To check whether PDO lets us pick a VFS.
- **mmap barely matters:** 46.54 µs off, 47.39 µs with 256 MB. A 64 MB cache was as good as 256 MB.
- **Like:** same single statement as the Swoole entries, `foreign_keys` off, existence check only when nothing was
  inserted.
- **Body:** PHP's default `trim()`, then a code-point count. The tests pass with that too, so JavaScript's Unicode
  trim (mattsplat) isn't required by the suite.
- **Local versus VM:** their machine was "about 3.2x faster than the box". tzimpel saw about 1.8x. We calibrate our
  own ratio once on x86 (Q3).

**What limited it:** CPU and the tail latency. "Above 145k the search fails on CPU: 150k ran at 93 % CPU with p95
567 ms." Later runs failed on p95/p99 at 76 to 85 % CPU.
