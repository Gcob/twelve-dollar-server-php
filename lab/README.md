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
  `opcache.memory_consumption=128` and `memory_limit=512M`, whatever the image's own ini says. JIT on is
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

## Checks

```bash
bash lab/check.sh
```

One line per check, `ok` or `FAIL`, non-zero exit if any fails. To add one, write a `check_<name>` function in the
script and list it in `CHECKS`.
