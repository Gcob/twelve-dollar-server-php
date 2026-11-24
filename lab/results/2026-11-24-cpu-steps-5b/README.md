# Phase 5b's instrument: the A/A floor in alternating order, the Mac's reconnect at 7,500, the PHP versions, S1-b's cost, the CPU variants and the profile

The first measurements of phase 5b, on a quiet Docker VM (Docker Desktop on an M3 Pro, arm64, 1 CPU for the server, 2 GiB, PHP 8.5 unless a
series says otherwise): the noise floor of the new method, the cost of a reconnect on the Mac at the Xeon's rate, a one-pair screen of
PHP 8.6 and 8.4 against 8.5, what two processes on one port cost per request against one (S1-b against S1-a), the screen of the CPU variants that
passed their gates (`APP_JSON=sqlite`; the others are listed with the number that stopped them) and the profile of the chosen combination. These are arm64 numbers, not a score. This file is written in two steps: the predictions first (below,
before any run), then the plan, the runs and the reading.

## Predictions (D5)

Copied unchanged from the phase's plan, section "Predictions (D5)" (all thirteen). This folder judges 1 to 10 (5 to 9 from the CPU variants' micro benches and counts, and, for `APP_JSON=sqlite`, one macro screen); 11 to 13 belong to
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
5. **`summarize.sh`** regenerates every table below from the JSON files, `stages.json`, `stages-s1b.json`, `s1b-12000/served.json` and three 5a
   folders (the Xeon's reconnect pair, the S1 series' reconnect at 12,000 req/s and its A/A at 12,000 req/s).
6. **`s1b-12000`, S1-b against S1-a (added after the four series above, from a detached checkout at commit `4e319b9`, the one that built
   `APP_WORKERS`; `stages-s1b.json` records it, no tracked file changed).** `series-s1b.txt` holds the call: 12,000 req/s, `s = 0.02`, 60,000
   idle, a 60 s plateau, 3 pairs, the alternating order, `--ext sockets --ext event --ext pcntl` on both sides (so the only difference is
   `APP_WORKERS=2`), `s1a` = `APP_PRAGMAS=mmap-off,APP_TELEMETRY=1` and `s1b` the same plus `APP_WORKERS=2`, the quiet check on, never
   `--allow-busy`. The floor is read twice: from 5a's A/A at 12,000 req/s (`--floor-from lab/results/2026-11-23-s1-fd-wall/aa-12000`: the
   bare skeleton in the old order, **0.516 µs/req by today's rule**, the floor the series ran with) and, as the more cautious reading, from this
   folder's A/A at 24,000 req/s (**0.864**). The driver wrote into a scratch folder and `s1b-12000/` was moved here.
   Two readings the step lab does not make were added, both read only and outside the pairs:
   - **Which process served.** The series' runs keep no sampler (`--no-series`), so the run files hold only the telemetry summed over the
     processes. The server's own log was followed from outside (`docker logs -f`, one file a run, started once the series was under way) and
     each process's `requests` summed into `s1b-12000/served.json`. **Round 1's S1-b log was not followed** (the follower started during
     the next run): its row says so.
   - **Memory.** One run of each variant after the series, `lab/realistic.sh --hold 12000,60` with the same flags and the sampler on
     (`s1b-12000/memory/`): `memory.current` and `Pss_Anon` peaks, file descriptors. One run each, not a pair.
7. **`json-sqlite`, the one CPU variant that was screened (from a detached checkout at commit `9b33c4d`, the lab after the parser, loop and driver
   switches; `stages-screens.json` records it, no tracked file changed).** `series-screens.txt` holds the call: `ref` = `APP_PRAGMAS=mmap-off`
   against `json-sqlite` = `APP_PRAGMAS=mmap-off,APP_JSON=sqlite`, 24,000 req/s, `s = 0.02`, 60,000 idle, a 60 s plateau, one pair, the alternating
   order (round 1 runs `json-sqlite` first and `ref` last), `--floor-from` the A/A at 24,000 req/s (0.864), the quiet check on. A screen that beat the
   floor would have had 2 more pairs (`--first-round 2`), and two variants beyond the noise on different steps one pair together: neither happened.
   The driver wrote into a scratch folder and `json-sqlite/` and `stages-screens.json` were moved here.
   **Not run, with the number that stopped each and why:**

   | Variant | Gate | The number | Why no macro pair |
   |---|---|---|---|
   | `APP_JSON=concat` | micro bench, ns per call of the route | feed 33,755 against `encode`'s 30,842 ns (+9.4 %), post +1.3 % | slower than `encode`: no pair can make it chosen |
   | `APP_DRIVER=ffi` with `APP_JSON=sqlite` | micro bench, the scope's own gate | feed 30,728 against PDO's 30,677 ns (+0.2 %); raw FFI at most -467 ns of a feed (-1.5 %, spreads touch) and -91 ns of a post; SQLite's own work is 98 % of a feed | the gate failed. The driver reads only, behind a bench-only flag (a server booted with it would answer 500 to a write), and cannot be measured at the macro |
   | `APP_PARSE=lean` | micro bench, ns per head parse | -18.7 % of a feed's head, -9.7 % and -10.2 % of a like's and a post's (about 50 ns of a request that costs about 27 µs) | under the 20 % bar: not wired, so there is no switch to run |
   | `APP_LOOP=nolock` | syscalls per request (`lab/syscalls.sh`) | 5.624 against the reference's 5.623 | a no-op on this image (`event.so` links no `libevent_pthreads`) |
   | `APP_LOOP=changelist` | the same | 5.620 against 5.623; with `APP_GROUP_COMMIT=1` `epoll_ctl` 0.158 to 0.078 a request (-1.6 % of the syscalls) | removes no syscall alone, and group commit, the only thing it pays with, did not beat the floor in 5a |
   | `APP_LOOP=poll` | the same | 5.511 against 5.623 (-0.11 a request) | counted with no idle connection; with 60,000 idle, `ppoll` passes every descriptor at each call, which the count does not see |
8. **`profile/`, the profile of the chosen combination, from the same detached checkout.** Nothing was chosen, so the combination is the reference
   alone (`APP_PRAGMAS=mmap-off`). One run of `lab/realistic.sh --image 8.5 --think-scale 0.02 --idle 60000 --lag-gate 6 --warmup 2400,60
   --no-series --env APP_PRAGMAS=mmap-off --env APP_TELEMETRY=0 --profile <file> --hold 24000,60`: 5a's skeleton profile, with the pragma. The fold's
   microseconds per request are the median of the reference runs of this folder at 24,000 req/s (the A/A's ten and the reference of each screen).

## What differed from the plan of the runs

- **Nothing was run twice and no series failed.** All four exited 0; every one of the 16 runs is valid, 0 other containers, 60,000 idle
  connections held at the end and none closed by the server.
- **The idle client bound again 200 times in 11 of the 14 runs at 24,000 req/s** (`idle.bind_retries` 200: the busy ports of the run before, as in
  5a), and in none at 7,500 req/s. No run waited on the idle client's addresses.
- **The reconnect pair ran with the churn run first** (the alternating order: round 1 runs the reference last), where the Xeon's pair ran the
  skeleton first. The skeleton then waited 54 s for k6's TIME_WAIT sockets (5,303 on its busiest address, above the limit of 2,500) to drain
  before it started: its `waited s` is in the table. The Xeon's pair started both runs with 26,870 and 27,732 on the busiest address and waited 0 s.
- **No screen beat the floor, so no confirmation pairs were run.**
- **The CPU variants' screens and the profile: nothing was run twice and no run was invalid.** The `json-sqlite` series exited 0 (5 min 30 s), the quiet
  check saw 0 other containers before it and before the profile, both screen runs and the profile run are valid with 60,000 idle held at the
  end and none closed by the server. The idle client bound again 200 times in `ref-1` and the profile run, 0 times in `json-sqlite-1` (the busy
  ports of the run before, as in 5a). Of the variants of scopes 4 to 6, one was screened (`APP_JSON=sqlite`); the other six are in the plan's table
  with their numbers.
- **The S1-b series: nothing run twice and no series failed.** The file exited 0; every one of the 6 runs is valid, 0 other containers, 60,000 idle
  held at the end and none closed by the server. No run waited for TIME_WAIT sockets. The idle client bound again 175 times in 5 of the 6 runs (0 in
  the first), the busy ports of the run before, as in 5a. The series took 16.5 minutes.
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

### S1-b on the Mac: the series, as the driver recorded it (`stages-s1b.json`)

The lab's commit when the file started: `4e319b9`, tracked files changed since: false. Gap between series: 60 s; `--allow-busy`: false.

| Series | start (UTC) | end (UTC) | exit code | other containers at the quiet check | busy | refused |
|---|---|---|---|---|---|---|
| s1b-12000 | 2026-11-24T07:04:04Z | 2026-11-24T07:20:40Z | 0 | 0 | false | false |

### S1-b on the Mac: S1-b against S1-a at 12,000 req/s (`APP_WORKERS=2` against one process, `APP_PRAGMAS=mmap-off`, telemetry on, `s = 0.02`, 60,000 idle, 3 pairs)

| Run | position in its round | valid | other containers | idle held at the end | closed by the server | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|
| s1b-1 | 1 | true | 0 | 60000 | 0 | 11923.8 | 99.3 % | 27.04 | 0.95 | 3.68 | pass |
| s1a-1 | 2 | true | 0 | 60000 | 0 | 11921.7 | 99.3 % | 24.89 | 1.6 | 4.6 | pass |
| s1a-2 | 1 | true | 0 | 60000 | 0 | 11930.4 | 99.4 % | 24.75 | 1.51 | 4.53 | pass |
| s1b-2 | 2 | true | 0 | 60000 | 0 | 11914.3 | 99.3 % | 27.04 | 1.01 | 3.96 | pass |
| s1b-3 | 1 | true | 0 | 60000 | 0 | 11922.4 | 99.3 % | 26.97 | 1.01 | 3.96 | pass |
| s1a-3 | 2 | true | 0 | 60000 | 0 | 11919.6 | 99.3 % | 24.9 | 1.7 | 4.67 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |
|---|---|---|---|---|---|---|---|
| s1b-1 | 0.84 | 3.05 | 9.77 % | 0.00 % | 0.514 | 0 | 0 |
| s1a-1 | 2.50 | 2.79 | 9.67 % | 0.00 % | 0.456 | 10036 | 0 |
| s1a-2 | 2.71 | 2.88 | 9.64 % | 0.00 % | 0.456 | 8442 | 0 |
| s1b-2 | 3.02 | 4.66 | 9.89 % | 0.00 % | 0.491 | 8495 | 0 |
| s1b-3 | 4.08 | 3.42 | 11.03 % | 0.00 % | 0.443 | 8463 | 0 |
| s1a-3 | 3.81 | 3.36 | 9.75 % | 0.00 % | 0.496 | 8509 | 0 |

Over the 6 runs: load on the plateau 2.79 to 4.66, the VM's CPU busy 9.64 to 11.03 %, steal 0.00 to 0.00 %, `fsync` 0.443 to 0.514 ms.

The pairs (S1-b minus S1-a, the order alternates: round 1 runs S1-b first, round 2 S1-a first, round 3 S1-b first):

| Round | order | S1-a µs/req | S1-b µs/req | S1-b minus S1-a µs | as a share of S1-a |
|---|---|---|---|---|---|
| 1 | s1b then s1a | 24.89 | 27.04 | +2.143 | +8.609 % |
| 2 | s1a then s1b | 24.75 | 27.04 | +2.289 | +9.247 % |
| 3 | s1b then s1a | 24.9 | 26.97 | +2.069 | +8.308 % |

Medians: S1-a 24.89 µs/req, S1-b 27.04 µs/req. Paired differences +2.143, +2.289, +2.069, **median +2.143 µs/req, +8.609 % of the median S1-a**. Achieved over offered: 99.3 % to 99.4 %; runs under the 97 % rule: 0 of 6.

Both processes served, from the server's own log (the telemetry line each process prints every second, `requests` summed over the run's whole life: the warm-up, the plateau and one request per idle connection):

| Run | processes | requests counted by each process | seconds in which each counted a request | share of the first |
|---|---|---|---|---|
| s1b-1 | not followed | - | - | - |
| s1b-2 | 2 | 452675 and 467536 | 155 and 154 | 49.2 % |
| s1b-3 | 2 | 454109 and 466643 | 154 and 153 | 49.3 % |
| memory/s1b | 2 | 432363 and 410520 | 83 and 82 | 51.3 % |

Memory of one run of each variant, with the sampler on (`--no-series` off; 12,000 req/s for 60 s after the warm-up, 60,000 idle; not a pair, not counted):

| Variant | valid | achieved req/s | µs CPU/req | memory.current peak MiB | Pss_Anon peak MiB | file descriptors peak | processes |
|---|---|---|---|---|---|---|---|
| s1a | true | 11921.9 | 23.97 | 591.6 | 107.3 | 62280 | 1 |
| s1b | true | 11922.9 | 26.22 | 583.4 | 98 | 62303 | 2 |

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  s1b            yes      11923.8        27     0.95     3.68         0   3.05     0.51  pass
    1  s1a            yes      11921.7      24.9      1.6      4.6     10036   2.79     0.46  pass
    2  s1a            yes      11930.4      24.8     1.51     4.53      8442   2.88     0.46  pass
    2  s1b            yes      11914.3        27     1.01     3.96      8495   4.66     0.49  pass
    3  s1b            yes      11922.4        27     1.01     3.96      8463   3.42     0.44  pass
    3  s1a            yes      11919.6      24.9      1.7     4.67      8509   3.36      0.5  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
s1a               3/3      0      24.9      24.8 to 24.9      4.6  reference                      -  reference
s1b               3/3      0        27          27 to 27     3.96  +2.1 +2.3 +2.1              +2.1  beyond the noise

Floor: 0.516 us, from lab/results/2026-11-23-s1-fd-wall/aa-12000: |median -0.172| + interquartile range 0.345 of 5 paired differences (quartiles by linear interpolation, inclusive)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.516 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

The same series against this folder's own floor (the A/A at 24,000 req/s above), the more cautious reading:

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  s1b            yes      11923.8        27     0.95     3.68         0   3.05     0.51  pass
    1  s1a            yes      11921.7      24.9      1.6      4.6     10036   2.79     0.46  pass
    2  s1a            yes      11930.4      24.8     1.51     4.53      8442   2.88     0.46  pass
    2  s1b            yes      11914.3        27     1.01     3.96      8495   4.66     0.49  pass
    3  s1b            yes      11922.4        27     1.01     3.96      8463   3.42     0.44  pass
    3  s1a            yes      11919.6      24.9      1.7     4.67      8509   3.36      0.5  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
s1a               3/3      0      24.9      24.8 to 24.9      4.6  reference                      -  reference
s1b               3/3      0        27          27 to 27     3.96  +2.1 +2.3 +2.1              +2.1  beyond the noise

Floor: 0.864 us, from lab/results/2026-11-24-cpu-steps-5b/aa-24000: |median 0.083| + interquartile range 0.78 of 5 paired differences (quartiles by linear interpolation, inclusive)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.864 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### S1-b on the Mac: what S1-b and S1-d add at the bench's sizes (soft limit 64,000; share of requests that reconnect = 1 - 64,000 / N)

| Users N | share that reconnect | S1-d at 7,500 req/s's reconnect (5.91 µs) adds | S1-d at 12,000 req/s's reconnect (6.62 µs) adds | S1-b adds (any N) | S1-b over S1-d (12,000 figure) |
|---|---|---|---|---|---|
| 100000 | 36 % | +2.128 µs (8.6 % of S1-a) | +2.382 µs (9.6 % of S1-a) | +2.143 µs (8.6 % of S1-a) | cheaper by 0.24 µs |
| 150000 | 57.3 % | +3.39 µs (13.6 % of S1-a) | +3.793 µs (15.2 % of S1-a) | +2.143 µs (8.6 % of S1-a) | cheaper by 1.65 µs |

S1-b and S1-d add the same at a share of 32.4 % of requests reconnecting (S1-d at the 12,000 req/s figure), that is N = 94662 users; with the 7,500 req/s figure, 36.2 % and N = 100390. Below that size S1-d is cheaper, above it S1-b is.

### The CPU variants of 5b: the series, as the driver recorded them (`stages-screens.json`)

The lab's commit when the file started: `9b33c4d`, tracked files changed since: false. Gap between series: 60 s; `--allow-busy`: false.

| Series | start (UTC) | end (UTC) | exit code | other containers at the quiet check | busy | refused |
|---|---|---|---|---|---|---|
| json-sqlite | 2026-11-24T09:25:57Z | 2026-11-24T09:31:27Z | 0 | 0 | false | false |

### `APP_JSON=sqlite` against `encode` at 24,000 req/s (`APP_PRAGMAS=mmap-off` on both, the A/A's floor, one pair)

| Run | position in its round | valid | other containers | idle held at the end | closed by the server | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|
| json-sqlite-1 | 1 | true | 0 | 60000 | 0 | 23468.7 | 97.8 % | 24.53 | 8.86 | 23.31 | pass |
| ref-1 | 2 | true | 0 | 60000 | 0 | 23473.9 | 97.8 % | 23.91 | 8.47 | 21.32 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |
|---|---|---|---|---|---|---|---|
| json-sqlite-1 | 0.14 | 4.61 | 25.28 % | 0.00 % | 0.360 | 0 | 0 |
| ref-1 | 5.04 | 4.36 | 24.26 % | 0.00 % | 0.316 | 9991 | 0 |

One pair: ref 23.91, json-sqlite 24.53 µs/req: **+0.621 µs, +2.596 %** of the reference.

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  json-sqlite    yes      23468.7      24.5     8.86    23.31         0   4.61     0.36  pass
    1  ref            yes      23473.9      23.9     8.47    21.32      9991   4.36     0.32  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
ref               1/1      0      23.9      23.9 to 23.9    21.32  reference                      -  reference
json-sqlite       1/1      0      24.5      24.5 to 24.5    23.31  +0.6                        +0.6  screen: not better in one pair

Floor: 0.864 us, from lab/results/2026-11-24-cpu-steps-5b/aa-24000: |median 0.083| + interquartile range 0.78 of 5 paired differences (quartiles by linear interpolation, inclusive)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.864 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### The profile of the chosen combination (the reference alone: `APP_PRAGMAS=mmap-off`), beside 5a's (Excimer, 1 ms CPU time, one run: 24,000 req/s, `s = 0.02`, 60,000 idle, telemetry off)

The profiled run is valid true, other containers 0, idle held 60000 / 60000. Profiled window (the server's whole life after its first answer: warm-up, ramps and plateau): 53093 samples at 1 ms, the cgroup's user CPU 36129 ms and system CPU 17275 ms (**32 % in the kernel**), the samples cover 99 % of that CPU, unclassified 0 %. The profiled run itself read 24.01 µs/req (the sampler costs CPU).

Each cell is a share of all the samples of its profile and the microseconds it is on the average request of that profile (the fold's `--us-per-req`: 5a's together 27.58 (the median of its 3 holds at 22,000 req/s, telemetry on, S1-d on, no `mmap-off`), 5a's skeleton 26.71 (the CPU steps' three references' median at 24,000 req/s, no pragma), and this run's 23.51 (the median of the 13 reference runs of this folder at 24,000 req/s, telemetry off)). The kernel's share is the cgroup's system CPU.

| Step | in this profile | 5a together: share, µs | 5a skeleton: share, µs | 5b reference: share, µs | 5b minus 5a together, µs | 5b minus 5a skeleton, µs |
|---|---|---|---|---|---|---|
| S1 accept connections | no soft limit (5a together ran S1-d, which never fired) | 1.6 %, 0.4 µs | 2.0 %, 0.5 µs | 1.6 %, 0.4 µs | -0.065 | -0.158 |
| S2 read and parse | unchanged | 8.2 %, 2.3 µs | 8.1 %, 2.2 µs | 8.8 %, 2.1 µs | -0.192 | -0.094 |
| S3 route | unchanged | 0.5 %, 0.1 µs | 0.6 %, 0.2 µs | 0.6 %, 0.1 µs | +0.003 | -0.019 |
| S4 verify the JWT | unchanged | 1.6 %, 0.4 µs | 1.6 %, 0.4 µs | 1.7 %, 0.4 µs | -0.042 | -0.028 |
| S5 validate the input | unchanged | 0.2 %, 0.1 µs | 0.2 %, 0.1 µs | 0.1 %, 0 µs | -0.032 | -0.03 |
| S6 query SQLite | `APP_PRAGMAS=mmap-off` (the reference; `APP_JSON=sqlite` screened, not better) | 50.6 %, 14 µs | 51.2 %, 13.7 µs | 48.4 %, 11.4 µs | -2.575 | -2.295 |
| S7 build the JSON | unchanged | 10.0 %, 2.8 µs | 9.4 %, 2.5 µs | 10.9 %, 2.6 µs | -0.195 | +0.052 |
| S8 write the response | unchanged | 20.9 %, 5.8 µs | 20.6 %, 5.5 µs | 21.5 %, 5.1 µs | -0.709 | -0.447 |
| S9 durability | unchanged | 0.0 %, 0 µs | 0.0 %, 0 µs | 0.0 %, 0 µs | 0 | 0 |
| event loop | unchanged | 6.5 %, 1.8 µs | 6.3 %, 1.7 µs | 6.4 %, 1.5 µs | -0.288 | -0.178 |
| unclassified | unchanged | 0.0 %, 0 µs | 0.0 %, 0 µs | 0.0 %, 0 µs | 0 | 0 |

The fold of `profile/profile.collapsed` with `--us-per-req` set to the reference runs' median:

```text
step                   GET /health     GET /feed  GET /posts/:id  POST /posts  POST /posts/:id/like       shared            all
S1 accept connections   0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us   1.6% 0.4us     1.6% 0.4us
S2 read and parse       0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us   8.8% 2.1us     8.8% 2.1us
S3 route                0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us   0.5% 0.1us     0.6% 0.1us
S4 verify the JWT       0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.2% 0.0us            1.5% 0.3us   0.0% 0.0us     1.7% 0.4us
S5 validate the input   0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us   0.0% 0.0us     0.1% 0.0us
S6 query SQLite         0.1% 0.0us   35.3% 8.3us      5.9% 1.4us   1.1% 0.3us            6.0% 1.4us   0.0% 0.0us   48.4% 11.4us
S7 build the JSON       0.0% 0.0us    9.9% 2.3us      0.8% 0.2us   0.1% 0.0us            0.1% 0.0us   0.0% 0.0us    10.9% 2.6us
S8 write the response   0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us  21.5% 5.1us    21.5% 5.1us
S9 durability           0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us   0.0% 0.0us     0.0% 0.0us
event loop              0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us   6.4% 1.5us     6.4% 1.5us
unclassified            0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us   0.0% 0.0us     0.0% 0.0us
all                     0.1% 0.0us  45.3% 10.6us      6.7% 1.6us   1.4% 0.3us            7.6% 1.8us  38.9% 9.1us  100.0% 23.5us
samples: 53093, 23.5 us per request on average
each cell: share of all samples and the microseconds it adds to the average request; S9 is inside S6 (autocommit)

within each endpoint (share of that column's own samples):
step                   GET /health  GET /feed  GET /posts/:id  POST /posts  POST /posts/:id/like  shared
S1 accept connections         0.0%       0.0%            0.0%         0.0%                  0.0%    4.1%
S2 read and parse             0.0%       0.0%            0.0%         0.0%                  0.0%   22.7%
S3 route                      0.0%       0.0%            0.0%         1.9%                  0.0%    1.4%
S4 verify the JWT             0.0%       0.0%            0.0%        13.9%                 19.4%    0.0%
S5 validate the input         0.0%       0.0%            0.7%         3.5%                  0.6%    0.0%
S6 query SQLite              73.3%      78.0%           87.8%        75.9%                 78.7%    0.0%
S7 build the JSON            26.7%      22.0%           11.5%         3.9%                  1.3%    0.0%
S8 write the response         0.0%       0.0%            0.0%         0.9%                  0.0%   55.3%
S9 durability                 0.0%       0.0%            0.0%         0.0%                  0.0%    0.0%
event loop                    0.0%       0.0%            0.0%         0.0%                  0.0%   16.5%
unclassified                  0.0%       0.0%            0.0%         0.0%                  0.0%    0.0%
weight in all samples         0.1%      45.3%            6.7%         1.4%                  7.6%   38.9%
```
<!-- END summarize -->

### The host's state, every run, in one table

The "Results" tables above hold each series' host lines. As a range over the 18 runs, all on a VM with no other container:

| Reading | 24,000 req/s runs (16) | 7,500 req/s runs (2) |
|---|---|---|
| load average on the plateau (1 min) | 3.78 to 5.60 | 3.12 to 3.24 |
| the VM's CPU busy on the plateau | 23.7 to 26.2 % | 8.2 to 10.6 % |
| steal | 0.00 % | 0.00 % |
| `fsync` of a 4 KiB write | 0.245 to 0.565 ms | 0.311 to 0.365 ms |
| the VM's CPU busy before the warm-up | 0.02 to 0.12 % | 0.02 to 0.05 % |

The CPU variants' screen added two runs to the 24,000 req/s column (14 before): `json-sqlite-1` (load 4.61, CPU 25.28 %, `fsync` 0.360 ms) and `ref-1` (4.36, 24.26 %, 0.316 ms,
0.12 % busy before, the only change of a range). The profile run read a plateau load of 4.94, 25.24 % busy, `fsync` 0.425 ms and
0.23 % busy before (a little above the 0.02 to 0.12 % of the others, still an idle VM): the same quiet machine.

The slowest run of a series is not a slow host: the A/A's two runs with the highest µs/req (b-1 23.87 and b-3 23.86) had a plateau load of 4.79
and 4.86 and a CPU share of 26.15 and 25.99 %, within the range of the others (3.78 to 5.60, 23.7 to 26.2 %), and `fsync` 0.296 and 0.365 ms.
The run with the slowest `fsync` (b-2, 0.565 ms) read 23.75 µs/req, in the middle. The slowest of all, `json-sqlite-1` (24.53), had a plateau load of 4.61, 25.28 % busy and
`fsync` 0.360 ms: nothing in its host line sets it apart, and it ran first in its round.

## The reading

- **The floor is 0.864 µs/req** (`|median| + interquartile range` = 0.083 + 0.780, five pairs: +0.555, +0.083, +0.636, -0.225, -0.405), 3.7 % of the
  reference's 23.4 µs/req. 5a's one-rule floor was 2.57 µs/req (the largest absolute difference of five, set by one pair whose run failed the 97 %
  rule) and 0.27 without that pair; the new rule gives 0.358 on 5a's own pairs (the new rule applied to 5a's own pairs). The new floor sits between the two, and all 10 runs
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

- **S1-b, two processes on one port, adds 2.14 µs per request over one process (+8.6 %), beyond both floors.** Three pairs, S1-b minus S1-a:
  +2.143, +2.289, +2.069 µs/req (+8.6, +9.2, +8.3 %), median +2.143 against the S1-a median of 24.89 (S1-b 27.04). Every pair has the same sign
  and the median is 4.2 times 5a's A/A floor at 12,000 req/s (0.516, the floor the series ran with) and 2.5 times this folder's 24,000 floor
  (0.864): **beyond the noise under both**. The extra run with the sampler on says the same (S1-a 23.97, S1-b 26.22: +2.24 µs, +9.4 %, one run
  each, not counted). The S1-a here (24.89) is under 5a's S1 series' skeleton at 12,000 req/s (27.95, another day and the old order), so
  the percentages are of this series' S1-a. This folder does not say where the 2.14 µs go (two processes share the one CPU the container
  has). The latency goes the other way: p95 0.95 to 1.01 ms for S1-b against 1.51 to 1.70 for S1-a, p99 3.68 to 3.96 against 4.53 to 4.67
  (probably because a stalled loop then holds half the connections, not all; not measured).
- **Both processes served, in every run whose log was followed.** In S1-b's runs 2 and 3 the two processes counted 452,675 and 467,536, then
  454,109 and 466,643 requests (49.2 and 49.3 % for the first), each in 153 to 155 of the 164 seconds of the run, and in the memory run
  432,363 and 410,520 (51.3 %). **Round 1's S1-b was not followed**: its summed telemetry says 2 processes printed lines and an open peak of
  62,268, the same as every other run, and its 27.04 µs/req and p95 0.95 ms read like runs 2 and 3, but a process that printed lines
  without serving would not show in what was kept. Nothing says it did not serve; the run did not prove that it did.
- **S1-b holds no more memory than S1-a in the one run of each**: `memory.current` peak 583.4 MiB (S1-a 591.6), `Pss_Anon` peak 98.0 MiB
  (S1-a 107.3), file descriptors 62,303 against 62,280. One run each cannot tell a difference of 8 MiB from none, so the reading is "no
  extra memory worth the name", not "less". The 60,000 idle connections cost their kernel memory whichever process holds them, and `Pss`
  splits the pages two processes share between them (the second process comes from a fork), so the sum does not double what they share.
- **At the bench's sizes, against S1-d (the table above).** S1-b's cost is the same at every N; S1-d's is a share `1 - 64,000 / N` of a
  reconnect, 5.91 µs at 7,500 req/s (one pair) or 6.62 at 12,000 (5 pairs). At 100,000 users S1-d adds 2.13 or 2.38 µs and S1-b 2.14: a tie,
  inside the floors. At 150,000 users S1-d adds 3.39 or 3.79 µs (13.6 or 15.2 % of S1-a) and **S1-b still 2.14 (8.6 %), cheaper by 1.25 to
  1.65 µs**, beyond the floors. The two cost the same at about 94,700 users (the 12,000 figure) to 100,400 (the 7,500 one): S1-d below, S1-b above.
  On the Mac the margin is small at 100,000 and about 1.5 µs at 150,000. On a Xeon a reconnect costs about four times the Mac's (23.7 against 5.91 µs
  at 7,500 req/s), so the same model there makes S1-d about four times dearer, while S1-b's price has to be measured on the Xeon (here it was
  measured at 12,000 req/s only; 150,000 users ask for about 15,900).

- **`APP_JSON=sqlite` at 24,000 req/s: +0.621 µs/req (+2.6 %), a screen that does not beat the floor** (0.864; a variant has to be lower by at least the floor).
  One pair, `json-sqlite` 24.53 against `ref` 23.91 µs/req, both valid and passing the 97 % rule (97.8 %), the host lines alike (load 4.61 and 4.36, CPU 25.3 and 24.3 %).
  The sign is the wrong one, and one pair says no more than that: **not better, not chosen, no confirmation pairs** (the rule gives them to a screen that beats the floor).
- **Against its micro, it reads 1.00 µs higher than predicted, 0.14 over the floor.** The micro bench (image 8.5.13, JIT on, 5 processes) says `sqlite` saves 392 ns of a feed
  (30,842 to 30,450, -1.3 %, inside the spread of its own range) and 431 ns of a post (2,430 to 1,999, -17.7 %). A loop is one feed, one post and 0.17 writes,
  2.17 requests, so the micro predicts 823 ns a loop, **-0.38 µs a request**, under the floor by itself. The pair's +0.621 is 1.00 above that. `json-sqlite` ran first in its
  round, and the A/A's first run of a round reads 0.19 to 0.34 µs more than the second (the order bias, see above): take that out and the gap is 0.66 to 0.81, inside the floor.
  One pair does not separate the two readings; the micro's own sign (a saving under the floor) and the pair's (a cost under the floor) agree on one thing: nothing here is beyond the noise.
- **No "together" pair:** it needs two variants on different steps beyond the noise, and none was.
- **The variants that were not run each read their gate, and the gates agree with the macro's floor.** `concat` costs 9.4 % more per feed than `encode` (33,755 against 30,842 ns): at the
  macro that would be about +1.4 µs a request (2,914 ns more a feed and 31 more a post, over a loop of 2.17 requests), the wrong way. The FFI driver with `sqlite` is 50 ns from PDO's per feed (+0.2 %, spreads that overlap) and even raw FFI, with no class, saves at most
  467 ns of a feed (-1.5 %), 0.4 µs a request at most: of the order of the floor, and the class as written is not under PDO. The lean parser saves about 50 ns of a request that costs 23.5 µs
  (0.2 %). The loop's `nolock` and `changelist` remove no syscall alone and `poll`'s -0.11 syscalls a request was counted with no idle connection. No gate said "worth a pair".
- **The profile of the reference (the chosen combination: nothing beat the floor): 23.51 µs/req** (median of the 13 reference runs of this folder at 24,000 req/s, 23.16 to 23.91; the
  profiled run itself read 24.01, the sampler costs CPU), **32 % of the CPU in the kernel**, 53,093 samples that cover 99 % of the cgroup's CPU, 0 % unclassified. By step:
  S6 (the query) 48.4 % (11.4 µs; the feed's query alone 35.3 %, 8.3 µs), S8 (the response) 21.5 % (5.1 µs), S7 (the JSON) 10.9 % (2.6 µs), S2 (read and parse) 8.8 % (2.1 µs),
  the loop 6.4 % (1.5 µs), S4 1.7 %, S1 1.6 %, S3 0.6 %, S5 0.1 %, S9 0 %. Against 5a's together profile (27.58 µs, 22,000 req/s, S1-d on, no `mmap-off`) and 5a's skeleton (26.71 at
  24,000): **S6 is still the largest step** (48.4 % against 50.6 and 51.2 %: the 2 to 3 points of `mmap-off`, which 5a priced at -1.31 µs), S8 21.5 against 20.9 and 20.6, S7 10.9 against 10.0 and 9.4,
  S2 8.8 against 8.2 and 8.1, the loop 6.4 against 6.5 and 6.3, the kernel 32 % against 31 and 31. The shares moved by under 3 points and the order of the steps did not change.
  **The microseconds are lower in every step (-4.1 µs in all against 5a's together, of which S6 is -2.6) because the day is lower**: this folder's A/A reads 23.2 to 23.9 where 5a's `mmap-off` pairs read
  25.0 to 25.6 and its skeleton 26.7, of which `mmap-off` explains about 1.3 µs (S6). Nothing in this folder says where the rest went (the host lines are alike), so the µs of two days are not compared
  here, only the shares.


## Did the predictions hold?

The ten this folder judges (4 and 10 were judged whole in the S1-b and PHP-version sections; 5 to 9 are new); 11 to 13 are for later folders of the phase.

1. **The host line on a quiet VM at 24,000 req/s: missed on one number.** Load average 3.78 to 5.60 (3 to 7: held), steal 0.00 (held), `fsync_ms`
   0.245 to 0.565 (0.05 to 2: held), but the VM's CPU 23.7 to 26.2 % busy, under the predicted 35 to 60 %. The line counts the VM's 12 CPUs, and the
   server (one CPU) and k6 (about 2.7) use about 3.7 of them at this rate.
2. **The A/A at 24,000 in alternating order: held on the median, missed on the floor.** The median paired difference is +0.083 µs, inside ±0.15. The floor is
   0.864 µs/req, just over the 0.3 to 0.8 range (the interquartile range is 0.780 because the differences follow the order).
3. **The Mac's reconnect at 7,500 req/s: missed.** 5.91 µs, under the 7 to 9.5 predicted; the Xeon over the Mac is 4.01, over the 2.5 to 3.4. The
   19 % the Mac's request rises at 7,500 did show in the skeleton (+16.5 %); the reconnect did not rise with it.
4. **S1-b on the Mac at 12,000 req/s: held.** +2.14 µs per request over S1-a (the predicted +1.5 to +5), +8.6 % (+5 to +18 %), beyond the floor
   under both readings: 0.516 (5a's A/A at 12,000) and 0.864 (this folder's 24,000), three pairs all positive. At 150,000 users it is 1.25 to
   1.65 µs under S1-d's price, at 100,000 a tie.
10. **PHP 8.6 against 8.5: held; 8.4 0 to 5 % slower: missed.** 8.6 is -0.1 % (within ±3 %, not beyond the floor). 8.4 is -0.4 % (0.4 point on the faster side of
    the predicted 0 to 5 % slower; also inside the floor, so 8.4 is not slower, and not faster either).

5. **`APP_JSON=concat`: missed, with the wrong sign.** The micro says 9.4 % **over** `encode` per feed (33,755 against 30,842 ns; predicted 3 to 12 % under), +1.3 % per post. The macro was not run (the
   prediction itself said it would be under the floor, judged on its micro), and a variant slower in the micro cannot be chosen.
6. **`APP_JSON=sqlite`: missed on both numbers.** The micro's feed is -1.3 % (predicted 10 to 25 % under; inside its own spread), the post -17.7 % (a post is cheap: -431 ns). The macro screen is
   **+0.621 µs/req, +2.6 %** (predicted -1.5 to -4, beyond the floor, and chosen): not better than the floor of 0.864, one pair, not chosen. The micro's reading: the feed's query alone is 24.3 µs of its 30.8, and SQLite's `json_object` and the aggregate's temp b-tree (`USE TEMP B-TREE FOR json_group_array(ORDER BY)` in the plan) cost about what PDO's arrays and the encoder did.
7. **The FFI driver: held.** With `encode` it is 10.15 µs a feed slower than PDO (40,995 against 30,849 ns, +32.9 %; predicted 8 to 30 µs); with `sqlite` it is +0.05 µs (+0.2 %, within ±1 µs of PDO with `sqlite`), and
   the micro's stop fired, as predicted. Not chosen.
8. **The loop presets: not measured at the macro, held on "none chosen".** The counts: `nolock` 5.624 and `changelist` 5.620 syscalls a request against the reference's 5.623, `poll` 5.511. No macro pair was run
   (no count passed the gate), so "each within ±0.5 µs" is neither confirmed nor missed.
9. **The lean parser: held.** The best head saves 18.7 % of a parse (the feed's, under the 20 % bar), the others 9.7 and 10.2 %; in a request that is about 50 ns (0.2 %), under the predicted 0.4 µs. Not wired.

## The choice

One row per step. A variant within the noise is not chosen unless it is simpler; none was both. On the Mac the configuration of phase 5b is **the reference, `APP_PRAGMAS=mmap-off`, with nothing else switched on**.

| Step | Chosen | Why |
|---|---|---|
| S1 accept connections (on the Mac) | **undecided here: the Xeon decides.** On the Mac S1-b (2 processes on one port) costs +2.14 µs/req (+8.6 %, beyond both floors) and S1-d (a soft limit that closes a share of the connections) costs `6.62 * (1 - 64,000 / N)` µs | a tie at 100,000 users, S1-b cheaper by 1.25 to 1.65 µs at 150,000; a reconnect on the Xeon costs about 4 times the Mac's, so S1-b's price has to be measured there before it is chosen. The reference runs one process with no soft limit |
| S2 read and parse | today's `parseHead` | the lean parse saves 18.7 % at best (50 ns of a request, 0.2 %), under the 20 % bar: not wired |
| S6 query: the pragmas | `APP_PRAGMAS=mmap-off` | the reference; 5a chose it from its own pairs, and this profile has S6 at 48.4 % of the samples |
| S6 query: the driver | PDO (`APP_DRIVER` unset) | FFI with `sqlite` is +0.2 % against PDO in the micro and even raw FFI saves at most 1.5 % of a feed; the gate failed |
| S7 build the JSON | `encode` (`APP_JSON` unset) | `concat` is 9.4 % slower per feed; `sqlite` screened +0.621 µs/req, not better, and it is not simpler (two more statements, and SQLite writes U+2028 and U+2029 raw where PHP escapes them) |
| the loop | the default (`epoll`, no `APP_LOOP`) | `nolock` is a no-op, `changelist` removes nothing without group commit (not chosen), `poll` has no gate that passed (its count was taken with no idle connection) |
| the PHP version | 8.5 | 8.6 is -0.1 % and 8.4 -0.4 % in one pair each, inside the floor: neither is faster or slower |
| S8, S9 | as in 5a | not touched by this phase's CPU variants |
