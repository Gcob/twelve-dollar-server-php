# Brief: scope 6/7, DIY server, our own loop and parser

**Worktree:** `phase-3-claude` (absolute path in your prompt) · **Run folder:** `plan/` of the main checkout
**Planned commit:** `feat(lab): DIY server, our own loop and parser`

**Read first:** [common.md](common.md), then `plan/state/developer.md` (scopes 1 to 5: the handler, the harnesses,
`--ext` and its order, the Workerman server as a second adapter).

**Summary:** the third bake-off server: our own event loop on ext-event and our own HTTP/1.1 parser, only what the 5
routes of the challenge need, on the shared handler.

**Today:** `handler.php`, `bake-swoole.php`, `bake-workerman.php`; `conformance.sh`, `macro.sh`, `conns.sh`; the source
images load `pcntl`, `sockets`, `event` with `--ext` (`sockets` before `event`).

**Expected:**

- **`lab/servers/bake-diy.php`:** run with `--ext sockets --ext event`. One process.
  - **Listening:** `stream_socket_server` on `0.0.0.0:$PORT` with `socket.backlog` 4096 and `so_reuseport` off (one
    process), non-blocking; `TCP_NODELAY` set on the listening socket through `socket_import_stream` +
    `socket_set_option` (accepted sockets inherit it on Linux; check it on an accepted socket once and say so). Prints
    at boot one socket line in the same format as the other servers (`backlog=… tcp_nodelay=…`), read back from the
    socket.
  - **Loop:** one `EventBase`; one persistent read `Event` on the listening socket (accept until `EAGAIN`, so a burst
    is drained in one callback); one read `Event` per connection; a write `Event` only while a connection has unsent
    bytes. Nothing per request that isn't needed (no objects per request; a connection's state can be a small array or
    object, your call, with the reason).
  - **Parser:** for each connection, a read buffer. On each read: append, then while the buffer holds a complete
    request: find `\r\n\r\n`; parse the request line (method, target, `HTTP/1.1` or `HTTP/1.0`); find
    `Content-Length` (case-insensitive) and `Connection` in the headers; wait for the whole body; call the handler with
    method, path, body; append the response to the write buffer; drop the request from the read buffer. Then write.
    `Authorization` isn't read yet (a later phase adds it). `Transfer-Encoding: chunked` gets 400 and close (k6 never
    sends it: say so in a comment).
  - **Response:** `HTTP/1.1 <status> <reason>\r\nContent-Type: application/json\r\nContent-Length: <n>\r\n\r\n<body>`;
    nothing else. Keep-alive by default on HTTP/1.1; `Connection: close` (or HTTP/1.0 without keep-alive) closes after
    the response is fully written.
  - **Writes:** `fwrite` as much as the socket takes; the rest stays in the connection's write buffer, a write event
    waits for the socket, and reading for that connection pauses while the buffer is over a limit (say 1 MiB), so a
    client that never reads can't grow the server's memory without bound.
  - **Errors:** a request line or a header block that can't be parsed: 400 `{"error":"bad request"}` and close; headers
    over 8 KiB without `\r\n\r\n`: 400 and close; a `Content-Length` that isn't digits: 400 and close; a client that
    closes (EOF) or errors frees its state and its events at once.
  - **Reusable connection code:** the per-connection logic (feed bytes, produce responses, write with partial
    writes) works on any stream, so the partial-write test can drive it on a `stream_socket_pair` without the listening
    socket.
- **Tests run by `lab/check.sh`, with the CLI in the 8.5 image:**
  - **Parser test** (`lab/servers/diy-parser-test.php` or under `lab/check/`): a sample request (with a body) fed
    complete; fed cut at **every byte position** (two pieces); two pipelined in one piece; a body split from its
    headers; the 400 cases. Each gives exactly the expected responses, in order.
  - **Partial-write test:** a `stream_socket_pair` whose peer doesn't read; the server side writes a response larger
    than the pair's buffer (find the size, say about 200 KiB on Linux; use a handler stub that returns a big body); check
    a partial write happened and the rest is buffered; then the peer reads everything and the bytes arrive whole and in
    order.
  - Conformance on `bake-diy.php`, and a 5 s macro run with `posts.js`, VALID.
- **`lab/README.md`:** the DIY server, what it parses and what it doesn't, the two tests.

**Done when:** `bash lab/conformance.sh --image 8.5 --server lab/servers/bake-diy.php --ext sockets --ext event` prints
every case `ok`; `lab/check.sh` runs the parser test and the partial-write test, both `ok`; `lab/macro.sh --image 8.5
--server lab/servers/bake-diy.php --ext sockets --ext event` at 7,000 req/s for 20 s is VALID on `--path /noop` and
with `--script lab/macro/k6/posts.js`; a smoke `conns.sh --steps 200,500 --max 500` holds 500; the whole `lab/check.sh`
passes (`N/N ok`).

**Seams and cases to test:** the parser test and the partial-write test above (red first), the conformance cases, the
macro and connection smoke runs.

**Tests to imitate:** `lab/check.sh` → `check_conformance_bake_swoole`, `check_macro_bake_swoole_posts_is_valid`; the
PHP style of `lab/conformance/client.php`.

**Decisions that touch you:**

- DIY runs on ext-event (PHP's `stream_select` is capped at 1,024 fds).
- Each runtime keeps its own headers: DIY sends only `Content-Type` and `Content-Length`.
- Every server: backlog 4,096 and `TCP_NODELAY` on, printed at boot.
- DIY's partial write is tested on a socket pair whose peer doesn't read (end to end on loopback, buffers autotune to
  megabytes, so the path would never run).
- Smoke runs on a busy VM aren't measurements: never commit result files.

**Out of scope:** `Authorization` and the JWT, POST routes, several processes, `Connection: close` shedding near the
fd limit (all later phases); the measurements (scope 7).

**Where to look:** `lab/servers/bake-swoole.php`, `bake-workerman.php`, `handler.php`; `lab/conformance/client.php`
(the cases DIY must pass). SHAs in `plan/state/developer.md`.

**Come back to me if:** ext-event can't drive PHP streams the way this needs, a decision is missing, or the "Done
when" doesn't pass after 3 tries.

## Notes from scope 5 (before launch)

- **One socket-line format for all three servers:** Workerman prints `socket: backlog=4096 tcp_nodelay=1`, Swoole
  prints `open_tcp_nodelay=1`. Use `tcp_nodelay` in DIY, and change `bake-swoole.php`'s boot line to the same key
  (`backlog=… tcp_nodelay=…`), in this commit, with any check or README text that reads it. The backlog can't be read
  back from a socket (no option for it, `/proc/net/tcp` shows 0 for a listener): print the requested value and say so
  in the README; `TCP_NODELAY` is read back where the runtime allows it.
