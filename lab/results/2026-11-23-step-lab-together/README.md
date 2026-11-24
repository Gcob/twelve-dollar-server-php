# The chosen variants together

The variants that survived the step lab, run together as one configuration, in the realistic mode and with the baseline's shape: a staircase
from 18,000 req/s at `s = 0.02`, 3 holds of 5 minutes at the highest passing rate, one profiled run. Docker Desktop on an M3 Pro (arm64), 1 CPU,
2 GiB, PHP 8.5, 60,000 idle connections. These are arm64 numbers, not a score. This file is written in two steps: the predictions and the plan of
the runs first (below, committed before any run), then the results and the verdicts.

## Predictions

All eighteen, copied unchanged from the phase's plan. This folder judges 12 (the others are judged by `2026-11-23-s1-fd-wall` (1 to 8),
`2026-11-23-cpu-steps` (9 to 11), `2026-11-23-swoole-entries` (14 to 17), and later ones).

Written by the project manager on 2026-11-22 at 20:55, before any phase 5 measurement, and revised at 21:12 after
the plan review, still before any measurement: prediction 5 counts the fd wall's users at `s = 0.04` (about 68,500,
not 69,000), prediction 8 holds 60,000 connections on one ring (a ring's table can't pass 65,535) with 80,000 on two as
a stretch, prediction 10 drops the prebuilt header prefix (the skeleton already has it). Arm64, Docker Desktop on an M3
Pro, quiet VM, PHP 8.5, the skeleton on the DIY loop, 1 CPU, unless a line says otherwise.

**What we start from:** the baseline: 27.15 µs/req at 24,000 req/s (`s = 0.02`, 60,000 idle, probes on); about 28.7
µs at 12,000 (the `s = 0.0286` staircase, probes on). The profile: S6 51.7 % (the feed's query 38.8 %), S8 20.2 %, S7
9.7 %, S2 8.0 %, the loop 6.5 %, the kernel 30.3 % of the CPU. DIY's `/noop` at 7,000 req/s: 21.88 µs.

**How they're judged:** a µs/req is the median of a variant's runs; a range holds if the measured value is inside it;
a difference is "beyond the noise" when every pair has the same sign and the median paired difference is at least the
A/A floor of its rate (D51).

1. **Syscalls per keep-alive request: 2 to 4 in total**, one read with data and one write per request, `epoll_wait`
   shared by several requests (under 0.5 per request at 2,000 req/s), no `epoll_ctl` per request; writes add 1 to 3
   (the WAL's `pwrite`, no `fsync` with `synchronous = NORMAL`). The kernel's 30 % is the TCP stack's work, not
   syscall entries.
2. **S1-a at 12,000 req/s, probes off: 25 to 30 µs/req.**
3. **One reconnect costs 8 to 20 µs of the server's CPU** (an accept, a close, the handshake and the teardown in the
   kernel, an event added and freed): S1-d with every request reconnecting at 12,000 req/s is 35 to 50 µs/req.
4. **S1-b with 2 processes costs 5 to 20 % more per request than S1-a** at 12,000 req/s (context switches between
   two loops on one CPU; each has its own SQLite connection), less than tzimpel's 27 %.
5. **The fd wall:** with 64,000 idle and k6's VUs on top (about 68,500 users at `s = 0.04`), the skeleton fails (k6
   connection errors or accepts paused) and S1-d passes with 0 errors, 0 accept pauses and the server's fds under
   65,535.
6. **At the bench's sizes, S1-d adds 2 to 8 µs per request at 100,000 users and 5 to 15 at 150,000**, so S1-d is
   chosen over S1-b.
7. **FFI micro:** an FFI call to `syscall(getpid)` costs 150 to 500 ns more than `posix_getpid()`; a `CData` field
   write 20 to 80 ns; `FFI::memcpy` and `FFI::string` of 200 B 50 to 200 ns, of 5 KB 150 to 600 ns; `pack()` of a 64-byte
   SQE 100 to 300 ns; the JIT changes none of them by more than 20 %. A PHP `fread` or `fwrite` of 200 B on a socket
   costs 1 to 3 µs. **The stop rule passes:** a request's FFI budget (about 1 µs) is under the two syscalls it removes.
8. **The ring's no-op server** holds 60,000 connections on one ring with its own fds under 100, passes the stress test
   with 0 mismatches, and costs 15 to 25 µs/req on `/noop` at 7,000 req/s (DIY: 21.88). The second ring (80,000
   connections) is not reached inside the time box.
9. **S6, the feed:** `two-step` is the fastest SQL, 10 to 30 % under the reference's ns per feed in the micro bench;
   `join` is slower than the reference (it groups the newest posts' likes before the limit applies, unless SQLite
   pushes the limit down); `FETCH_NUM` saves under 5 % of a feed; no pragma preset moves µs/req beyond the noise (the
   hot set fits the cache already). The chosen S6 saves 1 to 4 µs per request (4 to 15 %).
10. **S8:** `APP_IO=sockets` saves 0.5 to 2 µs per request, under the A/A floor, so it is judged on its syscall count
    and its micro cost, and the macro shows it costs nothing.
11. **S9:** group commit changes µs/req by 0 to −3 % (writes are 8 % of requests; batches of 1 to 3 at 24,000 req/s)
    and the p99 within the noise; the background checkpointer changes µs/req within the noise and lowers the
    per-second maximum of the longest callback, but not the stalled seconds (they are outside the server, Q10).
12. **Together:** the chosen variants cost 21 to 25 µs/req at 24,000 req/s (8 to 22 % under 27.15), the held rate at
    `s = 0.02` stays the harness's floor (about 23,400 req/s, D47), and S6 is still the largest step of the profile.
13. **x86 (if run):** a request costs 1.8 to 3 times more on the `c5.2xlarge`'s Xeon than on the M3.

Added on 2026-11-22 at 22:08 with scope 13 (D61), before any of its runs:

14. **The Swoole entries at 12,000 req/s with 60,000 idle on the Mac:** mattsplat 35 to 55 µs/req, tzimpel 40 to 60
    (his own Mac reading was 50 to 60 at fewer connections); both above the skeleton's S1-a.
15. **The Mac-to-bench factors** (94 and 101 over their Mac µs): 1.7 to 2.7 each, within 25 % of each other.
16. **Memory:** both hold the 60,000 idle within 2 GiB; mattsplat's `memory.current` is 2 to 4 times tzimpel's (its
    64 KiB receive buffer stays after each idle connection's first request; tzimpel's patch frees it).
17. **The skeleton on the bench** (its Mac µs at 12,000 times the mean factor): 45 to 75 µs per request, so scope 12
    should read 1.7 to 2.7 times the Mac on the Xeon.

Added on 2026-11-23 at 04:34 from scope 13's factors (3.22 and 3.08), before any x86 run; 13 and 17 stay as written:

18. **x86, from scope 13:** a request costs 2.9 to 3.4 times more on the Xeon than on the Mac, and the skeleton
    about 88 µs/req on the bench (86 to 90 with each factor alone).


## Plan of the runs

Every series starts with `docker ps` showing no container: the VM is quiet. No image build and no `lab/check.sh` during a series. A run that is
invalid is kept and shown, not counted. Every counted run says `other_containers: 0`.

1. **The combined screen.** Nothing was chosen on its own in the CPU steps' folder (no variant beat the floor of 2.57 µs/req at 24,000 req/s): `APP_PRAGMAS=cache-256m`
   was the nearest (-2.22 µs, 86 % of the floor), `APP_LOCKING=exclusive` the cheapest to defend (-0.85 µs, 2.39 syscalls fewer a request). They act on different costs (the
   page cache, the lock calls), so their sum may pass the floor that neither passes alone. One `lab/steplab.sh` pair: the skeleton as the reference, then
   `APP_PRAGMAS=cache-256m,APP_LOCKING=exclusive`, at 24,000 req/s, `s = 0.02`, 60 s plateau, 60,000 idle, warm-up 2,400 req/s for 60 s, telemetry off, floor 2.57.
   No other combination, no extra pair of a variant alone.
   - If the pair is lower than the reference by more than the floor, two more pairs (three in all), each round with its own reference, and the pair is confirmed when the
     median of the three paired differences still passes the floor with one sign.
   - Confirmed, the staircase runs the pair with S1-d. Otherwise it runs S1-d alone.
2. **The configuration.** The chosen switches plus S1-d: `APP_SOFT_CONN_LIMIT` set above the most connections the runs hold (60,000 idle plus k6's VUs at the top of
   the staircase, 5,400 at most: 65,400) and under the server's file descriptor limit (65,535), so it never fires: the realistic mode cannot show the bench's churn, and the
   price of a reconnect was measured on its own. The value is stated below and `close_responses` (the telemetry's count of limit closes) is checked to be 0 in each hold.
3. **The staircase,** as the baseline's: 60,000 idle, warm-up 2,000 req/s for 60 s, 60 s plateaus, from 18,000 req/s in steps of 1,000, split in runs of at most 7 steps (k6 keeps every
   sample and 12 million requests is the ceiling of a run), stopping at the first failing step, then a fine staircase in steps of 250 req/s from the last passing rate to the failing one.
   Telemetry and the per-second probes on, as in the baseline, so the µs/req compares with its 27.15.
4. **3 holds of 5 minutes** at the highest passing rate of the fine staircase, each a fresh run; the median of the three is the phase's µs/req. If a hold fails, the three move one fine step down.
5. **The profile:** one profiled 60 s run (Excimer, 1 ms, folded) at that rate, telemetry off like the baseline's profile; the fold's `--us-per-req` is the holds' median.
6. **The table:** each step S1 to S9, its variant, its µs per request in the profile before (the baseline's profile, and today's skeleton profile of the CPU steps' folder) and after; the
   users the held rate's µs maps to with the leaderboard's formula (about 8.0 million over the µs per request, on the Mac, not a score) and at the held rate (9.45 users per req/s), next
   to the µs S1-d adds at 100,000, 150,000 and 200,000 users (6.62 µs a reconnect, measured), so the users are not read without the reconnects' cost.
7. **Results and verdicts:** `summarize.sh` regenerates every table below from the JSON files next to it.

## What differed from the plan of the runs

- **The combined screen did not confirm.** The pair is -1.87 µs/req (26.66 for the skeleton, 24.78 for the combination) against a floor of 2.57, so it got no more pairs and the staircase ran S1-d alone: the "chosen
  variants together" of this phase are one variant, S1-d, set so that it never fires. The two switches alone were -2.22 (cache-256m) and -0.85 (exclusive): their sum, -3.07, is not what the pair measured.
- **The soft limit is 65,450** (`APP_SOFT_CONN_LIMIT=65450`). The most connections a run holds is the 60,000 idle plus k6's VUs: 4,157 VUs at 22,000 req/s (64,157 open in the holds), 4,346 at 23,000 (64,386 in the
  staircase), and 5,400 at the cap (`--vu-cap 5400`, the baseline's) would be 65,400. The server's file descriptors are 65,535 (`nofile`) of which 12 are its own at boot: 65,450 sits above the most a run
  can hold and under the descriptor limit, 73 below the 65,523 that are left for connections. Every counted run says `limit closes 0` (the server's count of `Connection: close` responses the limit caused), `accept pauses 0`
  and the most connections open, in the tables below; the descriptors' peak was 64,169 in the holds.
- **The staircase stopped at its first failing step, as the baseline's did:** the first run (18,000 to 24,000 in steps of 1,000) stopped at 23,000 (step 6 of 7), the fine staircase (22,000 to 23,000 in steps of 250)
  stopped at 22,250 (step 2 of 5). The baseline's fine staircase passed all of its steps. **The held rate is therefore 22,000 req/s**, not 24,000, and the 3 holds and the profile run there.
- **The holds and the profile have the per-second probes and the server's telemetry on, like the baseline's holds** (its 27.15 is a median of such holds), so the µs/req compares with 27.15; the profile run has the telemetry off,
  as the baseline's profile run had. The staircases and holds run with `lab/realistic.sh` directly (the step lab's runner is for A/B pairs); the screen runs with `lab/steplab.sh`.
- **A 60 s gap before every run but the first of the staircase.** The staircase's first run started at once after the screen's last run, so the idle client met the 32,768 TIME_WAIT sockets that run leaves: it
  moved to other addresses 8 times (200 retries, 9 source addresses) and the run is valid with 60,000 held and none closed. The screen's second run did the same (200 retries, 9 addresses). The fine staircase, the 3 holds and the
  profile run each started a minute after the one before: 0 retries and 6 addresses. The idle client's wall at 7,020 sockets on an address is left alone.
- **The first start of the screen failed twice, at no cost:** the script was not executable (run with `bash`), and `docker image inspect php-lab:8.5` said "No such image" for about a minute at 07:54 (a Docker blip, as the S1 series saw);
  it was fine at 07:55 and nothing had run.
- **The control ran last, after the rest, and its result is above:** the skeleton alone, one 2-step staircase (22,250 and 23,000 req/s, `s = 0.02`, 60,000 idle, `--vu-cap 5400`, lag gate 5.5 s, warm-up 2,000 req/s for 60 s, telemetry and probes on, no soft limit), run at 09:16, after the phase's other runs and the review of its first pass.
  Its first step failed, which ends a staircase, so 23,000 and the hold were not run.
- **The held rate was run again, interleaved, after the control, on a quiet VM** (20:03 end; `held-rate-interleaved/`): the skeleton, S1-d, the skeleton at one 24,000 req/s step each, because the control could not pass in its own state. A gate came first (the
  skeleton's step had to pass; it did, at 97.27 %). Neither this folder's staircase nor its three holds were rerun, and they ran without `APP_PRAGMAS=mmap-off`, chosen afterwards (`2026-11-23-cpu-steps`).
- **Nothing was invalid.** Every counted run: `valid: true`, `other_containers: 0`, 60,000 idle held at the end, none closed by the server. `docker ps` was empty before each run (07:51 to 08:42, 2026-11-23).
- **Scratch paths** (`<tmp>`) were scrubbed from the screen's run files, as in the earlier folders.

## Results

What follows is the output of `bash summarize.sh`, unedited: running it again must print the same text. The fold table in it runs `php-lab:8.5` in Docker; every other table is `jq` on the JSON files. The baseline's holds and profile,
today's skeleton's profile (the CPU steps' folder) and the reconnect's cost (the S1 series) are read from their own folders.

<!-- BEGIN summarize -->
### The combined screen: the skeleton against `APP_PRAGMAS=cache-256m` with `APP_LOCKING=exclusive` (24,000 req/s, `s = 0.02`, 60,000 idle, 60 s plateau, telemetry off, floor 2.57 µs/req)

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  result
    1  ref            yes      23296.4      26.7    13.04    29.58         0  pass
    1  cache-256m-exclusive yes      23329.5      24.8    12.29    30.03     10036  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)

variants (us is the server's CPU per request over the plateau)
variant         valid median us        min to max   p99 ms  paired differences us     median  verdict
ref               1/1      26.7      26.7 to 26.7    29.58  reference                      -  reference
cache-256m-exclusive    1/1      24.8      24.8 to 24.8    30.03  -1.9                        -1.9  screen: not better in one pair

Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 2.57 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

The pair is **-1.87 µs/req** (reference 26.66, combination 24.78), the floor is 2.57: screen: not better in one pair.

### The staircase (the combination is S1-d alone: no switch of the screen was confirmed), one run per file

**staircase-coarse-1**

Run `staircase/staircase-coarse-1.json`: think scale 0.02, VU cap 5400, warm-up 2000,60, 60 s plateaus, lag gate 5.5 s, server environment `APP_SOFT_CONN_LIMIT=65450 APP_TELEMETRY=1`; valid true, other containers 0, idle held 60000 at the start and 60000 at the end, aggregator max lag 4.84 s, k6 connection errors 0, limit closes 0, accept pauses 0, most connections open 64386.

| Step | VUs | offered req/s | achieved req/s | users | µs CPU/req | p95 ms | p99 ms | errors | k6 CPU % of one | result |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 3401 | 18000.4 | 17798.2 | 168193 | 27.7 | 4.6 | 11.41 | 0 % | 242.05 | pass |
| 2 | 3590 | 19000.7 | 18758.7 | 177269 | 27.4 | 5.84 | 15.37 | 0 % | 250.93 | pass |
| 3 | 3779 | 20001 | 19683.5 | 186009 | 27.7 | 7.52 | 18.1 | 0 % | 263.49 | pass |
| 4 | 3968 | 21001.4 | 20623.7 | 194894 | 27.6 | 8.86 | 21.32 | 0 % | 274.19 | pass |
| 5 | 4157 | 22001.7 | 21433.8 | 202550 | 27.8 | 12.47 | 35.37 | 0 % | 288.81 | pass |
| 6 | 4346 | 23002 | 22173.2 | 209537 | 28.5 | 19.79 | 76.71 | 0 % | 314.64 | FAIL: achieved below 97 % of offered |

Stopped at step 6: achieved below 97 % of offered.

**staircase-fine**

Run `staircase/staircase-fine.json`: think scale 0.02, VU cap 5400, warm-up 2000,60, 60 s plateaus, lag gate 5.5 s, server environment `APP_SOFT_CONN_LIMIT=65450 APP_TELEMETRY=1`; valid true, other containers 0, idle held 60000 at the start and 60000 at the end, aggregator max lag 2.755 s, k6 connection errors 0, limit closes 0, accept pauses 0, most connections open 64218.

| Step | VUs | offered req/s | achieved req/s | users | µs CPU/req | p95 ms | p99 ms | errors | k6 CPU % of one | result |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 4157 | 22001.7 | 21499.9 | 203174 | 27.7 | 9.4 | 22.97 | 0 % | 298.54 | pass |
| 2 | 4204 | 22250.4 | 21496 | 203137 | 28 | 15.37 | 42.92 | 0 % | 302.62 | FAIL: achieved below 97 % of offered |

Stopped at step 2: achieved below 97 % of offered.

### The holds (5 minutes each, a fresh run each), beside the baseline's three

| Run | valid | other containers | offered req/s | achieved req/s | users at 9.45 per req/s | µs CPU/req | p95 ms | p99 ms | errors | idle held (start / end) | limit closes | accept pauses | most connections open | fds peak | aggregator max lag s | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| hold-1 | true | 0 | 22001.7 | 21477.3 | 202961 | 27.65 | 10.13 | 26.65 | 0 % | 60000 / 60000 | 0 | 0 | 64157 | 64169 | 4.083 | pass |
| hold-2 | true | 0 | 22001.7 | 21506.8 | 203239 | 27.58 | 10.28 | 26.26 | 0 % | 60000 / 60000 | 0 | 0 | 64157 | 64169 | 5.332 | pass |
| hold-3 | true | 0 | 22001.7 | 21608.2 | 204197 | 27.08 | 8.1 | 20.69 | 0 % | 60000 / 60000 | 0 | 0 | 64157 | 64169 | 5.726 | pass |
| **median of the 3 counted holds** | | | 22001.7 | **21506.8** | **203239** | **27.58** | **10.13** | **26.26** | 0 % (max) | | | | | | |
| baseline: median of its 3 holds (the skeleton before the CPU steps, telemetry on) | | | 24002.3 | 23386.4 | 221002 | 27.15 | 11.93 | 28.29 | | | | | | | | |

The median of the 3 holds is **27.58 µs/req**, +0.43 µs from the baseline's 27.15 (+1.6 %). The holds run, in µs/req: 27.65, 27.58, 27.08 (the baseline's: 27.71, 27.15, 27.06).

### The control: the skeleton alone, with none of S1-d's accounting (no `APP_SOFT_CONN_LIMIT`), the same flags as the staircase above

Run `control/staircase.json`: think scale 0.02, VU cap 5400, warm-up 2000,60, 60 s plateaus, lag gate 5.5 s, server environment `APP_TELEMETRY=1`; valid true, other containers 0, idle held 60000 at the start and 60000 at the end, aggregator max lag 3.034 s, k6 connection errors 0, limit closes 0, accept pauses 0, most connections open 64239.

| Step | VUs | offered req/s | achieved req/s | users | µs CPU/req | p95 ms | p99 ms | errors | k6 CPU % of one | result |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 4204 | 22250.4 | 19713.3 | 186290 | 35.2 | 91.72 | 297.35 | 0 % | 370.26 | FAIL: achieved below 97 % of offered |

Stopped at step 1: achieved below 97 % of offered.

### The held rate, interleaved: one 24,000 req/s step each, the skeleton, S1-d (`APP_SOFT_CONN_LIMIT=65450`), the skeleton again, in that order, a minute apart

**skeleton-1**

Run `held-rate-interleaved/skeleton-1.json`: think scale 0.02, VU cap 5400, warm-up 2000,60, 60 s plateaus, lag gate 5.5 s, server environment `APP_TELEMETRY=1`; valid true, other containers 0, idle held 60000 at the start and 60000 at the end, aggregator max lag 4.204 s, k6 connection errors 0, limit closes 0, accept pauses 0, most connections open 64535.

| Step | VUs | offered req/s | achieved req/s | users | µs CPU/req | p95 ms | p99 ms | errors | k6 CPU % of one | result |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 4535 | 24002.3 | 23347 | 220629 | 26.3 | 11.41 | 25.49 | 0 % | 314.86 | pass |

No step failed.

**s1d-1**

Run `held-rate-interleaved/s1d-1.json`: think scale 0.02, VU cap 5400, warm-up 2000,60, 60 s plateaus, lag gate 5.5 s, server environment `APP_SOFT_CONN_LIMIT=65450 APP_TELEMETRY=1`; valid true, other containers 0, idle held 60000 at the start and 60000 at the end, aggregator max lag 3.211 s, k6 connection errors 0, limit closes 0, accept pauses 0, most connections open 64535.

| Step | VUs | offered req/s | achieved req/s | users | µs CPU/req | p95 ms | p99 ms | errors | k6 CPU % of one | result |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 4535 | 24002.3 | 23352.1 | 220678 | 26 | 11.07 | 25.11 | 0 % | 313.69 | pass |

No step failed.

**skeleton-2**

Run `held-rate-interleaved/skeleton-2.json`: think scale 0.02, VU cap 5400, warm-up 2000,60, 60 s plateaus, lag gate 5.5 s, server environment `APP_TELEMETRY=1`; valid true, other containers 0, idle held 60000 at the start and 60000 at the end, aggregator max lag 3.628 s, k6 connection errors 0, limit closes 0, accept pauses 0, most connections open 64535.

| Step | VUs | offered req/s | achieved req/s | users | µs CPU/req | p95 ms | p99 ms | errors | k6 CPU % of one | result |
|---|---|---|---|---|---|---|---|---|---|---|
| 1 | 4535 | 24002.3 | 23354.9 | 220704 | 26.6 | 11.75 | 24.74 | 0 % | 312.99 | pass |

No step failed.

| Order | run | achieved / offered | µs CPU/req | p99 ms |
|---|---|---|---|---|
| 1 | skeleton-1 | 97.27 % | 26.28 | 25.49 |
| 2 | s1d-1 | 97.29 % | 26.02 | 25.11 |
| 3 | skeleton-2 | 97.3 % | 26.58 | 24.74 |

### The profile (Excimer, 1 ms CPU time, one run: the held rate, `s = 0.02`, 60,000 idle, telemetry off), beside the baseline's and today's skeleton's

The profiled run is valid true, other containers 0, limit closes n/a (telemetry off), idle held 60000 / 60000. Profiled window (the server's whole life after its first answer: warm-up, ramps and plateau): 53899 samples at 1 ms, the cgroup's user CPU 37505 ms and system CPU 16680 ms (**31 % in the kernel**), the samples cover 100 % of that CPU, unclassified 0 %.

Each cell is a share of all the samples of its profile and the microseconds it is on the average request of that profile (the fold's `--us-per-req`: the baseline's 27.59 (its unprofiled runs' mean), the skeleton's 26.71 (the CPU steps' three references' median), and this run's 27.58 (the median of the 3 holds, telemetry on)). The kernel's share is the cgroup's system CPU.

| Step | variant in this configuration | baseline: share, µs | skeleton today: share, µs | together: share, µs | together minus baseline, µs |
|---|---|---|---|---|---|
| S1 accept connections | S1-d, `APP_SOFT_CONN_LIMIT=65450`: it never fires here (a reconnect costs 6.62 µs, priced below) | 1.7 %, 0.5 µs | 2.0 %, 0.5 µs | 1.6 %, 0.4 µs | -0.03 |
| S2 read and parse | unchanged | 8.0 %, 2.2 µs | 8.1 %, 2.2 µs | 8.2 %, 2.3 µs | +0.05 |
| S3 route | unchanged | 0.4 %, 0.1 µs | 0.6 %, 0.2 µs | 0.5 %, 0.1 µs | +0.03 |
| S4 verify the JWT | unchanged | 1.7 %, 0.5 µs | 1.6 %, 0.4 µs | 1.6 %, 0.4 µs | -0.03 |
| S5 validate the input | unchanged | 0.1 %, 0 µs | 0.2 %, 0.1 µs | 0.2 %, 0.1 µs | +0.03 |
| S6 query SQLite | the skeleton's query and pragmas (no S6 variant beat the floor, alone or together) | 51.7 %, 14.3 µs | 51.2 %, 13.7 µs | 50.6 %, 14 µs | -0.31 |
| S7 build the JSON | unchanged | 9.7 %, 2.7 µs | 9.4 %, 2.5 µs | 10.0 %, 2.8 µs | +0.08 |
| S8 write the response | the skeleton's locking (`exclusive` did not beat the floor, alone or in the screen) | 20.2 %, 5.6 µs | 20.6 %, 5.5 µs | 20.9 %, 5.8 µs | +0.19 |
| S9 durability | the skeleton's write per request (group commit did not beat the floor; the checkpointer failed its bound) | 0.0 %, 0 µs | 0.0 %, 0 µs | 0.0 %, 0 µs | 0 |
| event loop | unchanged | 6.5 %, 1.8 µs | 6.3 %, 1.7 µs | 6.5 %, 1.8 µs | 0 |
| unclassified | unchanged | 0.0 %, 0 µs | 0.0 %, 0 µs | 0.0 %, 0 µs | 0 |

The fold of `profile/profile.collapsed` with `--us-per-req` set to the holds' median:

```text
step                   GET /health     GET /feed  GET /posts/:id  POST /posts  POST /posts/:id/like        shared            all
S1 accept connections   0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    1.6% 0.5us     1.6% 0.5us
S2 read and parse       0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    8.2% 2.2us     8.2% 2.2us
S3 route                0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    0.5% 0.1us     0.5% 0.1us
S4 verify the JWT       0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.3% 0.1us            1.3% 0.4us    0.0% 0.0us     1.6% 0.4us
S5 validate the input   0.0% 0.0us    0.0% 0.0us      0.1% 0.0us   0.1% 0.0us            0.0% 0.0us    0.0% 0.0us     0.2% 0.0us
S6 query SQLite         0.2% 0.0us  38.0% 10.5us      5.7% 1.6us   0.9% 0.3us            5.9% 1.6us    0.0% 0.0us   50.6% 14.0us
S7 build the JSON       0.0% 0.0us    9.0% 2.5us      0.7% 0.2us   0.1% 0.0us            0.1% 0.0us    0.0% 0.0us    10.0% 2.8us
S8 write the response   0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us   20.9% 5.8us    20.9% 5.8us
S9 durability           0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    0.0% 0.0us     0.0% 0.0us
event loop              0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    6.5% 1.8us     6.5% 1.8us
unclassified            0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    0.0% 0.0us     0.0% 0.0us
all                     0.2% 0.1us  47.0% 13.0us      6.5% 1.8us   1.3% 0.4us            7.3% 2.0us  37.7% 10.4us  100.0% 27.6us
samples: 53899, 27.6 us per request on average
each cell: share of all samples and the microseconds it adds to the average request; S9 is inside S6 (autocommit)

within each endpoint (share of that column's own samples):
step                   GET /health  GET /feed  GET /posts/:id  POST /posts  POST /posts/:id/like  shared
S1 accept connections         0.0%       0.0%            0.0%         0.0%                  0.0%    4.3%
S2 read and parse             0.0%       0.0%            0.0%         0.0%                  0.0%   21.6%
S3 route                      0.0%       0.0%            0.0%         3.4%                  0.0%    1.3%
S4 verify the JWT             0.0%       0.0%            0.0%        18.7%                 17.8%    0.0%
S5 validate the input         0.0%       0.0%            0.9%         4.0%                  0.7%    0.0%
S6 query SQLite              84.2%      80.8%           87.8%        69.0%                 80.1%    0.0%
S7 build the JSON            15.8%      19.2%           11.3%         4.4%                  1.4%    0.0%
S8 write the response         0.0%       0.0%            0.0%         0.4%                  0.0%   55.5%
S9 durability                 0.0%       0.0%            0.0%         0.0%                  0.0%    0.0%
event loop                    0.0%       0.0%            0.0%         0.0%                  0.0%   17.3%
unclassified                  0.0%       0.0%            0.0%         0.0%                  0.0%    0.0%
weight in all samples         0.2%      47.0%            6.5%         1.3%                  7.3%   37.7%
```

### Users: what the held µs maps to, next to what S1-d adds at the bench's sizes

Users from the leaderboard's formula (about 8.0 million over the µs per request, arm64 Mac, not a score) are the CPU's capacity if the load had no harness floor; users at the held rate (9.45 per req/s) are what the harness offered at `s = 0.02`. S1-d adds a reconnect (6.62 µs, the S1 series) to the share of requests that open a new connection: `1 - 64000 / N` at N users (the first 64000 keep theirs), so its cost per request is `6.62 * (1 - 64000 / N)`.

| Configuration | µs/req | users (leaderboard formula) | users at the held rate |
|---|---|---|---|
| baseline (phase 4, 3 holds, S1-a) | 27.15 | 294659 | 221002 |
| **together, S1-d never firing (median of 3 holds)** | **27.58** | **290025** | **203239** |
| together + S1-d at 100000 users (+2.38 µs) | 29.97 | 266960 | |
| together + S1-d at 150000 users (+3.8 µs) | 31.38 | 254945 | |
| together + S1-d at 200000 users (+4.5 µs) | 32.09 | 249334 | |
<!-- END summarize -->

## The reading

- **The combination of the two cheap switches is not better than the floor.** cache-256m with exclusive is -1.87 µs in one pair, 73 % of the floor, less than the -3.07 their separate pairs summed to (-2.22 and -0.85):
  the screens of the CPU steps' folder were one pair each, so the three numbers are each inside what two identical runs give (the references of the CPU steps' folder spread by 0.7 µs). Nothing is chosen for S6 or S8,
  and group commit and the checkpointer were already out.
- **The phase's configuration is S1-d, and S1-d never fires in this mode.** It costs nothing the profile can see: S1 is 1.6 % of the samples (0.4 µs) against 1.7 % in the baseline (0.5 µs), and each of the other steps
  is within 0.3 µs of its baseline share except S6 (-0.3), S8 (+0.2). Its price is the reconnects of a run that goes past the limit, which the realistic mode cannot show: 6.62 µs a reconnect, 2.38 µs a request at 100,000
  users, 3.8 at 150,000 and 4.5 at 200,000 (the users table).
- **The Mac's µs/req is where the baseline left it:** 27.58 (27.65, 27.58, 27.08) against 27.15 (27.71, 27.15, 27.06), +0.43 µs, +1.6 %. The two sets of holds overlap (27.06 to 27.71 and 27.08 to 27.65) and the difference is a sixth of
  the floor: no change that this method can see. The skeleton of the CPU steps' folder cost 26.71 with the telemetry off and no probes, which is another condition.
- **The held rate is lower: 22,000 req/s, against 24,000.** The CPU per request is the same, but the 97 % rule failed at 23,000 (22,173 achieved, 96.4 %, p99 76.7 ms against 33.3 for the baseline at the same rate) and at 22,250
  (96.6 %), and passed at 22,000 (97.7 %, 98.2 % in the third hold). The baseline passed 23,000 at 97.5 % and 24,000 in 13 of 17 runs. Three readings that this folder cannot tell apart: the rule's line is noisy (the baseline's
  24,000 failed 4 of 17 times, so one failing step is a run of luck); S1-d's accounting on every request and every connection costs latency the CPU per request does not show; the Mac was busier today (impression: the host's load was not recorded, and the harness's own k6 takes 3
  of the VM's CPUs). The control that was meant to separate the first two (below) failed too, so it did not.
- **The control: the skeleton alone failed at 22,250 as well, and worse.** The run (the skeleton with no `APP_SOFT_CONN_LIMIT`, the same flags, 22,250 then 23,000, 2026-11-23 09:16 to 09:19, `other_containers: 0`,
  60,000 idle held, 0 closed) stopped at its first step: **19,713 req/s achieved of 22,250 (88.6 %), p99 297 ms, 35.2 µs/req**, against S1-d's 22,250 at 96.6 % (p99 42.9 ms) in the fine staircase. So no hold was run and 23,000 was not reached. The
  CPU per request is 27 % above the 27.4 to 28.5 of every S1-d step of the day, which a per-request accounting cost cannot explain in a run that has none of it: the server did the same work for more CPU, the sign of a slower host or VM
  (a neighbour on the Mac or in the VM's CPUs), not of the skeleton. The next run, the reference of an `APP_PRAGMAS=mmap-off` pair at 24,000 req/s started at 09:20 (kept in `cpu-steps/s6-mmap-off/pair-2-not-counted/`, not counted), came out the same: 35.2 µs/req,
  87.4 % of the 24,002 offered, p99 293 ms. **The reading: the skeleton does not hold 22,250 either under that state, so the 8 % drop of the held rate is not shown to be S1-d's. It is not shown to be the day's either:** the control cannot pass in the state it ran in, so it
  says nothing about the state of 08:00 to 08:40, when S1-d failed at 23,000 and 22,250 at normal CPU per request (28.5 and 28.0). For phase 5b: S1-d's per-request path (one comparison, one counter at each accept) is 0.4 µs in the profile, and the question of whether
  it moves the knee needs the skeleton and S1-d run interleaved, on a day when the skeleton passes 24,000, before S1-d is blamed or cleared. The host's load was not recorded for the S1-d staircase; during the control the Mac's load average was 12 to 14 (the run's own k6 and VM included).
- **The held rate, interleaved, on a quiet VM (2026-11-23, 19:53 to 20:03, `docker ps` empty before each run, `other_containers: 0`): the gate passed, and S1-d is not what lowered the knee.** One step each at 24,000 req/s with this
  folder's flags (`--vu-cap 5400 --lag-gate 5.5 --warmup 2000,60`, telemetry and probes on, 60 s plateau, a minute apart): the skeleton 23,347 achieved (97.27 %), 26.3 µs/req, p99 25.49 ms; S1-d
  (`APP_SOFT_CONN_LIMIT=65450`) 23,352 (97.29 %), 26.0 µs/req, p99 25.11; the skeleton again 23,355 (97.31 %), 26.6, p99 24.74. All three pass the 97 % rule at 24,000 req/s, the rate this folder's S1-d staircase failed at
  23,000 (96.4 %) and 22,250 (96.6 %): so on this day S1-d holds 24,000 as the skeleton does. That points to the state of that morning (the Mac's host, as the control said it could be) for the staircase's 22,000 req/s, not to S1-d's accounting.
  What it does not say: it is one step each, not a staircase, the three runs pass by 0.3 point (a line the baseline's own 24,000 steps failed 4 times in 17), and µs/req (26.0 to 26.6) is lower than the staircase's 27.4 to 28.5 because the
  host is in another state (the runs that morning, with the same code, read 27.6). The three runs separate nothing of S1-d from the skeleton beyond their own spread.
- **Not above the harness floor:** the held rate is a floor of the harness at `s = 0.02` (the server is 59 % busy at 22,000 req/s), so the result is the µs/req, which did not move. The mapped users at the held rate fell with the rate
  (203,239 against 221,002); by the leaderboard's formula on the µs they are 290,025 against 294,659.
- **The profile has not moved:** S6 50.6 % of the samples (51.7 % in the baseline), S8 20.9 % (20.2), S7 10.0 % (9.7), S2 8.2 % (8.0), the loop 6.5 % (6.5), 31 % of the CPU in the kernel (30). The feed's query alone is 38.0 % (38.8).
  S6 is still the largest step by far.

## Did the predictions hold?

12. **Mostly missed.** "The chosen variants cost 21 to 25 µs/req (8 to 22 % under 27.15)": 27.58, +1.6 % over the baseline, outside the range, because no CPU variant was chosen (none of S6's, S8's or S9's variants beat the floor, alone or
    in the combined screen). "The held rate at `s = 0.02` stays the harness's floor (about 23,400 req/s)": it fell to 21,507 achieved (22,000 offered), 8 % under, and the staircase failed at 23,000 and 22,250 where the baseline passed.
    "S6 is still the largest step of the profile": held, 50.6 % of the samples and 14.0 µs of a request.

## The choice

| Step | Chosen | Why |
|---|---|---|
| S1 | S1-d, `APP_SOFT_CONN_LIMIT` just under the file descriptor limit | past the limit it costs 6.62 µs a reconnect (2.4 µs a request at 100,000 users, 4.5 at 200,000); in this mode it never fires and its limit closes are 0 |
| S6 | the skeleton's query and pragmas | cache-256m -2.22 µs alone, -1.87 µs with `exclusive`: under the floor both times. `mmap-off` was chosen afterwards, from its own three pairs (`2026-11-23-cpu-steps`); this folder's staircase and holds ran without it and were not rerun |
| S8 | the skeleton's locking | `exclusive` -0.85 µs alone: under the floor |
| S9 | the skeleton's write per request | group commit +1.18 µs; the checkpointer failed its bound |

The phase's Mac µs/req is **27.58** (median of 3 holds of 5 minutes at 22,000 req/s, S1-d set above the run's connections), against the baseline's 27.15: +0.43 µs, inside the baseline's own spread, so the five steps of the step
lab did not change what a request costs on the Mac; what they changed is what happens past 65,500 connections (S1-d serves 68,535 users in the S1 series where the skeleton fails) and what is known about each step: S6's pragmas
are worth 1 to 2 µs and not provably more, `exclusive` 0.85 µs, group commit nothing, and the checkpointer cannot bound the WAL. The 27.15 and the 27.58 are both a floor of the harness at `s = 0.02`, not a capacity.
