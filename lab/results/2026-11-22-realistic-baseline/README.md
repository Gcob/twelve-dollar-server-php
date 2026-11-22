# The realistic baseline

The challenge app (the skeleton: `lab/app/`, the DIY server, 1 CPU) under the bench's own journey (`lab/macro/k6/realistic.js`, think
time scaled down), with 60,000 idle keep-alive connections held, on a quiet Docker VM (Docker Desktop on an M3 Pro, arm64, PHP 8.5).
These are arm64 numbers, not a score. This file is written in three steps: the predictions and the plan of the runs first (below,
before any measured run), then the results, then the verdicts.

### Predictions (D5)

Written by the project manager on 2026-11-22 at 10:57, before any phase 4 measurement (commit `b573485`), and revised
at 11:12 after the plan review, still before any measurement: prediction 3 maps users at 9.45 per req/s (D40) instead
of 10.8, and prediction 7 reads the WAL's frames, not its file size. Arm64, Docker Desktop on an M3 Pro, quiet VM, PHP
8.5, the DIY server, 1 CPU.

**What we start from:** the bake-off's DIY at 7,000 req/s: `/noop` 21.88 µs/req, `/posts/:id` (a different post each
request, all 500,000) 29.14; at 9,500, 17.37 and 27.66. DIY held 65,000 idle connections at 1.48 KiB of `Pss` each
(5.19 KiB of `memory.current`). Not measured yet: `/feed` (20 rows, 20 like counts, about 5 KB of JSON), the writes,
the JWT check. The Swoole entries cost 94 to 101 µs/req on the bench's x86 VM, a slower CPU than the M3.

**How they're judged:** a µs/req is the median of the 3 holds; a range holds if the measured value is inside it; a
share is a profile's share of the server's samples.

1. **The skeleton passes the challenge's 42 tests** with the reference SQL, `json_encode` and a hand-written HS256
   check, on the first full run of scope 1's harness after the code is written (no change needed in the test harness).
2. **µs CPU per request under the realistic mix: 50 to 90.** `/feed` costs 3 to 4 times a post (20 rows and 20 counts
   instead of 1), and is 46 % of the requests: it carries more than half of the CPU.
3. **The held rate (median of 3 holds) is 10,000 to 18,000 req/s, so 94,500 to 170,000 mapped users** on the Mac. This
   is arm64 (D35): the x86 VM's CPU is slower, so it is not a prediction of the score.
4. **The 97 % rule fails before the thresholds:** at the first failing step of the staircase, p95 is still under
   500 ms, and the step fails on its achieved rate. Without D31 the staircase would have passed one or more steps
   further.
5. **p99 at the held rate: under 50 ms on every endpoint**, and the writes (like, post) have the highest p99.
6. **Memory with 60,000 idle connections:** `memory.current` 500 to 800 MiB at the held rate (the bake-off's 254 MiB
   baseline plus 60,000 times 5.19 KiB, plus the WAL and SQLite's cache); `Pss_Anon` under 150 MiB.
7. **The WAL's frames in use stay under 2,000 (8 MiB) for the whole 5-minute hold**, a sawtooth: `wal_autocheckpoint`
   at its default (1,000 pages, about 4 MiB) checkpoints it, and one connection never starves a checkpoint. The file
   itself grows to its high-water mark and stays there.
8. **The profile's ranking:** S6 (SQLite) is the largest step with 35 to 55 % of the samples; then S8 (write, with the
   kernel's send inside `fwrite`) 10 to 20 %; then S7 (JSON) 10 to 20 %; S2 (read and parse) 5 to 10 %; S4 (JWT) under
   2 % (7.8 % of requests); S3, S5 and S9 under 2 % each. The cgroup's `system_usec` is 25 to 40 % of the CPU.
9. **Q10: the stalls are not the server's.** Under `posts.js` at rate / 10 VUs, stalls over 100 ms may come back, but
   in every stalled second the server's longest callback stays under 20 ms (the server wasn't running, so the host
   stalled it). Under the realistic hot set, warm, no second has a max latency over 100 ms in any of the 3 holds. Cold,
   the first seconds have more major faults and a higher p99, back to the warm level within 30 s.
10. **GC:** under 5 `gc_status()` runs per 5-minute hold, and none in a stalled second.
11. **Costs of the instruments:** telemetry under 2 % of µs/req; Excimer at 1 ms under 5 %.
12. **k6 at 2,500 VUs:** under 2 MiB per VU (the load test is small and its tokens are shared), so the VM's 7.75 GiB
    holds k6, the server and the idle client together.

The D numbers in this section are the decisions in `plan/decisions.md`.

The predictions were written at 10:57 and revised at 11:12, before any measurement, and not revised after the smoke runs of the
earlier scopes (busy VM), which had already passed 17,816 req/s.

## Plan of the runs

Every series starts with `docker ps` showing no container but the lab's own; every counted JSON says `other_containers: 0`. No image
build and no `lab/check.sh` during the series. A run that is invalid keeps its files and is shown, not counted.

1. **Calibration** on the quiet VM (`realistic.sh --calibrate`, stream on): k6's MiB per VU and its CPU, the aggregator's lag at low
   load and at the top rate, achieved against offered at low load; the VU cap; the scale `s`. The lag gate is the lag at the top rate
   plus 2 s (6 s if the top-rate lag is about 4 s).
2. **Staircase:** a fresh run, 60,000 idle, telemetry on, a warm-up at about 10 % of the expected capacity for 60 s, then steps of
   1,000 req/s from 3,000, 60 s plateaus, stopping at the first failing step. Then a fine staircase of 250 req/s from the last passing
   rate to the failing one. A knee above the cap lowers `s` (more req/s per VU, same VUs). A step where k6 and the aggregator cross
   80 % of their 8 CPUs is generator-bound, invalid.
3. **Holds:** 3 holds of 5 minutes at the highest passing rate of the fine staircase, each a fresh run (new seed copy, new server, new
   60,000 idle). The median of the 3 is the baseline. Then 1 hold one fine step above. If a hold fails, the 3 holds move one fine step
   down.
4. **Profile:** one 60 s run at the baseline's rate with Excimer (`--profile`), and the same run without it, interleaved: Excimer's
   cost. The fold's `--us-per-req` comes from the unprofiled run.
5. **Telemetry's cost:** 2 pairs of 60 s runs at the baseline's rate, telemetry on against off, interleaved.
6. **Q10:** `lab/macro/k6/posts.js` on the skeleton through `macro.sh --fresh-db --per-second` at 7,000 req/s with rate / 10 VUs
   (700), 30 s after a 10 s warm-up, 3 runs warm and 3 cold (`--cold`), interleaved; plus the first 60 s of a cold realistic hold
   against a warm one at the baseline's rate. A stall is a second whose max latency is over 100 ms; for each, the server's longest
   callback that second tells "inside the server" (callback at least the stall) from "the server was not running" (short callbacks).
7. **Results and verdicts:** `summarize.sh` regenerates every table below from the JSON files next to it.

## What differed from the plan of the runs

- **The calibration ran twice:** the default (50 and 300 VUs) and 300 and 5,000 VUs, so that k6's cost per VU at a few thousand VUs and
  the aggregator's lag at a top rate are measured, not extrapolated. The gate is the top-rate lag plus 2 s: 3.49 + 2 = **5.5 s**.
- **The staircase starts at 18,000 req/s and its think scale is 0.02, not 3,000 req/s at 0.0286.**
  - A first staircase at the calibrated 0.0286 ran 3,000 to 19,000 req/s (the most 5,400 VUs offer at that scale) and passed every
    step it judged (achieved 98.5 to 99.6 % of offered): **the knee is above the VU cap.** Its 17th step reached k6's memory budget
    (4,351 MiB) and k6 was killed, so the run is INVALID and sits in "Runs that do not count" with its steps shown, not counted.
    k6's memory grows with the request count (about 190 bytes a request on top of 0.34 MiB a VU: it keeps every sample of its
    trend metrics): about 12 million requests is the ceiling of one run, so a long staircase has to be cut.
  - As the plan says for a knee above the cap, `s` was lowered (more req/s per VU, same VUs): **0.02**, where 5,400 VUs offer 28,600 req/s
    and the 97 % rule leaves 5.8 ms of mean latency per request (8.35 ms at 0.0286). The staircase was run again from the last passing
    rate (18,000) in two runs: 18,000 to 24,000 (all pass), then 24,000 to 28,000 (the first step, 24,000, fails: 96.7 % achieved).
    The fine staircase (250 req/s, 23,000 to 24,000) passed every step, 24,000 included.
  - **The knee depends on `s`:** the 97 % rule spends 3 % of the offered rate, which is about `0.29 * s` seconds of mean latency per
    request. At 0.0286 the server passes 19,000 req/s with 98.5 % achieved; at 0.02 the line is crossed near 24,000. The baseline below
    is the rate held at `s = 0.02`, not a server limit: its CPU is 63 % busy there.
  - 24,000 req/s sits on the line: of the 17 runs at that rate, 4 failed the rule (96.7 to 97.0 % achieved) and 13 passed (97.1 to 97.7 %).
- **The holds** ran at 24,000 req/s (the highest passing rate of the fine staircase), each with a 60 s warm-up at 2,000 req/s like the
  staircases, a 300 s plateau and a fresh server, seed copy and 60,000 idle connections. All three passed: no step down. The hold one fine
  step above (24,250) passed too.
- **The 60 s runs** (Excimer, telemetry, cold and warm) ran at 24,000 req/s too. Three of them (`profile-off-2`, `telemetry-1-on`,
  `telemetry-1-off`) failed the 97 % rule by 0.1 to 0.3 points: they are valid and counted for what they measure (CPU per request, which the rule
  does not touch), and their result column says FAIL.
- **Excimer's cost** has three runs, unprofiled, profiled, unprofiled (the plan said one pair), all with the telemetry off: a profiled
  server runs without it, so the pair has to as well. The fold's `--us-per-req` is the mean of the two unprofiled runs.
- **The cold macro runs have no warm-up** (`--warmup 0`): a warm-up reads the copy back into the page cache and the run would no
  longer start cold. The warm ones keep the 10 s warm-up. The realistic cold and warm runs are two pairs of 60 s with no warm-up at all.
- **Two harness bugs** came out of the first runs and are fixed in their own commits: the run's own idle client was counted as another
  container (so no run with `--idle` could say `other_containers: 0`), and a run of 20 minutes failed at the very end with `jq: Argument list
  too long` (one JSON passed through the arguments, over the 1 MiB macOS allows), which cost a whole staircase.
- **The lag printed at the end can pass the gate in a valid run** (hold-3 says 6.3 s against 5.5): the gate is judged every second while k6
  runs, and the figure keeps the tail after k6 stops, when the newest sample's second no longer advances.
- **Run files:** every run's JSON and its `.txt` are here, `run-times.txt` has the start and end of each, and `profile.collapsed` holds
  the stacks. The JSON's command line is the one that ran. `challenge-test.txt` is the challenge's own suite on the app.

## Results

What follows is the output of `bash summarize.sh`, unedited: running it again must print the same text (`bash summarize.sh | diff - <(sed -n '/^<!-- BEGIN summarize -->$/,/^<!-- END summarize -->$/p' README.md | sed '1d;$d')`
prints nothing). The fold table in it runs `php-lab:8.5` in Docker; every other table is `jq` on the JSON files.

<!-- BEGIN summarize -->
### Calibration (quiet VM, stream on, think scale 0.0286)

| Run | VUs | k6 memory MiB | achieved / offered | k6 CPU (% of one CPU, µs/req) | aggregator max lag s |
|---|---|---|---|---|---|
| calibration-low | 50 | 79.48 | 0.997 | 13.88 %, 752 | 2.362 |
| calibration-low | 300 | 150.57 | 0.996 | 43.9 %, 397 | 2.988 |
| calibration-top | 300 | 150.56 | 0.994 | 44.08 %, 400 | 2.476 |
| calibration-top | 5000 | 1761.47 | 0.987 | 260 %, 142 | 3.491 |

| Calibration | MiB per VU | MiB at rest | VU cap (bound by) | scale for 20,000 req/s | lag gate to use s | valid | other containers |
|---|---|---|---|---|---|---|---|
| calibration-low | 0.284 | 65.26 | 5400 (file descriptors) | 0.02858 | 4.99 | true | 0 |
| calibration-top | 0.343 | 47.74 | 5400 (file descriptors) | 0.02858 | 5.49 | true | 0 |

### staircase-coarse-1

Run `staircase-coarse-1.json`: think scale 0.02, VU cap 5400, warm-up 2000,60, 60 s plateaus, lag gate 5.5 s; valid true, other containers 0, idle held 60000 at the start and 60000 at the end, aggregator max lag 5.965 s, k6 connection errors 0.

| Step | VUs | offered req/s | achieved req/s | users | µs CPU/req | p95 ms | p99 ms | errors | k6 CPU % of one | result |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 3401 | 18000.4 | 17783.8 | 168057 | 27.3 | 4.27 | 12.47 | 0 % | 238.99 | pass |
| 2 | 3590 | 19000.7 | 18764 | 177319 | 26.5 | 4.96 | 11.07 | 0 % | 241.47 | pass |
| 3 | 3779 | 20001 | 19738.2 | 186526 | 27.1 | 6.58 | 14.69 | 0 % | 256.84 | pass |
| 4 | 3968 | 21001.4 | 20701.3 | 195627 | 27.3 | 7.63 | 15.83 | 0 % | 270.05 | pass |
| 5 | 4157 | 22001.7 | 21554.7 | 203692 | 27.2 | 9.54 | 24.74 | 0 % | 281 | pass |
| 6 | 4346 | 23002 | 22418.1 | 211851 | 27.3 | 12.47 | 33.32 | 0 % | 298.29 | pass |
| 7 | 4535 | 24002.3 | 23299.9 | 220185 | 27.1 | 13.04 | 41.66 | 0 % | 312.44 | pass |

No step failed.

### staircase-coarse-2

Run `staircase-coarse-2.json`: think scale 0.02, VU cap 5400, warm-up 2000,60, 60 s plateaus, lag gate 5.5 s; valid true, other containers 0, idle held 60000 at the start and 60000 at the end, aggregator max lag 3.135 s, k6 connection errors 0.

| Step | VUs | offered req/s | achieved req/s | users | µs CPU/req | p95 ms | p99 ms | errors | k6 CPU % of one | result |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 4535 | 24002.3 | 23205.4 | 219291 | 26.8 | 13.84 | 38.67 | 0 % | 310.5 | FAIL: achieved below 97 % of offered |

Stopped at step 1: achieved below 97 % of offered.

### staircase-fine

Run `staircase-fine.json`: think scale 0.02, VU cap 5400, warm-up 2000,60, 60 s plateaus, lag gate 5.5 s; valid true, other containers 0, idle held 60000 at the start and 60000 at the end, aggregator max lag 5.587 s, k6 connection errors 0.

| Step | VUs | offered req/s | achieved req/s | users | µs CPU/req | p95 ms | p99 ms | errors | k6 CPU % of one | result |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 4346 | 23002 | 22529.2 | 212901 | 27.1 | 8.73 | 21.96 | 0 % | 297.47 | pass |
| 2 | 4393 | 23250.8 | 22682.1 | 214346 | 27.2 | 9.68 | 24.02 | 0 % | 296.19 | pass |
| 3 | 4441 | 23504.8 | 22989.2 | 217248 | 26.9 | 9.83 | 27.05 | 0 % | 297.7 | pass |
| 4 | 4488 | 23753.6 | 23179.1 | 219043 | 27.2 | 11.93 | 28.29 | 0 % | 304 | pass |
| 5 | 4535 | 24002.3 | 23442.8 | 221535 | 26.9 | 11.58 | 27.05 | 0 % | 304.44 | pass |

No step failed.

### The holds (5 minutes each, a fresh run each)

| Run | valid | other containers | offered req/s | achieved req/s | users at 9.45 per req/s | µs CPU/req | p95 ms | p99 ms | errors | k6 CPU % of one | idle held (start / end) | aggregator max lag s | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| hold-1 | true | 0 | 24002.3 | 23323.7 | 220409 | 27.71 | 13.04 | 33.32 | 0 % | 306.95 | 60000 / 60000 | 5.497 | pass |
| hold-2 | true | 0 | 24002.3 | 23386.4 | 221002 | 27.15 | 11.07 | 25.87 | 0 % | 306.19 | 60000 / 60000 | 3.803 | pass |
| hold-3 | true | 0 | 24002.3 | 23389.9 | 221035 | 27.06 | 11.93 | 28.29 | 0 % | 307.48 | 60000 / 60000 | 6.336 | pass |
| hold-above | true | 0 | 24251.1 | 23625.3 | 223259 | 26.96 | 11.58 | 27.87 | 0 % | 308.23 | 60000 / 60000 | 4.294 | pass |
| **median of the 3 counted holds** | | | 24002.3 | **23386.4** | **221002** | **27.15** | **11.93** | **28.29** | 0 % (max) | 306.95 | | | |

Per endpoint, p95 / p99 in ms over the plateau (requests in brackets):

| Run | GET /feed | GET /posts/:id | POST /posts/:id/like | POST /posts |
|---|---|---|---|---|
| hold-1 | 13.64 / 34.33 (3202656) | 12.29 / 32.83 (3202483) | 12.47 / 32.35 (481483) | 11.75 / 30.93 (63831) |
| hold-2 | 11.58 / 26.65 (3211701) | 10.59 / 25.49 (3211883) | 10.91 / 25.49 (481457) | 10.28 / 24.38 (64118) |
| hold-3 | 12.66 / 29.58 (3211681) | 11.41 / 27.46 (3211598) | 11.75 / 27.87 (482358) | 11.07 / 27.05 (64567) |
| hold-above | 12.11 / 28.71 (3244205) | 11.07 / 27.46 (3244819) | 11.58 / 27.87 (486071) | 10.91 / 27.05 (65237) |
| **median of the counted holds** | 12.66 / 29.58 | 11.41 / 27.46 | 11.75 / 27.87 | 11.07 / 27.05 |

### Per-second latency over each hold's plateau (stall: a second whose max latency, over any endpoint, is above 100 ms)

| Run | plateau seconds | stalled seconds | largest per-second max ms | median per-second p99 ms (GET /feed) | GC runs (telemetry) | GC runs in stalled seconds | longest callback ms | major faults |
|---|---|---|---|---|---|---|---|---|
| hold-1 | 298 | 21 | 303.5 | 22.29 | 0 | 0 | 48.86 | 0 |
| hold-2 | 298 | 16 | 243.5 | 20.24 | 0 | 0 | 36.622 | 0 |
| hold-3 | 298 | 16 | 117 | 20.69 | 0 | 0 | 40.093 | 0 |
| hold-above | 298 | 18 | 182.4 | 20.85 | 0 | 0 | 45.433 | 0 |

Excerpt of the first hold: ten seconds from the middle of the plateau (per endpoint: requests, then p50 / p99 / max latency in ms; the full series are in the JSON):

| second | req | GET /feed | GET /posts/:id | POST /posts/:id/like | POST /posts | server CPU ms |
|---|---|---|---|---|---|---|
| +149 | 23380 | 10830: 0.325 / 17.052 / 42.5 | 10771: 0.306 / 16.552 / 43.704 | 1570: 0.325 / 18.099 / 37.116 | 209: 0.32 / 13.639 / 14.878 | 624 |
| +150 | 23331 | 10708: 0.345 / 28.29 / 48.335 | 10774: 0.315 / 28.29 / 48.577 | 1630: 0.33 / 26.26 / 41.898 | 219: 0.383 / 24.016 / 32.102 | 656 |
| +151 | 23530 | 10816: 0.325 / 11.752 / 21.496 | 10843: 0.288 / 11.408 / 24.285 | 1638: 0.34 / 11.239 / 22.232 | 233: 0.335 / 13.438 / 18.095 | 633 |
| +152 | 23239 | 10705: 0.311 / 28.29 / 53.442 | 10694: 0.288 / 28.714 / 49.239 | 1622: 0.311 / 30.026 / 44.671 | 218: 0.33 / 25.113 / 42.011 | 637 |
| +153 | 19898 | 9598: 0.654 / 137.097 / 139.185 | 8837: 0.471 / 135.071 / 139.221 | 1296: 0.564 / 137.097 / 139.033 | 167: 0.493 / 135.071 / 138.851 | 708 |
| +154 | 23152 | 10277: 0.361 / 114.666 / 169.719 | 11042: 0.377 / 121.702 / 160.338 | 1622: 0.355 / 116.386 / 150.215 | 211: 0.302 / 109.657 / 113.053 | 631 |
| +155 | 23087 | 10588: 0.372 / 17.568 / 30.027 | 10710: 0.33 / 17.052 / 26.616 | 1570: 0.372 / 16.8 / 24.702 | 219: 0.35 / 14.914 / 15.886 | 666 |
| +156 | 23286 | 10832: 0.389 / 51.318 / 99.624 | 10706: 0.34 / 49.076 / 77.23 | 1538: 0.372 / 56.113 / 88.425 | 210: 0.372 / 41.047 / 70.675 | 658 |
| +157 | 23310 | 10710: 0.345 / 24.742 / 56.222 | 10771: 0.315 / 24.742 / 55.908 | 1617: 0.34 / 25.872 / 41.831 | 212: 0.335 / 25.113 / 37.215 | 639 |
| +158 | 23623 | 10873: 0.394 / 13.239 / 21.67 | 10908: 0.35 / 12.474 / 16.62 | 1640: 0.394 / 11.752 / 16.422 | 202: 0.4 / 8.99 / 10.325 | 669 |

### Memory and the WAL over each hold's plateau

| Run | Pss_Anon MiB (min .. max) | memory.current MiB (min .. max) | peak over the whole run: Pss_Anon / memory.current MiB | WAL frames (min .. max, median) | seconds above 2,000 frames | checkpoints seen (drops of the frame count) | WAL file KiB (start .. end, max) |
|---|---|---|---|---|---|---|---|
| hold-1 | 104.1 .. 159.9 | 594.7 .. 695.9 | 160.1 / 696.04 | 3 .. 1004, 524.5 | 0 | 101 | 4064 .. 4080, 4080 |
| hold-2 | 104 .. 158 | 594.2 .. 694.1 | 158.3 / 694.11 | 9 .. 1005, 559.5 | 0 | 112 | 4056 .. 4068, 4068 |
| hold-3 | 104.1 .. 158.2 | 593.8 .. 694.7 | 158.44 / 694.49 | 6 .. 1007, 522.5 | 0 | 98 | 4060 .. 4068, 4068 |
| hold-above | 106.1 .. 160.7 | 596.1 .. 697.1 | 160.94 / 699.48 | 12 .. 1009, 528 | 0 | 93 | 4056 .. 4072, 4072 |

Excerpt of the first hold, every 30 seconds of the plateau:

| second | Pss_Anon MiB | memory.current MiB | WAL frames | WAL file KiB | fds | server CPU % of one |
|---|---|---|---|---|---|---|
| +0 | 104.1 | 595.5 | 1000 | 4064 | 64547 | 60.2 |
| +30 | 109.3 | 604.2 | 817 | 4064 | 64547 | 60.2 |
| +60 | 114.8 | 614 | 413 | 4064 | 64547 | 62.3 |
| +90 | 120.2 | 623.5 | 328 | 4064 | 64547 | 63.5 |
| +120 | 125.6 | 633.6 | 573 | 4064 | 64547 | 63 |
| +150 | 131.2 | 643.9 | 949 | 4064 | 64547 | 65.6 |
| +180 | 136.8 | 655.2 | 676 | 4064 | 64547 | 64.8 |
| +210 | 144.2 | 667.2 | 283 | 4080 | 64547 | 65.9 |
| +240 | 149.7 | 678.1 | 1004 | 4080 | 64547 | 64.3 |
| +270 | 155.1 | 686.6 | 274 | 4080 | 64547 | 61.2 |

### Excimer's cost: the same 60 s run unprofiled, profiled, unprofiled (telemetry off in all three)

| Run | valid | other containers | server env | offered req/s | achieved req/s | µs CPU/req (plateau) | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|
| profile-off-1 | true | 0 | APP_TELEMETRY=0 | 24002.3 | 23325.5 | 26.87 | 11.75 | 30.48 | pass |
| profile-on | true | 0 | APP_PROFILE=/tmp/profile.collapsed APP_TELEMETRY=0 | 24002.3 | 23347.4 | 27.5 | 11.58 | 29.58 | pass |
| profile-off-2 | true | 0 | APP_TELEMETRY=0 | 24002.3 | 23227.1 | 28.32 | 16.07 | 42.29 | FAIL: achieved below 97 % of offered |

Unprofiled mean 27.59 µs/req (26.87 and 28.32), profiled 27.5: Excimer at 1 ms costs **-0.33 %** (against each unprofiled run: 2.36 % and -2.87 %) of the CPU per request.

Profiled window (the server's whole life after its first answer: warm-up, ramps and plateau): 57666 samples at 1 ms, the cgroup's user CPU 40406 ms and system CPU 17536 ms (**30 % in the kernel**), the samples cover 100 % of that CPU, unclassified 0 %.

Fold of `profile.collapsed` with `--us-per-req 27.59253358992909` (the unprofiled runs' mean). Each cell is a share of all the samples and the microseconds it adds to the average request:

```text
step                   GET /health     GET /feed  GET /posts/:id  POST /posts  POST /posts/:id/like        shared            all
S1 accept connections   0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    1.7% 0.5us     1.7% 0.5us
S2 read and parse       0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    8.0% 2.2us     8.0% 2.2us
S3 route                0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    0.4% 0.1us     0.4% 0.1us
S4 verify the JWT       0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.2% 0.1us            1.4% 0.4us    0.0% 0.0us     1.7% 0.5us
S5 validate the input   0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.1% 0.0us    0.0% 0.0us     0.1% 0.0us
S6 query SQLite         0.1% 0.0us  38.8% 10.7us      6.0% 1.6us   0.9% 0.3us            5.9% 1.6us    0.0% 0.0us   51.7% 14.3us
S7 build the JSON       0.0% 0.0us    8.8% 2.4us      0.7% 0.2us   0.0% 0.0us            0.1% 0.0us    0.0% 0.0us     9.7% 2.7us
S8 write the response   0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us   20.1% 5.6us    20.2% 5.6us
S9 durability           0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    0.0% 0.0us     0.0% 0.0us
event loop              0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    6.5% 1.8us     6.5% 1.8us
unclassified            0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    0.0% 0.0us     0.0% 0.0us
all                     0.2% 0.0us  47.6% 13.1us      6.7% 1.8us   1.3% 0.4us            7.5% 2.1us  36.8% 10.1us  100.0% 27.6us
samples: 57666, 27.6 us per request on average
each cell: share of all samples and the microseconds it adds to the average request; S9 is inside S6 (autocommit)

within each endpoint (share of that column's own samples):
step                   GET /health  GET /feed  GET /posts/:id  POST /posts  POST /posts/:id/like  shared
S1 accept connections         0.0%       0.0%            0.0%         0.0%                  0.0%    4.6%
S2 read and parse             0.0%       0.0%            0.0%         0.0%                  0.0%   21.8%
S3 route                      0.0%       0.0%            0.0%         2.8%                  0.0%    1.1%
S4 verify the JWT             0.0%       0.0%            0.0%        19.0%                 19.3%    0.0%
S5 validate the input         0.0%       0.0%            0.5%         3.3%                  0.8%    0.0%
S6 query SQLite              80.6%      81.4%           89.2%        72.0%                 79.0%    0.0%
S7 build the JSON            19.4%      18.6%           10.3%         2.5%                  0.9%    0.0%
S8 write the response         0.0%       0.0%            0.0%         0.4%                  0.0%   54.8%
S9 durability                 0.0%       0.0%            0.0%         0.0%                  0.0%    0.0%
event loop                    0.0%       0.0%            0.0%         0.0%                  0.0%   17.8%
unclassified                  0.0%       0.0%            0.0%         0.0%                  0.0%    0.0%
weight in all samples         0.2%      47.6%            6.7%         1.3%                  7.5%   36.8%
```

### Telemetry's cost: two pairs of 60 s runs, `APP_TELEMETRY=1` against `0`, interleaved

| Run | valid | other containers | server env | offered req/s | achieved req/s | µs CPU/req (plateau) | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|
| telemetry-1-on | true | 0 | APP_TELEMETRY=1 | 24002.3 | 23276.5 | 27.6 | 13.44 | 39.84 | FAIL: achieved below 97 % of offered |
| telemetry-1-off | true | 0 | APP_TELEMETRY=0 | 24002.3 | 23256.6 | 27.33 | 14.48 | 38.1 | FAIL: achieved below 97 % of offered |
| telemetry-2-off | true | 0 | APP_TELEMETRY=0 | 24002.3 | 23407.5 | 27.03 | 10.13 | 24.74 | pass |
| telemetry-2-on | true | 0 | APP_TELEMETRY=1 | 24002.3 | 23404.1 | 26.73 | 10.28 | 27.46 | pass |

Pair 1: 1 %, pair 2: -1.1 %; on against off over both pairs: **-0.05 %** of the CPU per request.

### What the stalls of each hold were (seconds of the plateau whose max latency is above 100 ms)

| Run | stalled seconds | callback at least as long as the stall (inside the server) | longest callback under 20 ms (outside the server) | in between | longest callback in a stalled second ms (median) | CFS throttling of the server's cgroup over the run (periods, ms) |
|---|---|---|---|---|---|---|
| hold-1 | 21 | 0 | 16 | 5 | 13.9 | 1, 0.1 |
| hold-2 | 16 | 0 | 14 | 2 | 12.7 | 1, 2.3 |
| hold-3 | 16 | 0 | 14 | 2 | 11.6 | 0, 0 |
| hold-above | 18 | 0 | 16 | 2 | 11.5 | 1, 9.2 |

### Q10: `posts.js` at 7,000 req/s with 700 VUs, 30 s (warm: after a 10 s warm-up; cold: the copy evicted from the page cache, no warm-up), per-second series

| Run | valid | other containers | achieved req/s | µs CPU/req | p99 ms | max ms | dropped iterations | seconds | stalled seconds | inside / outside / mixed | major faults (seconds 0-9 / 10-19 / 20-29) | median per-second p99 ms (0-9 / 10-19 / 20-29) | CFS throttled ms |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| q10-warm-1 | false | 0 | 6693 | 35.15 | 40.92 | 877.7 | 9193 | 31 | 5 | 0 / 2 / 3 | 0 / 0 / 0 | 1.1 / 1.5 / 2.4 | 325.4 |
| q10-cold-1 | true | 0 | 6999.5 | 25.44 | 2.02 | 38.4 | 0 | 31 | 0 | 0 / 0 / 0 | 1582 / 0 / 0 | 2 / 1.1 / 0.3 | 0 |
| q10-warm-2 | true | 0 | 6999.1 | 26.44 | 7.43 | 139 | 0 | 31 | 1 | 0 / 1 / 0 | 0 / 0 / 0 | 0.9 / 0.9 / 0.7 | 0 |
| q10-cold-2 | true | 0 | 6999.2 | 25.83 | 2.82 | 38.6 | 0 | 31 | 0 | 0 / 0 / 0 | 1579 / 0 / 0 | 1.9 / 0.7 / 0.4 | 0 |
| q10-warm-3 | false | 0 | 6997.2 | 25.77 | 14.07 | 147 | 39 | 31 | 1 | 0 / 1 / 0 | 0 / 0 / 0 | 1.4 / 1.3 / 1.2 | 27.3 |
| q10-cold-3 | true | 0 | 6999.5 | 25.99 | 3 | 51.4 | 0 | 31 | 0 | 0 / 0 / 0 | 1582 / 0 / 0 | 2.3 / 0.8 / 0.8 | 0 |

### Q10: the first 60 s of a realistic run, cold against warm (no warm-up, 60,000 idle, the baseline's rate; the 60 s counted from the first second that has requests, ramp included)

| Run | valid | other containers | achieved req/s | µs CPU/req | stalled seconds | inside / outside / mixed | major faults (seconds 0-9 / 10-29 / 30-59) | median per-second p99 ms (0-9 / 10-29 / 30-59) | page cache resident at start | CFS throttled ms |
|---|---|---|---|---|---|---|---|---|---|---|
| cold-60s-1 | true | 0 | 23387.8 | 27.09 | 2 | 0 / 2 / 0 | 29 / 4 / 0 | 5.1 / 23.1 / 19.8 | 0 % | 0 |
| warm-60s-1 | true | 0 | 23351.9 | 26.96 | 2 | 0 / 1 / 1 | 0 / 0 / 0 | 7.4 / 20.1 / 21.6 | 100 % | 0 |
| cold-60s-2 | true | 0 | 23321.1 | 27.44 | 7 | 0 / 4 / 3 | 28 / 3 / 0 | 10.3 / 22.2 / 20.7 | 0 % | 1.3 |
| warm-60s-2 | true | 0 | 23409.1 | 26.82 | 1 | 0 / 1 / 0 | 0 / 0 / 0 | 6.2 / 20.7 / 20.5 | 100 % | 0 |

### Every stalled second (max latency above 100 ms) of the Q10 runs and of the cold and warm realistic runs

| Run | second of the run | max latency ms | server's longest callback ms | requests | server CPU ms | major faults |
|---|---|---|---|---|---|---|
| q10-warm-1 | 14 | 307.4 | 72.694 | 6375 | 478 | 0 |
| q10-warm-1 | 24 | 257.2 | 180.953 | 3911 | 617 | 0 |
| q10-warm-1 | 25 | 877.7 | 180.685 | 1017 | 643 | 0 |
| q10-warm-1 | 26 | 611.4 | 6.342 | 7890 | 402 | 0 |
| q10-warm-1 | 27 | 173 | 6.5 | 6604 | 326 | 0 |
| q10-warm-2 | 28 | 139 | 3.76 | 6950 | 331 | 0 |
| q10-warm-3 | 7 | 147 | 14.2 | 6975 | 270 | 0 |
| cold-60s-1 | 23 | 207.3 | 13.724 | 21188 | 705 | 0 |
| cold-60s-1 | 38 | 105.7 | 10.854 | 23389 | 626 | 0 |
| warm-60s-1 | 34 | 102.3 | 8.772 | 23675 | 638 | 0 |
| warm-60s-1 | 48 | 175 | 24.033 | 21275 | 774 | 0 |
| cold-60s-2 | 15 | 107.4 | 14.397 | 21502 | 797 | 0 |
| cold-60s-2 | 21 | 106.6 | 11.164 | 23136 | 641 | 2 |
| cold-60s-2 | 25 | 112.5 | 53.717 | 22553 | 657 | 0 |
| cold-60s-2 | 47 | 108.5 | 9.434 | 23430 | 659 | 0 |
| cold-60s-2 | 53 | 136 | 7.758 | 23980 | 634 | 0 |
| cold-60s-2 | 57 | 132.9 | 25.87 | 20214 | 733 | 0 |
| cold-60s-2 | 58 | 187.8 | 36.503 | 22667 | 721 | 0 |
| warm-60s-2 | 37 | 107.4 | 9.464 | 23230 | 659 | 0 |

### Runs that do not count

| File | valid | reason | other containers |
|---|---|---|---|
| q10-warm-1.json | false | 9193 dropped iterations: k6 had no free VU to start them (700 VUs absorb a stall of 100 ms at 7000 req/s; latency max was 877 ms) | 0 |
| q10-warm-3.json | false | 39 dropped iterations: k6 had no free VU to start them (700 VUs absorb a stall of 100 ms at 7000 req/s; latency max was 146 ms) | 0 |
| invalid/staircase-s0.0286-k6-memory-budget.json | false | k6 was killed for reaching its memory budget (4351 MiB) | 0 |

Steps of `invalid/staircase-s0.0286-k6-memory-budget.json` (shown, not counted):

Run `invalid/staircase-s0.0286-k6-memory-budget.json`: think scale 0.0286, VU cap 5400, warm-up 1800,60, 60 s plateaus, lag gate 5.5 s; valid false, other containers 0, idle held 60000 at the start and 60000 at the end, aggregator max lag 2.509 s, k6 connection errors 0.

| Step | VUs | offered req/s | achieved req/s | users | µs CPU/req | p95 ms | p99 ms | errors | k6 CPU % of one | result |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 811 | 3001.7 | 2988.8 | 28244 | 48.2 | 0.49 | 1.55 | 0 % | 63.57 | pass |
| 2 | 1081 | 4001 | 3976.3 | 37576 | 42.5 | 0.52 | 3.63 | 0 % | 79.85 | pass |
| 3 | 1351 | 5000.3 | 4976.1 | 47024 | 38.7 | 0.56 | 4.08 | 0 % | 92.19 | pass |
| 4 | 1622 | 6003.3 | 5967.6 | 56394 | 35.7 | 0.66 | 5.5 | 0 % | 102.19 | pass |
| 5 | 1892 | 7002.6 | 6969.2 | 65859 | 33 | 0.74 | 5.93 | 0 % | 110.01 | pass |
| 6 | 2162 | 8001.9 | 7961 | 75232 | 32.2 | 1.1 | 6.88 | 0 % | 123.11 | pass |
| 7 | 2432 | 9001.3 | 8955.6 | 84630 | 30.8 | 1.51 | 8.6 | 0 % | 130.41 | pass |
| 8 | 2702 | 10000.6 | 9950.9 | 94036 | 30.6 | 2.22 | 9.98 | 0 % | 146.02 | pass |
| 9 | 2973 | 11003.6 | 10949.7 | 103474 | 29.4 | 2.61 | 8.99 | 0 % | 154.54 | pass |
| 10 | 3243 | 12002.9 | 11930.5 | 112743 | 28.7 | 2.94 | 9.54 | 0 % | 166.14 | pass |
| 11 | 3513 | 13002.2 | 12929.3 | 122182 | 28.3 | 3.37 | 9.68 | 0 % | 175.84 | pass |
| 12 | 3783 | 14001.6 | 13899.6 | 131351 | 28.3 | 4.21 | 10.91 | 0 % | 191.99 | pass |
| 13 | 4053 | 15000.9 | 14889.4 | 140705 | 29 | 5.93 | 15.83 | 0 % | 213.24 | pass |
| 14 | 4323 | 16000.2 | 15892.2 | 150182 | 28.1 | 5.26 | 10.91 | 0 % | 220.15 | pass |
| 15 | 4594 | 17003.2 | 16794.6 | 158709 | 29.3 | 7.86 | 20.39 | 0 % | 246.31 | pass |
| 16 | 4864 | 18002.5 | 17815.8 | 168359 | 28.6 | 8.22 | 17.31 | 0 % | 255.37 | pass |
| 17 | 5134 | 19001.8 | 18722.3 | 176926 | 29.5 | 11.58 | 29.15 | 0 % | 276.72 | pass |

No step failed.
<!-- END summarize -->

## Reading the results

- **Calibration:** k6 costs 0.28 to 0.34 MiB per VU (and 48 to 65 MiB at rest), so the memory cap is 12,700 to 15,300 VUs and the cap is the
  file descriptors, **5,400**. The scale that puts 20,000 req/s under it is 0.02858. k6 costs 752 µs of CPU per request at 50 VUs, 400 at
  300 and 142 at 5,000 VUs (260 % of one CPU). Achieved over offered is 0.994 to 0.997 at low load and 0.987 at 18,300 req/s. The
  aggregator's lag is 2.4 to 3.0 s at 300 VUs and 3.49 s at 5,000, so **the gate is 5.5 s**. k6 and the aggregator stay far from 80 % of their
  8 CPUs at the baseline (k6 307 % of one CPU, which is 38 % of the 8, and the aggregator is one process: 12.5 % at most), so no step is generator-bound.
- **Staircases:** at 0.0286 nothing fails up to 19,000 req/s (the cap); at 0.02 the CPU per request is 26.5 to 27.3 µs from 18,000 to 24,000
  and p95 grows from 4.3 to 13 ms. The first failing step is 24,000 (coarse run 2): p95 13.8 ms, p99 38.7 ms, 0 errors, failing on achieved
  96.7 %, never on a latency threshold. Mean latency at the baseline is 2.2 ms against a p95 of 11 to 13 ms.
- **The baseline (median of 3 holds at 24,000):** **23,386 req/s achieved, 221,002 users at 9.45 per req/s, 27.15 µs of CPU per request,
  p95 11.93 ms, p99 28.29 ms**, 0 errors, 60,000 idle connections held at the start and the end of each. The hold above (24,250) passes with
  23,625 req/s, 223,259 users, 26.96 µs, p95 11.58 ms, p99 27.87 ms: the baseline is a conservative reading of the rule at `s = 0.02`.
  Per endpoint (median p95 / p99 ms): `GET /feed` 12.66 / 29.58, `GET /posts/:id` 11.41 / 27.46, `POST /posts/:id/like` 11.75 / 27.87,
  `POST /posts` 11.07 / 27.05.
- **Latency second by second:** the median per-second p99 of `GET /feed` is 20 to 22 ms, but **every hold has 16 to 21 seconds (of 298)
  whose max latency is over 100 ms**, up to 303 ms. In none of the 53 stalled seconds of the three holds was a callback as long as the stall
  (44 of them have a longest callback under 20 ms, 9 between 20 and 49 ms), and the server's cgroup was throttled once or not at all (0 to 9 ms).
  No `gc_status()` run in any hold, no major fault.
- **Memory:** `Pss_Anon` climbs from 104 to 158 to 161 MiB over each plateau (91 MiB of idle connections and 6 MiB of the app are
  there at the start; the rest is consistent with SQLite's 64 MiB page cache filling as `GET /posts/:id` reads random posts: 91 + 6 + 64 = 161,
  and the four holds peak at 158 to 161; not proven by a longer run). `memory.current` goes from 594 to 697 MiB with it (page cache of the
  database file included).
- **The WAL:** frames in use go from 3 to 1,004 to 1,009 (the autocheckpoint at 1,000 pages), 93 to 112 checkpoints per hold, never above
  2,000. The file grows 8 to 16 KiB in a hold (4,056 to 4,080 KiB) and stays there.
- **The profile** (57,666 samples of the server's whole life after its first answer, warm-up and ramps included; 30 % of the CPU is in the
  kernel, the samples cover 100 % of the cgroup's CPU): S6 (SQLite) takes 51.7 % of the samples (14.3 µs of 27.6), the write (S8, with the
  kernel's send inside `fwrite`) 20.2 %, S7 (JSON) 9.7 %, read and parse (S2) 8.0 %, the event loop 6.5 %, accept and close (S1) 1.7 %, the JWT check
  (S4) 1.7 %, the route (S3) 0.4 %, validation (S5) 0.1 %. **S9 has no frame**: with autocommit a write's commit (and any checkpoint) happens inside
  `PDOStatement::execute`, so it counts in S6; the step lab will split it. `GET /feed` carries 47.6 % of the samples, `GET /posts/:id` 6.7 %,
  `POST /posts/:id/like` 7.5 %, `POST /posts` 1.3 %, and the work done before the route is known (read, parse, write, loop, accept) is
  36.8 %. Within `GET /feed` S6 is 81.4 % and S7 18.6 %.
  The profiled window includes the ramps, so the table gives shares; the microseconds use the unprofiled runs' 27.59 µs per request.
- **Excimer at 1 ms** costs -0.33 % of the CPU per request (+2.4 % against the first unprofiled run, -2.9 % against the second, which ran
  5 % apart from each other): it is inside the noise, and under 5 %. **The telemetry** costs -0.05 % (+1.0 % in the first pair, -1.1 % in the
  second): inside the noise, under 2 %.
- **Q10, are the bake-off's stalls the server's?** Mostly not. In the three holds 0 of 53 stalled seconds had a callback as long as the stall
  (44 under 20 ms), so the time is lost outside the PHP code (the host, k6, the VM). The exception is one `posts.js` run at 700 VUs
  (`q10-warm-1`, 877 ms): its cgroup was CFS-throttled for 325 ms in 6 periods, with two callbacks of 181 ms: the server was stopped by
  its own 1-CPU quota, not slowed by its code. The other two warm runs stalled once (139 and 147 ms, callbacks 4 and 14 ms), and two of the three
  warm `posts.js` runs dropped iterations like the bake-off's (9,193 and 39), against none of the three cold ones.
- **Cold against warm:** the cold `posts.js` runs show 1,579 to 1,582 major faults in their first 10 s and none after, a median per-second p99
  of 1.9 to 2.3 ms in the first 10 s against 0.3 to 0.8 ms in the last ten (warm: 0.9 to 1.4 against 0.7 to 2.4, the high one being the throttled run). The cold realistic runs show 28 to 29
  major faults in the first 10 s and 3 to 4 in the next 20, and no higher p99 than the warm ones (5.1 and 10.3 ms against 7.4 and 6.2 ms in the first 10 s).

## Did the predictions hold?

One line each, by the rule written with them (a range holds if the measured value is inside it; a µs/req is the median of the 3 holds).
**6 of 12 held** (1, 4, 7, 10, 11, 12).

1. **Held.** The challenge's 42 tests pass on the app (`challenge-test.txt`: `passed=42 failed=0`), with the reference SQL, `json_encode` and the hand-written HS256 check.
2. **Not held.** 27.15 µs of CPU per request, against 50 to 90. `GET /feed` carries 47.6 % of the CPU, not more than half, and a feed request costs about 7 times a post request (28 against 4 µs, each being 46 % of the requests), not 3 to 4 times.
3. **Not held.** 23,386 req/s and 221,002 mapped users, against 10,000 to 18,000 and 94,500 to 170,000.
4. **Held.** The first failing step (24,000, coarse run 2) has p95 13.84 ms (under 500) and fails on its achieved rate (96.7 %); without the rule the staircase
   would have gone on (24,250 and the three holds pass, and no latency threshold is near).
5. **Not held.** p99 is under 50 ms on every endpoint (27.05 to 29.58 ms, the worst single hold 34.33), but the writes do not have the highest p99: `POST /posts`
   has the lowest (27.05) and `POST /posts/:id/like` is second (27.87), under `GET /feed` (29.58).
6. **Not held.** `memory.current` is 594 to 697 MiB (inside 500 to 800), but `Pss_Anon` peaks at 158 to 161 MiB (over 150).
7. **Held.** The WAL's frames peak at 1,004 to 1,009 (under 2,000), a sawtooth with 93 to 112 checkpoints a hold, and the file stays at 4,056 to 4,080 KiB.
8. **Not held.** S6 is the largest, 51.7 % (inside 35 to 55), then S8 20.2 % (10 to 20: 0.2 over), S7 9.7 % (10 to 20: 0.3 under), S2 8.0 % (inside 5 to 10),
   S4 1.7 % and S3, S5, S9 under 2 % (inside), and the kernel is 30.3 % of the CPU (inside 25 to 40): the order and five ranges hold, two ranges miss by under a point.
9. **Not held.** Warm, 16 to 21 seconds of each hold have a max latency over 100 ms (the prediction was none). Of the stalls, 0 of 53 had a callback as long as the stall,
   but one `posts.js` run (181 ms callbacks, 325 ms of CFS throttling) was not under 20 ms. Cold, the major faults rise in the first seconds and the `posts.js` p99
   comes back within 20 s, but the realistic runs show no higher p99.
10. **Held.** No `gc_status()` run in any of the four 5-minute holds (under 5), so none in a stalled second.
11. **Held.** The telemetry costs -0.05 % (under 2 %) and Excimer at 1 ms -0.33 % (under 5 %), both inside the noise of the runs.
12. **Held.** k6 costs 0.28 to 0.34 MiB per VU (under 2): 1.76 GiB at 5,000 VUs, and a 5-minute hold peaks at 2.8 GiB with its request count.

## The step lab's order

The fd wall comes first. The 221,002 users are CPU-equivalent: one process holds at most about 65,500 connections (65,535 fds), so on the real bench this server caps near 71,000 users, whatever its CPU. S1's fd wall therefore comes first in the step lab, before the CPU ranking below. That means S1-d (one process, answering with `Connection: close` near the limit) or S1-b (several processes with `SO_REUSEPORT`). The first thing to measure there is its cost under churn: one accept and one close per request past the limit. The CPU ranking below then orders the rest.

The steps ranked by their µs per request in the profile (the profiled shares times the unprofiled runs' 27.59 µs per request; the baseline's 27.15 µs
would scale each by 1.6 % less):

| Rank | Step | Share of the samples | µs per request |
|---|---|---|---|
| 1 | S6 query SQLite (S9, the commit and checkpoint, is inside it) | 51.7 % | 14.3 |
| 2 | S8 write the response | 20.2 % | 5.6 |
| 3 | S7 build the JSON | 9.7 % | 2.7 |
| 4 | S2 read and parse | 8.0 % | 2.2 |
| 5 | the event loop (libevent and `epoll_wait`, not a step) | 6.5 % | 1.8 |
| 6 | S1 accept and close | 1.7 % | 0.5 |
| 7 | S4 verify the JWT | 1.7 % | 0.5 |
| 8 | S3 route | 0.4 % | 0.1 |
| 9 | S5 validate the input | 0.1 % | 0.0 |
| 10 | S9 durability (no frame of its own) | 0.0 % | 0.0 |
