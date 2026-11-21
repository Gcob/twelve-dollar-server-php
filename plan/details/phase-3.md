# Phase 3: runtime bake-off

**Done when:** one table in `lab/results/<date>-bake-off/README.md` gives, for Swoole, Workerman (caches patched out,
D10) and DIY, with the same handler: µs CPU/req at 7,000 req/s on a no-op route and on `GET /posts/:id` (D16), the max
idle connections one process holds, and the RSS per connection. Plus one Workerman run with its caches on, and the
two finalists at 9,500 req/s. The predictions below were written before any measurement (D5). Then the run stops: no
phase 4 (D12).

**Where (D14):** code on branch `phase-3-claude`, in its worktree. `plan/` stays on `main`.

## Decisions of this phase

Taken by the project manager while Jacob is away (D17 to D20 in [decisions.md](../decisions.md)):

- **D17, PHP 8.5 for the bake-off:** the newest version all three runtimes build on (Swoole stops at 8.5, Q7), built
  from source with the lab's flags (D13), so phase 4's version comparison starts from the same build. Workerman and
  DIY also get one information run on 8.6 if ext-event builds there (Q7's hypothesis).
- **D18, ext-event as the loop of Workerman and DIY:** PHP's `stream_select` is capped at 1,024 fds (`FD_SETSIZE`),
  so Workerman's default loop and a select-based DIY would fail the connection test at about 1,000. ext-event
  (libevent, epoll) is Workerman's recommended loop. Same loop for both, so the difference between them is the
  framework and the parser.
- **D19, each runtime keeps its own response headers:** Swoole adds `Server`, `Date` and `Connection`, Workerman adds
  `Server` and `Connection`, DIY sends only `Content-Type` and `Content-Length`. Fewer header bytes are part of what a
  runtime can save (HolyPHP, [prior-art.md](prior-art.md)). The results record each runtime's exact response bytes,
  so the table can be read with that in mind.
- **D20, two routes, not three:** a no-op `GET /noop` (the runtime alone) and `GET /posts/:id` (the runtime plus one
  indexed read, the spec's query with `WHERE p.id = ?`). `/health` with its `SELECT 1` sits between the two and would
  add a third of the runs for little.

## Scopes

| #   | Commit                                                              | Done when |
|-----|---------------------------------------------------------------------|-----------|
| 1   | `chore(lab): lint the lab's bash with a pinned shellcheck`          | `bash lab/check.sh` prints `ok` for `shellcheck`, the shellcheck image is pinned by tag and digest in `lib.sh`, and a fixture script with a known warning makes the check fail |
| 2   | `feat(lab): shared handler, Swoole bake-off server, conformance`    | `bash lab/conformance.sh --image 8.5 --server lab/servers/bake-swoole.php` prints every case `ok`; `lab/macro.sh` on that server at 7,000 req/s for 20 s is VALID on `/noop` and on the posts script; its JSON holds `other_containers` (0) |
| 3   | `feat(lab): idle-connection harness, max connections and RSS`       | `bash lab/conns.sh --image 8.5 --server lab/servers/bake-swoole.php --max 10000` prints one row per step and the RSS per connection, VALID; with `--server-nofile 2048` it reports a ceiling under 2,048 and exits 0, with the reason |
| 4   | `feat(lab): ext-event and Workerman 5.2.4 in the lab images`        | `lab/run.sh 8.5 php-info` prints `event: <version>` and `workerman: 5.2.4 (stock, nocache)`; `lab/run.sh 8.5 php /lab/servers/workerman-caches.php` prints the 5 caches filled on `stock` and empty on `nocache`; the 8.6 build has ext-event or a documented failure |
| 5   | `feat(lab): Workerman bake-off server, caches off and on`           | `lab/conformance.sh` prints every case `ok` on `bake-workerman.php` with `WORKERMAN_TREE=nocache` and `=stock`; `lab/macro.sh` at 7,000 req/s for 20 s is VALID on both routes for both trees; the server's process list shows no Swoole loaded |
| 6   | `feat(lab): DIY server, our own loop and parser`                    | `lab/conformance.sh` prints every case `ok` on `bake-diy.php`, the partial-read, pipelining and large-response cases included; `lab/macro.sh` at 7,000 req/s for 20 s is VALID on both routes |
| 7   | `docs(lab): the runtime bake-off`                                   | `lab/results/<date>-bake-off/README.md` holds the predictions (copied from this file, unchanged), then the table: µs/req (median and spread of 3 interleaved repeats) per runtime and route at 7,000, the finalists at 9,500, max connections and RSS per connection per runtime, each prediction marked held or not; every run VALID with `other_containers: 0`; raw JSON next to it |

Vertical slices: scope 2 brings the first bake-off server with the handler and the conformance test, because neither
can be checked without the other. Scope 3 proves the connection harness on that server before the other runtimes
exist. Scopes 5 and 6 each end with a runtime that passes conformance and a VALID macro run. Scope 7 only measures.

**The lab's suite:** `lab/check.sh`. Each scope adds its smoke check (a short conformance run per server, a 5 s macro
run per new server, a small connection run). It's the "full suite" of the skill, run before the reviews.

## Shared rules for every scope

Phase 2's rules hold ([phase-2.md](phase-2.md), "Shared rules"): limits, CPU layout in `lab/lib.sh`, pinned versions
with sha256, no absolute `/Users/...` paths, `reference/` read-only. New for phase 3:

- **A quiet VM (D15):** every measuring script (`macro.sh`, `conns.sh`, `micro.sh`) records in its JSON the count and
  names of running containers that aren't its own (`other_containers`), and prints a warning above 0. It still runs:
  `check.sh` smoke runs are not measurements. Scope 7 refuses to count a run with `other_containers` above 0.
- **No image build during a measurement (D15).** Scope 4 rebuilds the images; scope 7 measures only after it.
- **PHP extensions per server:** `LAB_SERVER_PHP_FLAGS` loads Swoole today. From scope 2, `macro.sh`, `conns.sh` and
  `conformance.sh` take `--ext <name>` (repeatable, default `swoole`), so a Workerman or DIY server runs without
  Swoole loaded and a Swoole server without ext-event. Everything else in the flags stays the same for all servers
  (OPcache, tracing JIT, 32M buffer, `file_update_protection=0`, `zend.assertions=-1`).
- **The worktree has no seed by default:** `lab/data/` and `reference/` are ignored. The worktree's `reference` is a
  relative symlink to the main checkout's clone (locally excluded, never committed), and `lab/seed.sh` has been run
  there.
- **The images are shared** with the main checkout (one Docker daemon). Scope 4 adds a layer at the end of each
  image, so the cached PHP and Swoole layers are reused and `main`'s `check.sh` still passes on them.

## Scope 1: shellcheck

- **Seam:** `check_shellcheck` in `lab/check.sh`, the image in `lib.sh` (`LAB_SHELLCHECK_IMAGE`, `koalaman/shellcheck`
  by tag and multi-arch digest). Runs in Docker: nothing is installed on the Mac.
- **What:** every `*.sh` under `lab/`, severity `warning` and up. Fix what it flags in the existing scripts without
  changing their behavior (quoting, `read -r`, ...); a warning that is a false positive gets a `# shellcheck
  disable=SCxxxx` with a one-line why.
- **Cases:** a clean tree passes; `lab/check/fixtures/lint-warning.sh` (excluded from the normal scan) is scanned on
  its own and must fail, which proves the check can fail; a missing image is pulled once, then pinned by digest.

## Scope 2: shared handler, Swoole server, conformance

- **Seams:** `lab/servers/handler.php` (no runtime code), `lab/servers/bake-swoole.php`, `lab/conformance.sh --image
  <v> --server <file> [--ext <e>] [--env K=V]`, the k6 script `lab/macro/k6/posts.js`, `other_containers` in
  `macro.sh`'s JSON.
- **The handler** is one function every runtime calls: method, path and body in, status and body bytes out. Routes:
  - `GET /noop`: 200 `{"status":"ok"}`, no database;
  - `GET /posts/:id`: the spec's post query with `WHERE p.id = ?` (`reference/.../SPEC.md`), a PDO statement prepared
    once at boot, 200 `{"post":{...}}` with keys in the spec's order; 404 `{"error":"not found"}` for an unknown id;
  - anything else: 404. An id that isn't digits only: 404.
  - The database is a copy of `lab/data/feed.db` made by the server at boot inside its container (never the file in
    `lab/data/` itself: WAL mode), with the pragmas of mattsplat's entry. The copy's page cache counts in the
    container's memory: the connection test reads the process's RSS, not the cgroup's memory, for that reason.
- **The Swoole server:** the no-op server's settings (`SWOOLE_BASE`, 1 worker, no coroutine, parsing and compression
  off), calling the handler, `Content-Type: application/json`.
- **Conformance** (also used by scopes 5 and 6): starts the server in a lab container like `macro.sh` does, then a
  PHP client on raw sockets checks, each case one line `ok` or `FAIL`:
  - `/noop` body and status; `/posts/1` equals, as JSON, what `sqlite3` returns for id 1 with the same query, keys in
    the spec's order; an unknown id and an unknown path give 404;
  - two requests on one keep-alive connection; two requests pipelined in one write; one request split across two
    writes (headers cut in the middle, 50 ms apart); a `POST` with a `Content-Length` body to an unknown route gives
    404 and the connection still serves the next request;
  - a response larger than one socket write (`GET /posts/:id` with a long body is not enough: the client reads with a
    small receive buffer, 1 KiB, so a server that drops a partial write fails);
  - the exact response bytes of `/noop` are printed (D19).
- **posts.js:** `constant-arrival-rate` like `fixed-rate.js`, the id of each request from a fixed sequence over the
  whole `posts` table (the same sequence on every run, no `Math.random`), so every runtime reads the same rows.
- **Cases:** conformance exits non-zero when a case fails and names it; the server container is removed after a
  failure (trap); `other_containers` is 0 on a quiet VM and lists the names otherwise.

## Scope 3: idle-connection harness

- **Seam:** `lab/conns.sh --image <v> --server <file> [--ext <e>] [--env K=V] [--steps a,b,...] [--max N]
  [--server-nofile N] [--out <path>]`, and a client program run in its own container.
- **What it measures:** how many idle keep-alive connections one server process holds, and what each costs in
  memory. The client opens connections in steps (default 1k, 5k, 10k, 20k, 30k, 40k, 50k, 60k, 65k, 66k), each sends
  one `GET /noop` and reads its answer (so the server has allocated its per-connection buffers, like a k6 user), then
  stays open. After each step, from the probe container: the server processes' summed `VmRSS`, the cgroup's
  `memory.current`, the established connections counted in `/proc/net/tcp`, and a fresh connection that must get an
  answer within 1 s.
- **The client:** a PHP script in a lab container (`--network host`, CPUs `4-11`, `nofile` well above 66k, no CPU or
  memory limit of the server's), non-blocking sockets. **Source addresses rotate over `127.0.0.2` and up**, so the
  client never runs out of ephemeral ports (about 28k per source address and destination). No `sysctl` change
  anywhere: the Docker VM is shared with other projects.
- **The ceiling:** the first step where a connection is refused, reset or times out, a held connection has closed, the
  fresh request fails, or the server was OOM-killed (`memory.events`). The output names which one. The max is the
  last step fully held, plus the exact count of connections still established when it stopped.
- **RSS per connection:** the slope of the summed `VmRSS` against connections held, a least-squares fit over the held
  steps from 1k up, and the baseline (no connection). Both in the table and the JSON.
- **Output:** one row per step (connections, VmRSS MiB, memory.current MiB, fresh request ms, ok/fail), the max, the
  slope, the reason it stopped, `other_containers`, and every raw reading in the JSON. Exit 0 when it found a ceiling
  or reached `--max`; non-zero only when the harness itself failed.
- **Cases:** `--server-nofile 2048` gives a ceiling under 2,048 with reason "refused" or "reset" (proves the ceiling
  detection without 65k sockets); the client and server containers are removed after any failure (trap); a step above
  `--max` isn't run.

## Scope 4: ext-event and Workerman in the images

- **ext-event:** the PECL `event` tarball, latest stable as of 2026-11-21, sha256 pinned, built against the image's
  PHP with `libevent-dev`, as a new last layer. Not enabled globally (loaded with `-d extension=event`, like Swoole).
  `--with-event-sockets` off unless Workerman needs it (it uses streams). On 8.6: if it doesn't build, save the error in
  `lab/results/event-on-php-8.6.md` and build the image without it (like Swoole, Q7).
- **Workerman:** the v5.2.4 GitHub tarball and the `workerman/coroutine` version its `composer.json` accepts, both
  sha256 pinned, unpacked in the image under `/opt/workerman/stock` and `/opt/workerman/nocache`, with a small PSR-4
  autoloader (no Composer in the image). `nocache` gets `lab/images/workerman-nocache.patch`, which removes the 5
  caches listed in [runtimes.md](runtimes.md) (D10). **The build fails if the patch doesn't apply**, or if any of the 5
  cache properties is still written after patching (checked by a grep in the build).
- **`php-info`:** adds `event: <version>` (or `not built`) and `workerman: 5.2.4 (stock, nocache)`.
- **`workerman-caches.php`:** decodes the same raw requests twice through Workerman's HTTP protocol, then reads the 5
  static caches by reflection: filled on `stock`, empty on `nocache`. This is what proves D10's patch works.
- **Cases:** a patch that doesn't apply fails the build (`check.sh` doesn't rebuild; the brief shows it once by hand
  and the developer reports it); `php-info` on every image still prints the phase 2 lines unchanged.

## Scope 5: Workerman server

- **Seam:** `lab/servers/bake-workerman.php`, with `WORKERMAN_TREE=nocache|stock` (default `nocache`) passed with
  `--env`.
- **Settings:** `count = 1`, ext-event loop set explicitly (`Worker::$eventLoopClass`), no daemon, logs to stdout, the
  handler, `Content-Type: application/json`. Workerman runs a master and one worker: both are in the server's cgroup,
  so both count in the CPU and the RSS.
- **Cases:** conformance on both trees; the server's `/proc/<pid>/maps` shows `event.so` and no `swoole.so`; the
  loop reported at start is the Event one, not Select.

## Scope 6: DIY server

- **Seam:** `lab/servers/bake-diy.php`.
- **What:** ext-event loop (`EventBase`, one `Event` on the listening socket, one per connection), raw non-blocking
  reads and writes, our own parser for what the 5 routes need: the request line, `Content-Length` and the body
  (`Authorization` is read in phase 4, when a route needs it). Keep-alive by default (HTTP/1.1), `Connection: close`
  honored. Pipelined requests in one read are all answered, in order. A partial write keeps the rest in a
  per-connection buffer and waits for the socket to be writable.
- **Errors:** a request line or header block that can't be parsed gets 400 and the connection closes; headers over
  8 KiB without the blank line: 400 and close; a client that closes mid-request frees its state.
- **Cases:** every conformance case, plus a unit-level check of the parser on raw byte strings (complete, cut at every
  byte position of a sample request, two pipelined, a body split from its headers), run by `check.sh` with the CLI.

## Scope 7: the bake-off

- **Before any run:** copy the Predictions section below into the results README, unchanged, and commit nothing
  else first. Check `docker ps`: other projects' containers running means no measurement (D15).
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
- **The table:** runtime, µs/req median and min..max per route at 7,000, at 9,500 for the finalists, p99, peak VmRSS
  under load, max connections and why it stopped, RSS per connection, and the response bytes of `/noop`. A
  `summarize.sh` builds it from the JSON, like phase 2's.
- **Then:** "Did the predictions hold?", one line each, and runtimes.md's flip rule: is patched Workerman within 30 %
  of Swoole on `/noop`?

## Predictions (D5)

Written by the project manager on 2026-11-21 at 16:29, before any phase 3 measurement. Arm64, Docker Desktop on an
M3 Pro, quiet VM, PHP 8.5, 1 CPU.

**What we start from:** the no-op Swoole server cost 50.2, 30.2 and 21.7 µs/req at 1k, 3k and 6k req/s on 8.3-apt,
on a **busy** VM. On the quiet VM the micro sample landed every swinging row on its slow level (D15), so quiet-VM
numbers may come out higher than busy-VM ones. mattsplat measured 54k req/s closed loop on one Apple Silicon core;
tzimpel saw 2 Swoole workers cost 27 % more per request and the stock 64 KiB receive buffer kill the worker at about
38k connections; HolyPHP measured fewer header bytes as part of a 9 % round.

1. **Swoole `/noop` at 7,000 req/s: 18 to 35 µs/req.** The busy-VM trend gives about 20 at 7k; the quiet VM may add up
   to 1.5x.
2. **`/posts/:id` costs 5 to 15 µs/req more than `/noop` on every runtime**, and the same amount (within 3 µs) on all
   three: the handler is the same code, so the gap between runtimes should be the same on both routes.
3. **Workerman with its caches out costs 30 to 70 % more than Swoole on `/noop`.** Its HTTP parsing, `Request` and
   `Response` objects and its connection object run in PHP. So runtimes.md's flip rule (within 30 % of Swoole) **fails**.
4. **Workerman's caches buy 10 to 25 % on `/noop`** (every request has the same bytes, so the cache always hits) **and
   under 5 % on posts.js** (each id appears once in a while, so the cache rarely hits).
5. **DIY lands within 15 % of Swoole on `/noop`, either side.** It runs more PHP than Swoole per request but builds no
   objects and sends 2 headers instead of 5. So the finalists are **Swoole and DIY**.
6. **At 9,500 req/s, µs/req is 5 to 15 % lower than at 7,000** for both finalists: the trend of phase 2 (fixed costs
   spread over more requests per wake-up).
7. **Max connections:** Swoole stops on **memory, between 25,000 and 40,000** (OOM kill), from its 64 KiB receive
   buffer per connection; Workerman and DIY stop on the **fd limit, above 65,000**.
8. **RSS per connection:** Swoole **60 to 80 KiB**, Workerman **3 to 10 KiB**, DIY **1 to 4 KiB**.
9. **p99 at 7,000:** under 3 ms on all three on both routes, with Workerman the highest.

## Out of scope

- **µs/req with many connections held** (1k, 30k, 65k open while the rate runs): it's S1 in phase 4 (steps.md). Phase 3
  measures CPU and connections separately. This path isn't touched.
- **Swoole's receive-buffer patch (tzimpel) and `Connection: close` shedding:** S1 variants, phase 4. Phase 3 measures
  stock Swoole, so its connection number is the one to beat.
- **Several workers, `SO_REUSEPORT`:** S1-b, phase 4. Every server here runs one worker.
- **JWT, writes, the feed:** phase 4 steps. The handler has two read routes only.
- **x86 numbers:** absolute numbers stay arm64 (D7). Moving to EC2 is a question for Jacob, not this phase.
- **Swoole on 8.6:** Q7.
