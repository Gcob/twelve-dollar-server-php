# lab/

The measuring lab of phases 2 to 4: scripts that build the same seed data and the same environment for every
measurement. Nothing in `lab/data/` is committed.

## Prerequisites (on the Mac)

- **Docker Desktop** running (the lab was built on 4.76 with its 12-CPU VM, cgroup v2). The images are built with
  `bash lab/build.sh all` (about 11 minutes, see `results/build-times.md`), and `lab/check.sh` fails until they are.
- **Node 18 or later** (24 here) and **`sqlite3`**: the seed generator is Node, and `lab/check.sh` reads the seed with `sqlite3`.
- **`jq`**: the macro harness builds and reads its JSON with it.
- The clone of the challenge in `reference/` (see Seed), and `curl`, `git`, `shasum` (they ship with macOS).

## Seed

```bash
bash lab/seed.sh
```

Builds the challenge's seed database from the clone in `reference/twelve-dollar-server-challenge/` (about 15 seconds
on an M3 Pro, about 250 MB) into `lab/data/feed.db` and `lab/data/tokens.json`. It must end with
`OK: ... content sha256 matches`. The clone is not ours; if it is missing:

```bash
git clone https://github.com/arjaythedev/twelve-dollar-server-challenge reference/twelve-dollar-server-challenge
```

## Images

```bash
bash lab/build.sh 8.4          # builds php-lab:8.4, appends the time to lab/results/build-times.md
bash lab/build.sh all          # every variant, one after the other
bash lab/run.sh 8.4 php-info
```

`php-lab:<variant>` is an image of Ubuntu 24.04 (pinned by digest) with PHP and, when it builds, Swoole 6.2.6:

| Variant | PHP | Swoole | How it is built |
| --- | --- | --- | --- |
| `8.3-apt` | 8.3.6 (Ubuntu's package) | 6.2.6 | apt, plus Swoole from its tarball (`Dockerfile.8.3-apt`) |
| `8.3` | 8.3.37 | 6.2.6 | PHP from the php.net tarball (`Dockerfile.src`) |
| `8.4` | 8.4.28 | 6.2.6 | same |
| `8.5` | 8.5.13 | 6.2.6 | same |
| `8.6` | 8.6.0 | not built | same, `WITH_SWOOLE=0`: Swoole 6.2.6 does not compile on 8.6 (`results/swoole-on-php-8.6.md`) |

The source builds share one Dockerfile and the same configure flags (CLI only, `pdo_sqlite` on the system libsqlite3,
`mbstring`, `sodium`, `ffi`, `ctype`, `iconv`, OPcache with its JIT, `CFLAGS=-O2`; the reason for each is in
`images/install-php-src.sh`). The PHP version, its sha256 (the one php.net publishes) and the Swoole switch of each
variant are in `lab/lib.sh`; the build stops if the tarball does not match. `8.3` next to `8.3-apt` is a control:
same PHP branch, Ubuntu's build flags against ours.
The times in `results/build-times.md` are one build after the other (`8.6` is shorter: no Swoole to compile).

An unknown variant exits non-zero and lists the known ones. `lab/run.sh` runs a command in the image with 1 CPU, 2 GiB,
no swap, 65535 file descriptors, on the host network, pinned to CPU 2; `lab/` is mounted at `/lab` (read-only, except
`lab/results/` and `lab/data/`). The CPU layout and the limits live in `lab/lib.sh`, shared by every lab script.
`php-info` prints the PHP, Swoole and SQLite versions, OPcache and JIT, and which extensions are present (`swoole:
not built` when the image has no Swoole), then `pcntl`, `sockets`, `event` (its version, or `not built`), `excimer` (the same) and the
Workerman version of its two trees (`workerman: 5.2.4 (stock, nocache)`).

### Extensions and Workerman

The layer of `Dockerfile.src` after Swoole (`images/install-extras.sh`, about 12 to 14 s to build) reuses PHP and Swoole's layers when it
changes, and the profiler has a layer after it (`images/install-excimer.sh`, about 14 s) so that building Excimer does not rerun this
script's `apt-get update` and could not move libevent between two measurements; a `php-info` change rebuilds in under a second. The extras add,
on every source image (8.3 to 8.6; `8.3-apt` is left as it was, nothing in the lab runs Workerman or the hand-written server on it):

| What | Version | Built from |
| --- | --- | --- |
| `pcntl`, `sockets` | the image's PHP | shared extensions, `phpize` on **the php.net tarball and sha256 the image's PHP was built from**, `CFLAGS=-O2` |
| `event` (PECL) | 3.2.0 | shared extension, `phpize`, against Ubuntu's `libevent-dev`, with `sockets` support; no OpenSSL, no pthreads |
| Workerman | 5.2.4 | the GitHub tag tarball, with `workerman/coroutine` 1.1.7 (the release its `composer.json` accepts) |
| `excimer` (PECL) | 1.2.6 | shared extension, `phpize`, in a layer of its own after this one (`images/install-excimer.sh`, `WITH_EXCIMER`): see "The profile" |

Every download is pinned by sha256 in the script, and the build stops on a mismatch. None of the three extensions is enabled
globally: a server loads them with `-d extension=...` (`--ext` of `macro.sh`, `conformance.sh` and `conns.sh`), **in this
order**, because `event` declares `sockets` as a dependency and PHP refuses to load it first:

```bash
php -d extension=pcntl -d extension=sockets -d extension=event server.php
```

`event` builds on PHP 8.6 as well (the switch `WITH_EVENT` in `lab_source_release` stays, in case a later PHP breaks it).
Workerman needs `pcntl` and `posix` to start (`posix` is built in), and runs on ext-event because its fallback, the `select()`
loop, is capped at 1,024 descriptors.

**Two Workerman trees**, so a run can show what its request caches buy:

- `/opt/workerman/stock`: Workerman as released.
- `/opt/workerman/nocache`: the same tree with `images/workerman-nocache.patch` applied. The 5 request caches are
  function-local `static` variables: `static $requests` in `TcpConnection::baseRead()`, and `static $cache` in `Http::input()`
  and in `Request::parseHeaders()`, `parseGet()` and `parsePost()`. The patch deletes them and their lookups; the code
  computes what it would have cached, every time, and nothing else changes. **The build fails** if the patch does not apply
  without fuzz, if the stock tree does not hold exactly those 5 statics, or if one is left in the patched tree.

Each tree has `<tree>/autoload.php`, a small PSR-4 autoloader with no Composer (`require '/opt/workerman/stock/autoload.php';`).
It follows the two `composer.json` files: `Workerman\Coroutine\` is the coroutine package's `src/`, and `Workerman\` is
looked up in Workerman's `src/`, then in the coroutine package's `src/`. A server file picks its tree and requires that file.
Both trees declare the same classes, so one PHP process can load only one of them.

`bash lab/run.sh 8.5 php /lab/servers/workerman-caches.php` proves the patch: a child process per tree pushes the same
request (a query string and a form body) through Workerman's HTTP protocol twice, over a socket pair, then reads the 5
statics with `ReflectionMethod::getStaticVariables()`. It prints `filled` or `empty` per cache and tree, and exits 0 only
if all 5 are filled on `stock` and all 5 empty on `nocache`.

A trap: Workerman ignores a request's `Connection: close` (it answers `Connection: keep-alive` and keeps the connection open),
so a client that reads until the server closes (PHP's `file_get_contents('http://...')`) waits for its own timeout (PHP's
`default_socket_timeout`, 60 s). Checked with a raw socket that sent `Connection: close` and waited 100 s: the answer came at
once, then nothing, and the client's timeout ended the wait, with no close from the server. Close from the handler
(`$connection->close($response)`) when a client needs it. `servers/bake-workerman.php` does not need it: the harnesses' clients
keep their connections open and never read until the server closes.

## Micro benchmarks

```bash
bash lab/micro.sh lab/micro/benches/sample.php                      # every image, JIT off then on
bash lab/micro.sh lab/micro/benches/sample.php --images 8.4,8.5 --jit on --out /tmp/run.json
```

Options: `--images a,b,...` (default: every variant), `--jit on|off|both` (default `both`), `--out <path>` (default
`lab/results/micro-<bench>-<UTC date and time>.json`), `--procs N` (processes per case, default 5), `--jit-buffer-size
64M`, `--quick` (short timing and 2 processes, for smoke checks: never a result). The bench file must be under `lab/` (it is mounted in the container).

It runs the bench through `lab/run.sh` (1 CPU, 2 GiB, pinned to CPU 2), **one image at a time**: never start two benches
at once, they would share the CPU. It exits non-zero on an unknown image, a missing image, a bad argument, or a JIT
state that is not the one requested. A case whose check fails is reported and skipped, and the exit code stays 0: look
for `SKIPPED` in the rows.

### The bench file

A PHP file that returns an array of named cases:

```php
<?php
return [
    'json_encode small array' => [
        'setup' => fn() => ['id' => 42, 'name' => 'ada'],      // optional, runs once, outside the timing
        'run'   => fn(array $post) => json_encode($post),      // the timed code; gets the setup's return value
        'check' => fn($result) => $result === '{"id":42,"name":"ada"}',
    ],
];
```

- `run` is called once before any timing and its result goes to `check(result, setup's value)`, which returns `true`, or
  `false`, or a string that is the failure message (a thrown exception also fails the case). `check` is required: a
  fast wrong variant is discarded, not ranked.
- The result of `run` is stored after each call, so the work cannot be optimized away. Return what the code computed.
- Names are free text; use `step/variant` (`routing/regex`) so the output sorts by step.
- `micro_feed_copy()` returns the path of a copy of `lab/data/feed.db` made once per run inside the container (about
  250 MB, kept for the cases that follow): `'setup' => fn() => new PDO('sqlite:' . micro_feed_copy())`. A bench that
  writes should copy that file again. Never open `lab/data/feed.db` itself: it is in WAL mode and leaves `-wal`/`-shm`
  files in `lab/data/`.
- `micro/benches/sample.php` is the format in use; `failing-check.php` is the fixture `lab/check.sh` uses.

### How it measures

- **One fresh PHP process per case, and each case in K processes (`--procs`, default 5).** The tracing JIT compiles the
  timing loop for the closure it saw first; timing the next case in the same process would make its number depend on the
  cases before it. The K processes are run round by round: round 1 runs every case with JIT off then on, then round 2
  does the same, and so on, so a slow period of the host hits every case alike. A run of 5 processes takes about 41 s
  per image and JIT state for the sample bench (about 82 s per image, from the committed sample run's start and end time).
- **Warm-up:** at least 1 s of the real loop (100 ms with `--quick`), which also finds N, the iteration count that makes
  one repeat last about 100 ms (10 ms with `--quick`). N is shown in the output.
- **Timing:** in each process, `hrtime(true)` around N iterations, 10 repeats, `gc_collect_cycles()` between them
  (outside the clock); the process's number is the median of its 10 repeats.
- **Reported:** the **median of the processes' medians** in ns/op, and the **spread across processes**: the smallest and
  the largest process median (`min .. max`). The JSON keeps, for each process, its median, its within-process spread
  (min, max) and its 10 sorted repeats.
- **UNSTABLE:** a case whose largest process median is more than 1.3 times its smallest gets `UNSTABLE xR` in the table
  (`unstable: true` and `max_over_min` in the JSON). Do not compare an unstable number between versions: run it again, or
  read the per-process medians first.
- **The loop's own cost** is the first row of every run, `(empty loop)`: the same loop calling a closure that returns
  `null`. It is **not subtracted** from the cases. Read a case as "this much, including about that much of loop". The
  loop costs less with JIT on, so a JIT gain on a very cheap case is partly the loop's.
- **OPcache and JIT:** every worker runs with `opcache.enable_cli=1`, `opcache.file_update_protection=0`,
  `opcache.memory_consumption=128`, `memory_limit=512M` and `zend.assertions=-1` (Ubuntu's `php.ini` sets it, the source
  images have no `php.ini`), whatever the image's own ini says. JIT on is
  `opcache.jit=tracing` with `opcache.jit_buffer_size=64M`; JIT off is `opcache.jit=disable` with the same buffer
  size (it works on 8.3 to 8.6, so that is the only setting that differs). The worker reads `opcache_get_status()['jit']`
  and exits non-zero if `on` is not what was requested (try `--jit on --jit-buffer-size 0`).
- **What OPcache caches in the CLI:** with no `opcache.file_cache`, the cache is the process's own shared memory: a script
  is cached once the process compiled it, and the cache dies with the process. The harness checks with
  `opcache_is_script_cached()` that `micro.php` and the bench file are cached (only cached code is JIT-compiled) and fails
  if not. Trap found: with the default `opcache.file_update_protection=2`, a file modified in the last 2 seconds is
  **not** cached, so a bench you just saved would run without JIT; the harness sets it to 0.

### Why the spread is across processes

The spread inside one process hides the real variance. With the first version of the harness (one process per case),
the same image and the same case (`ctype_digit "12345"`, 8.4, JIT on) gave medians of 27.8, 13.5, 28.0 and 27.3 ns in four
runs in a row, and `json_encode small array` gave 132.6, 135.1, 142.8 and 103.2 ns, while the min..max inside each run stayed
within about 10 %. Across images, `ctype_digit "12a"` with JIT on gave 26.6 ns on 8.3 and 11.3 ns on 8.4. Both modes are
steady inside a process, so the swing happens between processes.

The cause is **not established**. Hypotheses, untested except the first:

- *The JIT's code or memory layout differs between processes (ASLR).* One experiment, done once: the same worker 12 times
  with ASLR on and 12 times with ASLR off (`setarch -R`, verified: the stack and heap addresses were fixed), alternating, 8.4,
  JIT on, same case. ASLR on gave 27.4 28.2 27.5 13.2 13.1 28.0 28.2 13.1 27.2 26.7 28.8 28.3 (3 fast of 12); ASLR off gave
  27.6 26.7 27.4 28.2 27.0 28.2 13.1 27.1 28.5 27.0 27.5 27.2 (1 fast of 12). Two modes, about 13 and 27 ns, in both
  settings, so **ASLR alone does not explain it**. `setarch -R` is refused by Docker's default seccomp profile
  (`Operation not permitted`), so this needed `docker run --security-opt seccomp=unconfined` outside `lab/run.sh`.
- *macOS puts the Docker VM's vCPU on a performance core in some processes and on an efficiency core in others.* Not
  tested (the Mac gives no way to pin a core). It fits the 2x ratio and the two clean modes. The first full run with several
  processes (`results/micro-sample-20261121-1512.json`) points the same way: the slow mode also showed up with JIT off and on
  the empty loop (8.3-apt JIT off: `12.0 .. 25.4` ns), so it is not specific to JIT-compiled code. It does not prove it.
- *Which trace the JIT ends up with depends on timing during warm-up* (when the hot loop is compiled). Not tested.

Whatever the cause, the harness shows it instead of hiding it: several processes, the spread across them, and the
UNSTABLE flag.

**With the Docker VM quiet, the two modes went away.** The same sample, rerun with every other project's container
stopped (`results/micro-sample-20261121-1912.json`, 0 other containers, the Mac's load average 6.9 at the start), gave
1 UNSTABLE row of 40 instead of 28, and the largest process-to-process ratio of any other row was 1.16x. All 28 rows
that swung landed on their **slow** mode: `ctype_digit "12345"`, 8.4, JIT on, went from process medians of 13.4, 27.1,
27.0, 29.1 and 26.8 ns to 26.9, 27.2, 26.8, 28.2 and 27.3 ns. So the fast mode, not the slow one, came with the busy
VM. Why is still a hypothesis (a busy VM may keep the vCPU on a faster core or clock). What it means for the lab: measure
with the VM quiet (plan decision D15), and compare numbers only within the same conditions.

### Reading the output

```text
image   php      jit  case                                median ns/op  spread across procs         iterations  note
8.4     8.4.28   on   (empty loop)                                 5.2  5.1 .. 5.7                    19754482
8.4     8.4.28   on   ctype_digit "12345"                         20.5  13.1 .. 28.2                   7759183  UNSTABLE x2.15
```

One row per case, per image, per JIT state (the example above is made up to show the flag). The JSON file has the same numbers plus where they ran: the date, the exact
command (paths under the repo written relative), the Docker version and architecture, the CPU pinning and limits, and
for each run the image id (`docker image inspect` id of the local build), the PHP version, the JIT status as PHP reports it
and the ini values that matter. Numbers from another machine or another Docker version are not comparable with these.
`results/micro-sample-*.json` is the harness's first run: it proves the harness, not a step.

## Macro benchmarks

```bash
bash lab/macro.sh --image 8.4 --server lab/servers/noop-swoole.php --rate 2000 --duration 30
```

Loads a server running in a lab container with [k6](https://k6.io) at a **fixed request rate** (k6 starts `--rate`
requests per second whatever the server does, so a slow server shows up as latency and dropped iterations, not as a lower
rate), and reports what a request costs the server. Needs `jq` on the Mac. Options: `--warmup <s>` (default 10, same
rate, not measured), `--script <k6 js under lab/>` (default `lab/macro/k6/fixed-rate.js`), `--out <path>`,
`--port` (default 18080), `--path` (the URL path, default `/`), `--pre-vus` / `--max-vus` (default both `rate / 10`, at
least 50: see "VUs and connections"),
`--php-ini key=value` (added after the server's PHP flags, repeatable), `--ext <name>` (a PHP extension to load with
`-d extension=<name>`, repeatable, default `swoole`; giving one replaces the default), `--env K=V` (passed to the server
container with `-e`, repeatable) and `--label <text>` (letters, digits, `.`, `_`, `-`; goes in the JSON and in the default
file name after the server's name: `macro-<server>-<label>-<image>-...`). The JSON records `server.ext`, `server.env` and `label`;
Swoole's version is probed only when `swoole` is among the extensions. Three switches for the challenge app (see "The challenge
app on `macro.sh`" below): `--fresh-db`, `--cold` and `--per-second`.

`lab/servers/noop-swoole.php` is the floor: a Swoole HTTP server with the settings of the `php-swoole-mattsplat` entry
(`SWOOLE_BASE`, one worker, no coroutine, POST/cookie/file parsing and compression off) that answers `200 {"status":"ok"}`
to every request. The server runs with the PHP flags of mattsplat's `start.sh` plus two the lab pins
(`LAB_SERVER_PHP_FLAGS` in `lib.sh`): `opcache.file_update_protection=0` (by default a file saved less than 2 s before the
server starts is not cached, so it would run without OPcache and JIT, and the run would still look valid) and
`zend.assertions=-1` (Ubuntu's `php.ini` sets it; the source images have none and PHP's own default is 1). The JSON
records the ini values PHP reads back with these flags and whether the JIT is on (`server.ini`).

The other Swoole entry, tzimpel's, is configured differently, and the lab does not copy it: it runs `php -c php.ini` (64M
JIT buffer, `memory_limit=512M`, `opcache.validate_timestamps=0`, `zend.assertions=-1`) and sets `reactor_num`,
`open_tcp_nodelay`, `backlog` 8192 and `package_max_length`. The code adapted from mattsplat's entry is credited in
`lab/NOTICE.md`.

### Bake-off servers, the handler and the conformance test

The runtime bake-off compares runtimes (Swoole, Workerman, ext-event, a hand-written loop) serving the same two routes:
`GET /noop` (the runtime alone) and `GET /posts/:id` (the runtime plus one indexed read).

- **`lab/servers/handler.php`** is the one handler every runtime calls, so that runtimes differ by what they do around it. It
  holds no runtime code: `handler_handle($method, $path, $body)` returns `[status, body]`, `handler_boot()` copies the seed and
  opens it (`handler_copy_db()` and `handler_open_db()` are the two halves, for a runtime that forks workers: copy once before
  the fork, open in each worker). The routes and the error bodies are the challenge's (`{"error":"not found"}` for an unknown
  path or method, `invalid post id` with a 400 when `:id` is not a positive integer, `post not found` with a 404). The post query
  is the spec's with `WHERE p.id = ?`, prepared once at boot, with the pragmas of the `php-swoole-mattsplat` entry.
  **The database is a copy:** `lab/data/feed.db` is in WAL mode, so opening it would leave `-wal` and `-shm` files in `lab/data/`.
  The server containers mount `lab/data` read-only, and the first boot copies the seed (250 MB, a few seconds, before the server
  listens) to `/tmp/feed.db` inside the container. Side effect: `memory.peak` of a server that reads the database includes
  about 250 MB of page cache from that copy (about 500 MiB against 12 MiB for the no-op server). The handler also maps the database (`mmap_size` 256 MiB), so a server's
  `Pss` includes the database pages its requests touched: compare runtimes on `Pss_Anon` and `memory.current` (see "Memory under
  load" below), not on `Pss`.
- **`lab/servers/bake-swoole.php`** is the Swoole server on that handler: the settings of `noop-swoole.php` plus
  `open_tcp_nodelay`, `Content-Type: application/json`, the status the handler gives. Every bake-off server uses a listen
  backlog of 4,096 and TCP_NODELAY on. At boot it prints `socket: backlog=4096 tcp_nodelay=1`: the settings it asked for,
  as the images' Swoole is not built with sockets support and cannot read them back. `macro.sh`, `conns.sh` and
  `conformance.sh` copy that line into their output, and `macro.sh` and `conns.sh` into the JSON (`server.socket`). The three
  bake-off servers print the same two keys, `backlog` and `tcp_nodelay`.
- **`lab/servers/bake-workerman.php`** is the Workerman 5.2.4 server on that handler: one HTTP `Worker` (`count = 1`) on the
  Event loop, `Worker::$eventLoopClass` set to it explicitly. It reads `WORKERMAN_TREE`: `nocache` (the default, Workerman with
  its 5 request caches patched out) or `stock` (as released); any other value exits 1 with a message. It also exits 1 when
  `event` is not loaded, instead of letting Workerman fall back to `select()`. `onMessage` sends a `Response` object (status,
  `Content-Type: application/json`, the handler's body), the way Workerman's documentation does it: a plain string would always
  answer 200 `text/html`. Listen backlog 4,096 (the `backlog` socket context option); Workerman sets `TCP_NODELAY` itself on
  the listening socket when `sockets` is loaded. At boot the worker prints the tree, the loop class and
  `socket: backlog=4096 tcp_nodelay=1`, where `tcp_nodelay` is read back from the listening socket (`socket_get_option` on
  `socket_import_stream`) and the backlog is what was asked (the kernel does not give it back). Run it on each tree:

  ```bash
  bash lab/conformance.sh --image 8.5 --server lab/servers/bake-workerman.php --ext pcntl --ext sockets --ext event --env WORKERMAN_TREE=nocache
  bash lab/macro.sh --image 8.5 --server lab/servers/bake-workerman.php --ext pcntl --ext sockets --ext event \
    --env WORKERMAN_TREE=stock --label stock --rate 7000 --duration 20 --path /posts/1 --script lab/macro/k6/posts.js
  ```

  The extensions go in that order (`sockets` before `event`, which depends on it); `--label` puts the tree in the result's file
  name and JSON. **Two processes run in the container's cgroup:** Workerman's master (`WorkerMan: master process`, it only
  supervises) and its one worker. The CPU reading is the cgroup's, so it covers both; Pss and VmHWM are summed over every
  process of the cgroup; `conns.sh` reads memory the same way. The pid, status and log files are in `/tmp` (`/lab` is
  read-only), and the copy of the seed is made by the master before it forks, the SQLite handle opened by the worker.
- **`lab/servers/bake-diy.php`** is our own server on that handler: one process, our own event loop on ext-event and our own
  HTTP/1.1 parser, only what the challenge's routes need. Run it with `--ext sockets --ext event` (that order):

  ```bash
  bash lab/conformance.sh --image 8.5 --server lab/servers/bake-diy.php --ext sockets --ext event
  bash lab/macro.sh --image 8.5 --server lab/servers/bake-diy.php --ext sockets --ext event --label diy --rate 7000 \
    --duration 20 --path /posts/1 --script lab/macro/k6/posts.js
  ```

  - **The loop** (`diy-server.php`, shared with the challenge app): one `EventBase` (`epoll`); one persistent read event on the listening socket, which accepts
    until `accept()` has nothing left, so a burst of connections is taken in one callback; one persistent read event per
    connection; a write event only while a connection holds bytes the socket did not take. A connection's state is one small
    object (`DiyPeer`: its parser object and its two events) allocated at accept. A request
    allocates only its own strings (head, request line, method, target, body), the array `explode()` makes of its header lines,
    and its response. ext-event is used because PHP's `stream_select` is capped at 1,024 descriptors.
  - **The listening socket:** `stream_socket_server` with `backlog` 4,096 and `so_reuseport` off (one process), non-blocking;
    `TCP_NODELAY` is set on it with `socket_import_stream` and `socket_set_option`. At boot the server prints
    `socket: backlog=4096 tcp_nodelay=1` like the other two (the backlog is what was asked: the kernel does not give it back,
    `tcp_nodelay` is read back). **Accepted sockets inherit `TCP_NODELAY` from the listening socket on Linux**: the server
    reads it once from the first accepted socket and prints `accepted socket: tcp_nodelay=1` (the images show `1`).
  - **The parser** (`diy-connection.php`, class `DiyConnection`, which knows nothing about the loop and works on any
    non-blocking stream): on each read it appends to the connection's buffer, then, while the buffer holds a whole request,
    finds `\r\n\r\n`, reads the request line (method, target, `HTTP/1.1` or `HTTP/1.0`), reads `Content-Length`, `Connection` and
    `Transfer-Encoding` and `Authorization` (names compared without case) and waits for the whole body. It calls
    `handler_handle($method, $target, $body, $authorization)` (the bake-off's handler takes the first three and ignores the
    fourth; the target keeps its `?query`, which the handler cuts) and appends the response to the write buffer. The answer is
    `HTTP/1.1 <status> <reason>`, `Content-Type: application/json`, `Content-Length`, nothing else (the statuses it knows are 200,
    201, 400, 401, 404, 500 and 503). The `Authorization` value is handed over without its surrounding spaces, `''` when the request
    has none.
  - **What it refuses with `400 {"error":"bad request"}` and a close:** a request line that does not have a method, a target and
    `HTTP/1.1` or `HTTP/1.0`; a header line without a name and a colon; a block of request line and headers over 8 KiB (checked
    before the blank line arrives too, so a client that never ends its headers is cut at 8 KiB); a `Content-Length` that is not
    plain digits, appears twice, or is over 1 MiB (a bound on one connection's memory; the challenge's bodies are tiny);
    `Transfer-Encoding` of any kind (k6 never sends a chunked body). **What it does not read:** other headers (a line only has to have a name and a colon), absolute-form targets (the handler answers 404), lines ended by a
    bare `\n`.
  - **Keep-alive:** on by default on `HTTP/1.1`. `Connection: close` closes the connection after its response is fully written,
    and what the client sent after that request is not answered; so does `HTTP/1.0` without `Connection: keep-alive`. An
    `HTTP/1.0` client that asks for keep-alive keeps the connection open but the answer carries no `Connection` header, so
    most such clients close on their own.
  - **Writes:** `fwrite` as much as the socket takes; the rest stays in the connection's write buffer and a write event waits for
    the socket. While the buffer holds 1 MiB or more, the connection stops reading **and stops answering requests it already
    received** (they stay in its read buffer) until the buffer drops under the limit: a client that never reads cannot make the
    server's memory grow past 1 MiB plus one response. A client that closes, or a write that fails, frees the connection's
    events and its stream at once, with the bytes it did not take. At the descriptor limit `accept()` fails and the listening event
    fires again at once: shedding there is for a later phase.
  - **Two tests, run by `lab/check.sh`:** `lab/check/diy-parser-test.php` feeds `DiyConnection` through a socket pair and compares
    the responses with literal expected bytes: a request complete, **cut at every byte position** (two pieces), two requests
    pipelined (also cut everywhere), a body split from its headers, the `Connection` and `HTTP/1.0` rules, every kind of 400 above
    and a client that leaves. `lab/check/diy-partial-write-test.php` uses a socket pair whose client end does not read: on a Linux
    pair the kernel takes 212,992 bytes, so a 640,075-byte response is written in part, the rest waits in the buffer, and the bytes
    then arrive whole and in order; with two 2 MB responses and a third request queued behind them, reading pauses and the third
    request is answered only after the buffer drains. (End to end on loopback the buffers grow to megabytes, so that path would
    never run.) Run one by hand with `bash lab/run.sh 8.5 php /lab/check/diy-parser-test.php`.
- **`lab/conformance.sh`** proves that a server speaks HTTP/1.1 correctly with that handler:

  ```bash
  bash lab/conformance.sh --image 8.5 --server lab/servers/bake-swoole.php [--ext <name>]... [--env K=V]... [--port 18090]
  ```

  It starts the server like `macro.sh` does (`lab_start_server` in `lib.sh`) and runs `lab/conformance/client.php`, which
  uses raw sockets (no curl), in a second container on the same host network. One line per case, `ok    <case>` or
  `FAIL  <case>: <why>`, exit 1 if one fails; both containers are removed whatever happens. The cases: `noop` (200, the exact
  body, `Content-Type: application/json`); `post 1` (the same JSON values, with the same types and key order, as `sqlite3`
  gives on the Mac for post 1 with the same query); `errors` (the 404 and 400 bodies, `/posts/1/like`, `/posts/`);
  `keep-alive` (two requests on one connection); `pipelining` (three requests in one write, answered in order);
  `split request` (cut in the middle of the headers, 50 ms apart); `body then reuse` (a `POST /nope` with a body, then a
  `GET /noop` on the same connection); `response bytes` (prints the exact bytes of the `/noop` response: each runtime keeps
  its own headers). It ends with the event loop the server printed at boot (`loop: ...`, when it prints one: Workerman, DIY) and
  its socket line.
- **`lab/macro/k6/posts.js`** is `fixed-rate.js` for `GET /posts/<id>`: the id is the iteration number times 999,983 (a prime),
  modulo 500,000, plus 1, so the sequence over the seed's post ids is the same on every run and uses no random number. It
  takes the scheme, host and port of `--path`'s URL, so `--path /posts/1` makes the readiness check read the database too.

```bash
bash lab/macro.sh --image 8.5 --server lab/servers/bake-swoole.php --rate 7000 --duration 20 --path /posts/1 \
  --script lab/macro/k6/posts.js
```

### Quiet VM

A measurement next to other work is not comparable with one on a quiet VM. Just before the measured run, `macro.sh` lists the
running containers that are not its own three (whoever started them, another checkout's lab run included) and writes how
many in the JSON (`other_containers`: `count`, never the names: they belong to other projects and the results are committed).
Above 0, it prints `WARNING: N other containers running: see docker ps` when it reads them and again before the verdict.
The run completes and its validity does not change: a smoke run is not a measurement,
and whether the VM is quiet enough is for whoever reads the results to judge. `macro.sh` and `conns.sh` do the same; `micro.sh` does not.

### Layout

Three containers, all `--network host` inside Docker's VM. **Never run k6 on macOS itself**: Docker Desktop forwards a
port from the Mac into its VM through a userspace proxy, which would pollute every number.

| Container          | Image                         | CPUs                 | Limits                                |
|--------------------|-------------------------------|----------------------|---------------------------------------|
| `lab-macro-server` | `php-lab:<image>`             | `2` (`LAB_CPUSET_SERVER`) | 1 CPU, 2 GiB, no swap, 65535 fds (the lab's) |
| `lab-macro-k6`     | `grafana/k6` 1.8.3 by digest  | `4-11` (`LAB_CPUSET_K6`)  | none of its own                       |
| `lab-macro-probe`  | `php-lab:<image>`, sleeping   | `0-1` (`LAB_CPUSET_PROBE`) | none                                  |

The three have fixed names: a run refuses to start if one exists (a killed run, or another run in progress), and tells
you the `docker rm -f` to run. The three are removed at the end of every run that started, whatever happens (a `trap`).
The k6 image is pinned by tag **and** digest in `lib.sh` (`LAB_K6_IMAGE`; the 1.x line, 2.x exists). k6 runs as
`docker exec` in a container that stays alive, so its cgroup still exists when its CPU is read after the run.

### How the numbers are computed

- **How `cpu.stat` is read: from outside the cgroup.** The probe container has `--cgroupns host --pid host`, so it
  sees the VM's whole cgroup tree and every process. It reads `/sys/fs/cgroup/docker/<server id>/cpu.stat` itself, so the
  read costs the server nothing (a `docker exec <server> cat ...` would run inside the server's cgroup and land in the
  measure). The probe sits on CPUs 0 and 1, away from the server and k6. The probe's script is `lab/macro/probe.sh`.
- **µs CPU per request** = (`usage_usec` of the server's cgroup after the measured run, minus before) / (the
  `http_reqs` count of that run, from k6's `--summary-export`). The window between the two reads is a few hundred ms longer
  than the run (starting and stopping k6). The server's idle cost is measured too, over 2 s right after the warm-up
  (`server_idle_usec_per_s`, 45 to 290 µs per second in trial runs, against about 38 ms of CPU per second under load, so it does not move the number). The connections k6 opens
  at the start of the run are in the measure.
- **Latency** p50, p95, p99, max, from k6's `http_req_duration` (ms, as k6 measures it; k6 is on the same machine).
- **Connections open** = the established connections to the server's port, counted from the probe in `/proc/net/tcp` at 1/4, 1/2
  and 3/4 of the measured run (the table shows the largest, the JSON keeps the three). **VUs running at once** = the maximum
  of k6's `vus` gauge: how many iterations were in flight together, which is not the number of connections (see below).
- **Memory under load, `Pss_Anon` and `Pss`.** The probe reads the sums of `Pss_Anon` and of `Pss` from
  `/proc/<pid>/smaps_rollup` over the server's processes, and the cgroup's `memory.current`, at 1/4, 1/2 and 3/4 of the measured
  run (the JSON keeps the three in `results.memory.under_load`, with `max_pss_anon_mib` and `max_pss_mib`; the table shows the
  largest of each). **Compare runtimes on `Pss_Anon` (heap and stacks, no file pages) and on `memory.current`, not on `Pss`:**
  `Pss` counts the file pages a process maps, and the handler maps the SQLite database (`mmap_size`), so `Pss` grows with the
  rows the requests touched (the same server read 74 MiB on `/noop` and 182 MiB on `/posts/<id>`): it depends on the request
  count and the ids, not on the runtime. `Pss` is kept as "including the mapped database". Both split a page that several
  processes share between them, where `VmHWM` counts shared libraries and mapped files in full and `memory.peak` counts page
  cache, so a runtime that forks workers is comparable with one that does not.
- **Peak RSS**, two numbers, because they differ: the server cgroup's `memory.peak` (counts page cache charged to the
  cgroup) and the highest `VmHWM` of the processes in the cgroup (`/proc/<pid>/status`, counts the pages the process maps,
  shared libraries included). Both cover the whole life of the server, warm-up included. In trial runs `VmHWM` was about
  twice `memory.peak` (26 vs 12 MiB); a likely reason is that the image's file pages were charged to the cgroup that read
  them first, not to the server (not checked).
- **k6's own CPU** = its container's `usage_usec` delta over the same window, as a percent of one CPU. In trial runs k6
  used about 50 % of one CPU at 2,000 req/s with 8 CPUs of room: it is not the bottleneck. Check this number whenever
  the rate goes up.
- The server's `throttled_usec` over the window is in the output too (non-zero means the 1 CPU limit cut the server).

### VUs and connections

k6 gives each iteration to a VU that is idle at that instant, and **drops the iteration when no VU is idle** (the
executor does a non-blocking send on an unbuffered channel, `TryRunIteration` in `lib/executor/ramping_arrival_rate.go`,
used by `constant_arrival_rate.go`; k6 1.8.3). Idle VUs queue in first-in first-out order, so the iterations rotate over **all**
the pre-allocated VUs: the connections open equal the pre-allocated VUs (checked: 50 VUs, 50 connections; 500 VUs, 500
connections), even when only 4 to 8 iterations are ever in flight. The harness used to report the in-flight maximum as
"VUs used (open connections)", which was wrong; it now reports both.

Why iterations were dropped with a handful of VUs in flight: about once per 30 s run, something stalls for tens of
ms (the largest request latency of a run is the stall: 14 to 40 ms in the trial runs, on the server or the VM; not found
which), and at 2,000 req/s a 37 ms stall starts 74 iterations that all wait. With 50 VUs, the 24 extra are dropped (a run with a max
latency of 36.6 ms dropped 24, one with 39.6 ms dropped 27; shorter stalls dropped 1 to 11, which this does not explain
exactly). With enough VUs the same stall is absorbed and shows up as latency (`latency max`, p99). So the default is
**VUs = rate / 10 (100 ms of requests), at least 50, all started before the test**: 200 at 2,000 req/s. An unplanned VU (when
`--max-vus` is above `--pre-vus`) is initialized during the run and drops iterations while it does.

Numbers behind the default (8.3-apt, noop server, 2,000 req/s, `lab/macro.sh --pre-vus N --max-vus N`):

- 50 VUs, 30 s: 4 runs of 5 had drops (11, 1, 1 and 27; one had 0), and 1 run of 3 at 20 s (24).
- 200 VUs, 20 s: 0 drops in 3 runs. 500 VUs, 30 s and 20 s: 0 drops in 8 runs (max latency 6 to 41 ms).
- CPU per request did not follow the connection count: 34.4 to 39.9 us at 50 VUs, 34.8 to 36.2 at 200, 32.5 to 41.0 at 500 (the
  noise is larger than any effect). If a later server is sensitive to the number of connections, set `--pre-vus`.

### Validity

A run with an **error rate above 0 %** or **`dropped_iterations` above 0** is still printed and written, but is marked
`INVALID: <reasons>` in the table and `"valid": false` in the JSON, and `lab/macro.sh` exits 3. Dropped iterations mean k6
had no free VU to start requests at the requested rate (a stall longer than the VUs absorb, or a server too slow), so the rate
that was measured is not the rate that was asked for; the message says how long a stall the VUs absorb and the largest latency of the run. Exit 1 is any other failure (bad argument, the server did not answer, k6
failed); exit 2 is a usage error.

### Reading the output

```text
image 8.4 (PHP 8.4.28, Swoole 6.2.6), noop-swoole.php, k6 v1.8.3 (...)
requested 2000 req/s for 30s (warm-up 10s), target http://127.0.0.1:18080/
  requests                     60001
  CPU us / request             38.67
  latency ms p50 / p95 / p99   0.19 / 0.6 / 1.58
  error rate                   0.00%
  dropped iterations           0
  ...
VALID
```

The JSON (`results/macro-<server>-<image>-<rate>rps-<UTC date and time>.json`) holds the same numbers, where it ran
(Docker Desktop and engine versions, the VM's kernel, CPU layout, limits), the image id, the PHP and Swoole versions, the
PHP flags, the k6 image by digest and its version, the exact command, and under `raw` everything the numbers come from:
both `cpu.stat` snapshots (before and after the measured run, and around the idle window), the memory files, and k6's
full summaries of the measured run and the warm-up. Numbers from another machine or Docker version are not comparable.

### Traps

- **Ports 8080 and 80 are usually taken on the VM's host network** by other containers (a Swoole server that cannot bind
  dies at once, but a "wait until it answers" would have succeeded against the other server). The default port is 18080,
  and the run refuses a port that already accepts connections before starting the server.
- **The same case can swing about 2x from one process to the next on this Mac** (see "Why the spread is across processes").
  The macro numbers can swing the same way: repeat a run, and compare the JSON files, before trusting one number.
- k6 1.x is pinned, but the `--summary-export` format is read by key (`http_reqs.count`, `http_req_duration.med`,
  `vus.max`, `dropped_iterations.count`, which k6 leaves out when it is 0): re-check them when the pin moves.
- Do not start an image build or another benchmark during a measured run: they share the VM's CPUs and its memory bus.

## The challenge app and its test

`lab/app/` is the challenge's five endpoints (`GET /health`, `GET /feed`, `GET /posts/:id`, `POST /posts`,
`POST /posts/:id/like`, as `reference/twelve-dollar-server-challenge/SPEC.md` says) served by the DIY loop, with the simplest
variant of every step of a request, on purpose: later work measures the alternatives one by one.

- **`lab/app/server.php`** is the entry, started like a challenge submission: `SQLITE_PATH` (the file it opens, never a copy),
  `JWT_SECRET`, `HOST` (default `0.0.0.0`) and `PORT` (default 8080), with `--ext sockets --ext event`. It listens only once the
  database is open and prints the same boot lines as the bake-off's DIY server (`listening on`, `loop:`, `socket:`).
  **`lab/app/app.php`** holds the work, one function per step so that a profiler can tell them apart: `handler_handle` (the
  route, a plain match), `jwt_verify`, `id_validate`, `body_validate`, `feed_query`, `post_query`, `post_insert`, `post_exists`,
  `like_insert`, `feed_json`, `post_json`, `like_json`, `health_json`, `response_json`, `response_error`. Parsing and writing are
  `DiyConnection`'s. The SQL is the spec's reference SQL; every write is its own autocommit transaction, committed before the
  response is built; the pragmas are the bake-off handler's. Every token is verified on every request, and a token without `exp`
  is rejected. `lab/check/app-test.php` covers what the challenge's suite does not (the JWT and body rules, one like per user,
  the feed's order).
- **`lab_start_app`** (`lab/lib.sh`) is how a harness starts the app on a fresh database: it copies `lab/data/feed.db` **with
  `cp` inside the server container** (the copy's page cache is charged to the server's cgroup, like the bake-off's copy), runs
  `sync` on the copy, then starts the app with `SQLITE_PATH` pointing at it. `lab/data/` is mounted read-only and never written.
- **`lab/challenge-test.sh`** runs the challenge's own `test/test.sh`, unchanged, against it:

  ```bash
  bash lab/challenge-test.sh --image 8.5 [--server lab/app/server.php] [--ext sockets --ext event] [--port 18110]
  ```

  It starts the server on a fresh copy, waits for `GET /health` (60 s at most, like the challenge's `test/run.sh`), prints the
  suite's output and exits with its code (`passed=42 failed=0`, exit 0). Both containers are removed at the end, whatever
  happens. Run it twice in a row: each run has its own copy, so the second passes as well (the suite's golden answers fail on a
  database a first run wrote to). `--server` takes any file that reads the same environment: `lab/check/fixtures/wrong-golden-app.php`
  is the real app on a database with one post changed, and `lab/check.sh` checks that the harness fails on it and names the check.
- **Where the suite runs:** in a container on the host network, from the image `php-lab-tools:1` (`lab/images/Dockerfile.tools`:
  Ubuntu 24.04 by digest, plus bash, curl, jq and openssl, which `test.sh` needs and the php-lab images lack: no `jq`). It is built
  the first time (`lab_ensure_tools_image`). Docker Desktop does not publish a host-network container's ports to macOS unless
  its host networking setting is on, and a harness must not change that setting, so running `test.sh` from the Mac does not work
  here. No published image was used for the four tools: building them from the pinned Ubuntu is less to trust than a third-party
  image.

## The realistic mode

```bash
bash lab/realistic.sh --image 8.5 --think-scale 0.03 --staircase 2000,2000,12000,60   # req/s: from, step, to, s per plateau
bash lab/realistic.sh --image 8.5 --think-scale 0.03 --hold 10000,300                  # req/s, seconds of the plateau
bash lab/realistic.sh --image 8.5 --think-scale 0.03 --calibrate                       # k6's memory per VU, the VU cap, the scale
```

Loads the challenge app (`lab/app/server.php`, started on a fresh copy of the seed) the way the challenge's bench does. k6 runs
**the bench's own script**: `lab/macro/k6/realistic.js` is a copy of `reference/twelve-dollar-server-challenge/bench/load.js`
(the loop: the feed, a post from it, 15 % like, 2 % new post, think time between; the tokens of `lab/data/tokens.json`; the
`name` tags) with **two changes**, both named in its header: every `sleep(x)` is `sleep(x * THINK_SCALE)`, and `options` come
from the environment (`REALISTIC_OPTIONS`, built by the harness). `check_realistic_script_is_the_benchs` in `lab/check.sh` diffs
the copy against `load.js` and fails on any other change, an unscaled sleep included. The MIT credit is in `lab/NOTICE.md`.

### The numbers of the journey

- One loop is **2.17 requests** (1 feed + 1 post + 0.15 like + 0.02 new post) and **20.5 s of mean think time** (5 + 5.5 + 10).
  One VU offers `2.17 / (20.5 * scale)` req/s; the harness turns a rate into VUs with `rate * 20.5 * scale / 2.17`, rounded up.
- A steady load is **9.45 users per req/s** (20.5 / 2.17). **Users are always mapped from the achieved rate** (`users` in the
  table is `9.45 * achieved`), never from the VUs and never with 10.8 (the leaderboard's 10.8 includes the bench's ramps).
- With the think time scaled by `s`, a few thousand VUs make the rate of the bench's many more. The price: latency weighs
  `1 / s` times more in a VU's loop (a request that takes 10 ms stretches a loop of 0.6 s by 3 %, not a loop of 20 s by 0.1 %).

### A step passes, or fails with its reason

A step is judged **on its plateau only**. It passes when **p95 < 500 ms, p99 < 1 s, errors < 1 % and achieved >= 97 % of offered**
(offered = VUs times the per-VU rate; achieved = the requests of the plateau over its seconds). The 97 % rule is there because
the bench's own thresholds are not enough once think time is scaled: a VU that waits longer for a response offers less load, so
the latency thresholds alone pass loads far past saturation (at `s = 0.02`, 3.6 times the VUs of the knee). A failing step prints
its reasons (`achieved below 97 % of offered` comes first when it is one) and **the staircase stops there**: the aggregator judges
each step as it ends and the harness stops k6. A failing step is a result, not an error: the exit code stays 0.

The pass rule spends 3 % of the offered rate, which is about `0.29 * s` seconds of mean latency per request (a request that
takes longer than that makes the VU's loop long enough to fall under 97 %).

### Layout and the live stream

| Container            | What                                                                                           | CPUs   |
|----------------------|------------------------------------------------------------------------------------------------|--------|
| `lab-realistic-server` | `php-lab:<image>` running the app, 1 CPU, 2 GiB                                              | `2`    |
| `lab-realistic-k6`   | the pinned k6, `--memory` at the budget below, `--local-ips` 127.0.1.1-4, CSV out to a FIFO    | `4-11` |
| `lab-realistic-agg`  | `lab/macro/aggregate.php` (PHP): reads the FIFO, judges steps, reads the cgroups every second  | `4-11` |
| `lab-realistic-probe`| memory and `/proc` from outside, the aggregator's status once a second                         | `0-1`  |

A named volume (`lab-realistic-run`) holds the FIFO, the aggregator's status and its result: removed at the end, like the
containers, whatever happens (a `trap`). **Nothing raw goes to disk**: k6's CSV (about 12 rows per request) goes into the FIFO and
the aggregator keeps, per second and per endpoint (the `name` tag), a latency histogram with log buckets (1.5 % wide, a latency is
read back within 0.75 %), the counts and the errors. A step's p95 and p99 are the merge of its seconds' histograms. It parses only
the `http_req_duration` rows (one per request: latency, second, name, `expected_response`) and the `vus` rows; a duration row it
cannot parse is counted (`unparsed`) and makes the run invalid. The request count is the number of duration rows, the same as
k6's `http_reqs` (checked against k6's own summary in `check_realistic_staircase_passes`: the same count, p95 within 3 %).

- **The plateau** comes from k6's `vus` gauge (a row each second): the seconds where it reads the step's VUs, without the first and
  the last (the ramp may have ended, or the next one started, inside them). A step is judged once a sample of the next second
  arrived.
- **The server's CPU per request** is read by the aggregator from the server's `cpu.stat` on every whole second (the aggregator
  has `--cgroupns host`, like the probe), so a window's CPU is the difference between two readings on the plateau's edges, scaled
  by the time between them, over the requests of the same whole seconds. No `docker exec` sits on the measuring path.
- **k6's ports:** k6 binds its own source addresses (`--local-ips 127.0.1.1-127.0.1.4`, recorded in the JSON as `k6.local_ips`, with
  the addresses the server saw in `k6.client_ips_seen`): the next measurement holds 60,000 idle connections from a client that
  `bind()`s its ports, and a port that is bound is skipped by any `connect()` that is not, so k6 on one address would run out.
  k6 1.8.3 accepts loopback addresses.

### The guard: lag and memory

k6 does not slow down when its CSV reader falls behind: it buffers the samples in its own memory. So:

- **The aggregator's lag** is the clock against the newest sample's second, written to the status every second. A run whose lag
  passes the gate (`--lag-gate`, default 6 s) is **invalid** with that reason, and k6 is stopped. The lag at low load is about
  1.0 to 1.8 s: the CSV's timestamps are whole seconds, k6 flushes every 250 ms (`K6_CSV_SAVE_INTERVAL`, the default is 1 s), and
  the aggregator reads the clock on whole seconds. The gate is the lag measured in calibration plus 2 s.
- **k6's memory** has a budget: the VM's memory minus 2 GiB (the server), 512 MiB (the client that holds the idle connections:
  257 MiB measured with 60,000 of them, so a margin of 2 times) and 1 GiB of margin, set as the container's `--memory`
  (`--k6-memory <MiB>` sets it by hand, a test hook). A run whose k6 reaches 95 % of it, or is killed for it, is **invalid**.
- **k6's memory also grows with the request count:** about 190 bytes a request on top of 0.34 MiB a VU (k6 keeps every sample of its
  trend metrics for the end-of-run percentiles). A run of about 12 million requests with 5,134 VUs reached the budget at 4.1 GiB and was
  killed (`INVALID`): at 18,000 req/s that is 11 minutes. A long staircase is cut into runs, each started from a rate it does not need
  to climb to; a 5-minute hold at 24,000 req/s (7.3 million requests, 4,535 VUs) peaked at 2.8 GiB.
- **The lag printed at the end can pass the gate in a valid run:** the gate is judged every second while k6 runs; after k6 stops, the
  newest sample's second stops advancing and the lag grows until the aggregator is told to end, and `max_lag_s` keeps that tail.
- **The replay case** (`check_replay_keeps_up`): `lab/macro/replay.php` feeds a recorded CSV (`lab/check/fixtures/k6-rows.csv`,
  real k6 rows) to the aggregator at 480,000 rows a second (40,000 req/s at 12 rows a request) for 10 s. The aggregator reads
  every row and request, none unparsed, with a lag of 1.0 s; the feeder was never more than 0.1 s late. At 1,500,000 rows a second
  the lag stayed at 1.0 s too. The first reader keeps only two kinds of rows, as above; it did not need to be faster.

### The calibration

`--calibrate` runs 50 VUs for 60 s, then 300 VUs for 60 s (`--calibrate-vus`, `--calibrate-seconds`), each with the stream
running, and prints k6's memory per VU (the difference between the two plateaus), the **VU cap** and the **scale**:

- the cap is the smaller of `(the VM's memory - 2 GiB - 512 MiB - 1 GiB) / MiB per VU` and the server's free file descriptors
  (65,535 - 60,000 idle connections - a margin for the server's own, **5,400**); a per-VU cost under the noise of two readings
  bounds nothing;
- the scale is the `s` that puts 20,000 req/s under the cap: `cap * 2.17 / (20,000 * 20.5)`, with the margin the 97 % rule leaves
  (`0.29 * s` s of mean latency per request);
- the harness **refuses more VUs than the cap** (`--vu-cap`, default 5,400): exit 2, before any container starts.

Smoke runs on the Docker VM with 23 other projects' containers running (7,935 MiB, 12 vCPUs; not a measurement), the app on 8.5
(the JSON files are in `lab/results/2026-11-22-realistic-calibration/`; this table is typed by hand from them: that folder has no `summarize.sh`, so the results check skips it):

| Run                          | VUs  | k6 memory | achieved / offered | k6 CPU                    | aggregator lag |
|------------------------------|------|-----------|--------------------|---------------------------|----------------|
| `--think-scale 0.03`, 60 s   | 50   | 72.1 MiB  | 0.995              | 13.3 % of a CPU, 759 us/req | 1.31 s         |
|                              | 300  | 143.9 MiB | 0.995              | 41.0 %, 389 us/req        | 1.25 s         |
| `--think-scale 0.1`, 30 s    | 300  | 138.9 MiB | 0.996              | 20.4 %, 646 us/req        | 1.21 s         |
|                              | 2000 | 678.1 MiB | 0.998              | 62.8 %, 297 us/req        | 1.90 s         |

- **k6 costs about 0.3 MiB per VU** (0.287 from 50 to 300, 0.317 from 300 to 2,000) **and 44 to 58 MiB at rest**: 5,400 VUs are
  about 1.8 GiB, inside the 3.75 GiB budget. The memory cap is 12,100 to 13,400 VUs, so **the cap is the file descriptors: 5,400**.
- **The scale is 0.02858** (`--think-scale 0.0285` to stay under it): 5,400 VUs offer 20,000 req/s, and the 97 % rule leaves 8.35 ms
  of mean latency per request.
- **At low load achieved / offered is 0.995 to 0.998:** k6's own loop overhead already takes 0.2 to 0.5 % of the 3 % margin.
- **k6 costs 300 to 650 us of CPU per request** with the stream on (it falls as the rate rises: 759, 389, 297 us). At that scale
  20,000 req/s is about 6 CPUs of k6 on the 8 it shares with the aggregator: read `k6_cpu_percent_of_one_cpu` on the high steps.
- The gate to use is the largest lag plus 2 s: 3.3 to 3.9 s in the smoke runs below. At the rates of the baseline (18,000 to 24,000 req/s, 60,000 idle
  connections) the lag reached 3.1 to 5.5 s while k6 ran, so the default is **6 s** (`--lag-gate` still overrides it).

### Output and exit codes

A table with one row per step (VUs, offered and achieved req/s, mapped users, CPU us per request, p95 and p99 overall, errors,
`pass` or `FAIL: <reasons>`), a line per endpoint under it, and a JSON (`results/realistic-<mode>-<server>-<image>-<UTC>.json`):
every step (window, requests, percentiles per endpoint, errors, CPU, k6's CPU), the think scale and the per-VU rate, the VU cap, k6's
local IPs, its peak memory and CPU, the aggregator's max lag and the gate, the server's peak `Pss_Anon` and `memory.current`,
`other_containers`, the exact command, the aggregator's per-second rows (`results.per_second`: requests, errors, p95, p99 and the
endpoints' count, p50, p99 and max of each second), the per-second series (`results.series`, see below), `idle`, `cold`,
`k6_connection_errors`, `results.run_total` and k6's own summary. Exit **0**: a valid run (a failing step included); **3**: printed but
invalid (lag, k6's memory, unparsed rows); **2**: usage, or VUs above the cap; **1**: any other failure (the server died, k6 failed).
`--warmup <rate>,<s>` runs the same journey first (not scored), `--ramp <s>` sets the ramp of each step (default a quarter of the
plateau, 2 to 10 s), `--server`, `--ext` (default `sockets` and `event`), `--env` and `--label` are as in the other harnesses.

### Traps

- **The plateau is a few seconds shorter than the step**: the ramp is not scored, and the first and last second of the plateau are
  left out. At 20 s plateaus a step has about 18 seconds of data.
- **A new VU sleeps `between(0, 5) * s` before its first request** (the bench's own spread), so a ramp is not a step in rate:
  the plateau starts after it.
- **k6's CPU is what the stream costs too:** about 12 CSV rows a request. Read `k6.cpu_percent_of_one_cpu` and each step's
  `k6_cpu_percent_of_one_cpu` before trusting a high step: k6 and the aggregator share CPUs 4 to 11.
- **A run on the Docker VM next to other projects' containers is a smoke run:** `other_containers` and the `WARNING` line say
  how many.

### Idle connections, the per-second series, telemetry and a cold start

```bash
bash lab/realistic.sh --image 8.5 --think-scale 0.0286 --idle 60000 --staircase 2000,2000,18000,20
bash lab/realistic.sh --image 8.5 --think-scale 0.0286 --idle 60000 --cold --hold 19900,25
```

**`--idle <n>`** holds `<n>` idle keep-alive connections from before the first request to the end of the run: the bench's thousands of
users who sit on a connection (the run is the same with none). One client (`lab/conns/client.php` in its **hold mode**, in its own
container `lab-realistic-idle` on the load CPUs, `nofile` 200,000) opens them **one at a time** (one `GET /health` each, a 200 whose body
matches `{"status":"ok",...}`: the hold mode takes a path and a body pattern; `/noop` and its exact body stay the default for
`lab/conns.sh`), from rotating 127.0.0.x source addresses as in the connection test, **before the warm-up**. It sweeps them once
(`held` event) and holds them until the harness creates a file, then sweeps again (`ended` event): **a connection the server closed is
the run's failure**, whatever the reason (`INVALID: the server closed 200 of the 200 idle connections during the run: 0 held at the end`,
exit 3). A client that cannot open them all (`held` below `<n>` with a failure) stops the run with that reason, exit 1.

- **The count held at the start and at the end** is in the table and in `idle` (`held_at_start`, `held_at_end`, `closed_by_server_*`),
  next to what the **server** counts (`server_established_at_start` and `_at_end`, from `/proc/net/tcp`, and the file descriptors it has open).
- **The client's memory is measured:** with 60,000 connections, 257 MiB of `memory.current` (peak 258): 44 MiB of heap, 213 MiB of kernel
  memory for its sockets (`kernel` in `memory.stat`; the PHP process's RSS is 56 MiB, so `docker stats` and `ps` miss four fifths), about
  4.4 KiB per connection. The budget for it in the k6 memory is 512 MiB (`LAB_IDLE_CLIENT_MIB`). Opening 60,000 one at a time takes
  about 10 s, from 6 source addresses.
- **Sockets stay under the server's 65,535 file descriptors:** the server has about 12 of its own, the VU cap leaves 5,400 for k6. A run
  at 19,565 req/s with 5,377 VUs and 60,000 idle ones peaked at 65,389 open file descriptors (`server.fds` in the series), with no k6
  connection error. k6's own source addresses (127.0.1.1-4) were enough: the fallback `IP_BIND_ADDRESS_NO_PORT` was not needed.
- **`k6_connection_errors`** counts the k6 rows whose error code is 12xx (dial, reset by the peer, broken pipe), with `k6_error_codes`
  for every code. It is reported, not a validity rule: a server out of file descriptors shows as failed requests in the step anyway.

**The per-second series** (`results.series` in the JSON, a table at the end of the output): one row per second of the measured run
(`k6` starts a moment after the sampler, so the first row is a partial second), with:

| Column (JSON)                             | From                                                                                           |
|-------------------------------------------|------------------------------------------------------------------------------------------------|
| `endpoints.<name>`: `count`, `p50`, `p99`, `max` | the aggregator's histograms (p50, p99: within 0.75 %); `max` is exact                          |
| `server.cpu_usec`                         | the sampler: `usage_usec` of the server's cgroup, in us per second                              |
| `server.pss_anon_kb`, `memory_current`    | the sampler, at the end of the second (`Pss_Anon` summed over the server's processes)           |
| `server.wal_bytes`, `server.wal_frames`   | the sampler: the `-wal` file's size, and `mxFrame` from the `-shm` header                      |
| `server.fds`, `server.minflt`, `majflt`   | the sampler: open file descriptors; page faults of the second (`/proc/<pid>/stat`)             |
| `telemetry`                               | the server's own line for that second (below), `null` when it printed none                      |

- **One sampler loop** (`lab/macro/sampler.php`) runs inside the probe container (CPUs 0-1) and appends a line a second to a file there;
  never one `docker exec` a second (runc and dockerd work is not pinned off the server's CPU). It reads at whole seconds (a few ms
  after), and a row needs the readings at both ends of its second: a missed one leaves `server: null` in that row and its neighbour,
  never a delta over two seconds. The table and the JSON are made by `lab/macro/series.php` from the aggregator's rows, the sampler's lines
  and the server's log (`lab/macro/series-lib.php`, tested by `lab/check/series-test.php`).
- **The WAL's frames, not its size:** SQLite starts the WAL over from its first frame after a checkpoint **without truncating the file**,
  so the file's size only grows (4.1 MB in a run that checkpointed many times) and only `mxFrame` shows the checkpoints (960 frames, then 608).
  `mxFrame` is the 32-bit integer at offset 16 of the `-shm` file, **in the byte order of the machine** (little-endian on arm64 and x86; the
  wal-index is shared memory, so it is native, not big-endian), written twice (offset 16 and 64): the reader re-reads when the two copies
  differ. The test writes rows into a real WAL, checkpoints, writes again, and compares with the frames the `-wal` file's size gives.
- **`/proc/<pid>/root` is read with `head`, not with PHP:** PHP resolves that link to `/` before it opens a file, and opens the probe's own `/tmp`.
- **SQLite's own page cache counters** (`sqlite3_db_status`: hits, misses) are not read: `pdo_sqlite` does not expose them and the handle is
  not reachable from PHP. The page faults stand for it (the database is mapped: a page that is not in the page cache is a major fault,
  one that is but not yet mapped is a minor one).

**Telemetry, `APP_TELEMETRY=1`:** off by default in the app. `lab/realistic.sh` and `lab/macro.sh --fresh-db` turn it on unless `--env
APP_TELEMETRY=...` is given (a later measurement compares on against off). One line a second on stdout, from `lab/servers/diy-telemetry.php`:

```text
telemetry {"second":1795370018,"requests":{"GET /feed":8253,"GET /posts/:id":7948},"wal_bytes":4161232,"longest_callback_ms":9.815,"gc_runs":0,"gc_collected":0,"minflt":28,"majflt":0}
```

`second` is the one that just ended (the timer is set for 2 ms after the whole second, and a line takes the second it was set for, never
the clock's: a timer that fires early must not repeat the second before). Requests are counted per endpoint by the app (`app_count`,
one call per request), `longest_callback_ms` is the longest callback of the event loop that second (two `hrtime` calls around each
callback, `accept`, read and write alike), `gc_*` are the deltas of `gc_status()`, `minflt` and `majflt` the process's own. When the
event loop stalls for 5 ms, this is the line that says whether it was one callback (and the sampler's `majflt` whether it waited
on the disk). The cost of having it on is not measured here.

**`--cold`:** the server starts on a copy of the seed whose pages were evicted from the page cache. `lab_start_app` copies the seed with
`cp` (inside the server container, so the page cache is charged to its cgroup), `sync`s it (a dirty page is not evicted), then
`dd iflag=nocache count=0` (a `posix_fadvise(DONTNEED)` on **that file only**: never a VM-wide `drop_caches`), and
`lab/macro/fincore.php` reads how much of the copy the page cache holds **just before the app opens it**. That is `cold` in the JSON
(`resident_bytes`, `size_bytes`, `resident_share`) and a line of the output: 249,843,712 of 249,843,712 bytes without `--cold`, 0 with it.
A `--cold` run whose copy is more than 5 % resident is invalid. It goes into `lab_start_app`, so every harness that starts the app gets
it (`LAB_COLD=1`, and `lab_fincore_line <container>` reads the reading back). The images do not ship `fincore` (`util-linux-extra` on
Ubuntu 24.04), so `fincore.php` is the same `mincore(2)` through FFI (`php -d ffi.enable=1`): it maps the file (which reads nothing) and counts the
resident pages. A warm-up warms the copy again: a cold start has none (`--warmup 0` in `macro.sh`, whose default is 10 s; `realistic.sh` has none by default). The first requests then show as major faults in the
series (20 to 27 a second at 400 req/s in the smoke run) and `memory.current` growing as the page cache refills.

**`--no-series`** (`realistic.sh`): no sampler and no server reads while k6 runs, for a run whose p99 or stalls the probes might disturb
(the sampler reads the server's `smaps_rollup` and lists its fds every second). The poll keeps only k6's memory and the aggregator's status;
`results.series` is null, the server's memory peaks are null, `per_second_probes` is false and the table says the per-second part is off. The
per-step results and `results.per_second` (the aggregator's latency, and the server's CPU from its cgroup) stay. The telemetry line stays too
unless `--env APP_TELEMETRY=0` turns it off.

### The challenge app on `macro.sh`

`lab/macro.sh --fresh-db` starts its server the way `lab/realistic.sh` does: `lab_start_app` (a fresh copy of the seed, `SQLITE_PATH`,
`JWT_SECRET`, `APP_TELEMETRY=1`, extensions `sockets event` unless `--ext` says otherwise) instead of a bake-off server that copies its own seed;
without the switch nothing changes. `--cold` (needs `--fresh-db`) is as above. **`--per-second`** adds the series of the measured run
(the warm-up is not in it): k6 writes its CSV into the aggregator (`lab/macro/aggregate.php` in `lab-macro-agg`, a FIFO in the volume
`lab-macro-run`), which names an endpoint by the URL's path with its numbers as `:id` (`/posts/:id`, so `posts.js` is one endpoint),
and the same sampler and series as above give the server's columns. The aggregator's request count must equal k6's own (checked in
`check_macro_fresh_db_cold_per_second`), and a lag above 4 s or an unparsed row makes the run invalid. The CSV costs k6 about 300 us of CPU
per request: the server's numbers do not change, k6's do.

```bash
bash lab/macro.sh --image 8.5 --server lab/app/server.php --fresh-db --cold --per-second --rate 2000 --duration 30 \
  --script lab/macro/k6/posts.js --path /posts/1
```

## The profile

`--profile <file>` on `lab/realistic.sh` and `lab/macro.sh --fresh-db` runs the challenge app under **Excimer** (PECL 1.2.6, a sampling
profiler on the CPU time of the thread) and folds its samples into the steps of a request, to tell which step costs the most per
request and per endpoint. Excimer is in the 8.3, 8.4 and 8.5 images, never enabled globally (`--ext excimer`, which `--profile` adds), and
`php-info` prints `excimer: 1.2.6`. **It does not build on PHP 8.6** (`results/excimer-on-php-8.6.md`: `XtOffsetOf` and `INI_INT` are gone):
the 8.6 image is built with `WITH_EXCIMER=0` (`excimer: not built`) and `--profile` on it stops before anything starts.

```bash
bash lab/realistic.sh --image 8.5 --think-scale 0.1 --warmup 100,5 --hold 300,20 --profile /tmp/profile.collapsed
php lab/profile/fold.php /tmp/profile.collapsed --us-per-req 240    # in a lab container: bash lab/run.sh 8.5 php /lab/profile/fold.php ...
```

### In the server

`APP_PROFILE=<path in the container>` (and `APP_PROFILE_PERIOD`, seconds of CPU time between two samples, default 0.001) starts an
`ExcimerProfiler` on `EXCIMER_CPU` before the first request (`lab/servers/diy-profile.php`, started by `DiyServer::run`). The servers have no
signal handling and are removed with `docker rm -f`, and `/lab` is read-only, so a timer of the event loop writes the **collapsed stacks**
(`frame;frame;frame <count>`, one line per distinct stack) to the container's own disk every 2 s, through a temporary file and a rename.
The harness waits for the next write after the load, reads the cgroup, and copies the file out with `docker exec cat`. The profiler is
stopped while the timer writes, so a profile never holds its own flush. With `--profile` the telemetry is off unless `--env APP_TELEMETRY=..`
says otherwise (a profile of the server, not of the telemetry's timers). The loop's three callbacks are now named methods
(`[$this, 'onReadable']`), not first-class closures: a profile names a first-class callable `{closure:file(line)}`, whose line moves with
every edit, and the rules need a name.

**The window** is the whole life of the server after its first answer: the idle connections, the warm-up, the ramps and the plateau, and an
idle second or two. The JSON's `profile` key holds the samples, the cgroup's `user_usec` and `system_usec` over that window, the share
of the CPU the samples cover (`samples_over_cgroup_cpu`, 0.97 to 1.0 in the smokes: the CPU timer counts the kernel's time too) and
the fold. The `us/req` printed for a profiled run is the profiled server's: **Excimer costs CPU, so it is never a baseline**; it comes from the
cgroup's CPU over the window divided by the requests of the window (the warm-up's, the run's and one `GET /health` per idle connection).

### The fold and its rules

`lab/profile/fold.php <collapsed file or -> [--rules <file>] [--us-per-req <n>]` prints one table: the rows are the steps S1 to S9, the
event loop and unclassified, the columns are the five endpoints, `shared` and `all`. A sample takes the step of its **leaf frame** (the
innermost one), if `lab/profile/steps.rules` names it (a frame name, or a prefix ending in `*`), and the endpoint of the route function
found anywhere on its stack; a sample with no route function (reading, parsing, writing, the loop: the work done before the route is known) is
`shared`. Every cell is a share of **all** the samples (the table sums to 100 %, a column's total is its weight in the run), and with
`--us-per-req` the microseconds it adds to the average request. A second block gives each endpoint column as a share of its own samples,
which is the one that answers "which step costs the most for `GET /feed`". A leaf that no rule names makes the sample `unclassified`, whatever its
callers are (Excimer never shows an internal function as a frame, so the leaf is always one of our PHP functions), and those leaves are
listed under the table: a rename in the app shows up there, not as a wrong step. The profiler's own flush (`DiyProfile::write`) goes to the
event loop: it is not a step of a request. `lab/check/fold-test.php`
tests the fold on a hand-written profile of 1,000 samples with known shares.

| Step | Frames of `steps.rules` | What is in it |
| --- | --- | --- |
| S1 accept | `DiyServer::onAccept`, `DiyConnection::close` | `stream_socket_accept` and the new socket's setup, and `fclose` |
| S2 read and parse | `DiyConnection::onReadable`, `::parse`, `::parseHead` | `fread` (the kernel's receive path), the header parse; `parse` also holds the response head's concatenation (S8 work, too small to split without a function of its own) |
| S3 route | `handler_handle`, `app_count`, the `route_*` functions | the match on method and path |
| S4 JWT, S5 validate | `jwt_verify` and its decoder, `id_validate`, `body_validate` | |
| S6 query | `feed_query`, `post_query`, `post_insert`, `post_exists`, `like_insert`, `route_health` | `PDOStatement::execute` and the fetch; `route_health` runs its query inline |
| S7 JSON | the `*_json` functions | `json_encode` |
| S8 write | `response_json`, `response_error`, `DiyConnection::advance`, `::onWritable` | `fwrite` (the kernel's send path) |
| S9 durability | none | SQLite commits inside `PDOStatement::execute` (autocommit), so a write's commit and its WAL checkpoint are in S6. The row stays at 0 to say so |
| event loop | `DiyServer::run`, `::onReadable`, `::onWritable`, `::settle`, `DiyProfile::write` | libevent's dispatch and `epoll_wait` (see the calibration), the events added and removed, the profiler's own flush |

### Where Excimer's samples land (the calibration)

Excimer takes a sample at the next VM interrupt check, so the rules rest on a measurement: `lab/profile/calibrate.php`, run by
`check_excimer_calibration` with the JIT on (`tracing`) and off.

- **An internal function's time is its calling PHP function's.** The `hash` mode has one PHP function (`calib_hash_step`) whose time is
  all in `hash('sha256')`, and one (`calib_loop_step`) of plain PHP. Timed with `hrtime` and no profiler, the hash is 28.3 % of the CPU with
  the JIT on and 33.4 % with it off. Profiled for 6 s (CPU time, 1 ms), `calib_hash_step` holds **28.2 % and 33.8 %** of the samples (0.1 and
  0.4 points off; the check allows 5), and no frame is named `hash`: internal functions never appear in a profile. The kernel's time inside
  `fread`, `fwrite` and `stream_socket_accept` is therefore in the PHP function that called them, which is why each step has its own function.
- **libevent's and `epoll_wait`'s time lands on the next callback's own frame.** Nothing in them can take a sample, so it is taken when the
  callback's PHP starts. A persistent 0 s timer around an empty callback (libevent spinning, `epoll_wait(0)` each time) puts **97.9 %** of the
  samples on the callback's frame and 2.1 % on the function that called `dispatch()`; a socket pair ping-pong (one `fread` and one `fwrite` per
  callback) puts 66 % on the callback function that does them and 32 % on the closure that libevent calls (JIT off: 61 % and 37 %). In the
  app that is `DiyServer::onReadable`'s own frame, which holds almost no PHP, so its own samples are the loop's.
- **The kernel's time is counted.** The samples add up to the CPU the process used (`getrusage`, user and system): 3,969 samples against
  3,985 ms of CPU for the spinning loop (43 % of it in the kernel), 3,974 against 3,978 for the ping-pong (70 % in the kernel). What
  a sample cannot say is which syscall: `read` and `epoll_wait` share the frame they land on.

### Reading the table

The cgroup's user and system CPU of the window is printed under it. The system share is the kernel's work for the whole server (the
sockets, the page faults, SQLite's `pwrite` and `fsync`), and it is inside the PHP frames above. A sample in `GET /feed` S6 is the
statement's execution and the row fetch (`PDOStatement::execute`, `fetchAll`), SQLite's own C code. The `GET /health` column holds only
the harness's own polls, because the bench's journey never asks for it.

**Traps:** a profile from `macro.sh` is the app on one URL, so only that endpoint has samples; the telemetry's timers are not in the profile unless
asked for; the 8.6 image has no Excimer; and the CPU of a profiled run is higher than an unprofiled one's (the cost is measured, not assumed:
run the same load with and without `--profile` and compare the `us/req` of the plateau).

## The step lab

Two instruments to judge a change to the server: `lab/steplab.sh` compares variants by CPU per request, `lab/syscalls.sh` counts the
syscalls per request.

### `lab/steplab.sh`: variants against a reference

```bash
bash lab/steplab.sh --image 8.5 --rate 24000 --think-scale 0.02 --idle 60000 --seconds 60 --pairs 3 \
  --variant ref= --variant telemetry-on=APP_TELEMETRY=1 --floor 5 --out /tmp/steplab-telemetry
```

Each run is `lab/realistic.sh --hold <rate>,<seconds>` (a fresh seed copy, server and idle connections each time), with `--no-series`
(no per-second probes) and the server's telemetry off unless the variant sets `APP_TELEMETRY`. The default warm-up is a tenth of the
rate for 60 s (`--warmup <req/s>,<s>` changes it). `--variant <name>=<K=V,K=V...>` sets environment variables (an empty list is the
skeleton as it is); `--server-variant <name>=<php file under lab/>` runs another server file. **The first variant is the
reference.** Runs are **interleaved by round**: round 1 runs every variant once in the given order, round 2 again, and so on for
`--pairs` rounds, so a slow drift of the VM hits every variant alike.

**The judgment** (`lab/steplab-verdict.jq`, a pure function of the run JSON files): the number of a run is the server's CPU per
request over the plateau (what the aggregator reads from the cgroup). A run counts when its JSON is valid. A variant's **paired
differences** are its number minus the reference's of the same round; a round where either run is invalid has no pair. A variant is
`beyond the noise` when it has at least 2 pairs, **every pair has the same sign** (a zero has none) **and** the median paired difference
is at least `--floor <us>` in absolute value; otherwise `within the noise`. Fewer than 2 pairs: `no verdict`, with the count. Without
`--floor`: `no floor: not judged` (the floor comes from an A/A calibration: two identical variants, the largest median paired difference
they show). The rule is printed under the tables.

**TIME_WAIT sockets.** Before each run the runner counts the TIME_WAIT sockets on k6's source addresses (`probe.sh time-wait`: the VM's
`/proc/net/tcp`, a socket counts for an address that is at either end, because the side that closes first keeps the port busy) and waits
until the busiest address holds at most `--time-wait-max` (default 1,000). A closed connection keeps its port for 60 s, the VM's
ephemeral ports are 55000 to 65535 (about 10,500 per address) and k6 opens about one connection per VU, a quarter of them on each
address (1,200 at 24,000 req/s), so under 1,000 a run has 9,500 free ports per address, and above it the sockets of the run before are
still there. A count that does not drop within `--time-wait-wait` seconds (default 150) is a harness failure. The counts before and after
each run (per address, the busiest, the total on k6's addresses, the total on the VM) are in the run's JSON, under `steplab.time_wait`,
and the busiest address before each run is in the table (`tw/addr`).

**What it writes** into `--out` (default `lab/results/steplab-<label>-<image>-<time>/`): `<variant>-<round>.json` (the realistic run's
JSON with a `steplab` object: variant, index, round, the variant's env and server file, the TIME_WAIT counts), `<variant>-<round>.txt`
(that run's table), `summary.json` and `summary.txt`. `bash lab/steplab-summary.sh <folder> [--floor <us>] [--json <file>]` rebuilds the
two tables and the verdicts from the JSON files alone, so a results folder's `summarize.sh` calls it. Exit codes: 0 every run ran (an
invalid run or a failing step is a result), 1 a harness failure, 2 usage. The runs of a comparison take what they take: a 60 s plateau
with 60,000 idle connections is about 4 minutes a run, plus the drain of the TIME_WAIT sockets.

`check_steplab_verdicts` runs the verdict on recorded run files (`lab/check/fixtures/steplab/<case>/`: identical variants, a variant
1 ms slower in every round, mixed signs, the same sign under the floor, an invalid round of the variant or of the reference, a single
pair), and `check_steplab_live` runs two variants for two rounds at a low rate and reads the tables' shape.

### `lab/syscalls.sh`: syscalls per request

```bash
bash lab/syscalls.sh --image 8.5                       # the skeleton, 2,000 req/s, 20 s of strace
bash lab/syscalls.sh --image 8.5 --env APP_X=1 --out /tmp/count.json
```

A realistic hold at `--rate` (default 2,000 req/s, `--think-scale` 0.1, no idle connections, no per-second probes, telemetry off) and,
from 3 s into its plateau, a sidecar container in the server's pid namespace (`--pid container:<server>`, `--cap-add SYS_PTRACE`, on the
probe CPUs) runs `strace -c -f -p <server pid>` for `--seconds` (default 20), then detaches. **Only counts are kept.** strace stops the
server at each syscall, so it slows it down and its time columns mean nothing; they are dropped. The table gives each syscall's calls,
calls per request, errors (an `EAGAIN` counts as an error) and the total per request. The requests are **the aggregator's** (one row per
second of k6's own samples), summed over the whole seconds of the window, which starts on a whole second of the VM's clock: the traced
server serves fewer requests than the nominal rate, so the division uses what it served. The JSON holds the table, the window, the
request count and the command.

strace comes from `lab/images/Dockerfile.strace`: the lab's pinned Ubuntu with strace 6.8-0ubuntu2 installed at that exact version
(`lab_ensure_strace_image` builds it the first time). Its raw output stays in a temporary folder: no path or process id goes into the
JSON, so a result can be committed. If the VM refuses ptrace, the script prints strace's own message and exits 1. Exit codes: 0, 1 a
harness failure, 2 usage, 3 the realistic run was invalid.

**Reading it.** On the skeleton (keep-alive, 2,000 req/s) the write family (`write`, `sendto`, `writev`) is 1 per request, one response
each; `check_syscalls_live` asserts it is near 1 and that the total is positive. `check_syscalls_table_parse` reads strace's table from
a real capture (`lab/check/fixtures/strace-c.txt`).

## Connection test

`lab/conns.sh` measures how many idle keep-alive connections one server process holds, and what each one costs in memory:

```bash
bash lab/conns.sh --image 8.5 --server lab/servers/bake-swoole.php [--ext <name>]... [--env K=V]... [--label <text>] \
  [--steps 1000,5000,...] [--max <n>] [--server-nofile <n>] [--port 18100] [--out <path>]
```

The default steps are 1000, 5000, 10000, 20000, 30000, 40000, 50000, 60000, 65000 and 66000; `--max` drops the steps above
it. The server starts like `macro.sh` and `conformance.sh` start theirs (`lab_start_server`: 1 CPU, 2 GiB, `nofile` 65535). Two
more containers join it: the probe of `macro.sh` (`lab/macro/probe.sh`, from outside the server's cgroup) and a client
(`lab/conns/client.php` in a php-lab container on the load CPUs, `nofile` 200000, no CPU or memory limit).

- **The client opens connections one at a time.** For each one it connects (blocking), writes `GET /noop HTTP/1.1` with a `Host`
  header, reads the whole answer (status 200, body `{"status":"ok"}`) and keeps the socket open. One at a time means the
  accept queue never fills, so a connection that gets no answer is the server's limit and not a burst the kernel dropped. The
  client stays alive between steps, and `lab/conns.sh` drives it through a FIFO (`step <total>`, `quit`) and reads its answers
  as JSON lines from a file.
- **Source addresses rotate over 127.x.** One client address has only as many ephemeral ports as `ip_local_port_range` gives
  (10,536 on the lab's VM at the time of writing, 28,232 with Linux's default of 32768-60999; the client reads the file and
  keeps 500 ports in reserve), so the client binds each connection to `127.0.0.N:0` (`socket.bindto`) and moves to another
  address before the ports run out. The next address is one that is the local address of no socket at all: a run right after
  another one skips the addresses whose `TIME_WAIT` sockets (the client closes first, so they sit on its side, for 60 s) are
  still there, and never fails on `bind`. `127.0.0.1` stays for the probe's fresh request. No `sysctl` is changed: the Docker
  VM is shared. If every address from 127.0.0.2 to 127.0.0.254 is taken, the client waits up to 70 s, then fails.
- **What is read at each step,** after the client opened its connections and swept them (non-blocking reads: an EOF or a reset
  means the server closed one), and 1 s later: the summed `Pss` and `Pss_Anon` of the server's processes, the cgroup's `memory.current` and
  `memory.events` (`oom_kill`), the established connections to the server port in `/proc/net/tcp`, and a fresh request from
  `127.0.0.1`, which must answer within 1 s. The `/proc/net/tcp` count is a cross-check of the client's count, not what max
  connections is made of.
- **The baseline** is read before the first step, after one `GET /noop` on one connection (then closed), so the first-request
  allocations are in it.
- **Max connections** is what the client got an answer on and still holds at the last fully held step. The table also gives the
  exact count held when the run stopped (the failing step's, after the sweep).
- **The ceiling** is the first step where one of these happens, and the output names it: `connect timeout` or `request timeout`
  (2 s), `connection reset`, `connection closed by the server (EOF)` (on the connection being opened) or `held connection closed
  by the server (EOF)` (found by the sweep), `connection refused`, `bad answer`, `fresh request failed`, `server OOM-killed`,
  `server died (exit code N)`. Linux does not refuse a SYN because of a full accept queue or a server out of fds: it completes
  the handshake, then the request times out or resets. A server out of fds (`--server-nofile 256`) shows as `request timeout`.
  Reaching `--max` (or the last step) is the other way a run ends: `no ceiling: ...`. Both are results, exit 0.
- **A client-side error is a harness failure** (exit 1), never a ceiling: a `bind` that fails, `EMFILE` in the client, no free
  port, no free source address, a client that exits or prints something that is not an event.
- **Memory per connection** is the least-squares slope of the summed `Pss` against the connections held, and the same for
  `Pss_Anon` (the figure to compare runtimes on) and `memory.current`, over the held steps (KiB per connection; `n/a` below two held steps). It is a slope over the steps, not a
  per-connection constant: in one run on a busy VM (not a result) Swoole went from about 69 KiB per connection between 1,000
  and 10,000 connections to about 5 KiB between 20,000 and 65,000, so the slope depends on the steps it covers. Read the table
  too.
- **`--server-nofile N`** sets the server container's `nofile` (a test hook, recorded in the JSON as `server.nofile`).
  `lab/conns.sh` reads the limit back from `/proc/<pid>/limits`.
- **Output:** a table (one row per step: target, held, Pss, `Pss_Anon`, `memory.current`, `/proc/net/tcp` count, fresh request in ms, `ok`
  or the reason), then max connections, why it stopped, the three slopes, the baseline (`Pss`, `Pss_Anon`, `memory.current`), the server's socket line, the number of other
  containers (with the same warning as `macro.sh`) and the versions. The JSON (`lab/results/conns-<server>[-<label>]-<image>-
  <UTC date and time>.json`) holds every reading (`steps[]` with the client's event and the probe's reading), the exact command,
  `results.ceiling` and `results.memory_per_connection`. The three containers (`lab-conns-server`, `-client`, `-probe`) are
  removed at the end whatever happens, and the run refuses to start when one of them exists.

### The client's hold mode

`php lab/conns/client.php <port> --hold <n> [--path <path>] [--body-regex <pcre>] --end-file <file>` is what `lab/realistic.sh --idle` uses:
no commands, no baseline. It opens `<n>` connections the same way (one at a time, rotating source addresses), sweeps them, prints a `held`
event (`held`, `closed_by_server`, `failure`, `seconds`, the client's `rss_kb`), waits for the file, sweeps again and prints `ended`. A body
that does not match the pattern is `bad answer`. `check_idle_client_hold_mode` runs it against `lab/check/fixtures/idle-timeout-app.php` (a server
that closes every connection idle for 2 s): ended at once, all 50 held; ended 4 s later, all 50 closed by the server; a wrong pattern, a failure.

### Traps of the connection test

- **The ephemeral port range of the VM is not Linux's default** (55000-65535 here): never hard-code 28,232.
- **`json_encode` returns `false` for a byte that is not UTF-8**, which printed a blank line as an event: the client's `emit`
  substitutes invalid bytes. A PHP fatal error goes to stderr (`display_errors=stderr`), not into the events file.
- **A `stream_socket_client` that fails on `EMFILE` gives errno 0 and an empty message.** That is why a connect error with no
  known errno is a harness failure with the client's `nofile` in the message.
- **PHP's read buffer would hold 8 KiB per connection in the client** (500 MiB for 65,000 sockets): `stream_set_read_buffer($fp,
  0)`.
- **Swoole at its fd limit accepts nothing more but still completes the handshake,** so the client's connect succeeds and the
  request times out: 65,522 connections answered with `nofile` 65535 (the server keeps about 13 fds for itself).

## Checks

```bash
bash lab/check.sh
```

One line per check, `ok` or `FAIL`, non-zero exit if any fails. To add one, write a `check_<name>` function in the
script and list it in `CHECKS`.

`check_results_regenerate` keeps the results folders honest: it runs every `lab/results/*/summarize.sh` (from its
folder, reading only the raw files next to it) and checks the folder's `README.md` against it, byte for byte, so a
README cannot drift from its raw files. A README with `<!-- BEGIN summarize -->` and `<!-- END summarize -->` lines
must hold exactly the output between them (a stale extra line fails too); one without them must hold every non-empty
line, anywhere. It prints `ok` per folder, or the first difference. A folder without a `summarize.sh` is named as skipped, not failed. A table is regenerated
with `bash lab/results/<folder>/summarize.sh`, pasted into the README with the prose around it kept. The baseline's
summary runs `lab/run.sh`, so this check needs Docker and the `php-lab:8.5` image. `check_results_check_catches_drift`
proves the check can fail, on `lab/check/fixtures/results-drift/` (a README that holds a near copy of one line, and
one whose block holds a stale line).
