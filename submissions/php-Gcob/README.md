# PHP + our own event loop

| | |
|---|---|
| Language | PHP 8.5.13, built from the php.net tarball (sha256 pinned) by `install.sh` with `./configure CFLAGS=-O2 --disable-cgi --disable-fpm --enable-opcache --with-pdo-sqlite --enable-mbstring --with-sodium --with-ffi --enable-ctype --with-iconv`; OPcache with the tracing JIT |
| Framework | None: an event loop of our own (`loop.php`, `connection.php`) on ext-event 3.2.0 (PECL tarball, sha256 pinned), which uses Ubuntu 24.04's libevent 2.1.12-stable |
| SQLite driver | `pdo_sqlite`, linked to Ubuntu 24.04's SQLite 3.45.1 |
| Dependencies | None beyond PHP's own extensions (pcntl, sockets, posix, mbstring, ctype, hash, json) and ext-event. No Composer. The toolchain and the libraries come from Ubuntu's apt |
| **Nginx or direct** | **Direct**: serves `0.0.0.0:80` itself, with `HOST` and `PORT` read from the environment |

## Running it

```bash
sudo bash install.sh   # apt: toolchain and libraries; builds PHP and ext-event into /opt/php-gcob
bash build.sh          # nothing to compile; lints every PHP file
SQLITE_PATH=... JWT_SECRET=... HOST=0.0.0.0 PORT=80 bash start.sh
```

- **PHP goes to `/opt/php-gcob`**, its own prefix, so it never clashes with the system's PHP (Ubuntu 24.04 ships 8.3).
  No `php.ini` is written and nothing is enabled globally: `start.sh` loads pcntl, sockets and event with
  `-d extension=`, and passes the OPcache and JIT settings the same way.
- **`install.sh` took 232 s** in a clean Ubuntu 24.04 container limited to 1 CPU and 2 GiB, on an arm64 core (Docker on
  an M3 Pro). The droplet's x86 vCPU is not measured yet.
- **`start.sh` was healthy after 0.1 s** in the same container (the poll step is 0.1 s), with 42 of 42 checks passing
  there. `bash lab/submission-test.sh` repeats this run, as root then `deploy`:
  [lab/submission-test.sh](https://github.com/Gcob/twelve-dollar-server-php/blob/main/lab/submission-test.sh).
- The last line `install.sh` prints is `installed: PHP 8.5.13, SQLite 3.45.1, libevent 2.1.12-stable, ext-event 3.2.0,
  OPcache with JIT, ...`. It is printed by the installed PHP itself, and the install fails if an extension or the JIT
  is missing.

## Optimizations, and why

Every choice was judged on **microseconds of CPU per request** at a fixed request rate, against a noise floor made of
A/A pairs (the same server run twice), in a replay of the bench's own `load.js` journey with 60,000 idle connections
held. The method, the harness and every raw result are in
[lab/README.md](https://github.com/Gcob/twelve-dollar-server-php/blob/main/lab/README.md). The numbers below come
from Docker on an M3 Pro (arm64, 1 CPU, 2 GiB), unless a line names the AWS `c5.2xlarge` (one Xeon vCPU, its
hyperthread sibling left idle). Neither is the droplet.

- **Our own loop on ext-event, one request at a time, no framework.** A readable event reads, parses, runs the handler
  and writes the answer in one callback: no coroutine, no thread, no request or response object. In the
  runtime bake-off (7,000 req/s) it cost 21.88 µs per request on a trivial route and 29.14 on a post read from the
  seed, against Swoole's 25.47 and 32.83 and Workerman's 26.24 and 33.32 (its caches out): 14.1 % and 11.3 % under
  Swoole. Results:
  [lab/results/2026-11-21-bake-off](https://github.com/Gcob/twelve-dollar-server-php/tree/main/lab/results/2026-11-21-bake-off).
- **Two processes on one port (`SO_REUSEPORT`), each with a soft limit of 64,000 connections.** One process has 65,535
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
  not measured at 150,000.
- **The supervisor.** The parent forks the two processes and opens nothing itself. It never restarts one: if one ends,
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

The code is in this folder: `app.php` (the five endpoints and SQLite), `connection.php` (one HTTP connection),
`loop.php` (the event loop), `workers.php` (the supervisor), `server.php` (the configuration and the start).

- **Rule 1, any number of processes:** two, forked by `app_workers_supervise()` in `workers.php`, each with its own
  loop, its own listening socket (`diy_listen()` in `loop.php`, `SO_REUSEPORT`) and its own database connection.
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
  `json_encode`. The soft limit in `DiyConnection::respond()` (`connection.php`) compares the process's own count of
  open connections with a constant, so it behaves the same for any client, and it never closes an idle connection.
- **Rule 9, Nginx or direct:** direct. `server.php` reads `HOST` (default `0.0.0.0`) and `PORT` (default 80) from the
  environment, with `SQLITE_PATH` and `JWT_SECRET`, and reads no other variable.
- **Rule 10, built from source, pinned:** `install.sh` pins PHP 8.5.13 and ext-event 3.2.0 by version and sha256 and
  checks each download (`fetch()`) before unpacking it. The libraries and the toolchain come from Ubuntu's own apt
  packages. Nothing is prebuilt. In the clean container, `start.sh` was healthy after 0.1 s (limit: 60 s).
- **Rule 11, nothing tuned for us:** no kernel parameter, no CPU pinning and no `setrlimit`. The two processes, the
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

This is not what the bench will read. The AWS core costs about 1.57 times less per request than the bench's box, as
estimated from two entries (the leaderboard's numbers against the same entries on this Xeon), so the bench should read
lower. We give no number for it. The runs, one by one:
[lab/results/2026-11-25-x86-score](https://github.com/Gcob/twelve-dollar-server-php/tree/main/lab/results/2026-11-25-x86-score).

What is checked: `test/test.sh` passes 42 of 42 in a clean Ubuntu 24.04 container (1 CPU, 2 GiB,
`install.sh` as root, `build.sh` and `start.sh` as `deploy` on port 80), and in a run that copies the challenge's CI
setup, where Ubuntu's PHP 8.3 is first on the `PATH` (`bash lab/submission-test.sh --ci`).
