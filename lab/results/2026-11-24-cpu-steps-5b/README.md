# Phase 5b's instrument: the A/A floor in alternating order, the Mac's reconnect at 7,500, the PHP versions

The first measurements of phase 5b, on a quiet Docker VM (Docker Desktop on an M3 Pro, arm64, 1 CPU for the server, 2 GiB, PHP 8.5 unless a
series says otherwise): the noise floor of the new method, the cost of a reconnect on the Mac at the Xeon's rate, and a one-pair screen of
PHP 8.6 and 8.4 against 8.5. These are arm64 numbers, not a score. This file is written in two steps: the predictions first (below,
before any run), then the plan, the runs and the reading.

## Predictions (D5)

Copied unchanged from the phase's plan, section "Predictions (D5)" (all thirteen). This folder judges 1, 2, 3 and 10; the others belong to
later folders of the phase.


Written by the project manager on 2026-11-23 at 23:24, before any phase 5b measurement. Arm64, Docker Desktop on an
M3 Pro, quiet VM, PHP 8.5, the reference `APP_PRAGMAS=mmap-off` (25.0 to 25.6 µs/req at 24,000 req/s in 5a's pairs),
unless a line says otherwise.

1. **The host line on a quiet VM** during a 24,000 req/s plateau: load average 3 to 7, the VM's CPU 35 to 60 % busy,
   steal 0, `fsync_ms` 0.05 to 2 ms.
2. **The A/A at 24,000 in alternating order:** the median paired difference within ±0.15 µs (the order bias of
   about -0.2 cancels), and the floor (`|median| + interquartile range`) 0.3 to 0.8 µs/req.
3. **The Mac's reconnect at 7,500 req/s:** 7 to 9.5 µs (6.62 at 12,000, plus the 19 % the Mac's request rises at
   7,500), so the Xeon over the Mac for a reconnect is 2.5 to 3.4, not 3.58.
4. **S1-b on the Mac at 12,000 req/s:** +1.5 to +5 µs per request over S1-a (+5 to +18 %), beyond the floor.
5. **`APP_JSON=concat`:** 3 to 12 % under `encode` in ns per feed (micro); -0.2 to -0.8 µs per request at the macro,
   under the floor, so judged on its micro.
6. **`APP_JSON=sqlite`:** 10 to 25 % under `encode` in ns per feed (PDO's hundred values per feed and the encoder
   replaced by one pass in C); -1.5 to -4 µs per request at the macro, beyond the floor, and chosen.
7. **The FFI driver:** with `encode`, slower than PDO by 8 to 30 µs per feed (one FFI call per column and per row,
   about 120 a feed); with `sqlite`, within ±1 µs of PDO with `sqlite` (a handful of calls a feed), so the micro's
   stop fires or its pair is within the noise: not chosen.
8. **The loop presets:** each within ±0.5 µs of the reference, none chosen.
9. **The lean parser:** saves under 20 % of a parse in the micro (under 0.4 µs a request), so it isn't wired.
   (Revised at 23:37 after the plan review, before any measurement: the first version straddled the bar.)
10. **PHP 8.6 against 8.5:** within ±3 % (not chosen unless beyond the floor); 8.4 0 to 5 % slower.
11. **Together on the Mac:** 5b's configuration 1.5 to 4 µs per request under 5a's (6 to 15 %), interleaved holds;
    the held rate at `s = 0.02` stays the harness's floor (22,000 to 24,000 req/s); S6 still the largest step.
12. **x86, S1:** the second reconnect pair within 10 % of 23.69 µs; S1-b's 2 workers cost +5 to +15 % per request on
    the Xeon, less than S1-d's +25 % at 150,000 users: S1-b chosen for the bench's sizes.
13. **x86, the configuration:** 5b's 6 to 15 % under 5a's on the Xeon; the bench estimate 71 to 80 µs/req.

## Plan of the runs

Every series started with the quiet check of `lab/stages.sh` (no running container but the lab's, never `--allow-busy`); no image build and no
`lab/check.sh` ran during a series. The series file is `series.txt` here: `bash lab/stages.sh lab/results/2026-11-24-cpu-steps-5b/series.txt
--out lab/results/2026-11-24-cpu-steps-5b`, 60 s between series. The runs were made from a detached checkout of the lab at commit `0280e4c`
(the step lab's series driver, host line, alternating order and floor rule; `stages.json` records it, with no tracked file changed), not from
the branch's checkout, so that nothing edited the lab's code while they ran. Every call is PHP 8.5 (`--image 8.5`), `--think-scale 0.02`,
`--idle 60000`, a 60 s plateau, the warm-up of a tenth of the rate for 60 s, the alternating order (round 1 runs the reference last).

1. **`aa-24000`, the floor of the new method.** `APP_PRAGMAS=mmap-off` against itself (`a` and `b`, the same environment), 24,000 req/s, 5 pairs,
   telemetry off. Its first pair was the real-shape check of the new order and of the host line: both runs valid, both with a `host`.
   The floor is read from it, `|median| + interquartile range`, and every later screen of the phase reads it with `--floor-from`.
2. **`reconnect-7500`, the cost of one reconnect on the Mac at the Xeon's rate.** The skeleton (`APP_TELEMETRY=1`, the bare skeleton on purpose)
   against `APP_TELEMETRY=1,APP_SOFT_CONN_LIMIT=60000` (the soft limit equals the idle count, so every request of k6 reconnects), 7,500 req/s,
   `--vu-cap 5400`, one pair: the flags of the Xeon's reconnect pair, for the comparison. Its close count must be about its requests.
3. **`php-8.6` and `php-8.4`, a screen each.** `ref` (PHP 8.5) against `php86` or `php84` (`--variant-args 'php86=--image 8.6'`), both
   `APP_PRAGMAS=mmap-off`, 24,000 req/s, one pair, `--floor-from` the A/A folder. One pair is a screen, never a verdict; a screen that
   beat the floor would have had 2 more pairs (`--first-round 2`).
4. **Flags for the TIME_WAIT gates:** none. The defaults of `steplab.sh` were used: k6's addresses wait to hold at most 2,500 TIME_WAIT
   sockets (150 s at most), the idle client's addresses never wait (`--idle-time-wait-max` 100,000, since the idle client binds again on a busy
   port). No `--lag-gate`, no `--warmup`.
5. **`summarize.sh`** regenerates every table below from the JSON files, `stages.json` and two 5a folders (the Xeon's reconnect pair, the S1
   series' reconnect at 12,000 req/s).

## What differed from the plan of the runs

- **Nothing was run twice and no series failed.** All four exited 0; every one of the 16 runs is valid, 0 other containers, 60,000 idle
  connections held at the end and none closed by the server.
- **The idle client bound again 200 times in 11 of the 14 runs at 24,000 req/s** (`idle.bind_retries` 200: the busy ports of the run before, as in
  5a), and in none at 7,500 req/s. No run waited on the idle client's addresses.
- **The reconnect pair ran with the churn run first** (the alternating order: round 1 runs the reference last), where the Xeon's pair ran the
  skeleton first. The skeleton then waited 54 s for k6's TIME_WAIT sockets (5,303 on its busiest address, above the limit of 2,500) to drain
  before it started: its `waited s` is in the table. The Xeon's pair started both runs with 26,870 and 27,732 on the busiest address and waited 0 s.
- **No screen beat the floor, so no confirmation pairs were run.**
- **The host line's CPU share is of the whole VM** (12 CPUs): the server's own CPU is one of them, k6 uses most of the others.

## Results

<!-- BEGIN summarize -->
### The series, as the driver recorded them (`stages.json`)

The lab's commit when the file started: `0280e4c`, tracked files changed since: false. Gap between series: 60 s; `--allow-busy`: false.

| Series | start (UTC) | end (UTC) | exit code | other containers at the quiet check | busy | refused |
|---|---|---|---|---|---|---|
| aa-24000 | 2026-11-24T05:43:14Z | 2026-11-24T06:10:36Z | 0 | 0 | false | false |
| reconnect-7500 | 2026-11-24T06:11:36Z | 2026-11-24T06:18:06Z | 0 | 0 | false | false |
| php-8.6 | 2026-11-24T06:19:06Z | 2026-11-24T06:24:35Z | 0 | 0 | false | false |
| php-8.4 | 2026-11-24T06:25:35Z | 2026-11-24T06:31:03Z | 0 | 0 | false | false |

### A/A at 24,000 req/s in alternating order (`APP_PRAGMAS=mmap-off` against itself, `s = 0.02`, 60,000 idle, telemetry off, 5 pairs)

| Run | position in its round | valid | other containers | idle held at the end | closed by the server | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|
| b-1 | 1 | true | 0 | 60000 | 0 | 23498.9 | 97.9 % | 23.87 | 7.98 | 20.69 | pass |
| a-1 | 2 | true | 0 | 60000 | 0 | 23512.5 | 98 % | 23.32 | 7.3 | 18.1 | pass |
| a-2 | 1 | true | 0 | 60000 | 0 | 23473.2 | 97.8 % | 23.66 | 8.6 | 21.96 | pass |
| b-2 | 2 | true | 0 | 60000 | 0 | 23493.3 | 97.9 % | 23.75 | 8.86 | 20.09 | pass |
| b-3 | 1 | true | 0 | 60000 | 0 | 23521.7 | 98 % | 23.86 | 7.75 | 18.93 | pass |
| a-3 | 2 | true | 0 | 60000 | 0 | 23570.6 | 98.2 % | 23.22 | 7.19 | 16.07 | pass |
| a-4 | 1 | true | 0 | 60000 | 0 | 23549.8 | 98.1 % | 23.4 | 7.08 | 17.31 | pass |
| b-4 | 2 | true | 0 | 60000 | 0 | 23551.8 | 98.1 % | 23.17 | 7.08 | 16.07 | pass |
| b-5 | 1 | true | 0 | 60000 | 0 | 23541.2 | 98.1 % | 23.29 | 7.08 | 17.83 | pass |
| a-5 | 2 | true | 0 | 60000 | 0 | 23553.5 | 98.1 % | 23.7 | 7.19 | 16.8 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |
|---|---|---|---|---|---|---|---|
| b-1 | 0.18 | 4.79 | 26.15 % | 0.00 % | 0.296 | 0 | 0 |
| a-1 | 4.69 | 5.06 | 23.93 % | 0.00 % | 0.298 | 9964 | 0 |
| a-2 | 5.61 | 4.50 | 24.49 % | 0.00 % | 0.264 | 7054 | 0 |
| b-2 | 5.09 | 3.94 | 25.32 % | 0.00 % | 0.565 | 7182 | 0 |
| b-3 | 4.12 | 4.86 | 25.99 % | 0.00 % | 0.365 | 7183 | 0 |
| a-3 | 4.85 | 4.49 | 23.92 % | 0.00 % | 0.329 | 7171 | 0 |
| a-4 | 4.12 | 3.78 | 25.23 % | 0.00 % | 0.389 | 7164 | 0 |
| b-4 | 3.94 | 5.60 | 25.64 % | 0.00 % | 0.295 | 7154 | 0 |
| b-5 | 4.86 | 4.30 | 23.72 % | 0.00 % | 0.245 | 7155 | 0 |
| a-5 | 4.54 | 5.07 | 24.09 % | 0.00 % | 0.287 | 7181 | 0 |

The pairs (b minus a, the order alternates: round 1 runs b first, round 2 a first, and so on):

| Round | order | a µs/req | b µs/req | b minus a µs |
|---|---|---|---|---|
| 1 | alternate: b then a | 23.32 | 23.87 | +0.555 |
| 2 | alternate: a then b | 23.66 | 23.75 | +0.083 |
| 3 | alternate: b then a | 23.22 | 23.86 | +0.636 |
| 4 | alternate: a then b | 23.4 | 23.17 | -0.225 |
| 5 | alternate: b then a | 23.7 | 23.29 | -0.405 |

**Floor: |median| + interquartile range = 0.083 + 0.78 = 0.864 µs/req.** Differences +0.555, +0.083, +0.636, -0.225, -0.405; median +0.083, q1 -0.225, q3 +0.555, interquartile range 0.78.
Medians: a 23.4 µs/req, b 23.75 µs/req; the median of the 10 runs is 23.53. Achieved over offered: 97.8 % to 98.2 %; runs under the 97 % rule: 0 of 10.

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  b              yes      23498.9      23.9     7.98    20.69         0   4.79      0.3  pass
    1  a              yes      23512.5      23.3      7.3     18.1      9964   5.06      0.3  pass
    2  a              yes      23473.2      23.7      8.6    21.96      7054    4.5     0.26  pass
    2  b              yes      23493.3      23.7     8.86    20.09      7182   3.94     0.56  pass
    3  b              yes      23521.7      23.9     7.75    18.93      7183   4.86     0.37  pass
    3  a              yes      23570.6      23.2     7.19    16.07      7171   4.49     0.33  pass
    4  a              yes      23549.8      23.4     7.08    17.31      7164   3.78     0.39  pass
    4  b              yes      23551.8      23.2     7.08    16.07      7154    5.6      0.3  pass
    5  b              yes      23541.2      23.3     7.08    17.83      7155    4.3     0.25  pass
    5  a              yes      23553.5      23.7     7.19     16.8      7181   5.07     0.29  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
a                 5/5      0      23.4      23.2 to 23.7    17.31  reference                      -  reference
b                 5/5      0      23.7      23.2 to 23.9    18.93  +0.6 +0.1 +0.6 -0.2 -0.4      +0.1  no floor: not judged: run with --floor <µs> from an A/A calibration

Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least the floor in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### The Mac's reconnect at 7,500 req/s (the skeleton against S1-d with every request reconnecting, `APP_SOFT_CONN_LIMIT=60000`, telemetry on, one round)

| Run | position in its round | valid | other containers | idle held at the end | closed by the server | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|
| s1d-every-1 | 1 | true | 0 | 60000 | 0 | 7450.5 | 99.3 % | 38.48 | 1.1 | 3.74 | pass |
| skeleton-1 | 2 | true | 0 | 60000 | 0 | 7453.5 | 99.3 % | 32.57 | 0.84 | 3.74 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |
|---|---|---|---|---|---|---|---|
| s1d-every-1 | 1.86 | 3.24 | 10.56 % | 0.00 % | 0.365 | 0 | 0 |
| skeleton-1 | 1.47 | 3.12 | 8.20 % | 0.00 % | 0.311 | 9820 | 54 |

S1-d with every request reconnecting: the server sent 538025 `Connection: close` responses; k6 made 489175 requests, plus the warm-up's nominal 48750 (its rate times its plateau plus half its 10 s ramp; the server counts its whole life): a difference of 100, 0.02 % of the closes, so every request reconnected.

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  s1d-every      yes       7450.5      38.5      1.1     3.74         0   3.24     0.37  pass
    1  skeleton       yes       7453.5      32.6     0.84     3.74      9820   3.12     0.31  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
skeleton          1/1      0      32.6      32.6 to 32.6     3.74  reference                      -  reference
s1d-every         1/1      0      38.5      38.5 to 38.5     3.74  +5.9                        +5.9  no floor: not judged: run with --floor <µs> from an A/A calibration

Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least the floor in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

One pair: the skeleton 32.57, S1-d with every request reconnecting 38.48 µs/req: **one reconnect costs 5.91 µs on the Mac at 7,500 req/s** (18.2 % of the skeleton). At 12,000 req/s the Mac's was 6.62 µs (median of 5 pairs, S1 series), so the cost is 0.89 times that. The Xeon's reconnect at 7,500 req/s was 23.69 µs (one pair: skeleton 53.54, every-request 77.23): **the Xeon over the Mac for a reconnect is 4.01** (3.58 against the Mac's 12,000 req/s figure).

### PHP 8.6 against 8.5 at 24,000 req/s (`APP_PRAGMAS=mmap-off` on both, 8.6 through `--variant-args`, the A/A's floor, one pair)

| Run | position in its round | valid | other containers | idle held at the end | closed by the server | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|
| php86-1 | 1 | true | 0 | 60000 | 0 | 23583.4 | 98.3 % | 23.14 | 6.58 | 15.14 | pass |
| ref-1 | 2 | true | 0 | 60000 | 0 | 23578.7 | 98.2 % | 23.16 | 6.68 | 15.14 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |
|---|---|---|---|---|---|---|---|
| php86-1 | 1.01 | 4.33 | 23.75 % | 0.00 % | 0.285 | 10036 | 0 |
| ref-1 | 4.04 | 5.46 | 23.71 % | 0.00 % | 0.287 | 9936 | 0 |

One pair: ref 23.16, php86 23.14 µs/req: **-0.024 µs, -0.104 %** of the reference.

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  php86          yes      23583.4      23.1     6.58    15.14     10036   4.33     0.28  pass
    1  ref            yes      23578.7      23.2     6.68    15.14      9936   5.46     0.29  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
ref               1/1      0      23.2      23.2 to 23.2    15.14  reference                      -  reference
php86             1/1      0      23.1      23.1 to 23.1    15.14  -0                            -0  screen: not better in one pair

Floor: 0.864 us, from lab/results/2026-11-24-cpu-steps-5b/aa-24000: |median 0.083| + interquartile range 0.78 of 5 paired differences (quartiles by linear interpolation, inclusive)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.864 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### PHP 8.4 against 8.5 at 24,000 req/s (`APP_PRAGMAS=mmap-off` on both, 8.4 through `--variant-args`, the A/A's floor, one pair)

| Run | position in its round | valid | other containers | idle held at the end | closed by the server | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|
| php84-1 | 1 | true | 0 | 60000 | 0 | 23562.6 | 98.2 % | 23.43 | 6.98 | 16.31 | pass |
| ref-1 | 2 | true | 0 | 60000 | 0 | 23560.5 | 98.2 % | 23.51 | 6.78 | 15.83 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |
|---|---|---|---|---|---|---|---|
| php84-1 | 2.08 | 3.95 | 23.99 % | 0.00 % | 0.293 | 7050 | 0 |
| ref-1 | 4.05 | 4.54 | 25.10 % | 0.00 % | 0.302 | 9940 | 0 |

One pair: ref 23.51, php84 23.43 µs/req: **-0.086 µs, -0.367 %** of the reference.

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  php84          yes      23562.6      23.4     6.98    16.31      7050   3.95     0.29  pass
    1  ref            yes      23560.5      23.5     6.78    15.83      9940   4.54      0.3  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
ref               1/1      0      23.5      23.5 to 23.5    15.83  reference                      -  reference
php84             1/1      0      23.4      23.4 to 23.4    16.31  -0.1                        -0.1  screen: not better in one pair

Floor: 0.864 us, from lab/results/2026-11-24-cpu-steps-5b/aa-24000: |median 0.083| + interquartile range 0.78 of 5 paired differences (quartiles by linear interpolation, inclusive)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.864 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```
<!-- END summarize -->

### The host's state, every run, in one table

The "Results" tables above hold each series' host lines. As a range over the 16 runs, all on a VM with no other container:

| Reading | 24,000 req/s runs (14) | 7,500 req/s runs (2) |
|---|---|---|
| load average on the plateau (1 min) | 3.78 to 5.60 | 3.12 to 3.24 |
| the VM's CPU busy on the plateau | 23.7 to 26.2 % | 8.2 to 10.6 % |
| steal | 0.00 % | 0.00 % |
| `fsync` of a 4 KiB write | 0.245 to 0.565 ms | 0.311 to 0.365 ms |
| the VM's CPU busy before the warm-up | 0.02 to 0.08 % | 0.02 to 0.05 % |

The slowest run of a series is not a slow host: the A/A's two runs with the highest µs/req (b-1 23.87 and b-3 23.86) had a plateau load of 4.79
and 4.86 and a CPU share of 26.15 and 25.99 %, within the range of the others (3.78 to 5.60, 23.7 to 26.2 %), and `fsync` 0.296 and 0.365 ms.
The run with the slowest `fsync` (b-2, 0.565 ms) read 23.75 µs/req, in the middle.

## The reading

- **The floor is 0.864 µs/req** (`|median| + interquartile range` = 0.083 + 0.780, five pairs: +0.555, +0.083, +0.636, -0.225, -0.405), 3.7 % of the
  reference's 23.4 µs/req. 5a's one-rule floor was 2.57 µs/req (the largest absolute difference of five, set by one pair whose run failed the 97 %
  rule) and 0.27 without that pair; the new rule gives 0.358 on 5a's own pairs (scope 2's recomputation). The new floor sits between the two, and all 10 runs
  passed the 97 % rule (97.8 to 98.2 % of offered), so no run's failure moves it.
- **The order bias is gone from the median, not from the runs.** The median paired difference is +0.083 µs (5a's were all negative, about -0.2 with the reference
  first). The bias is still in the data: the first run of a round cost 23.62 µs/req on average (median 23.66) and the second 23.43 (median
  23.32), 0.19 to 0.34 more for the one that runs first. Alternating the order spreads it over both variants, which is what keeps the
  median near 0; the interquartile range (0.780) is the price: the differences swing with the order (rounds 1, 3 and 5, `b` first: +0.555, +0.636,
  -0.405; rounds 2 and 4, `a` first: +0.083, -0.225), so the floor is 0.864 and not 0.358. Five pairs say this much, not more.
- **The Mac's reconnect at 7,500 req/s is 5.91 µs** (the skeleton 32.57, S1-d with every request reconnecting 38.48; one pair, so ±0.864 at
  the floor: 5.05 to 6.77). The close count agrees: 538,025 `Connection: close` responses against 489,175 requests of k6 plus 48,750 of the
  warm-up, a difference of 100 (0.02 %): every request reconnected. It is under the 6.62 µs of the S1 series at 12,000 req/s (median of five pairs),
  not above it: the skeleton's request is dearer at 7,500 (32.57, +16.5 % over S1-a's 27.95 at 12,000), the reconnect is not.
  **The Xeon's 23.69 µs over the Mac's 5.91 is 4.01**; against the 12,000 req/s figure it was 3.58. With the floor's band on one pair, the
  factor is 3.5 to 4.7: the Xeon's reconnect costs about four times the Mac's, not three.
- **PHP 8.6 against 8.5: -0.024 µs/req (-0.1 %), a screen that does not beat the floor** (0.864): within the noise, no confirmation run. **PHP 8.4
  against 8.5: -0.086 µs/req (-0.4 %), the same.** Neither version is faster or slower than 8.5 on the DIY app in one pair; 8.4 is not 0 to 5 %
  slower. The references of the two pairs read 23.16 and 23.51 µs/req, inside the A/A's runs (23.17 to 23.87).
- **The host stayed quiet in every run** (the table above): a plateau load of 3 to 6, the VM's CPU at about a quarter for 24,000 req/s, no steal,
  `fsync` under 0.6 ms, no other container. Nothing in a host line explains a slow run, and no run was slow.

## Did the predictions hold?

Only the four this folder judges; the others are for later folders of the phase.

1. **The host line on a quiet VM at 24,000 req/s: missed on one number.** Load average 3.78 to 5.60 (3 to 7: held), steal 0.00 (held), `fsync_ms`
   0.245 to 0.565 (0.05 to 2: held), but the VM's CPU 23.7 to 26.2 % busy, under the predicted 35 to 60 %. The line counts the VM's 12 CPUs, and the
   server (one CPU) and k6 (about 2.7) use about 3.7 of them at this rate.
2. **The A/A at 24,000 in alternating order: held on the median, missed on the floor.** The median paired difference is +0.083 µs, inside ±0.15. The floor is
   0.864 µs/req, just over the 0.3 to 0.8 range (the interquartile range is 0.780 because the differences follow the order).
3. **The Mac's reconnect at 7,500 req/s: missed.** 5.91 µs, under the 7 to 9.5 predicted; the Xeon over the Mac is 4.01, over the 2.5 to 3.4. The
   19 % the Mac's request rises at 7,500 did show in the skeleton (+16.5 %); the reconnect did not rise with it.
10. **PHP 8.6 against 8.5: held; 8.4 0 to 5 % slower: missed.** 8.6 is -0.1 % (within ±3 %, not beyond the floor). 8.4 is -0.4 % (0.4 point on the faster side of
    the predicted 0 to 5 % slower; also inside the floor, so 8.4 is not slower, and not faster either).
