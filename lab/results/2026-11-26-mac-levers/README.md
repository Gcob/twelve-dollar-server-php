# Phase 8's levers on the Mac

The step lab's pairs on the Mac's quiet Docker VM (arm64): phase 7's submission (the reference) against the two levers phase 8 still has open, the
tuned SQLite (`8.5-sqlite`) and our own io_uring loop (`APP_RING=1 APP_RINGS=3`), with the Mac's own A/A floor. Arm64 numbers: they close nothing
on their own and start no change to the submission; the same series runs later on AWS x86. This file is written in two steps: the predictions
first (below, before any run of the series), then the plan of the runs, the machine, the tables and the reading.

## Predictions

Written by the project manager on 2026-11-26 at 21:21, before any run of the series.

> Mac's Docker VM (arm64, kernel 6.12), 7,500 req/s, `s = 0.02`, 60,000 idle, 60 s runs, no seccomp filter, the
> reference phase 7's submission.
>
> 14. **The Mac's A/A floor:** 0.5 to 2.0 µs/req; the reference at 31 to 35 µs/req (scope 5's smokes read about 32.5).
> 15. **The tuned SQLite's feed micro on the Mac:** 15 to 28 % under Ubuntu's 3.45.1 (scope 2's smoke read 23 %),
>     enough to call for its pair; the pair −1.5 to −4 µs/req, beyond the floor with about 60 % confidence.
> 16. **The ring on the Mac:** −1.5 to +1.5 µs/req, within the floor (scope 5's three smokes: −1.0, +0.1, −0.3): not
>     chosen on the Mac, its verdict left to the x86 series.
> 17. **The winners together:** the tuned SQLite alone, if it wins; nothing to pair otherwise.
> 18. **Time:** 2 to 3 hours of runs.

## Plan of the runs

One quiet Docker VM, the five steps one after the other, from the branch's commit `0c6da9f` (the series started at 21:27 on 2026-11-26 and ended at 22:25; a doc-only commit, the x86
session's predictions, landed on the branch in between: no code and no tracked file changed while the runs went). Before each step `docker ps` showed no running container; every run's JSON says
`other_containers.count` 0. No image build and no `lab/check.sh` ran during the series. Every call has `--image 8.5 --rate 7500 --think-scale 0.02 --idle 60000 --seconds 60 --warmup 750,10 --seccomp-unconfined`,
the alternating order and an `--expect-loop` for every variant; `REF` below is the reference's part:
`--variant ref= --server-variant ref=submissions/php-Gcob/server.php --variant-args "ref=--ext pcntl --ext sockets --ext event" --expect-loop ref=epoll`.

1. **`aa-7500/`, the A/A floor:** `ref` against `ref2` (the same server file and arguments), 5 pairs, `--out lab/results/2026-11-26-mac-levers/aa-7500`. The floor is
   `bash lab/steplab-floor.sh lab/results/2026-11-26-mac-levers/aa-7500`; every later step has `--floor-from` that folder. Stop: fewer than 4 of 10 valid runs.
2. **`feed-micro/`, the feed micro:** `bash lab/micro.sh lab/micro/benches/feed.php --images 8.5,8.5-sqlite --jit on --jit-buffer-size 32M --out lab/results/2026-11-26-mac-levers/feed-micro/feed.json`:
   the full run (5 processes a case), the JIT as the submission's `install.sh` sets it (`opcache.jit=tracing`, a 32 MiB buffer). The bar: the saving per feed times 0.46 feeds a request (a bench loop makes
   one feed in about 2.17 requests), in µs/req, against the floor.
3. **`sqlite-7500/`, the tuned SQLite's pair** (only if the bar reaches the floor): `ref` against `sqlite` = `--variant sqlite= --server-variant sqlite=submissions/php-Gcob/server.php
   --variant-args "sqlite=--image 8.5-sqlite --ext pcntl --ext sockets --ext event" --expect-loop sqlite=epoll`, 1 pair, then 2 more (`--first-round 2`) because the first beat the floor.
4. **`ring-7500/`, the ring's pair:** `ref` against `ring` = the lab app on 3 rings configured as it would ship:
   `--variant ring=APP_RING=1,APP_RINGS=3,APP_PRAGMAS=mmap-off,APP_SOFT_CONN_LIMIT=192000 --variant-args "ring=--server-nofile 32768" --expect-loop "ring=ring, 3 rings"` (the 60,000 idle span 2 rings; telemetry
   off on both sides). 1 pair, then 2 more because the first beat the floor. Against the submission the lab app's other settings already match (`submission-parity`'s README): `mmap-off` is the submission's
   `cache_size -65536` and `mmap_size 0`, the other pragmas are the same statements, the backlog is 4,096 on both, and the workers and the loop are what the ring replaces; no other setting was added.
5. **`together-7500/`, the winners together** (both 3 and 4 won): `ref` against `ring-sqlite` = the ring variant of step 4 with `--image 8.5-sqlite` added to its `--variant-args`, 1 pair.

`summarize.sh` regenerates every table below from the JSON files; the raw console output of every step is in the factory's private folder.

## The machine

| | |
|---|---|
| Mac | Apple M3 Pro, 12 cores, 36 GiB, macOS 27.2 |
| Docker | Docker Desktop 4.76.0, engine 29.5.2 |
| The VM | 12 CPUs, 7.75 GiB; kernel `6.12.76-linuxkit` (`uname -r` in a lab container); transparent huge pages `[always] madvise never` (`/sys/kernel/mm/transparent_hugepage/enabled`) |
| The lab's limits | the server on one CPU (cpuset 2), 2 GiB, no swap, 65,535 fds (32,768 for the ring variant's server), host network; no seccomp filter on either side |
| The image | `php-lab:8.5` (PHP 8.5.13, SQLite 3.45.1 from Ubuntu) and `php-lab:8.5-sqlite` (SQLite 3.54.1 from the amalgamation, tuned, PGO), both arm64 |
| The code | the branch at `0c6da9f` |
| Load before the series | nothing running in Docker; the Mac's own load average was 3.8 (the desktop apps) |

## What differed from the brief

- **The micro ran with `--jit on --jit-buffer-size 32M`** (one JIT state, the submission's buffer): the micro's default buffer is 64 MiB and it runs JIT on and off.
- **The bar reads the `APP_PRAGMAS=mmap-off` row**, not the default row: the submission's connection settings are `mmap_size = 0`. Both rows are in the table.
- **The together pair's variant is named `ring-sqlite`** (and its output folder is `together-7500/`).
- **`summarize.sh` adds a "loop line" column** to the runs tables, the run's `server.loop`, so the `--expect-loop` check can be read from the table.
- **Nothing else:** no step stopped early, no run was repeated, no run was invalid.

## Results

<!-- BEGIN summarize -->
### The Mac's A/A floor (the reference against itself, `ref` and `ref2`, 5 pairs, 7,500 req/s)

| Run | position in its round | valid | other containers | idle held at the end | loop line | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|
| ref2-1 | 1 | true | 0 | 60000 | epoll | 7459.4 | 99.4 % | 31.69 | 0.63 | 2.57 | pass |
| ref-1 | 2 | true | 0 | 60000 | epoll | 7440.3 | 99.1 % | 34.79 | 0.94 | 5.11 | pass |
| ref-2 | 1 | true | 0 | 60000 | epoll | 7445 | 99.2 % | 33.75 | 0.79 | 3.63 | pass |
| ref2-2 | 2 | true | 0 | 60000 | epoll | 7454.3 | 99.3 % | 32.99 | 0.68 | 3.42 | pass |
| ref2-3 | 1 | true | 0 | 60000 | epoll | 7447.1 | 99.2 % | 32.74 | 0.68 | 3.42 | pass |
| ref-3 | 2 | true | 0 | 60000 | epoll | 7449.2 | 99.3 % | 32.68 | 0.65 | 3.27 | pass |
| ref-4 | 1 | true | 0 | 60000 | epoll | 7447.9 | 99.2 % | 32.96 | 0.76 | 3.37 | pass |
| ref2-4 | 2 | true | 0 | 60000 | epoll | 7455.4 | 99.3 % | 33 | 0.69 | 3.03 | pass |
| ref2-5 | 1 | true | 0 | 60000 | epoll | 7452.1 | 99.3 % | 33.68 | 0.74 | 3.37 | pass |
| ref-5 | 2 | true | 0 | 60000 | epoll | 7453.9 | 99.3 % | 33.38 | 0.71 | 3.47 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before |
|---|---|---|---|---|---|---|
| ref2-1 | 0.33 | 2.24 | 7.50 % | 0.00 % | 0.374 | 0 |
| ref-1 | 2.55 | 3.03 | 10.70 % | 0.00 % | 0.467 | 10036 |
| ref-2 | 3.31 | 2.94 | 8.67 % | 0.00 % | 0.424 | 9144 |
| ref2-2 | 2.58 | 3.02 | 8.31 % | 0.00 % | 0.452 | 9128 |
| ref2-3 | 2.93 | 2.29 | 8.57 % | 0.00 % | 0.548 | 9165 |
| ref-3 | 2.19 | 2.54 | 8.25 % | 0.00 % | 0.445 | 9159 |
| ref-4 | 3.42 | 2.81 | 7.74 % | 0.00 % | 0.461 | 9083 |
| ref2-4 | 2.81 | 3.23 | 8.40 % | 0.00 % | 0.464 | 9164 |
| ref2-5 | 2.58 | 3.15 | 8.70 % | 0.00 % | 0.481 | 9150 |
| ref-5 | 3.38 | 2.87 | 9.96 % | 0.00 % | 0.488 | 9137 |

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  ref2           yes       7459.4      31.7     0.63     2.57         0   2.24     0.37  pass
    1  ref            yes       7440.3      34.8     0.94     5.11     10036   3.03     0.47  pass
    2  ref            yes         7445      33.8     0.79     3.63      9144   2.94     0.42  pass
    2  ref2           yes       7454.3        33     0.68     3.42      9128   3.02     0.45  pass
    3  ref2           yes       7447.1      32.7     0.68     3.42      9165   2.29     0.55  pass
    3  ref            yes       7449.2      32.7     0.65     3.27      9159   2.54     0.45  pass
    4  ref            yes       7447.9        33     0.76     3.37      9083   2.81     0.46  pass
    4  ref2           yes       7455.4        33     0.69     3.03      9164   3.23     0.46  pass
    5  ref2           yes       7452.1      33.7     0.74     3.37      9150   3.15     0.48  pass
    5  ref            yes       7453.9      33.4     0.71     3.47      9137   2.87     0.49  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
ref               5/5      0      33.4      32.7 to 34.8     3.47  reference                      -  reference
ref2              5/5      0        33      31.7 to 33.7     3.37  -3.1 -0.8 +0.1 +0 +0.3        +0  no floor: not judged: run with --floor <µs> from an A/A calibration

Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least the floor in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

Floor: **0.855 µs/req** (|median 0.04| + interquartile range 0.815, 5 paired differences -3.1, -0.76, +0.05, +0.04, +0.3).

Valid runs: 10 of 10. Reference (both sides) median 33 µs/req.

### The feed micro (`lab/micro.sh lab/micro/benches/feed.php --images 8.5,8.5-sqlite --jit on --jit-buffer-size 32M`, the JIT as the submission runs it, 5 processes a case)

| Case | Ubuntu's 3.45.1 (`8.5`) ns/op | tuned 3.54.1 (`8.5-sqlite`) ns/op | saving ns | saving % |
|---|---|---|---|---|
| `feed/reference/assoc, APP_PRAGMAS=mmap-off` | 29982 | 22109 | 7874 | 26.3 % |
| `feed/reference/assoc` | 30955 | 23819 | 7136 | 23.1 % |
| `post/reference/assoc` | 2450 | 2067 | 383 | 15.6 % |

The submission opens its connections with `cache_size = -65536` and `mmap_size = 0`, which is the `APP_PRAGMAS=mmap-off` case: that row is the one the bar reads.

**The bar:** the saving per feed, 7874 ns = 7.87 µs, times 0.46 feeds a request = **3.62 µs/req**, against the floor 0.855 µs/req: it reaches the floor, so the pair is run. (With the default pragmas row the saving is 7136 ns, 3.28 µs/req.)

### The tuned SQLite's pairs (`sqlite`: the submission's server on `8.5-sqlite`, against `ref`)

| Run | position in its round | valid | other containers | idle held at the end | loop line | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|
| sqlite-1 | 1 | true | 0 | 60000 | epoll | 7445.9 | 99.2 % | 30.24 | 0.68 | 3.17 | pass |
| ref-1 | 2 | true | 0 | 60000 | epoll | 7448.4 | 99.2 % | 33.24 | 0.71 | 3.32 | pass |
| ref-2 | 1 | true | 0 | 60000 | epoll | 7449.4 | 99.3 % | 33.62 | 0.75 | 3.68 | pass |
| sqlite-2 | 2 | true | 0 | 60000 | epoll | 7445.9 | 99.2 % | 29.98 | 0.65 | 3.03 | pass |
| sqlite-3 | 1 | true | 0 | 60000 | epoll | 7452.6 | 99.3 % | 29.95 | 0.65 | 3.17 | pass |
| ref-3 | 2 | true | 0 | 60000 | epoll | 7449.7 | 99.3 % | 33.48 | 0.73 | 3.47 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before |
|---|---|---|---|---|---|---|
| sqlite-1 | 0.95 | 2.39 | 8.36 % | 0.00 % | 0.396 | 0 |
| ref-1 | 2.60 | 2.79 | 8.46 % | 0.00 % | 0.526 | 10036 |
| ref-2 | 3.09 | 3.95 | 8.48 % | 0.00 % | 0.424 | 9141 |
| sqlite-2 | 3.24 | 3.50 | 9.22 % | 0.00 % | 0.399 | 9166 |
| sqlite-3 | 3.26 | 3.27 | 8.68 % | 0.00 % | 0.632 | 9163 |
| ref-3 | 2.63 | 2.31 | 8.53 % | 0.00 % | 0.390 | 9129 |

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  sqlite         yes       7445.9      30.2     0.68     3.17         0   2.39      0.4  pass
    1  ref            yes       7448.4      33.2     0.71     3.32     10036   2.79     0.53  pass
    2  ref            yes       7449.4      33.6     0.75     3.68      9141   3.95     0.42  pass
    2  sqlite         yes       7445.9        30     0.65     3.03      9166    3.5      0.4  pass
    3  sqlite         yes       7452.6        30     0.65     3.17      9163   3.27     0.63  pass
    3  ref            yes       7449.7      33.5     0.73     3.47      9129   2.31     0.39  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
ref               3/3      0      33.5      33.2 to 33.6     3.47  reference                      -  reference
sqlite            3/3      0        30        30 to 30.2     3.17  -3 -3.6 -3.5                -3.5  beyond the noise

Floor: 0.855 us, from lab/results/2026-11-26-mac-levers/aa-7500: |median 0.04| + interquartile range 0.815 of 5 paired differences (quartiles by linear interpolation, inclusive)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.855 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### The ring's pairs (`ring`: the lab app on 3 rings, `APP_PRAGMAS=mmap-off`, soft limit 192,000, server nofile 32,768, against `ref`)

| Run | position in its round | valid | other containers | idle held at the end | loop line | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|
| ring-1 | 1 | true | 0 | 60000 | ring, 3 rings | 7450.9 | 99.3 % | 31.26 | 1.14 | 5.58 | pass |
| ref-1 | 2 | true | 0 | 60000 | epoll | 7452.5 | 99.3 % | 33.41 | 0.73 | 3.32 | pass |
| ref-2 | 1 | true | 0 | 60000 | epoll | 7451.4 | 99.3 % | 33.28 | 0.74 | 3.32 | pass |
| ring-2 | 2 | true | 0 | 60000 | ring, 3 rings | 7445.1 | 99.2 % | 31.15 | 1.05 | 5.5 | pass |
| ring-3 | 1 | true | 0 | 60000 | ring, 3 rings | 7449.4 | 99.3 % | 31.36 | 1.14 | 5.58 | pass |
| ref-3 | 2 | true | 0 | 60000 | epoll | 7456.9 | 99.4 % | 33.34 | 0.72 | 3.17 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before |
|---|---|---|---|---|---|---|
| ring-1 | 1.69 | 3.23 | 9.77 % | 0.00 % | 0.415 | 9149 |
| ref-1 | 3.81 | 2.91 | 8.52 % | 0.00 % | 0.445 | 9191 |
| ref-2 | 2.57 | 3.18 | 9.26 % | 0.00 % | 0.459 | 9172 |
| ring-2 | 3.29 | 3.75 | 9.71 % | 0.00 % | 0.484 | 9113 |
| ring-3 | 3.08 | 4.38 | 9.74 % | 0.00 % | 0.542 | 9172 |
| ref-3 | 4.12 | 3.95 | 8.76 % | 0.00 % | 0.424 | 9179 |

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  ring           yes       7450.9      31.3     1.14     5.58      9149   3.23     0.42  pass
    1  ref            yes       7452.5      33.4     0.73     3.32      9191   2.91     0.45  pass
    2  ref            yes       7451.4      33.3     0.74     3.32      9172   3.18     0.46  pass
    2  ring           yes       7445.1      31.2     1.05      5.5      9113   3.75     0.48  pass
    3  ring           yes       7449.4      31.4     1.14     5.58      9172   4.38     0.54  pass
    3  ref            yes       7456.9      33.3     0.72     3.17      9179   3.95     0.42  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
ref               3/3      0      33.3      33.3 to 33.4     3.32  reference                      -  reference
ring              3/3      0      31.3      31.2 to 31.4     5.58  -2.1 -2.1 -2                -2.1  beyond the noise

Floor: 0.855 us, from lab/results/2026-11-26-mac-levers/aa-7500: |median 0.04| + interquartile range 0.815 of 5 paired differences (quartiles by linear interpolation, inclusive)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.855 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### The winners together (`ring-sqlite`: the ring on `8.5-sqlite`, against `ref`)

| Run | position in its round | valid | other containers | idle held at the end | loop line | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|
| ring-sqlite-1 | 1 | true | 0 | 60000 | ring, 3 rings | 7444.7 | 99.2 % | 27.8 | 1.01 | 4.67 | pass |
| ref-1 | 2 | true | 0 | 60000 | epoll | 7454.6 | 99.3 % | 32.74 | 0.65 | 3.32 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before |
|---|---|---|---|---|---|---|
| ring-sqlite-1 | 2.45 | 3.50 | 9.53 % | 0.00 % | 0.574 | 9147 |
| ref-1 | 3.85 | 3.48 | 8.00 % | 0.00 % | 0.410 | 9147 |

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  ring-sqlite    yes       7444.7      27.8     1.01     4.67      9147    3.5     0.57  pass
    1  ref            yes       7454.6      32.7     0.65     3.32      9147   3.48     0.41  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
ref               1/1      0      32.7      32.7 to 32.7     3.32  reference                      -  reference
ring-sqlite       1/1      0      27.8      27.8 to 27.8     4.67  -4.9                        -4.9  screen: beats the floor

Floor: 0.855 us, from lab/results/2026-11-26-mac-levers/aa-7500: |median 0.04| + interquartile range 0.815 of 5 paired differences (quartiles by linear interpolation, inclusive)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.855 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### One line per lever

- **tuned SQLite:** reference 33.48 µs/req, tuned SQLite 29.98 µs/req over 3 pair(s); paired differences -3, -3.64, -3.52, **median -3.52 µs/req** (-10.53 %) against the floor 0.855: **beyond the floor**. Mac estimate, arm64, not the bench: 86800 x 33.48 / 29.98 = **96919 users**.
- **ring:** reference 33.34 µs/req, ring 31.26 µs/req over 3 pair(s); paired differences -2.15, -2.13, -1.98, **median -2.13 µs/req** (-6.39 %) against the floor 0.855: **beyond the floor**. Mac estimate, arm64, not the bench: 86800 x 33.34 / 31.26 = **92575 users**.
- **ring on the tuned SQLite:** reference 32.74 µs/req, ring on the tuned SQLite 27.8 µs/req over 1 pair(s); paired differences -4.94, **median -4.94 µs/req** (-15.09 %) against the floor 0.855: **one pair: a screen that beats the floor, no verdict**. Mac estimate, arm64, not the bench: 86800 x 32.74 / 27.8 = **102230 users**.

<!-- END summarize -->

## The reading

All figures are arm64, on the Mac's Docker VM, at 7,500 req/s: they close nothing on their own and start no change to the submission. The reference runs at about 33 µs/req.

- **The floor is 0.855 µs/req** (|median +0.04| + interquartile range 0.815 of 5 paired differences). All 10 runs are valid, every run's loop line is `epoll`. The first pair of the A/A is far from the other four
  (-3.10 against -0.76 to +0.30): `ref2` ran first and read 31.7, `ref` second and read 34.8. The floor counts every valid run, so that one pair is most of its interquartile range; without it the four
  others would give a floor under 0.4. It is kept as the rule says, so the verdicts below are against the cautious reading.
- **The tuned SQLite (chosen on the Mac).** The micro says 7,874 ns less a feed (26.3 % under Ubuntu's 3.45.1 on the submission's pragmas, 23.1 % on the default pragmas), which is 7.87 x 0.46 = 3.62 µs/req, four times the
  floor, so its pair was run. The three pairs are -3.00, -3.64 and -3.52 µs/req (median -3.52, -10.5 %): all the same sign, 4 times the floor, the pair says what the micro said (3.62 against 3.52). Chosen on the Mac
  because the bar, the three pairs and the micro agree, and the effect is in the SQLite library's own work, which has no reason to be an arm64 trick; the x86 series still has to confirm it before the
  submission's `install.sh` builds it. Mac estimate (arm64, not the bench): 86,800 x 33.48 / 29.98 = 96,919 users.
- **The ring (chosen on the Mac, as a candidate for x86, not as a result).** The three pairs are -2.15, -2.13 and -1.98 µs/req (median -2.13, -6.4 %), the same sign and 2.5 times the floor; all six runs valid, every
  loop line `ring, 3 rings` (no fallback). Two things stop it from being a verdict: it is one lever on one kind of CPU, and its p99 is worse in every pair (5.5 to 5.6 ms against 3.2 to 3.3 ms for the reference), a cost
  in tail latency that the CPU number does not show. Mac estimate (arm64, not the bench): 86,800 x 33.34 / 31.26 = 92,575 users.
- **The winners together** are one pair, so a screen: -4.94 µs/req (-15.1 %), beyond the floor. The two levers' own medians add to -5.65; the pair reads 0.7 under that, inside the A/A's spread, so they look
  additive, which one pair does not prove. Mac estimate: 86,800 x 32.74 / 27.80 = 102,230 users (arm64, not the bench).

### The predictions judged

14. **The A/A floor 0.5 to 2.0 µs/req, the reference at 31 to 35:** right. The floor is 0.855; the reference reads 33.0 in the A/A and 32.7 to 33.5 in the pairs.
15. **The feed micro 15 to 28 % under 3.45.1, the pair -1.5 to -4 µs/req, beyond the floor with about 60 % confidence:** right on all three. The micro reads 26.3 % (23.1 % on the default pragmas), the pair -3.52, beyond the floor.
16. **The ring -1.5 to +1.5 µs/req, within the floor, not chosen:** wrong. -2.13 is 0.63 µs outside the range and 2.5 times the floor, three pairs of three. The smokes of the ring's scope read -1.0, +0.1 and -0.3 without
    `APP_PRAGMAS=mmap-off` on the ring side (the lab app's default maps 256 MiB of the database, the submission's `mmap_size` is 0); this series gave the ring the submission's pragmas. That the 256 MiB map
    cost the smokes about 2 µs is a guess: no pair here tells the ring with the map from the ring without it.
17. **The winners together: the tuned SQLite alone, if it wins, nothing to pair otherwise:** its premise was wrong (the ring won too), so the pair was run: -4.94, one pair.
18. **Time, 2 to 3 hours of runs:** wrong, about an hour: 21:27 to 22:25 for 24 runs (the A/A 10, the tuned SQLite 6, the ring 6, together 2) and the micro.
