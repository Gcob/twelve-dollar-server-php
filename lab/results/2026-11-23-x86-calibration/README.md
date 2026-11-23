# The x86 calibration

The skeleton and S1-d run on one AWS `c5.2xlarge` (Intel Xeon, x86-64), in the lab's realistic mode with the Mac's shape: `s = 0.02`, 60,000 idle
connections, the server on one vCPU with its hyperthread sibling idle, 2 GiB, PHP 8.5. The Mac's Docker VM is busy with other projects'
containers, so no Mac run is made now: the x86 factor is read against the Mac's existing runs, named below, and the same-rate Mac pair is a
follow-up for a quiet VM. These are x86 numbers on a shared cloud host, not a score. This file is written in two steps: the predictions and the
plan first (committed before any run on the instance), then the results.

## Predictions

Copied unchanged from the phase's plan, in full. This folder judges 13, 17 and 18 (the others are judged by `2026-11-23-s1-fd-wall` (1 to 8),
`2026-11-23-cpu-steps` (9 to 11), `2026-11-23-step-lab-together` (12) and `2026-11-23-swoole-entries` (14 to 16)).

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

1. **The machine:** one `c5.2xlarge` in `ca-central-1` (a `m5.2xlarge` only if there is no capacity), Ubuntu 24.04, Docker from Docker's apt
   repository, nothing else running (`other_containers: 0` in every counted run). The branch's commit is sent with `git archive`; the images
   (`php-lab:8.5`, and `8.3-apt` and `8.3-apt-tzimpel` for the Swoole entries) are built there with `lab/build.sh`, the seed with `lab/seed.sh`
   (it checks the seed's content hash). The CPU layout is `LAB_CPU_LAYOUT=x86-8` (`lab/README.md`, "CPU layouts"): the siblings are read on the
   instance, the server alone on one vCPU with its sibling idle, k6, the idle client and the probe on the other cores. The CPU model is the
   `model name` of `/proc/cpuinfo`; nothing else about the machine is published.
2. **The rate the Xeon holds:** a staircase of the skeleton (`APP_TELEMETRY=1`, probes on, the Mac's flags) at `s = 0.02` with 60,000 idle,
   from 4,000 req/s in steps of 2,000, then 500, stopping at the first failing step (the 97 % rule, as on the Mac). The fixed rate is the
   highest passing step, the one below it if that one passes by less than a point.
3. **Skeleton against S1-d, 3 pairs** (`lab/steplab.sh`, 60 s plateau, the baseline's warm-up, telemetry on in both, skeleton first in each
   round): S1-d is `APP_SOFT_CONN_LIMIT=65450`, above the run's connections, so it never fires (scope 11's setting). It is the only
   variant the step lab chose, so it is "the chosen configuration". No A/A calibration is made on the instance: no floor, no verdict; the
   skeleton's own spread over its runs is the noise, said next to each difference.
4. **The reconnect on x86:** one pair, the skeleton against S1-d with `APP_SOFT_CONN_LIMIT=60000` (the 60,000 idle fill the limit, so every
   request of k6 reconnects), the method of the S1 series. Its paired difference is the cost of one reconnect on the Xeon; with the model of
   that series (a share `1 - 64,000 / N` of the requests reconnect) it gives S1-d's added µs at 100,000, 150,000 and 200,000 users.
5. **The Swoole entries, if they cost under 30 minutes more:** `php-swoole-mattsplat` and `php-swoole-tzimpel` unchanged, one pair each
   against the skeleton at the same rate, on the images the Mac runs used (`8.3-apt` and `8.3-apt-tzimpel`).
6. **The Mac side:** the x86 factor is the Xeon's skeleton µs/req over the Mac's, taken from the Mac's own skeleton runs at the nearest rate
   and shape: the S1 series' S1-a at 12,000 req/s (27.95 µs/req, telemetry on, median of 5; `2026-11-23-s1-fd-wall`) and the skeleton of
   the Swoole pairs (27.94 and 28.34). The rate difference is said. A same-rate Mac pair waits for a quiet VM.
7. **The end:** the instance terminated (3 hours at most from its launch), its security group and key pair deleted, and the describes of
   the teardown script checked (their output is in the hand-back, not here: it holds ids).
