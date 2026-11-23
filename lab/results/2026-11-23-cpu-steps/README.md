# The CPU steps' variants (S6, S8, S9), measured

What each surviving variant of the feed query's pragmas (S6), the lock calls (S8) and the group commit (S9) costs per request in the
realistic mode, against the skeleton as it is today, and which one each step keeps. Docker Desktop on an M3 Pro (arm64), 1 CPU,
2 GiB, PHP 8.5. These are arm64 numbers, not a score. This file is written in two steps: the predictions and the plan of the runs
first (below, committed before any run of the series), then the results and the verdicts.

## Predictions (D5)

All eighteen, copied unchanged from the phase's plan. This folder judges 9, 10 and 11; the others are judged by the folders
`2026-11-23-s1-fd-wall` (1 to 8) and `2026-11-23-swoole-entries` (14 to 17), and later ones.

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

Every series starts with `docker ps` showing no container: the VM is quiet. No image build and no `lab/check.sh` during a series.

1. **The reference is today's skeleton** (commit `b01c3bb`: the skeleton now has one more method call per request, `respond()`, and
   one `instanceof Closure` test). It is on both sides of every pair, so the comparison is clean; its µs/req is compared with the
   baseline's 27.15 in one line below.
2. **The method (D51, D60):** `lab/steplab.sh` at 24,000 req/s, `s = 0.02`, 60,000 idle connections, a 60 s plateau, the baseline's warm-up
   (2,400 req/s for 60 s), telemetry off (on, on both sides, for S9), the reference first in each round. The floor is **2.57 µs/req**,
   the 24,000 req/s A/A of the S1 series (`2026-11-23-s1-fd-wall/aa-24000`). **One screening pair per variant, each with its own reference
   run**; only a variant that is lower than the reference by at least the floor gets two more pairs (three in all; five for S9).
3. **S6 (the micro bench of the S6 variants decided most of it):** no pair for `join`, `two-step`, `num` or the fetch loops. In the
   micro bench `join` (4 to 5 times slower) and `two-step` (50 to 60 % slower), in every fetch mode, and `num-loop` (+10.9 %) are
   more than 10 % above the reference; `num` (+9.5 %) is just under and `assoc-loop` (+1.3 %) is inside the spread, and neither has
   a reason to gain at the macro. Two screening pairs: `APP_PRAGMAS=mmap-off` and `APP_PRAGMAS=cache-256m` (-3.2 % and -3.0 % in the
   micro, at the edge of their spread). `cache-8m` (+0.5 %) gets none.
4. **S8:** one screening pair, `APP_LOCKING=exclusive` (5.58 to 3.20 syscalls per request). It rules out the checkpointer in a second
   process and the `mxFrame` sampler; both are said in the choice. `APP_IO` was not built (the syscall count left nothing to remove).
5. **S9:** one screening pair, `APP_GROUP_COMMIT=1`, telemetry on for both sides, judged on its p99 first (D49); its batch sizes are
   reported. **No run for `APP_CHECKPOINTER`:** it failed its bound in its own smoke (the WAL never restarted); that finding is reported
   as a result.
6. **The profile:** one profiled 60 s run (`--profile`, Excimer, folded) of each chosen variant, and of the skeleton, since the
   baseline's profile is older than the code it profiles.
7. **Results and verdicts:** `summarize.sh` regenerates every table below from the JSON files next to it. A run that is not valid is
   kept and shown, not counted.

## What differed from the plan of the runs

- **Step 0 came first and fitted its 30 minutes** (commit `fix(lab): the idle client retries a busy port`): the idle client (`lab/conns/client.php`)
  now binds again on a `Cannot assign requested address` (and, after 25 failures of one connection in a row, moves to another address); the
  step lab's `--idle-time-wait-max` defaults to 100,000 (never wait). The proof is the "Step 0" table of the results below: three real-shape runs
  back to back, no wait, all valid with 60,000 held and 0 closed. See "What the retry found".
- **One pair per variant, each with its own reference run**, not one reference run shared by all the variants of a round: a pair's noise is its own
  two runs'. All four screens ran with the reference first and the variant second, in one `steplab.sh` call each, with the floor of 2.57 µs/req.
- **No variant beat the floor, so none got more pairs and none was profiled**; the profile is the skeleton's (the baseline's is older than the
  code: `respond()` is new). S9's pair has both sides with telemetry on (the reference's µs/req is its own, 26.49).
- **`lab/realistic.sh` got two fields in this scope**, so that S9's batches are in its JSON: `server_connections.telemetry.group_commit` (commits, mean and
  largest batch, summed over the server's life) and `longest_callback_ms_max`. The file was replaced between two pairs of the series, atomically; they read telemetry
  only when it is on, so the pairs with telemetry off were not affected. (The mmap-off pair ran before the edit, the other three after it.)
- **`APP_CHECKPOINTER` was not run** (it failed its own bound, below). **`APP_IO` was not built**, so S8 has the one variant, `APP_LOCKING=exclusive`.
- **The first reference run of the series (mmap-off's) started with 200 TIME_WAIT sockets on one of k6's addresses**, left by the lab's own check a minute earlier: far
  under the limit of 2,500, in the JSON (`tw/addr`).
- **Two more `mmap-off` pairs were asked for after the first review, and neither was counted.** They ran from 09:20 on 2026-11-23, with `lab/steplab.sh --first-round 2` (a flag added for it: the rounds number on from the
  folder's last). Round 2's reference ran at 09:20 on a VM with no other container and failed the 97 % rule at 35.2 µs/req (87.4 % of offered, p99 293 ms: the same state as the held rate's control in
  `2026-11-23-step-lab-together`, which also read 35.2 µs/req); its `mmap-off` run started when the Docker VM filled with other containers (19 of them in the run's JSON) and read 58.6 µs/req at 15,092 req/s. The pair is not counted: both runs are kept in
  `s6-mmap-off/pair-2-not-counted/` with the runner's log, and the run in flight when round 3 started was stopped before it left a file. So `mmap-off` has its one counted pair (-1.31 µs), and the two more that the review asked for wait for a quiet VM.
- **Every run counted below:** `valid: true`, `other_containers: 0`, 60,000 idle held and none closed by the server.
- **Scratch paths** (`<tmp>`) were scrubbed from the runs' `command` fields and tables, as in the earlier folders; the syscall counts carry no `other_containers`
  field (`docker ps` was empty before each).

## Results

<!-- BEGIN summarize -->
### The floor and the reference

The A/A floor at 24,000 req/s (the S1 series, `2026-11-23-s1-fd-wall/aa-24000`): **2.57 µs/req**, the largest absolute paired difference of its 5 pairs; the median of its 10 runs is 26.11 µs/req.

Today's skeleton, the reference of every pair: telemetry off (S6 and S8) 26.37, 27.06, 26.71 µs/req, median **26.71**; telemetry on (S9) 26.49 µs/req. The baseline's was 27.15 (phase 4, probes on), before the `respond()` split and the `instanceof Closure` test of a request.

### Every run of the series

| Series | Run | valid | other containers | idle held at the end | closed by the server | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|
| s6-mmap-off | ref-1 | true | 0 | 60000 | 0 | 97.8 % | 26.37 | 8.99 | 21.64 | pass |
| s6-mmap-off | mmap-off-1 | true | 0 | 60000 | 0 | 97.7 % | 25.06 | 9.54 | 24.02 | pass |
| s6-cache-256m | ref-1 | true | 0 | 60000 | 0 | 97.4 % | 27.06 | 10.75 | 26.65 | pass |
| s6-cache-256m | cache-256m-1 | true | 0 | 60000 | 0 | 97.7 % | 24.83 | 8.35 | 22.29 | pass |
| s8-exclusive | ref-1 | true | 0 | 60000 | 0 | 97.4 % | 26.71 | 11.41 | 27.46 | pass |
| s8-exclusive | exclusive-1 | true | 0 | 60000 | 0 | 97.8 % | 25.86 | 9.12 | 19.79 | pass |
| s9-group-commit | ref-1 | true | 0 | 60000 | 0 | 97.7 % | 26.49 | 8.73 | 19.5 | pass |
| s9-group-commit | group-commit-1 | true | 0 | 60000 | 0 | 97.7 % | 27.68 | 9.83 | 25.11 | pass |

### The step lab's tables, one series at a time (the reference first in each pair; the floor is 2.57 µs/req)

**s6-mmap-off**

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  result
    1  ref            yes      23474.6      26.4     8.99    21.64       200  pass
    1  mmap-off       yes      23446.6      25.1     9.54    24.02     10036  pass
tw/addr: the most TIME_WAIT sockets on one of k6's source addresses when the run started (0 when the runner did not count)

variants (us is the server's CPU per request over the plateau)
variant         valid median us        min to max   p99 ms  paired differences us     median  verdict
ref               1/1      26.4      26.4 to 26.4    21.64  reference                      -  reference
mmap-off          1/1      25.1      25.1 to 25.1    24.02  -1.3                        -1.3  screen: not better in one pair

Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 2.57 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

**s6-cache-256m**

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  result
    1  ref            yes      23386.9      27.1    10.75    26.65      7063  pass
    1  cache-256m     yes      23452.9      24.8     8.35    22.29      7143  pass
tw/addr: the most TIME_WAIT sockets on one of k6's source addresses when the run started (0 when the runner did not count)

variants (us is the server's CPU per request over the plateau)
variant         valid median us        min to max   p99 ms  paired differences us     median  verdict
ref               1/1      27.1      27.1 to 27.1    26.65  reference                      -  reference
cache-256m        1/1      24.8      24.8 to 24.8    22.29  -2.2                        -2.2  screen: not better in one pair

Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 2.57 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

**s8-exclusive**

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  result
    1  ref            yes      23373.3      26.7    11.41    27.46      7187  pass
    1  exclusive      yes      23485.3      25.9     9.12    19.79      7153  pass
tw/addr: the most TIME_WAIT sockets on one of k6's source addresses when the run started (0 when the runner did not count)

variants (us is the server's CPU per request over the plateau)
variant         valid median us        min to max   p99 ms  paired differences us     median  verdict
ref               1/1      26.7      26.7 to 26.7    27.46  reference                      -  reference
exclusive         1/1      25.9      25.9 to 25.9    19.79  -0.8                        -0.8  screen: not better in one pair

Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 2.57 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

**s9-group-commit**

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  result
    1  ref            yes      23459.3      26.5     8.73     19.5      7163  pass
    1  group-commit   yes      23438.6      27.7     9.83    25.11      7132  pass
tw/addr: the most TIME_WAIT sockets on one of k6's source addresses when the run started (0 when the runner did not count)

variants (us is the server's CPU per request over the plateau)
variant         valid median us        min to max   p99 ms  paired differences us     median  verdict
ref               1/1      26.5      26.5 to 26.5     19.5  reference                      -  reference
group-commit      1/1      27.7      27.7 to 27.7    25.11  +1.2                        +1.2  screen: not better in one pair

Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 2.57 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### Each variant against the reference

| Series | Variant | pairs | reference µs/req | variant µs/req | paired difference µs | floor µs | reference p99 ms | variant p99 ms | verdict |
|---|---|---|---|---|---|---|---|---|---|
| s6-mmap-off | mmap-off | 1 | 26.37 | 25.06 | -1.31 | 2.57 | 21.64 | 24.02 | screen: not better in one pair |
| s6-cache-256m | cache-256m | 1 | 27.06 | 24.83 | -2.22 | 2.57 | 26.65 | 22.29 | screen: not better in one pair |
| s8-exclusive | exclusive | 1 | 26.71 | 25.86 | -0.85 | 2.57 | 27.46 | 19.79 | screen: not better in one pair |
| s9-group-commit | group-commit | 1 | 26.49 | 27.68 | +1.18 | 2.57 | 19.5 | 25.11 | screen: not better in one pair |

### `APP_PRAGMAS=mmap-off`, its 1 counted pair(s), against both readings of the floor

The floor of the five A/A pairs is **2.57 µs/req**, but its largest pair is the one whose run failed the 97 % rule; the floor of the 4 A/A pairs whose runs both passed it is **0.27 µs/req**. Each pair is the variant's µs/req minus the reference's of the same round (the reference runs first).

| Pair (round) | reference µs/req | mmap-off µs/req | paired difference µs | reference p99 ms | mmap-off p99 ms |
|---|---|---|---|---|---|
| 1 | 26.37 | 25.06 | -1.31 | 21.64 | 24.02 |

| Reading of the floor | floor µs/req | median paired difference µs | pairs with the same sign | verdict of the rule |
|---|---|---|---|---|
| the 5 A/A pairs | 2.57 | -1.31 | true | screen: not better in one pair |
| the 4 A/A pairs that passed the 97 % rule | 0.27 | -1.31 | true | screen: beats the floor |

### S9: group commit, judged on its latency first (telemetry on for both sides)

| Run | µs CPU/req | p99 ms | median per-second p99 ms | largest per-second max ms | stalled seconds of the plateau (max latency above 100 ms) | longest callback ms (the most of any second) | commits | mean batch | largest batch |
|---|---|---|---|---|---|---|---|---|---|
| ref-1 | 26.49 | 19.5 | 15.48 | 130.4 | 2 of 58 | 16.05 | - | - | - |
| group-commit-1 | 27.68 | 25.11 | 18.24 | 146.4 | 3 of 58 | 28.47 | 91495 | 1.45 | 79 |

### The micro bench of the S6 variants beside the macro pairs (ns per feed: query and JSON, 5 processes, JIT on; one developer's run on the Mac's VM)

| Variant | micro: median ns per feed | micro: against the reference | macro: median paired difference µs/req | macro: against the reference's µs/req |
|---|---|---|---|---|
| `APP_PRAGMAS=mmap-off` | 29954 | -3.2 % | -1.31 | -5 % |
| `APP_PRAGMAS=cache-256m` | 30030 | -3 % | -2.22 | -8.2 % |

### Syscalls per request (strace -c, 2,000 req/s, 20 s of the plateau; counts only), the skeleton and `APP_LOCKING=exclusive`

| syscall | skeleton: calls per request | exclusive: calls per request | difference |
|---|---|---|---|
| `epoll_pwait` | 0.513 | 0.553 | +0.04 |
| `fcntl` | 2.456 | 0 | -2.46 |
| `pread64` | 0.064 | 0.07 | +0.01 |
| `pwrite64` | 0.572 | 0.593 | +0.02 |
| `recvfrom` | 1 | 1 | 0 |
| `sendto` | 1 | 1 | 0 |
| **total** | **5.607** | **3.219** | **-2.388** |
| requests counted in the window | 39875 | 40034 | |

### Step 0: three real-shape runs back to back with no wait (the idle client retries a busy port): 24,000 req/s, `s = 0.02`, 60,000 idle, telemetry off

| Run | valid | other containers | waited before the run (s) | TIME_WAIT on the busiest idle address when it started | idle held at the end | closed by the server | source addresses used | connects retried | µs CPU/req |
|---|---|---|---|---|---|---|---|---|---|
| a-1 | true | 0 | 0 | 0 | 60000 | 0 | 6 | 0 | 26.34 |
| b-1 | true | 0 | 0 | 10036 | 60000 | 0 | 9 | 200 | 26.84 |
| c-1 | true | 0 | 0 | 7065 | 60000 | 0 | 9 | 200 | 26.37 |

### The profile of today's skeleton (Excimer, 1 ms CPU time, one run: 24,000 req/s, `s = 0.02`, 60,000 idle, telemetry off), beside the baseline's

Profiled window (the server's whole life after its first answer: warm-up, ramps and plateau): 58321 samples at 1 ms, the cgroup's user CPU 40546 ms and system CPU 18030 ms (**31 % in the kernel**), the samples cover 100 % of that CPU, unclassified 0 %.

Share of all the samples per step, the baseline's profile (phase 4, probes on) and today's (the all column of the fold):

| Step | baseline: share of the samples | today: share of the samples | today: µs on the average request (reference median 26.71 µs/req) |
|---|---|---|---|
| S1 accept connections | 1.7 % | 2.0 % | 0.5 |
| S2 read and parse | 8.0 % | 8.1 % | 2.2 |
| S3 route | 0.4 % | 0.6 % | 0.2 |
| S4 verify the JWT | 1.7 % | 1.6 % | 0.4 |
| S5 validate the input | 0.1 % | 0.2 % | 0.1 |
| S6 query SQLite | 51.7 % | 51.2 % | 13.7 |
| S7 build the JSON | 9.7 % | 9.4 % | 2.5 |
| S8 write the response | 20.2 % | 20.6 % | 5.5 |
| S9 durability | 0.0 % | 0.0 % | 0 |
| event loop | 6.5 % | 6.3 % | 1.7 |
| unclassified | 0.0 % | 0.0 % | 0 |

The fold of `profile/skeleton.collapsed` with `--us-per-req` set to the reference runs' median (an unprofiled number):

```text
step                   GET /health     GET /feed  GET /posts/:id  POST /posts  POST /posts/:id/like        shared            all
S1 accept connections   0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    2.0% 0.5us     2.0% 0.5us
S2 read and parse       0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    8.1% 2.2us     8.1% 2.2us
S3 route                0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    0.5% 0.1us     0.6% 0.1us
S4 verify the JWT       0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.2% 0.1us            1.4% 0.4us    0.0% 0.0us     1.6% 0.4us
S5 validate the input   0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.1% 0.0us            0.1% 0.0us    0.0% 0.0us     0.2% 0.0us
S6 query SQLite         0.1% 0.0us  38.2% 10.2us      6.0% 1.6us   1.0% 0.3us            6.0% 1.6us    0.0% 0.0us   51.2% 13.7us
S7 build the JSON       0.0% 0.0us    8.6% 2.3us      0.7% 0.2us   0.0% 0.0us            0.1% 0.0us    0.0% 0.0us     9.4% 2.5us
S8 write the response   0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us   20.6% 5.5us    20.6% 5.5us
S9 durability           0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    0.0% 0.0us     0.0% 0.0us
event loop              0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    6.3% 1.7us     6.3% 1.7us
unclassified            0.0% 0.0us    0.0% 0.0us      0.0% 0.0us   0.0% 0.0us            0.0% 0.0us    0.0% 0.0us     0.0% 0.0us
all                     0.1% 0.0us  46.8% 12.5us      6.7% 1.8us   1.3% 0.3us            7.6% 2.0us  37.5% 10.0us  100.0% 26.7us
samples: 58321, 26.7 us per request on average
each cell: share of all samples and the microseconds it adds to the average request; S9 is inside S6 (autocommit)

within each endpoint (share of that column's own samples):
step                   GET /health  GET /feed  GET /posts/:id  POST /posts  POST /posts/:id/like  shared
S1 accept connections         0.0%       0.0%            0.0%         0.0%                  0.0%    5.3%
S2 read and parse             0.0%       0.0%            0.0%         0.0%                  0.0%   21.7%
S3 route                      0.0%       0.0%            0.0%         2.9%                  0.0%    1.4%
S4 verify the JWT             0.0%       0.0%            0.0%        16.8%                 18.1%    0.0%
S5 validate the input         0.0%       0.0%            0.6%         4.6%                  0.8%    0.0%
S6 query SQLite              82.1%      81.6%           89.3%        73.4%                 79.9%    0.0%
S7 build the JSON            17.9%      18.4%           10.1%         2.0%                  1.2%    0.0%
S8 write the response         0.0%       0.0%            0.0%         0.3%                  0.0%   55.0%
S9 durability                 0.0%       0.0%            0.0%         0.0%                  0.0%    0.0%
event loop                    0.0%       0.0%            0.0%         0.0%                  0.0%   16.7%
unclassified                  0.0%       0.0%            0.0%         0.0%                  0.0%    0.0%
weight in all samples         0.1%      46.8%            6.7%         1.3%                  7.6%   37.5%
```
<!-- END summarize -->

## What the retry found (step 0)

The old client stopped the run on its first `Cannot assign requested address`. Why it did, in the runs of this folder:

- **A run right after another one hits it at about 7,000 connections per address, not at the 10,036 the client budgets.** The previous run leaves
  32,768 TIME_WAIT sockets (the VM's cap): 28,233 of them on the last three of its six addresses (the client closes the last ones first, so the cap is spent there) and 4,535 on k6's,
  none on the first three. The client picks 127.0.0.2 as free (no socket of any state at either end), opens 7,020 connections on it, and then every connect fails. In the proof runs
  **8 of the 9 addresses used were left that way**, each after 7,020 connections (a replay with the watcher on `/proc/net/tcp` showed 7,020 established on each): 25 failures in a row
  each (200 retries in all), and the client moved on; the ninth address took the remaining 3,840. On a quiet VM with no earlier run
  (run a) there is no failure and 6 addresses are enough.
- **Why a free address stops at 7,000 ports is not understood.** It is not the address's own TIME_WAIT sockets (it has none), and it is two thirds of the 10,536 ports of the range,
  which looks like a rule of the kernel's port choice and not a coincidence; a smaller replay of the same pair (2,000 req/s, 5 s hold, no gap
  worth the name) made 0 retries, so what the earlier run leaves matters (its size and its 60 s). I did not go further.
- **What the retry costs:** 200 failed connects of 60,000 (0.3 %), and 3 more source addresses (9 instead of 6) of the 253 available; µs/req of b and c (26.84, 26.37) against a
  (26.34). The gate for the idle client's sockets is still there (`--idle-time-wait-max 0` waits for them to drain, about a minute).
- **The fix is in the client**, so `lab/conns.sh` and `lab/realistic.sh --idle` get it too; the events carry `bind_retries`.

## The checkpointer (D63): a finding, not a pair

`APP_CHECKPOINTER` was not run. It failed its own bound in the smoke of the scope that built it, which ran it once at the pair's rate (24,000 req/s, 60,000 idle,
2 minutes, telemetry on, `docker ps` empty): these are its figures, from that scope's hand-back (scratch runs, not in this folder: counts only). A 2-minute rerun of that smoke, saved in this folder so that anyone can reproduce the numbers,
was planned for `s9-checkpointer/` and not run: it waits for a quiet VM.

| Smoke (one run each) | achieved req/s | µs CPU/req | p99 ms | WAL frames in use (`mxFrame`, the sampler) | WAL file |
|---|---|---|---|---|---|
| `APP_CHECKPOINTER=1000` | 23,172 | 31.81 | 46.2 | 758,740 at the end, growing all run (6,568 frames the most in a second) | 3.13 GB |
| `APP_GROUP_COMMIT=1` | 23,348 | 27.16 | 25.9 | 1,006 at most (SQLite's own checkpoint) | 4.2 MB |

The checkpointer does copy the WAL back (`nBackfill` follows `mxFrame` one to three seconds behind), but a WAL starts over from its first frame only when a
checkpoint has caught up with `mxFrame` at the moment a write begins. A `PASSIVE` pass from another process copies up to the `mxFrame` it saw when it began, the
writer adds frames meanwhile, and at about 2,000 writes a second the gap is never zero; SQLite's own autocheckpoint runs inside the writer, so no frame is added during it
and the WAL restarts. At that rate a 5-minute run would write about 8 GB. `wal_checkpoint(RESTART)` and `PASSIVE` repeated until caught up also grew in scratch runs at 15,000 to
17,000 writes a second. The bound was 2 times the most frames written between two checkpoints (about 13,100); the run reached 58 times it.

## The reading

- **No variant beat the floor.** Three of the four are lower than the reference (cache-256m -2.22 µs, mmap-off -1.31, exclusive -0.85) and group commit is higher (+1.18), every
  one under 2.57. One pair is a screen, not a verdict. The A/A at this rate (`2026-11-23-s1-fd-wall/aa-24000`) had four of its five pairs within 0.3 µs and one at 2.57, and that 2.57 pair is the one whose run (b-2: 28.48 µs/req, p99 51 ms, 96.7 %) failed the 97 % rule: the floor
  of 2.57 is set by a run that would not have counted as a pass, so a difference of 2 µs is not out of what two identical runs do now and then; the references of this folder (26.37, 27.06, 26.71 and, with telemetry on, 26.49) spread by 0.7 µs.
- **`mmap-off`, against both readings of the floor:** the floor of the five A/A pairs is 2.57 µs/req, set by the one pair whose run failed the 97 % rule; the floor of the four pairs that passed it is **0.27 µs/req**. The one counted pair is -1.31 µs: not
  better than 2.57 (51 % of it), and 4.9 times 0.27. One pair is a screen under both readings, and the table "against both readings of the floor" above is where the two more pairs will land. Which reading is the right one, and so whether S6 takes `mmap-off`,
  is Jacob's to choose (D65); this folder does not change the choice.
- **S6, the pragmas:** both presets are lower by the sign the micro bench gave them (-3.2 % and -3.0 % of a feed), and by more at the macro (-5 % and -8 % of a request),
  but the micro's 3 % is about 1 µs of a feed (31 µs for the query and the JSON), and a feed is 47 % of the requests, so it is worth 0.4 to 0.5 µs of an average request; the macro's 1.3 and 2.2 are
  three to five times that. The cache preset is
  86 % of the floor: close, and unconfirmed (D60: a variant under the floor gets one pair).
- **S8, `exclusive`:** 2.39 syscalls fewer per request (5.607 to 3.219, `fcntl` 2.456 to 0; nothing else moved by more than 0.04) is -0.85 µs: 0.36 µs per `fcntl` (an uncontended `F_SETLK`
  on the WAL's `-shm` file), 3 % of the request. It rules out a checkpointer in a second process and the `mxFrame` sampler, and the database cannot be opened from outside while the server runs.
  On the rules it is allowed: the challenge's test copies the seed and talks HTTP, and the leaderboard's footnote ᶳ says entry #344 (Go, fasthttp) is scored with EXCLUSIVE locking.
- **S9, group commit:** +1.18 µs (+4.5 %) and a worse p99 in this pair (25.11 against 19.5 ms), but the four references' own p99 run from 19.5 to 27.5 ms, so the p99 did not clearly move.
  Batches: a mean of 1.45 writes per commit (the server's whole life, warm-up included) and a largest of 79, as the smoke of the scope that built it said (1.56, 76): at the bench's rate there
  is almost nothing to share, and each turn pays the `loop(LOOP_ONCE)` call and the flush. The longest callback of any second is 28.5 ms against the reference's 16.1; stalled seconds
  (max latency above 100 ms) 3 of 58 against 2 of 58. This pair ran with telemetry on on both sides, against a floor measured with it off, so its own noise may be wider than the floor says.
- **The skeleton today costs what it cost:** the median of the three telemetry-off references is 26.71 µs/req, against 26.11 for the S1 series' 10 A/A runs before `respond()` and the
  `instanceof Closure` test (+0.6, inside the noise) and 27.15 for the baseline (probes on). The one more method call per request is not visible.
- **The profile did not move:** S6 51.2 % of the samples (51.7 % in the baseline), S8 20.6 % (20.2), S2 8.1 % (8.0), S7 9.4 % (9.7), the event loop 6.3 % (6.5), 31 % of the CPU in the kernel
  (30 %). The feed's query alone is 38.2 % (38.8 %).

## Did the predictions hold?

9. **Half.** Held: `join` is slower than the reference (4 to 5 times, in the micro bench), and no pragma preset moves µs/req beyond the noise (-1.31 and -2.22 µs against a floor of 2.57, one pair each).
   Missed: `two-step` is not the fastest SQL (50 to 60 % *slower* in the micro bench, not 10 to 30 % under), `FETCH_NUM` does not save under 5 % (it costs 9.5 % more), and no S6 variant is chosen, so
   "the chosen S6 saves 1 to 4 µs (4 to 15 %)" has nothing to measure: the best candidate, cache-256m, is -2.22 µs (8 %), inside that range and under the floor, from one pair.
10. **Not judged as written; its range held for the one S8 variant that exists.** `APP_IO=sockets` was not built: the count showed exactly one `recvfrom` and one `sendto` per request and nothing to remove. The S8 variant
    that was built, `exclusive`, saves 0.85 µs per request, inside the predicted 0.5 to 2 µs and under the floor, and its syscall count is 43 % lower (5.607 to 3.219).
11. **Half.** Held: group commit's p99 is within the noise (25.11 against a reference of 19.5, the four references' spread being 19.5 to 27.5). Missed: µs/req did not fall by 0 to 3 %, it rose by 4.5 %
    (+1.18, under the floor, so within the noise but on the wrong side); and the checkpointer clause missed: it was not run, and in its smoke it cost 31.81 µs/req against 27.16 for group commit alone, with a WAL of 3.13 GB.

## The choice

| Step | Chosen | Why |
|---|---|---|
| S6 | the skeleton's feed query and pragmas | no variant beat the floor: cache-256m -2.22 µs (the nearest), mmap-off -1.31, both one pair; the SQL and fetch variants were slower in the micro bench and were not run |
| S8 | the skeleton's default locking | `exclusive` -0.85 µs, under the floor and rules out the checkpointer in a second process, the `mxFrame` sampler and any outside connection; it is allowed on the rules and cheap, so it stays a candidate for the combined run |
| S9 | the skeleton's write per request | group commit +1.18 µs and a p99 inside the noise, with 1.45 writes per commit at this rate; the checkpointer fails its bound (the WAL never restarts) |

A variant within the noise is not chosen unless it is simpler, and none is simpler than the code it replaces. The three small negatives (cache-256m, mmap-off, exclusive) are lower by
2.2, 1.3 and 0.85 µs and act on different costs (the page cache, the lock calls); together they could pass the floor that none passes alone, which is a question for the run that puts variants together.
