# PHP + our own event loop

| | |
|---|---|
| Language | PHP 8.5.13, built from the php.net tarball (sha256 pinned) by `install.sh` with `./configure CFLAGS=-O2 --disable-cgi --disable-fpm --enable-opcache --with-pdo-sqlite --enable-mbstring --with-sodium --with-ffi --enable-ctype --with-iconv`; OPcache with the tracing JIT |
| Framework | None: an event loop of our own, in PHP. First choice, an io_uring loop driven through PHP's FFI (`ring.php`: one process, three rings). When the machine refuses io_uring, the epoll loop it replaced (`loop.php`, `connection.php`, two processes) on ext-event 3.2.0 (PECL tarball, sha256 pinned), which uses Ubuntu 24.04's libevent 2.1.12-stable |
| SQLite driver | `pdo_sqlite`, linked to SQLite 3.54.1 that `install.sh` builds from sqlite.org's amalgamation (sha256 pinned) with `-O2 -march=native`, the compile options sqlite.org recommends for a single-threaded program and profile-guided optimisation, under `/opt/sqlite-tuned` |
| Dependencies | None beyond PHP's own extensions (FFI, pcntl, sockets, posix, mbstring, ctype, hash, json), ext-event and SQLite, all built from source. No Composer. The toolchain and the other libraries (libffi among them) come from Ubuntu's apt |
| **Nginx or direct** | **Direct**: serves `0.0.0.0:80` itself, with `HOST` and `PORT` read from the environment |

## Running it

```bash
sudo bash install.sh   # apt: toolchain and libraries; builds SQLite into /opt/sqlite-tuned, PHP and ext-event into /opt/php-gcob
bash build.sh          # nothing to compile; lints every PHP file
SQLITE_PATH=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

- **PHP goes to `/opt/php-gcob`**, its own prefix, so it never clashes with the system's PHP (Ubuntu 24.04 ships 8.3).
  No `php.ini` is written and nothing is enabled globally: `start.sh` loads pcntl, sockets and event with
  `-d extension=`, and passes the OPcache and JIT settings the same way.
- **FFI is built in** (`--with-ffi`, against Ubuntu's libffi) and needs no setting: PHP's default, `ffi.enable=preload`, allows it in a CLI
  script, which is how `start.sh` runs the server. `install.sh` ends by calling libc through it, and fails if it cannot.
- **`install.sh` took 258 to 276 s** in eight runs of `bash lab/submission-test.sh` (with and without Docker's default seccomp filter, and the two
  runs of `--ci`, twice over), in a clean Ubuntu 24.04 container limited to 1 CPU and 2 GiB, on an arm64 core (Docker on an M3 Pro). The ring adds nothing
  to it but a call to libc through FFI at the end: FFI was already built into PHP, and `ring.php` is a PHP file. It took 222 s before it built its
  own SQLite: the two builds of the library and the training are the difference. The droplet's x86 vCPU is not measured yet (the same install ran 425 s on a one-core AWS `c5.large`, before
  the SQLite build).
- **`start.sh` was healthy after 0.1 s** in the same container (the poll step is 0.1 s), with 42 of 42 checks passing
  there (`lab/submission-test.sh` prints both), on the ring (the container without Docker's default seccomp filter, which refuses io_uring) and on the epoll fallback (with it).
  `bash lab/submission-test.sh --seccomp-unconfined` and `bash lab/submission-test.sh` repeat these runs, as root then `deploy`, and each says
  which loop booted:
  [lab/submission-test.sh](https://github.com/Gcob/twelve-dollar-server-php/blob/main/lab/submission-test.sh).
- The last line `install.sh` prints is `installed: PHP 8.5.13, SQLite 3.54.1 (THREADSAFE=0 ...), libevent 2.1.12-stable,
  ext-event 3.2.0, OPcache with JIT, FFI (calls libc), ...`. It is printed by the installed PHP itself, and the install fails if an extension
  or the JIT is missing, if FFI cannot call libc, if SQLite is not 3.54.1 or not built with `THREADSAFE=0`, or if the `php` binary does not load
  `/opt/sqlite-tuned/lib/libsqlite3.so.0`.

## Optimizations, and why

Every choice was judged on **microseconds of CPU per request** at a fixed request rate, against a noise floor made of
A/A pairs (the same server run twice), in a replay of the bench's own `load.js` journey with 60,000 idle connections
held. The method, the harness and every raw result are in
[lab/README.md](https://github.com/Gcob/twelve-dollar-server-php/blob/main/lab/README.md). The numbers below come
from Docker on an M3 Pro (arm64, 1 CPU, 2 GiB), unless a line names the AWS `c5.2xlarge` (one Xeon vCPU, its
hyperthread sibling left idle). Neither is the droplet.

- **An io_uring loop of our own, in PHP, with the epoll loop as its fallback.** `ring.php` drives three io_uring rings through PHP's FFI (raw
  system calls: no C is compiled and no liburing is used). Connections are direct descriptors in a table per ring, so a connection takes no file
  descriptor of the process: 150,000 held connections cost 12 descriptors. Receive is multishot from one pool of provided buffers shared by every
  connection (an idle connection holds no buffer), send is one `SEND` of the response copied into a pooled slot, and a turn of the loop is one
  `io_uring_enter`. On Ubuntu's 6.8 kernels the registration of a buffer ring answers `EINVAL`, so there the loop gives the pool to the kernel with
  the older `IORING_OP_PROVIDE_BUFFERS` and takes back the buffers a turn consumed with one more submission per run of ids (the buffer ring is
  used on a kernel that takes it, and the `loop:` line says which one runs). On the Xeon (`c5.2xlarge`, kernel 6.8, the older buffers, 7,500
  requests a second, 60,000 idle connections) the ring costs **4.49 µs less per request than the epoll loop (8.1 %, 3 pairs of 3, beyond the A/A
  floor of 0.92 µs)**, and together with the tuned SQLite **11.59 µs less (21.0 %, 3 pairs of 3)**:
  [lab/results/2026-11-26-x86-levers](https://github.com/Gcob/twelve-dollar-server-php/tree/main/lab/results/2026-11-26-x86-levers). Why the ring is not
  Swoole's or ext-mrloop's: [lab/results/2026-11-26-off-the-shelf-uring](https://github.com/Gcob/twelve-dollar-server-php/tree/main/lab/results/2026-11-26-off-the-shelf-uring).
  `ring.php` is a copy of the lab's ring, `lab/servers/ring-server.php` as of phase 8, with its test hooks, its environment knobs, its
  statistics line and two members nothing in the submission reads taken out
  ([lab/servers/ring-server.php](https://github.com/Gcob/twelve-dollar-server-php/blob/main/lab/servers/ring-server.php));
  `check_submission_ring_is_the_labs` in `lab/check.sh` fails when the logic of one of the two files changes and the other's does not. An idle server is not at 0 % CPU: with
  nothing to do the loop wakes every 500 µs on the active ring, and the pairs above were measured with it.
- **The fallback, decided once at boot.** Before it opens the database or listens, `server.php` builds the three rings. If the machine refuses a step
  (Docker's default seccomp filter, which answers `EPERM` to `io_uring_setup`; a kernel without io_uring or with it switched off; a limit), or cannot
  run the ring at all (no FFI, `ffi.enable` off, a `HOST` that is not an IPv4 address, any error while the rings are being built), the server runs
  the epoll loop below and says why in its `loop:` boot line: `loop: epoll (io_uring refused: setup 1)`, `loop: epoll (ring unavailable: <the reason>)`. A ring that runs never switches later: a refusal after the boot is a crash.
- **The epoll loop, our own on ext-event, one request at a time, no framework.** A readable event reads, parses, runs the handler
  and writes the answer in one callback: no coroutine, no thread, no request or response object. In the
  runtime bake-off (7,000 req/s) it cost 21.88 µs per request on a trivial route and 29.14 on a post read from the
  seed, against Swoole's 25.47 and 32.83 and Workerman's 26.24 and 33.32 (its caches out): 14.1 % and 11.3 % under
  Swoole. Results:
  [lab/results/2026-11-21-bake-off](https://github.com/Gcob/twelve-dollar-server-php/tree/main/lab/results/2026-11-21-bake-off).
- **The fallback's two processes on one port (`SO_REUSEPORT`), each with a soft limit of 64,000 connections.** One process has 65,535
  file descriptors (the bench gives `LimitNOFILE=65535`), and the bench holds more users than that. With 64,000 idle
  connections and k6's users on top (68,535 at once), one process without a limit reached 34.2 % of the offered rate
  and 2.03 % errors, while a process that sends `Connection: close` past 64,000 and lets clients reconnect had no error
  ([lab/results/2026-11-23-s1-fd-wall](https://github.com/Gcob/twelve-dollar-server-php/tree/main/lab/results/2026-11-23-s1-fd-wall),
  Mac, 12,000 req/s). The soft limit works like this: a response built while more than 64,000 connections are open in
  that process says `Connection: close`; **an idle connection is never closed**. Two options were priced on the Xeon
  at 7,500 req/s ([lab/results/2026-11-24-x86-s1b](https://github.com/Gcob/twelve-dollar-server-php/tree/main/lab/results/2026-11-24-x86-s1b)):
  one process that reconnects past the limit, or two processes. A reconnect costs 23.56 µs there. A second process
  costs +7.44 µs per request (50.31 to 57.75, three pairs, all the same sign). At 150,000 users, two processes add
  10.90 µs per request (7.44, plus the share of requests that still reconnect past 64,000 in each) against 13.51
  for one process, so two processes were kept. The cost is memory: about 1.0 GiB at 150,000 users (1,026 MiB)
  against 615 MiB, half of the 2 GiB box. The 150,000-user figures are computed from the 60,000-connection runs,
  not measured at 150,000. The ring has no such wall (its tables hold up to 3 x 65,535 connections with no descriptor each, and 150,000 held
  connections measured 844 MiB for the whole container with `lab/conns.sh`): one process with a soft limit of 192,000 over its three rings, with the same rule, a
  response built while more are open says `Connection: close` and an idle connection is never closed.
- **The fallback's supervisor.** The parent forks the two processes and opens nothing itself. It never restarts one: if one ends,
  however it ends, it stops the other and exits 1, so a crash shows instead of leaving a half server (systemd decides
  what follows).
- **`mmap` off, a 64 MiB page cache.** Reads go through `pread` and SQLite's cache instead of a 256 MiB memory map.
  Three pairs against the map, all lower: -1.31, -1.98 and -2.21 µs per request (the references cost 26.4 to 27.6 µs),
  at 24,000 req/s. This is beyond the floor of the A/A pairs whose runs kept 97 % of the offered rate (0.27 µs) and
  not beyond the floor of all five (2.57 µs), so it was kept for its three same-sign pairs and one pragma that reverts
  in one line:
  [lab/results/2026-11-23-cpu-steps](https://github.com/Gcob/twelve-dollar-server-php/tree/main/lab/results/2026-11-23-cpu-steps).
- **Prepared statements, the reference SQL, `json_encode`.** The statements are prepared once per process. The SQL is
  the challenge's reference query: the variants (a join, a two-step query, other fetch modes) were slower in the micro
  benchmark and never reached a server run. The JSON is built by `json_encode`, against the variants in the next item.
- **Our own SQLite: 3.54.1 from the amalgamation, single-threaded options, `-march=native`, profile-guided.** SQLite is
  most of a request's CPU, and Ubuntu's 3.45.1 is a general build. `install.sh` builds sqlite.org's `sqlite-autoconf-3540100`
  (sha256 pinned) with `THREADSAFE=0`, no memory statistics, no double-quoted strings, no deprecated interfaces, no
  progress callback, no shared cache, stack temporaries and no expression depth limit (the options sqlite.org recommends
  for a single-threaded program, each one read against what PDO and the app call), then compiles it twice. The first
  build is instrumented, PHP is built against it, and a training runs the app's six statements
  (`sqlite-train.php`, which reads them from `app.php`) in the bench's mix of one loop (a feed, a post, a like 15 % of the time, a
  new post 2 %), 70,072 statements on a database of the seed's size; the second build reads that profile. PHP is not rebuilt:
  the library keeps its soname and exports, and `php` finds it at the same path. **The training data is generated**, from the
  challenge's schema, by `sqlite-train.php` itself (50,000 users, 500,000 posts, about 2 million likes, a fixed seed): it reads
  neither the seed database nor anything the bench runs. Ubuntu's `libsqlite3` is untouched. On the Xeon (`c5.2xlarge`, kernel
  6.8, 7,500 requests a second, 60,000 idle connections) the server costs 55.3 µs per request on Ubuntu's SQLite, and the tuned
  one **7.33 µs less (13.3 %), in 3 pairs of 3, beyond the A/A floor of 0.60 µs**; the feed read alone is 16.4 % faster in the
  micro benchmark:
  [lab/results/2026-11-26-x86-levers](https://github.com/Gcob/twelve-dollar-server-php/tree/main/lab/results/2026-11-26-x86-levers).
- **Measured and not kept**, in the same two folders
  ([2026-11-23-cpu-steps](https://github.com/Gcob/twelve-dollar-server-php/tree/main/lab/results/2026-11-23-cpu-steps)
  and [2026-11-24-cpu-steps-5b](https://github.com/Gcob/twelve-dollar-server-php/tree/main/lab/results/2026-11-24-cpu-steps-5b)):
  - group commit: +1.18 µs per request in one pair, a screen under the noise floor (2.57 µs), not a settled
    difference;
  - exclusive locking: -0.85 µs in one pair, also under the noise floor, and it forbids a second process on the
    database;
  - SQLite building the JSON (`json_group_array`): +0.62 µs in one pair, under its floor (0.86 µs) too;
  - the JSON by string concatenation: 9.4 % slower per feed in the micro benchmark;
  - an FFI driver to `libsqlite3`: +0.2 % against PDO per feed, and SQLite's own work is 98 % of a feed, so a driver
    has little to remove;
  - a leaner HTTP parser: saves 18.7 % of a parse, about 50 ns of a request;
  - libevent's loop presets: `nolock` and `changelist` remove no system call per request (5.624 and 5.620 against
    5.623), and `poll` was counted with no idle connections, which `poll` passes on every call;
  - PHP 8.4 and 8.6 against 8.5: -0.4 % and -0.1 %, inside the floor.

## Rules audit

The code is in this folder: `app.php` (the five endpoints and SQLite), `ring.php` (the io_uring loop and its HTTP parser), `connection.php`
(one HTTP connection of the epoll loop), `loop.php` (the epoll loop), `workers.php` (the epoll loop's supervisor), `server.php` (the
configuration, the choice of loop and the start).

### The loop: the ring, its older buffers on 6.8, its fallback, and why FFI

- **The ring.** One process, three rings (`ring_open()` in `ring.php`), all accepting from one listening socket: the first ring takes
  connections until its table is full, the next takes the rest. A ring is set up with `SINGLE_ISSUER`, `DEFER_TASKRUN` and no kernel thread
  (no SQPOLL), so the kernel posts completions only inside our own `io_uring_enter`, on our own thread. Nothing newer than kernel 6.8 is used.
  The requests are parsed and answered by the same rules as `connection.php` (header and body limits, pipelining, `Connection: close`, short
  sends, a response over a send slot), and the same `handler_handle()` of `app.php` runs them.
- **The older buffers on 6.8.** The first ring asks for a buffer ring; Ubuntu's 6.8 kernels answer `EINVAL` to that registration, and only to
  that, so the loop switches to `IORING_OP_PROVIDE_BUFFERS` (kernel 5.7) for all three rings and says `legacy buffers` in its `loop:` line. A
  kernel that takes the buffer ring says `buffer ring`. Any other refusal is a refusal of the ring.
- **The fallback.** Any refused step is the epoll loop, as it was before the ring existed (`workers.php`, `loop.php`, `connection.php`: two
  processes, a soft limit of 64,000 each), with the reason in the `loop:` line. Under Docker's default seccomp filter the server takes this path and
  still passes the 42 checks (`lab/submission-test.sh` runs it both ways).
- **Why FFI.** PHP has no io_uring of its own. The extensions that offer one were tried first and not kept: Swoole's `uring_socket` costs more per
  request than the epoll loop in the smoke and one process still stops at 65,535 descriptors, and ext-mrloop closes every connection after one
  request ([lab/results/2026-11-26-off-the-shelf-uring](https://github.com/Gcob/twelve-dollar-server-php/tree/main/lab/results/2026-11-26-off-the-shelf-uring)).
  Each would also be another thing to build and pin. FFI is PHP's own extension, built from the same tarball with `--with-ffi`, and calls the
  kernel's `syscall()` and a handful of libc functions (`ring.php` declares them, and the sizes of the kernel's structures are checked at boot).
  `ring.php` is the only file that uses it, and only on `libc.so.6`: there is no FFI driver for SQLite (the app reads SQLite through
  `pdo_sqlite`).

- **Rule 1, any number of processes:** the ring is one process with three rings (`ring_open()` in `ring.php`) and one database connection; the
  fallback is two, forked by `app_workers_supervise()` in `workers.php`, each with its own loop, its own listening socket (`diy_listen()` in
  `loop.php`, `SO_REUSEPORT`) and its own database connection.
- **Rule 5, no caching across requests:** every request runs its own statements against SQLite (`feed_query()`,
  `post_query()`, `post_exists()`, `like_insert()`, `post_insert()` in `app.php`). The only thing that lives from one
  request to the next is the set of prepared statements, which `app_boot()` prepares once (they cache the query plan,
  not data). There is no result, response or token cache. `jwt_verify()` recomputes every token's HMAC-SHA256 and
  compares it with `hash_equals` on every request, accepts HS256 only, and rejects a token with no `exp` or an expired
  one. SQLite's page cache is the only cache.
- **Rule 6, durable before the response:** `app_connection_pragmas()` sets `journal_mode = WAL` and
  `synchronous = NORMAL`, and there is no explicit transaction: each write is its own autocommit transaction.
  `post_insert()` fetches every row of the `INSERT ... RETURNING` (steps the statement to its end, where autocommit
  commits it, and a failed commit is an exception, so the route answers 500), before `post_create()` builds the 201.
  `like_insert()` runs a statement that ends when `execute()` returns, before `like_create()` answers.
- **Rule 7, no hard-coded response, no load-test detection:** every body comes from SQLite or from the request through
  `json_encode`. The soft limit in `AppRing::parse()` (`ring.php`) and in `DiyConnection::respond()` (`connection.php`)
  compares the count of open connections with a constant, so it behaves the same for any client, and it never closes an idle connection.
- **Rule 9, Nginx or direct:** direct. `server.php` reads `HOST` (default `0.0.0.0`) and `PORT` (default 80) from the
  environment, with `SQLITE_PATH` and `JWT_SECRET`, and reads no other variable.
- **Rule 10, built from source, pinned:** `install.sh` pins PHP 8.5.13, ext-event 3.2.0 and SQLite 3.54.1 by version and
  sha256 and checks each download (`fetch()`) before unpacking it. The other libraries and the toolchain come from
  Ubuntu's own apt packages (libffi among them, for PHP's FFI extension, which is built from PHP's own tarball). The ring is PHP in this folder:
  no C is compiled and no library is downloaded for it. Nothing is prebuilt. The SQLite is compiled on the machine, twice (once with the profile
  instrumentation, once with the profile), and the training between the two runs the server's own statements on a database
  that `sqlite-train.php` generates from the challenge's schema: no seed, no bench data and no request of the bench is
  read or replayed. In the clean container, `start.sh` was healthy after 0.1 s (limit: 60 s).
- **Rule 11, nothing tuned for us:** no kernel parameter, no CPU pinning and no `setrlimit`. The ring needs none of them: it runs when the
  machine lets a process call io_uring (Ubuntu 24.04's own default), and when it does not the server falls back and says so. Its tables
  are sized by the open-files limit the process already has (it never raises it). The rings, the two fallback processes, the
  backlog (4,096) and the pragmas are settings inside our own process.

## Results

**Our own run, not the bench's score.** We ran the entry on AWS with the challenge's `bench/load.js`, unchanged. The
server was a `c5.large` limited to one core (EC2's CPU options) and 2 GB for the whole box (`mem=2G`), with no swap.
`install.sh` installed it and systemd started it as `deploy` with `LimitNOFILE=65535` and `CAP_NET_BIND_SERVICE`. k6
ran on a separate 16-vCPU box in the same placement group. The search was shortened: 2-minute probes from 71,000 users
in 5 % steps, then a 5-minute hold.

135,000 users held for 5 minutes: p95 171 ms, p99 328 ms, no error, 14,122 requests a second, the server at 83 % of its
core and 881 MiB at peak. At 142,000 users the run failed, and we could not separate the server's wall from the load
generator's. So 135,000 is a lower bound.

This is not what the bench will read. The bench's core is about 1.57 times slower per request than the AWS core, as
estimated from two entries (the leaderboard's numbers against the same entries on this Xeon), so the bench should read
lower. The results give an estimate, labelled as one; this README claims none. The runs, one by one:
[lab/results/2026-11-25-x86-score](https://github.com/Gcob/twelve-dollar-server-php/tree/main/lab/results/2026-11-25-x86-score).

What is checked: `test/test.sh` passes 42 of 42 in a clean Ubuntu 24.04 container (1 CPU, 2 GiB,
`install.sh` as root, `build.sh` and `start.sh` as `deploy` on port 80), and in a run that copies the challenge's CI
setup, where Ubuntu's PHP 8.3 is first on the `PATH` (`bash lab/submission-test.sh --ci`).
