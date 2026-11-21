# Phase 3: runtime bake-off

**Done when:** one table in `lab/results/<date>-bake-off/README.md` gives, for Swoole, Workerman (caches patched out,
D10) and DIY, with the same handler: µs CPU/req at 7,000 req/s on a no-op route and on `GET /posts/:id` (D16), the max
idle connections one process holds, and the RSS per connection. Plus one Workerman run with its caches on, and the
two finalists at 9,500 req/s. The predictions below were written before any measurement (D5). Then the run stops: no
phase 4 (D12).

**Where (D14):** code on branch `phase-3-claude`, in its worktree. `plan/` stays on `main`.

**Plan review:** [PLAN-2026-11-21-1635.md](../reviews/PLAN-2026-11-21-1635.md), NOT_OK (1 🔴, 3 🟠, 10 🟡). Its five
questions were settled by the project manager with the reviewer's own picks (D21 to D24), and its minor points are
folded in below. Delta: [PLAN-2026-11-21-1650-delta.md](../reviews/PLAN-2026-11-21-1650-delta.md), OK, its 4 🟡 folded in.

## Decisions of this phase

Taken by the project manager while Jacob is away (D17 to D24 in [decisions.md](../decisions.md)):

- **D17, PHP 8.5 for the bake-off:** the newest version all three runtimes build on (Swoole stops at 8.5, Q7), built
  from source with the lab's flags (D13), so phase 4's version comparison starts from the same build. Workerman and
  DIY also get one information run on 8.6 if ext-event builds there (Q7's hypothesis).
- **D18, ext-event as the loop of Workerman and DIY:** PHP's `stream_select` is capped at 1,024 fds (`FD_SETSIZE`),
  so Workerman's default loop and a select-based DIY would fail the connection test at about 1,000. ext-event
  (libevent, epoll) is Workerman's recommended loop. Same loop for both, so the difference between them is the
  framework and the parser.
- **D19, each runtime keeps its own response headers:** Swoole sends `Server`, `Date`, `Connection`, `Content-Type`
  and `Content-Length`; Workerman 5.2.4 sends `Connection`, `Content-Type` and `Content-Length` (no `Server`); DIY
  sends `Content-Type` and `Content-Length`. Fewer header bytes are part of what a runtime can save (HolyPHP,
  [prior-art.md](prior-art.md)). The results record each runtime's exact response bytes.
- **D20, two routes, not three:** a no-op `GET /noop` (the runtime alone) and `GET /posts/:id` (the runtime plus one
  indexed read, the spec's query with `WHERE p.id = ?`). `/health` with its `SELECT 1` sits between the two and would
  add a third of the runs for little.
- **D21, the images get `pcntl`, `sockets` and `event` as shared extensions:** built with `phpize` from the same
  sha256-pinned php.net tarball (and the PECL `event` tarball), in a new last layer, loaded per server with `--ext`.
  Workerman refuses to start without `pcntl`, and skips `TCP_NODELAY` without `sockets`. D13's configure flags and
  the cached PHP layers stay untouched.
- **D22, the same socket settings for all three, recorded:** listen backlog 4,096 (the VM's `somaxconn`) and
  `TCP_NODELAY` on, in every server; the results record both next to the response bytes. A runtime's default backlog
  (PHP's 32 for a DIY `stream_socket_server`) is an accident of the harness, not a runtime choice.
- **D23, max connections is counted by the client:** the connections that got their answer and are still open.
  `/proc/net/tcp` stays in the JSON as a cross-check (it also counts connections waiting in the accept queue). A
  client-side error (`bind`, `EMFILE`, no free port) fails the run as a harness failure, never as a ceiling.
- **D24, DIY's partial write is tested at the connection level:** on a `stream_socket_pair` whose peer doesn't read,
  not end to end (loopback buffers autotune to megabytes, so an end-to-end case can pass without a partial write).

## Scopes

| #   | Commit                                                              | Done when |
|-----|---------------------------------------------------------------------|-----------|
| 1   | `chore(lab): lint the lab's bash with a pinned shellcheck`          | `bash lab/check.sh` prints `ok` for `shellcheck`, the shellcheck image is pinned by tag and digest in `lib.sh`, and a fixture script with a known warning makes the check fail |
| 2   | `feat(lab): shared handler, Swoole bake-off server, conformance`    | `bash lab/conformance.sh --image 8.5 --server lab/servers/bake-swoole.php` prints every case `ok`; `lab/macro.sh` on that server at 7,000 req/s for 20 s is VALID on `/noop` and with the posts script; its JSON holds `other_containers` and the `--env`/`--ext` used |
| 3   | `feat(lab): idle-connection harness, max connections and RSS`       | `bash lab/conns.sh --image 8.5 --server lab/servers/bake-swoole.php --max 10000` prints one row per step, the max and the RSS per connection, and exits 0; with `--server-nofile 2048` it reports a ceiling under 2,048 with a named reason and exits 0; a second run right after the first doesn't fail on `bind` |
| 4   | `feat(lab): pcntl, sockets, ext-event and Workerman in the images`  | `lab/run.sh 8.5 php-info` prints `pcntl`, `sockets`, `event: <version>` and `workerman: 5.2.4 (stock, nocache)`; `lab/run.sh 8.5 php /lab/servers/workerman-caches.php` prints the caches filled on `stock` and empty on `nocache`; a minimal Workerman `Worker` on the Event loop answers one request on each tree; the 8.6 build has ext-event or a documented failure |
| 5   | `feat(lab): Workerman bake-off server, caches off and on`           | `lab/conformance.sh` prints every case `ok` on `bake-workerman.php` with `WORKERMAN_TREE=nocache` and `=stock`; `lab/macro.sh` at 7,000 req/s for 20 s is VALID on both routes for both trees; the server's process maps show `event.so` and no `swoole.so` |
| 6   | `feat(lab): DIY server, our own loop and parser`                    | `lab/conformance.sh` prints every case `ok` on `bake-diy.php`; `lab/check.sh` runs the DIY parser test (every cut position) and the partial-write test on a socket pair, both `ok`; `lab/macro.sh` at 7,000 req/s for 20 s is VALID on both routes |
| 7   | `docs(lab): the runtime bake-off`                                   | `lab/results/<date>-bake-off/README.md` holds the predictions (copied from this file, unchanged), then the table: µs/req (median and spread of 3 interleaved repeats) per runtime and route at 7,000, the finalists at 9,500, max connections and RSS per connection per runtime, each prediction marked held or not; every counted run VALID with `other_containers: 0`; raw JSON next to it |

Vertical slices: scope 2 brings the first bake-off server with the handler and the conformance test, because neither
can be checked without the other. Scope 3 proves the connection harness on that server before the other runtimes
exist. Scope 4 ends with a Workerman that boots, so an image problem is caught in the scope that rebuilds the images.
Scopes 5 and 6 each end with a runtime that passes conformance and a VALID macro run. Scope 7 only measures.

**The lab's suite:** `lab/check.sh`. Each scope adds its smoke check (a short conformance run per server, a 5 s macro
run per new server, a small connection run). It's the "full suite" of the skill, run before the reviews.

## Shared rules for every scope

Phase 2's rules hold ([phase-2.md](phase-2.md), "Shared rules"): limits, CPU layout in `lab/lib.sh`, pinned versions
with sha256, no absolute `/Users/...` paths, `reference/` read-only. New for phase 3:

- **A quiet VM (D15):** `macro.sh` and `conns.sh` record in their JSON the count and names of running containers that
  aren't this run's own (`other_containers`, a lab run from another checkout included), and print a warning above 0. They still run: `check.sh` smoke runs are not
  measurements. Scope 7 refuses to count a run with `other_containers` above 0.
- **No image build during a measurement (D15).** Scope 4 rebuilds the images; scope 7 measures only after it.
- **PHP extensions per server:** `LAB_SERVER_PHP_FLAGS` loads Swoole today (and `macro.sh` probes Swoole's version with
  it). From scope 2, `macro.sh`, `conns.sh` and `conformance.sh` take `--ext <name>` (repeatable, default `swoole`),
  so a Workerman or DIY server runs without Swoole loaded and a Swoole server without ext-event. Everything else in
  the flags stays the same for all servers (OPcache, tracing JIT, 32M buffer, `file_update_protection=0`,
  `zend.assertions=-1`). They also take `--env K=V` (repeatable, passed to the server container) and `--label <text>`
  (in the JSON and the file name, so a stock and a nocache run don't share a name). The JSON records the `--ext`,
  `--env` and `--label` used.
- **The worktree has no seed by default:** `lab/data/` and `reference/` are ignored. The worktree's `reference` is a
  relative symlink to the main checkout's clone (locally excluded, never committed), and `lab/seed.sh` has been run
  there.
- **The images are shared** with the main checkout (one Docker daemon). Scope 4 adds a layer at the end of each
  source image, so the cached PHP and Swoole layers are reused and `main`'s `check.sh` still passes on them.
- **Memory readings:** the sum of `Pss` from `/proc/<pid>/smaps_rollup` over the server's processes (Workerman runs a
  master and a worker: summed `VmRSS` would count their shared pages twice), and the cgroup's `memory.current`, which
  also holds the kernel's socket buffers (what reaches the 2 GiB limit). Both everywhere a memory number is reported.
  Pss has no high-water mark: `macro.sh` samples both at 1/4, 1/2 and 3/4 of the run and keeps the largest.
- **Socket settings recorded (D22):** each server prints its backlog and `TCP_NODELAY` at boot (Workerman and DIY read
  them back with `socket_get_option`; Swoole prints its configured values, it can't read them back), and the harnesses
  copy that line into their JSON (`server.socket`).

## Scope 1: shellcheck (done, `a0477ba`)

- **Seam:** `check_shellcheck` in `lab/check.sh`, the image in `lib.sh` (`LAB_SHELLCHECK_IMAGE`, `koalaman/shellcheck`
  by tag and multi-arch digest). Runs in Docker: nothing is installed on the Mac.
- **What:** every bash script under `lab/`, severity `warning` and up, fixed without changing behavior.
- **Cases:** a clean tree passes; `lab/check/fixtures/lint-warning.sh` must fail (SC2046: SC2086 is only `info`).

## Scope 2: shared handler, Swoole server, conformance

- **Seams:** `lab/servers/handler.php` (no runtime code), `lab/servers/bake-swoole.php`, `lab/conformance.sh --image
  <v> --server <file> [--ext <e>]... [--env K=V]...`, the k6 script `lab/macro/k6/posts.js`, `--ext`, `--env`,
  `--label` and `other_containers` in `macro.sh`.
- **The handler** is one function every runtime calls: method, path and body in, status and body bytes out. Routes,
  with the spec's error bodies (`{"error":"<message>"}`, `reference/.../SPEC.md`, "Errors"):
  - `GET /noop`: 200 `{"status":"ok"}`, no database;
  - `GET /posts/:id`: the spec's post query with `WHERE p.id = ?`, a PDO statement prepared once at boot, 200
    `{"post":{"id":…,"body":…,"created_at":…,"author":…,"like_count":…}}` in that key order; 404 `post not found` for
    an unknown id; 400 `invalid post id` when `:id` isn't a positive integer (`0`, `-1`, `abc`, `1.5`);
  - anything else: 404 `not found`.
  - The database is a copy of `lab/data/feed.db` made by the server at boot inside its container (never the file in
    `lab/data/` itself: WAL mode), with the pragmas of mattsplat's entry (64 MiB cache, 256 MiB mmap: the pages the
    posts route touches count in the process's memory, the no-op route touches none).
- **The Swoole server:** the no-op server's settings (`SWOOLE_BASE`, 1 worker, no coroutine, parsing and compression
  off, backlog 4,096) plus `open_tcp_nodelay => true` (D22), calling the handler, `Content-Type: application/json`.
- **Conformance** (also used by scopes 5 and 6): starts the server in a lab container like `macro.sh` does, then a
  PHP client on raw sockets checks, each case one line `ok` or `FAIL`:
  - `/noop` body and status; `/posts/1` equals, as JSON, what `sqlite3` returns for id 1 with the same query (its
    `username` column mapped to the key `author`), keys in the spec's order; `/posts/999999999` gives 404
    `post not found`; `/posts/abc`, `/posts/0`, `/posts/1.5` give 400 `invalid post id`; an unknown path gives 404
    `not found`;
  - two requests on one keep-alive connection; two requests pipelined in one write; one request split across two
    writes (headers cut in the middle, 50 ms apart); a `POST` with a `Content-Length` body to an unknown path gives
    404 and the connection still serves the next request;
  - the exact response bytes of `/noop` are printed (D19).
- **posts.js:** `constant-arrival-rate` like `fixed-rate.js`, the id of each request from a fixed sequence over ids 1
  to 500,000 (the seed's posts; the same sequence on every run, no `Math.random`), so every runtime reads the same rows.
- **Cases:** conformance exits non-zero when a case fails and names it; the server container is removed after a
  failure (trap); `other_containers` lists the names of running non-lab containers; a run with `--env` and `--label`
  records both in the JSON and puts the label in the file name.

## Scope 3: idle-connection harness

- **Seam:** `lab/conns.sh --image <v> --server <file> [--ext <e>]... [--env K=V]... [--label <text>] [--steps a,b,...]
  [--max N] [--server-nofile N] [--out <path>]`, and a client script run in its own container.
- **What it measures:** how many idle keep-alive connections one server process holds, and what each costs in
  memory. Steps (default 1k, 5k, 10k, 20k, 30k, 40k, 50k, 60k, 65k, 66k): at each step the client opens connections
  **one at a time** (blocking connect, one `GET /noop`, read its whole answer, keep the socket open), so the accept
  queue never fills and the server has allocated its per-connection buffers, like a k6 user. After each step: a sweep
  of non-blocking reads over the held sockets (an EOF means the server closed one), and from the probe container the
  sum of `Pss` of the server's processes, the cgroup's `memory.current`, the established connections in
  `/proc/net/tcp`, `memory.events` (OOM kills), and a fresh connection from `127.0.0.1` that must get an answer
  within 1 s.
- **The client:** a PHP script in a php-lab container (`--network host`, CPUs `4-11`, `nofile` well above 66k, no CPU
  or memory limit of the server's). **Source addresses rotate over a block of 127.x addresses (from `127.0.0.2`)**, so
  it never runs out of ephemeral ports (28,232 per source address and destination on this VM). No `sysctl` change
  anywhere: the Docker VM is shared with other projects. Before it starts, it waits until no `TIME_WAIT` socket
  remains on its source addresses (a 66k run leaves 66k for 60 s), or the run uses the next block.
- **Max connections (D23):** the connections the client got an answer on and still holds, at the last step fully held,
  plus the exact count when it stopped. **The ceiling** is the first step where a connect or request times out, a
  connection is reset, a held connection closed, the fresh request fails, or the server was OOM-killed: the output
  names which. Linux doesn't refuse a SYN because of a full accept queue or a server out of fds, so "refused" isn't
  expected. A client-side error (`bind`, `EMFILE`, no port) exits non-zero as a harness failure.
- **RSS per connection:** the slope of summed `Pss` against connections held (least squares over the held steps from
  1k up), the same for `memory.current`, and the baseline before any connection. All in the table and the JSON.
- **Output:** one row per step (connections, Pss MiB, memory.current MiB, `/proc/net/tcp` count, fresh request ms,
  ok/fail), the max, both slopes, the reason it stopped, `other_containers`, and every raw reading in the JSON. Exit 0
  when it found a ceiling or reached `--max`; non-zero only when the harness itself failed.
- **Cases:** `--server-nofile 2048` gives a ceiling under 2,048 with a named reason (proves the detection without 65k
  sockets); two runs back to back both pass; the client and server containers are removed after any failure (trap);
  a step above `--max` isn't run.

## Scope 4: pcntl, sockets, ext-event and Workerman in the images

- **Extensions (D21):** for each source image (8.3 to 8.6), a new last layer builds `pcntl` and `sockets` with
  `phpize` from the same php.net tarball and sha256 already pinned in `lib.sh`, and the PECL `event` tarball (3.2.0,
  latest stable on 2026-11-21, sha256 pinned) against `libevent-dev`. None enabled globally: loaded with
  `-d extension=...` through `--ext`, like Swoole. On 8.6, if `event` doesn't build, save the error in
  `lab/results/event-on-php-8.6.md` and build that image without it (like Swoole, Q7). `8.3-apt` is left as is (the
  bake-off doesn't use it).
- **Workerman:** the v5.2.4 GitHub tarball and `workerman/coroutine` v1.1.7 (what its `composer.json` accepts), both
  sha256 pinned, unpacked under `/opt/workerman/stock` and `/opt/workerman/nocache`, each with a small PSR-4
  autoloader (no Composer). The `Workerman\` prefix maps to two roots (Workerman's `src/` and the coroutine package's
  `src/`). `nocache` gets `lab/images/workerman-nocache.patch`, which removes the 5 caches of D10: the function-local
  `static` caches in `TcpConnection::baseRead()` (`$requests`), `Http::input()` (`$cache`) and
  `Request::parseHeaders()`, `parseGet()`, `parsePost()`. **The build fails if the patch doesn't apply**, or if a grep
  still finds one of the 5 statics.
- **`php-info`:** adds `pcntl`, `sockets` (present or not), `event: <version>` (or `not built`) and
  `workerman: 5.2.4 (stock, nocache)`.
- **`workerman-caches.php`:** runs one child process per tree (both trees declare the same classes). Each feeds the same
  raw requests through Workerman's HTTP protocol, through a `TcpConnection` on a socket pair for `baseRead()`, and calls
  `header()`, `get()` (with a query string) and `post()` (with a form body), twice; then reads the 5 statics with
  `ReflectionMethod::getStaticVariables()`. Filled on `stock`, empty on `nocache`, one line per cache and tree.
- **A Workerman that boots:** a minimal `Worker` (Event loop, `pcntl`, `sockets` and `event` loaded, `start` in argv,
  pid, status and log files in `/tmp`, not in the read-only `/lab`) answers one request on each tree.
- **Cases:** a patch that doesn't apply fails the build (shown once by hand, reported by the developer; `check.sh`
  doesn't rebuild); `php-info` on every image still prints the phase 2 lines unchanged.

## Scope 5: Workerman server

- **Seam:** `lab/servers/bake-workerman.php`, with `WORKERMAN_TREE=nocache|stock` (default `nocache`) passed with
  `--env`, and `--ext pcntl --ext sockets --ext event`.
- **Settings:** `count = 1`, `Worker::$eventLoopClass` set to the Event loop explicitly, no daemon, backlog 4,096,
  `TCP_NODELAY` on (Workerman sets it itself when `sockets` is loaded: the server reads it back and prints it at boot), `start` in
  argv, pid, status and log files in `/tmp`, the handler, `Content-Type: application/json`. Workerman runs a master and
  one worker: both are in the server's cgroup, so both count in the CPU and the memory.
- **Cases:** conformance on both trees; the server's `/proc/<pid>/maps` shows `event.so` and no `swoole.so`; the loop
  reported at start is the Event one, not Select; the JSON of a macro run records the tree (`--label`).

## Scope 6: DIY server

- **Seam:** `lab/servers/bake-diy.php` with `--ext sockets --ext event` (in that order: `event` built with sockets
  support needs `sockets` loaded first), and its connection code reusable on any stream (for the socket-pair test).
- **What:** ext-event loop (`EventBase`, one `Event` on the listening socket, one per connection), raw non-blocking
  reads and writes, our own parser for what the 5 routes need: the request line, `Content-Length` and the body
  (`Authorization` is read in phase 4, when a route needs it). Backlog 4,096 (`socket.backlog`) and `TCP_NODELAY` on
  (through `sockets`, on the listening socket). Keep-alive by default (HTTP/1.1), `Connection: close` honored.
  Pipelined requests in one read are all answered, in order. A partial write keeps the rest in a per-connection buffer
  and waits for the socket to be writable.
- **Errors:** a request line or header block that can't be parsed gets 400 and the connection closes; headers over
  8 KiB without the blank line: 400 and close; a client that closes mid-request frees its state.
- **Cases:** every conformance case; a parser test on raw byte strings (complete, cut at every byte position of a
  sample request, two pipelined, a body split from its headers); **the partial-write test (D24):** a
  `stream_socket_pair` whose peer doesn't read, a response larger than its buffer, then the peer reads and the bytes
  arrive whole and in order. Both tests run by `check.sh` with the CLI.

## Scope 7: the bake-off

- **Before any run:** copy the Predictions section below into the results README, unchanged, and commit nothing
  else first. Check `docker ps`: other projects' containers running means no measurement (D15), and the project
  manager waits or reports.
- **Image:** `8.5` for all (D17).
- **µs/req at 7,000 req/s:** 4 servers (Swoole, Workerman nocache, Workerman stock, DIY) × 2 routes (`/noop`,
  posts.js), 30 s measured after 10 s of warm-up, **3 repeats interleaved** (every server and route once, then
  again, then again). 24 runs, about 20 minutes.
- **The finalists:** the two of Swoole, Workerman nocache and DIY with the lowest posts µs/req at 7,000 (Workerman stock
  isn't a candidate: D10 keeps it as information). Both routes at 9,500 req/s, 3 interleaved repeats: 12 runs.
- **Connections:** `lab/conns.sh` once per server (Workerman stock excluded: its caches don't change what a held
  connection costs), up to 66k.
- **8.6 information:** if scope 4 built ext-event on 8.6, Workerman nocache and DIY once each on both routes at 7,000
  on `8.6`, marked "information, one run".
- **The table:** runtime, µs/req median and min..max per route at 7,000, at 9,500 for the finalists, p99, peak memory
  under load, max connections and why it stopped, both slopes per connection, the backlog, `TCP_NODELAY`, and the
  response bytes of `/noop`. A `summarize.sh` builds it from the JSON, like phase 2's.
- **Then:** "Did the predictions hold?", one line each, by the rules written with them, and runtimes.md's flip rule:
  is patched Workerman within 30 % of Swoole on `/noop`?

## Predictions (D5)

Written by the project manager on 2026-11-21 at 16:29, before any phase 3 measurement (commit `4e3a8a5`), and
revised at 16:44 after the plan review, still before any measurement: 7 and 8 now follow the prior art's 18 to
42 KiB per connection, and each prediction says how it's judged. Arm64, Docker Desktop on an M3 Pro, quiet VM, PHP
8.5, 1 CPU.

**What we start from:** the no-op Swoole server cost 50.2, 30.2 and 21.7 µs/req at 1k, 3k and 6k req/s on 8.3-apt,
on a **busy** VM. On the quiet VM the micro sample landed every swinging row on its slow level (D15), so quiet-VM
numbers may come out higher than busy-VM ones. tzimpel saw 2 Swoole workers cost 27 % more per request, 184 MB RSS at
10k connections with stock Swoole (about 18 KiB each) and the worker die at about 38k; mattsplat saw 840 MB at 20k
(about 42 KiB each); HolyPHP measured fewer header bytes as part of a 9 % round.

**How they're judged:** a µs/req number is the median of the 3 interleaved repeats; a percentage is relative to the
number named in the prediction; a range holds if the measured value is inside it.

1. **Swoole `/noop` at 7,000 req/s: 18 to 35 µs/req.** The busy-VM trend gives about 20 at 7k; the quiet VM may add up
   to 1.5x.
2. **`/posts/:id` costs 5 to 15 µs/req more than `/noop` on every runtime**, and the gap (posts minus noop) differs by
   at most 3 µs between the three: the handler is the same code, so the runtimes should differ by the same amount on
   both routes.
3. **Workerman with its caches out costs 30 to 70 % more than Swoole on `/noop`.** Its HTTP parsing, `Request` and
   `Response` objects and its connection object run in PHP. So runtimes.md's flip rule (within 30 % of Swoole) **fails**.
4. **Workerman with its caches on is 10 to 25 % cheaper than with them out on `/noop`** (every request has the same
   bytes, so `baseRead()`'s cache returns the decoded request every time) **and under 5 % cheaper on posts.js** (each
   id comes back rarely, so the cache rarely hits). Only 2 of the 5 caches can move these numbers: the handler never
   calls `header()`, `get()` or `post()`.
5. **DIY lands within 15 % of Swoole on `/noop`, either side.** It runs more PHP than Swoole per request but builds no
   objects and sends 2 headers instead of 5. So the finalists are **Swoole and DIY**.
6. **At 9,500 req/s, µs/req is 5 to 15 % lower than at 7,000** for both finalists: the trend of phase 2 (fixed costs
   spread over more requests per wake-up).
7. **Max connections:** Swoole stops on **memory (OOM kill), between 35,000 and 60,000**: about 30 KiB of process
   memory per connection plus the kernel's socket buffers reach 2 GiB before 65,535 fds. Workerman and DIY stop on the
   **fd limit, between 65,000 and 65,535**.
8. **Memory per connection (Pss slope):** Swoole **15 to 45 KiB** (prior art's 18 to 42), Workerman **3 to 10 KiB**,
   DIY **1 to 4 KiB**. The `memory.current` slope is higher than the Pss slope on all three, by the kernel's socket
   memory.
9. **p99 at 7,000:** under 3 ms on all three on both routes, with Workerman the highest.

## Out of scope

- **µs/req with many connections held** (1k, 30k, 65k open while the rate runs): it's S1 in phase 4 (steps.md). Phase 3
  measures CPU and connections separately. This path isn't touched.
- **Swoole's receive-buffer patch (tzimpel) and `Connection: close` shedding:** S1 variants, phase 4. Phase 3 measures
  stock Swoole, so its connection number is the one to beat.
- **Several workers, `SO_REUSEPORT`:** S1-b, phase 4. Every server here runs one worker.
- **JWT, writes, the feed:** phase 4 steps. The handler has two read routes only.
- **Each runtime's default backlog and `TCP_NODELAY`:** set the same for all (D22); not measured.
- **x86 numbers:** absolute numbers stay arm64 (D7). Moving to EC2 is a question for Jacob, not this phase.
- **Swoole on 8.6:** Q7.
