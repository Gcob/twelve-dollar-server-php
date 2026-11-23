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
