# lab/

The measuring lab of phases 2 to 4: scripts that build the same seed data and the same environment for every
measurement. Nothing in `lab/data/` is committed.

## Seed

```bash
bash lab/seed.sh
```

Builds the challenge's seed database from the clone in `reference/twelve-dollar-server-challenge/` (about a minute,
about 250 MB) into `lab/data/feed.db` and `lab/data/tokens.json`. It must end with
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
not built` when the image has no Swoole).

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
  does the same, and so on, so a slow period of the host hits every case alike. A run of 5 processes takes about 90 s
  per image and JIT state for the sample bench.
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
`--php-ini key=value` (added after the entries' PHP flags, repeatable).

`lab/servers/noop-swoole.php` is the floor: a Swoole HTTP server with the settings of both Swoole entries
(`SWOOLE_BASE`, one worker, no coroutine, POST/cookie/file parsing and compression off) that answers `200 {"status":"ok"}`
to every request. The server runs with the PHP flags of the entries' `start.sh` plus two the lab pins
(`LAB_SERVER_PHP_FLAGS` in `lib.sh`): `opcache.file_update_protection=0` (by default a file saved less than 2 s before the
server starts is not cached, so it would run without OPcache and JIT, and the run would still look valid) and
`zend.assertions=-1` (Ubuntu's `php.ini` sets it; the source images have none and PHP's own default is 1). The JSON
records the ini values PHP reads back with these flags and whether the JIT is on (`server.ini`).

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

## Checks

```bash
bash lab/check.sh
```

One line per check, `ok` or `FAIL`, non-zero exit if any fails. To add one, write a `check_<name>` function in the
script and list it in `CHECKS`.
