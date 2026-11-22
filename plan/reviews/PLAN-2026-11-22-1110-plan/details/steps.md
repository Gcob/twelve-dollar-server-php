# Steps, variants and how to measure them

Every use case ([sequences.md](sequences.md)) is a chain of the same 9 steps. For each step: the variants we think
could work (the theory), and how we measure them. The method itself is in [measuring.md](measuring.md).

Each result goes in a table under its step, with the date, the environment (D7), the PHP version, the command that
produced it, and the prior-art prediction it checks (D5).

## Across all steps: the PHP version (D8)

- **Variants:** 8.3 (apt on Ubuntu 24.04, what both Swoole entries used), 8.4, 8.5 and 8.6 (released 2026-11-19),
  the last three compiled from source.
- **Measure:** the micro benches of S3 to S7 on each version, JIT on and off, then the macro run on the best two.
- **Risks to check in phase 2:**
  - Swoole on 8.6: the latest releases (6.2.6, 6.3.0-rc2) don't mention 8.6. If it doesn't build, 8.6 waits.
  - Install time: compiling PHP in `install.sh` takes minutes on 1 vCPU, and one submission failed on an install
    timeout. If 8.4+ wins, how to install it becomes a question for the plan.

## S1: accept and keep connections

- **Matters for:** UC0, so the 71,000 ceiling.
- **Variants:**
  - **S1-a:** one process holds every connection (`SWOOLE_PROCESS`, RoadRunner, FrankenPHP). Ceiling 65,535 fds.
  - **S1-b:** N processes with `SO_REUSEPORT`, each accepts its own connections (`SWOOLE_BASE`, Workerman
    `reusePort`, DIY). Ceiling N x 65,535, if the kernel's `fs.file-max` follows.
  - **S1-c:** close idle sockets after a timeout. **Ruled out by prior art:** two entries scored 0, because k6
    doesn't retry a POST sent on a socket the server just closed ([prior-art.md](prior-art.md)).
  - **S1-d:** one process, and past a threshold (around 61k open fds), answer with `Connection: close` so the client
    reconnects next time. How HolyPHP's classic mode reached 110k to 145k. To check: how Swoole sends that header and
    closes cleanly after the response.
  - **Receive buffer per connection:** Swoole's 64 KiB buffer stays on every idle connection (tzimpel patched it out).
    Compare the stock build, the patch, and Swoole's own buffer settings.
- **Measure:** max idle connections before the first error, RSS per connection, and µs/req at 1k, 30k and 65k open
  connections (the many-connection cost is the big unknown). tzimpel already measured 2 processes at +27 % CPU/req.

## S2: read and parse the request

- **Matters for:** every request.
- **Variants:** the runtime's parser (C in Swoole, PHP in Workerman), or our own parser that only reads the request
  line, `Authorization`, `Content-Length` and the body.
- **Measure:** µs/req of a no-op route on each runtime, at a fixed rate (macro). The DIY parser also gets a micro
  bench on raw request bytes.

## S3: route

- **Matters for:** every request.
- **Variants:** a `match` on the method and the first path bytes, `str_starts_with` chains, `preg_match`, a router
  library (FastRoute).
- **Measure:** micro bench, ns per route on the real path mix (46 % `/feed`, 46 % `/posts/:id`, ...).

## S4: verify the JWT

- **Matters for:** UC3 and UC4 (7.8 % of requests), on every one of them (rule 5: no cached verification).
- **Variants:**
  - `firebase/php-jwt` (library, pinned) versus hand-written: `explode`, `hash_hmac('sha256', ...)`,
    `hash_equals`;
  - payload with `json_decode` versus reading only `sub`, `username`, `exp`;
  - base64url with `strtr` + `base64_decode` versus `sodium_base642bin`.
- **Measure:** micro bench, ns per token, with the valid token and the 7 bad tokens of the test suite (a wrong
  result is a failed variant, whatever its speed).

## S5: validate the input

- **Matters for:** UC2 to UC4.
- **Variants:**
  - id: `ctype_digit` + cast, `preg_match('/^[1-9][0-9]*$/')`, `filter_var`;
  - body: `json_decode` with or without `JSON_THROW_ON_ERROR`, then `trim`, then the length with `mb_strlen`,
    `iconv_strlen` or `preg_match_all('/./u')`.
- **Correctness first:** the test trims spaces around `café ✓`. PHP's `trim()` only removes ASCII whitespace; we
  must check what the reference (and SQLite's `length()`) count as one character.
- **Measure:** micro bench, ns per call.

## S6: query SQLite

- **Matters for:** every request, and the biggest suspect for UC1.
- **Variants:**
  - **driver:** `PDO_SQLITE` or FFI straight to `libsqlite3`. The `SQLite3` extension is out: it steps a statement
    twice and runs `INSERT ... RETURNING` twice (tzimpel, [prior-art.md](prior-art.md));
  - **feed SQL:** the reference correlated subquery, a `LEFT JOIN ... GROUP BY`, or two statements (the 20 posts,
    then the counts with `IN (...)`);
  - **fetch mode:** `FETCH_NUM` versus `FETCH_ASSOC`, `fetch()` in a loop versus `fetchAll()`;
  - **pragmas:** `mmap_size`, `cache_size`, `temp_store`, all allowed by rule 6;
  - **statements:** prepared once at boot and reset, versus prepared per request (to see what reuse saves).
- **Measure:** micro bench per query on a fresh seed copy, ns per call, and `EXPLAIN QUERY PLAN` saved with the
  result.
- **Not a variant, rule 5 (D29):** every request runs its own reads. Batching several requests' reads into one
  `IN (...)`, or sharing one result between identical requests, is what the challenge's author ruled out on
  2026-11-15. Two statements for one request's feed (the 20 posts, then their counts) stay allowed.

## S7: build the JSON

- **Matters for:** UC1 above all (20 posts, about 5 KB).
- **Variants:** `json_encode` of PHP arrays, string concatenation with `json_encode` only on `body` and `username`,
  `sprintf`, `implode` of prebuilt pieces, and the flags (`JSON_UNESCAPED_SLASHES`, `JSON_UNESCAPED_UNICODE`).
- **Correctness first:** the golden files are compared byte for byte.
- **Measure:** micro bench, ns per feed and per post, on real rows.

## S8: write the response

- **Matters for:** every request.
- **Variants:** the runtime's response object, a raw write with prebuilt header bytes (`Date` and
  `Content-Length` only change), with or without compression (optional in the spec, costs CPU).
- **Measure:** macro only (the syscall dominates), µs/req at a fixed rate.

## S9: durability

- **Matters for:** UC3 and UC4, and the p99 of everyone, because a checkpoint can land inside any commit.
- **Variants:**
  - one transaction per write versus group commit (writes queued for a few ms, one `COMMIT`, then every response);
  - **group commit per loop turn** (D30): each turn of the event loop gathers the writes that arrived together, runs
    one `BEGIN … COMMIT`, then answers them all. No timer: at low load a batch is one write (no added latency), near
    saturation the batches grow by themselves. Rule 6 allows it because every response waits for its commit;
  - `wal_autocheckpoint` default, larger, or off with a `PASSIVE` checkpoint on a timer;
  - **a background checkpointer** (D30): a separate process runs `PRAGMA wal_checkpoint(PASSIVE)` on a timer, with the
    server's `wal_autocheckpoint` off. The checkpoint's CPU stays on the same core, but its wait on the disk (`fsync`)
    leaves the event loop, which would otherwise freeze every connection while it runs;
  - `synchronous=NORMAL` (minimum allowed) is the starting point.
- **Measure:** macro, p99 of the reads while the writes run, WAL size over 5 minutes.
