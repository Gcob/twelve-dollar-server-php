# S1 and the io_uring spike, measured

What S1 (the fd wall) costs, and what the io_uring spike buys, on a quiet Docker VM (Docker Desktop on an M3 Pro, arm64, PHP 8.5, the
skeleton on the DIY loop, 1 CPU). These are arm64 numbers, not a score. This file is written in two steps: the predictions and the plan of
the runs first (below, committed before any measured run), then the results and the verdicts.

## Predictions (D5)

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

## Plan of the runs

Every series starts with `docker ps` showing no container: the VM is quiet, and every counted JSON says `other_containers: 0`. No image
build and no `lab/check.sh` during a series. A run that is invalid keeps its files and is shown, not counted (a valid run whose step fails
the 97 % rule still counts for its µs per request).

1. **Syscall counts:** `lab/syscalls.sh` at 2,000 req/s on the skeleton and with `APP_SOFT_CONN_LIMIT=0`.
2. **A/A calibration:** `lab/steplab.sh` with two identical skeleton variants, 5 pairs at 24,000 req/s (`s = 0.02`, 60,000 idle, telemetry
   off), then 5 pairs at 12,000 req/s (telemetry on). The floor of a rate is the largest absolute paired difference of its 5 pairs.
3. **S1 at 12,000 req/s:** the skeleton against `APP_SOFT_CONN_LIMIT=60000`, telemetry on for both, 5 pairs, judged with the 12,000 floor.
   The cost of one reconnect is the median paired difference; the close count of the telemetry must equal k6's requests.
4. **The fd wall:** two 5-minute holds at 12,000 req/s, `s = 0.04`, 64,000 idle, k6's VUs on top, probes on: the skeleton, then
   `APP_SOFT_CONN_LIMIT=64000`.
5. **At the bench's sizes:** the share of requests that reconnect at 100,000, 150,000 and 200,000 users, times the cost of one reconnect.
6. **The spike:** the FFI micro on 8.5 with the JIT on and off; the ring's no-op server against DIY's on `/noop` (7,000 and 24,000 req/s);
   `conns.sh` on one ring at 60,000 and on two rings at 80,000.
7. **Results and verdicts:** `summarize.sh` regenerates every table below from the JSON files next to it.

## What differed from the plan of the runs

- **The first A/A series stopped at its second run.** The idle client could not open its 60,000 connections (`Cannot assign requested address`):
  the VM still held 32,768 TIME_WAIT sockets from the previous run, which leaves its source addresses almost no free port, and the step lab's
  default gate only counts the sockets on k6's addresses (limit 2,500), so it let the next run start at once. The series was started again from
  the first run with `--time-wait-max 1` (every run waits about 58 s for the sockets to drain, so each starts with none). The first attempt's
  one run is valid and is kept in `aborted-first-attempt/`, shown below and not counted. The gate should count the idle client's addresses too.
- **Flags the plan did not fix:** the aggregator's lag gate is the default 6 s; both fd-wall holds have `--vu-cap 5000` (4,535 VUs are needed, so
  the cap does not bind) and a 60 s warm-up at 1,200 req/s, as the step lab's runs do.
- **The close count includes the warm-up.** The server's telemetry counts its whole life, and the warm-up's requests (not recorded in the run's
  JSON) reconnect too: the tables use the nominal count (the warm-up rate times its plateau plus half its ramp) and say so. One extra run without
  a warm-up (`s1-check/`) shows the equality exactly.
- **`other_containers` is not in the syscall or the micro JSON** (their scripts do not record it). `docker ps` showed no container before each
  syscall count and before the micro bench; the realistic, macro and connection JSONs record it themselves, and every counted one says 0.
- **DIY's requests per turn.** DIY prints no turn count. A first try (the voluntary context switches of the process, read from outside) gives only
  an upper bound, and the ring shows how loose: 2,712 blocking waits a second against its own 6,339 turns. A count with `strace -p` is a true
  count but the traced server batches more, and at 24,000 req/s it collapsed (the run is invalid). A server file that drives DIY's loop by hand
  with `EventBase::loop(LOOP_ONCE)` to count the turns never served a request (3.6 million iterations a second, the port never answered, while
  the same call in a stand-alone script blocks): not kept, not understood. So DIY's requests per turn is an upper bound only.
- **The ring's stress test was not rerun here:** its result (2,000,000 requests over 1,000 connections, 0 mismatches) is the spike's own.
- **Scratch paths were scrubbed after the runs:** the step lab writes its temporary folder into each run's `command` and into the `.txt` next to
  it; `<tmp>` replaces it in those files.
- **The ring's `ring:` lines** come from the server's output, followed with `docker logs -f` from outside during the runs (the script removes the
  container at its end); `ring-lines/` keeps their counts, one object a second.

## Results

Every table is printed by `summarize.sh` from the files next to it. A run counts when its JSON says `valid: true` and `other_containers: 0`.

<!-- BEGIN summarize -->
### Syscalls per request (strace -c on the skeleton, 2,000 req/s, 20 s of the plateau; counts only)

| syscall | skeleton: calls per request | `APP_SOFT_CONN_LIMIT=0` (every request reconnects): calls per request | difference |
|---|---|---|---|
| `fcntl` | 2.458 | 4.476 | +2.02 |
| `epoll_ctl` | 0 | 2.015 | +2.02 |
| `ppoll` | 0 | 1.018 | +1.02 |
| `accept` | 0 | 1.015 | +1.01 |
| `recvfrom` | 1 | 1 | 0 |
| `sendto` | 1 | 1 | 0 |
| `close` | 0 | 1 | +1 |
| `shutdown` | 0 | 1 | +1 |
| `pwrite64` | 0.582 | 0.566 | -0.02 |
| `pread64` | 0.071 | 0.066 | -0.01 |
| `epoll_pwait` | 0.529 | 0.005 | -0.52 |
| **total** | **5.641** | **13.163** | **+7.522** |
| requests counted in the window | 39955 | 30659 | |
| write family (`write`, `sendto`, `writev`) per request | 1 | 1 | |

Errors in the two tables: 0 in all.

### A/A calibration at 24,000 req/s (the skeleton against itself, `s = 0.02`, 60,000 idle, telemetry off, 5 pairs)

| Run | valid | other containers | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|
| a-1 | true | 0 | 23434.8 | 97.6 % | 26.1 | 10.75 | 25.49 | pass |
| b-1 | true | 0 | 23428.4 | 97.6 % | 25.84 | 10.75 | 20.69 | pass |
| a-2 | true | 0 | 23442.1 | 97.7 % | 25.91 | 10.75 | 21.96 | pass |
| b-2 | true | 0 | 23212.6 | 96.7 % | 28.48 | 15.14 | 51.32 | FAIL: achieved below 97 % of offered |
| a-3 | true | 0 | 23404 | 97.5 % | 26.12 | 11.93 | 25.11 | pass |
| b-3 | true | 0 | 23444.3 | 97.7 % | 25.96 | 10.91 | 22.97 | pass |
| a-4 | true | 0 | 23446.9 | 97.7 % | 26.35 | 10.59 | 21.64 | pass |
| b-4 | true | 0 | 23413.3 | 97.5 % | 26.09 | 11.24 | 25.11 | pass |
| a-5 | true | 0 | 23374.4 | 97.4 % | 26.27 | 11.75 | 29.58 | pass |
| b-5 | true | 0 | 23485.6 | 97.8 % | 26.21 | 10.28 | 21.32 | pass |

| Round | a µs/req | b µs/req | b minus a µs | a p99 ms | b p99 ms |
|---|---|---|---|---|---|
| 1 | 26.1 | 25.84 | -0.26 | 25.49 | 20.69 |
| 2 | 25.91 | 28.48 | +2.57 | 21.96 | 51.32 |
| 3 | 26.12 | 25.96 | -0.16 | 25.11 | 22.97 |
| 4 | 26.35 | 26.09 | -0.27 | 21.64 | 25.11 |
| 5 | 26.27 | 26.21 | -0.06 | 29.58 | 21.32 |

Medians: a 26.12 µs/req, b 26.09 µs/req. Paired differences (b minus a): -0.26, +2.57, -0.16, -0.27, -0.06, median -0.16. **Floor (the largest absolute paired difference of the 5 pairs): 2.57 µs/req** (9.8 % of the median run). Achieved over offered: 96.7 % to 97.8 % (median 97.6 %); runs under the 97 % rule: 1 of 10.

### A/A calibration at 12,000 req/s (the skeleton against itself, `s = 0.02`, 60,000 idle, telemetry on, 5 pairs)

| Run | valid | other containers | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|
| a-1 | true | 0 | 11912.8 | 99.2 % | 27.22 | 2.32 | 7.3 | pass |
| b-1 | true | 0 | 11905.8 | 99.2 % | 27.05 | 2.29 | 7.3 | pass |
| a-2 | true | 0 | 11885.4 | 99 % | 28.6 | 2.19 | 7.86 | pass |
| b-2 | true | 0 | 11917.7 | 99.3 % | 27.17 | 1.62 | 4.74 | pass |
| a-3 | true | 0 | 11915.3 | 99.3 % | 27.36 | 1.67 | 5.03 | pass |
| b-3 | true | 0 | 11911.2 | 99.2 % | 27.81 | 1.83 | 5.34 | pass |
| a-4 | true | 0 | 11924.7 | 99.3 % | 27.55 | 1.51 | 5.11 | pass |
| b-4 | true | 0 | 11917.6 | 99.3 % | 27.62 | 1.7 | 5.42 | pass |
| a-5 | true | 0 | 11907.6 | 99.2 % | 27.85 | 1.72 | 5.11 | pass |
| b-5 | true | 0 | 11914.9 | 99.3 % | 27.57 | 1.83 | 5.26 | pass |

| Round | a µs/req | b µs/req | b minus a µs | a p99 ms | b p99 ms |
|---|---|---|---|---|---|
| 1 | 27.22 | 27.05 | -0.17 | 7.3 | 7.3 |
| 2 | 28.6 | 27.17 | -1.43 | 7.86 | 4.74 |
| 3 | 27.36 | 27.81 | +0.45 | 5.03 | 5.34 |
| 4 | 27.55 | 27.62 | +0.07 | 5.11 | 5.42 |
| 5 | 27.85 | 27.57 | -0.27 | 5.11 | 5.26 |

Medians: a 27.55 µs/req, b 27.57 µs/req. Paired differences (b minus a): -0.17, -1.43, +0.45, +0.07, -0.27, median -0.17. **Floor (the largest absolute paired difference of the 5 pairs): 1.43 µs/req** (5.2 % of the median run). Achieved over offered: 99 % to 99.3 % (median 99.3 %); runs under the 97 % rule: 0 of 10.

### S1 at 12,000 req/s: the skeleton (s1a) against S1-d (s1d: `APP_SOFT_CONN_LIMIT=60000`, the 60,000 idle fill the limit, every request of k6 reconnects), `s = 0.02`, 60,000 idle, telemetry on in both, 5 pairs

| Run | valid | other containers | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|
| s1a-1 | true | 0 | 11906.7 | 99.2 % | 28.02 | 2 | 6.01 | pass |
| s1d-1 | true | 0 | 11893.7 | 99.1 % | 34.64 | 3.12 | 6.38 | pass |
| s1a-2 | true | 0 | 11908.4 | 99.2 % | 27.52 | 1.75 | 5.11 | pass |
| s1d-2 | true | 0 | 11852.2 | 98.7 % | 36.29 | 3.74 | 13.64 | pass |
| s1a-3 | true | 0 | 11918.1 | 99.3 % | 27.95 | 1.91 | 5.42 | pass |
| s1d-3 | true | 0 | 11895.7 | 99.1 % | 34.33 | 3.22 | 6.48 | pass |
| s1a-4 | true | 0 | 11912.8 | 99.2 % | 27.97 | 1.67 | 4.88 | pass |
| s1d-4 | true | 0 | 11893.3 | 99.1 % | 34.58 | 3.08 | 6.2 | pass |
| s1a-5 | true | 0 | 11912.3 | 99.2 % | 27.94 | 1.86 | 5.58 | pass |
| s1d-5 | true | 0 | 11902.7 | 99.2 % | 34.34 | 3.08 | 6.29 | pass |

The server's close count against k6's requests (the telemetry counts the server's whole life: the warm-up's requests reconnect too, and their count is not in the run's JSON, so the nominal one is used: the warm-up rate times its plateau plus half its 10 s ramp):

| Round | s1a µs/req | s1d µs/req | s1d minus s1a µs | `Connection: close` responses (telemetry) | k6 requests (run, warm-up not included) | nominal warm-up requests (rate x (plateau + ramp / 2)) | closes minus both | as a share of the closes |
|---|---|---|---|---|---|---|---|---|
| 1 | 28.02 | 34.64 | +6.62 | 859370 | 781161 | 78000 | +209 | 0.02 % |
| 2 | 27.52 | 36.29 | +8.77 | 856648 | 778524 | 78000 | +124 | 0.01 % |
| 3 | 27.95 | 34.33 | +6.38 | 858899 | 781094 | 78000 | -195 | -0.02 % |
| 4 | 27.97 | 34.58 | +6.62 | 858972 | 780794 | 78000 | +178 | 0.02 % |
| 5 | 27.94 | 34.34 | +6.4 | 859597 | 781454 | 78000 | +143 | 0.02 % |

S1-a median 27.95 µs/req, S1-d median 34.58. Paired differences (s1d minus s1a): +6.62, +8.77, +6.38, +6.62, +6.4, **median 6.62 µs: the cost of one reconnect** (23.7 % of the skeleton's µs/req). Floor of the A/A at 12,000: 1.432 µs/req.

The step lab's own summary of these runs (its rule: beyond the noise when every pair has the same sign and the median paired difference passes the floor):

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  result
    1  s1a            yes      11906.7        28        2     6.01         0  pass
    1  s1d            yes      11893.7      34.6     3.12     6.38         0  pass
    2  s1a            yes      11908.4      27.5     1.75     5.11         0  pass
    2  s1d            yes      11852.2      36.3     3.74    13.64         0  pass
    3  s1a            yes      11918.1      27.9     1.91     5.42         0  pass
    3  s1d            yes      11895.7      34.3     3.22     6.48         0  pass
    4  s1a            yes      11912.8        28     1.67     4.88         0  pass
    4  s1d            yes      11893.3      34.6     3.08      6.2         0  pass
    5  s1a            yes      11912.3      27.9     1.86     5.58         0  pass
    5  s1d            yes      11902.7      34.3     3.08     6.29         0  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)

variants (us is the server's CPU per request over the plateau)
variant         valid median us        min to max   p99 ms  paired differences us     median  verdict
s1a               5/5      27.9        27.5 to 28     5.42  reference                      -  reference
s1d               5/5      34.6      34.3 to 36.3     6.38  +6.6 +8.8 +6.4 +6.6 +6.4      +6.6  beyond the noise

Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 1.432 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### What S1-d adds at the bench's sizes (soft limit L = 64,000; share of requests that reconnect = 1 - L / N)

| Users N | requests per second (N / 9.45) | share that reconnect | µs added per request (share x the cost of one reconnect) | as a share of the skeleton's µs/req | above 15 %? |
|---|---|---|---|---|---|
| 100000 | 10582 | 36 % | 2.38 | 8.5 % | no |
| 150000 | 15873 | 57.3 % | 3.79 | 13.6 % | no |
| 200000 | 21164 | 68 % | 4.5 | 16.1 % | **yes** |

Inputs: cost of one reconnect and the skeleton's µs/req are S1's medians above (12,000 req/s, telemetry on, probes off).

### The fd wall: two 5-minute holds at 12,000 req/s, `s = 0.04`, 64,000 idle connections, k6's VUs on top, the sampler on (the file descriptors the process holds are 65,535 at most)

| Run | valid | other containers | VUs | idle held (start / end) | users at once (idle + VUs) | fds peak (sampler) | open connections peak (telemetry) | accept pauses (telemetry) | `Connection: close` responses | k6 connection errors | errors | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| skeleton | true | 0 | 4535 | 64000 / 64000 | 68535 | 65535 | 65523 | 5 | 0 | 21628 | 24756 (2.03 %) | 34.2 % | 40.73 | 0.55 | 4.08 | FAIL: achieved below 97 % of offered; errors at or above 1 % |
| s1d | true | 0 | 4535 | 64000 / 64000 | 68535 | 64229 | 65470 | 0 | 3726421 | 0 | 0 (0 %) | 99.4 % | 36.22 | 4.47 | 11.41 | pass |

| Run | k6 error codes | per-second max latency over the plateau (ms) | stalled seconds (max latency above 100 ms) | server memory.current peak MiB | Pss_Anon peak MiB | k6 memory peak MiB | VU cap bound by | aggregator max lag s |
|---|---|---|---|---|---|---|---|---|
| skeleton | {"1050":4097,"1211":21628} | 60022.6 | 12 | 612.73 | 114.66 | 1620.61 | --vu-cap | 2.656 |
| s1d | {} | 218.3 | 3 | 612.41 | 136.68 | 2256.56 | --vu-cap | 3.678 |

S1-d at the fd wall: 3726421 `Connection: close` responses against 3647838 k6 requests plus about 78000 of the warm-up: +583 (0.02 % of the closes), so every request of k6 reconnected.

TIME_WAIT sockets on k6's addresses are not counted by these two runs (the runner that counts them is the step lab's); the VM's ephemeral ports are 55000 to 65535.

### Runs that do not count

| File | valid | reason | other containers |
|---|---|---|---|
| aborted-first-attempt/aa-24000-a-1.json | true | its series stopped before the second run (a harness failure, see what differed); the run itself was valid | 0 |

### The FFI micro bench (`micro.sh lab/micro/benches/ffi.php --images 8.5 --jit both`, 5 processes per case, median ns per operation)

| Case | JIT off ns | JIT off, fastest .. slowest process | JIT on ns | JIT on, fastest .. slowest process | on / off | status |
|---|---|---|---|---|---|---|
| (empty loop) | 19.5 | 19.1 .. 19.5 | 13.4 | 13 .. 13.5 | 0.69 | ok |
| syscall/getmypid() native | 157.4 | 149.8 .. 162.9 | 146.1 | 145.1 .. 147.3 | 0.93 | ok |
| syscall/FFI syscall(getpid), 1 argument | 194.6 | 191.8 .. 195 | 180.6 | 177.7 .. 191.6 | 0.93 | ok |
| syscall/FFI syscall(getpid), 6 arguments | 220.2 | 215.3 .. 221.1 | 206.9 | 199.2 .. 209.3 | 0.94 | ok |
| cdata/write one u64 field of an SQE | 27.6 | 27.6 .. 28.4 | 22.9 | 22.6 .. 23.2 | 0.83 | ok |
| cdata/read one u64 field of an SQE | 26.6 | 26.4 .. 27.6 | 22.2 | 21.8 .. 22.7 | 0.83 | ok |
| cdata/write the 6 fields of a send SQE | 84.1 | 83.8 .. 86.4 | 61.8 | 60.5 .. 62.3 | 0.73 | ok |
| cdata/write all 14 fields of an SQE in the ring (sqes[i]) | 108.1 | 106.3 .. 109.2 | 90.9 | 90.1 .. 92.1 | 0.84 | ok |
| cdata/write a u32 through a pointer (ring tail) | 27.8 | 27.7 .. 27.9 | 25.1 | 24.5 .. 25.3 | 0.9 | ok |
| cdata/read a u32 through a pointer (ring tail) | 29.7 | 29.6 .. 30.4 | 25.2 | 25.1 .. 25.6 | 0.85 | ok |
| memcpy/64 B (one SQE) | 77 | 76.4 .. 77.4 | 56.8 | 56.6 .. 57.1 | 0.74 | ok |
| memcpy/200 B (a post) | 80.2 | 79.5 .. 82.2 | 59.3 | 58.7 .. 60 | 0.74 | ok |
| memcpy/5 KB (a feed) | 166.9 | 166.7 .. 167.5 | 147.3 | 146.5 .. 150.1 | 0.88 | ok |
| memcpy/64 B at a pointer + offset | 81.6 | 81.2 .. 85.7 | 68.3 | 67.5 .. 68.7 | 0.84 | ok |
| string/16 B (one CQE) | 69.2 | 68.7 .. 70.2 | 57.6 | 56.9 .. 58.1 | 0.83 | ok |
| string/200 B (a request) | 72.8 | 71.4 .. 76.8 | 59.5 | 59.1 .. 59.9 | 0.82 | ok |
| string/5 KB | 165.7 | 164.9 .. 166 | 155.1 | 154.4 .. 155.7 | 0.94 | ok |
| pack/one 64-byte SQE | 134.1 | 133.2 .. 134.3 | 111 | 110.1 .. 111.7 | 0.83 | ok |
| unpack/one 16-byte CQE | 82 | 81.9 .. 82.3 | 75.6 | 75.1 .. 76.3 | 0.92 | ok |
| batch/32 SQEs: pack() in a loop, one memcpy | 4389.8 | 4369.4 .. 4512 | 3895.8 | 3876.2 .. 4045.6 | 0.89 | ok |
| batch/32 SQEs: one pack() of 32, one memcpy | 6681.1 | 6661.8 .. 6834.9 | 6444 | 6345.1 .. 6586 | 0.96 | ok |
| batch/32 CQEs: one FFI::string, one unpack() | 1999.8 | 1968.6 .. 2061.8 | 1993.4 | 1960.7 .. 2020.1 | 1 | ok |
| batch/32 CQEs: one FFI::string, 32 unpack() with an offset | 2372.4 | 2358.4 .. 2388.1 | 2238.2 | 2224.8 .. 2276.4 | 0.94 | ok |
| socket/fwrite + fread 200 B, unix pair | 527.3 | 511.1 .. 550.4 | 506 | 490.5 .. 524.5 | 0.96 | ok |
| socket/fwrite + fread 5 KB, unix pair | 923.3 | 841.3 .. 932.9 | 879.4 | 819.8 .. 906.3 | 0.95 | ok |
| socket/fread with nothing to read (EAGAIN), unix pair | 215.8 | 209.4 .. 225 | 215.4 | 214.9 .. 222.8 | 1 | ok |
| socket/fwrite + fread 200 B, tcp loopback | 2047.5 | 2032.3 .. 2091 | 2032.2 | 1995.1 .. 2061.6 | 0.99 | ok |
| socket/fwrite + fread 5 KB, tcp loopback | 2313 | 2298.4 .. 2337.9 | 2296.3 | 2274.2 .. 2318.7 | 0.99 | ok |
| socket/fread with nothing to read (EAGAIN), tcp loopback | 228.3 | 218 .. 230.3 | 211.6 | 205.9 .. 218.7 | 0.93 | ok |

Machine: Docker Desktop 4.76.0 (228118), arm64, cpuset 2, --cpus=1 --memory=2g --memory-swap=2g --ulimit nofile=65535:65535; PHP 8.5.13, `ffi.enable` preload.

### The micro numbers against prediction 7, and the JIT's effect

| Quantity | JIT off | JIT on | predicted |
|---|---|---|---|
| FFI `syscall(getpid)` minus `getmypid()`, ns | 37.2 | 34.5 | 150 to 500 |
| write one CData field, ns | 27.6 | 22.9 | 20 to 80 |
| `FFI::memcpy` 200 B, ns | 80.2 | 59.3 | 50 to 200 |
| `FFI::string` 200 B, ns | 72.8 | 59.5 | 50 to 200 |
| `FFI::memcpy` 5 KB, ns | 166.9 | 147.3 | 150 to 600 |
| `FFI::string` 5 KB, ns | 165.7 | 155.1 | 150 to 600 |
| `pack()` of a 64-byte SQE, ns | 134.1 | 111 | 100 to 300 |
| `fwrite` + `fread` 200 B, TCP loopback, ns | 2048 | 2032 | 1,000 to 3,000 |
| `fwrite` + `fread` 200 B, unix socket pair, ns | 527 | 506 | 1,000 to 3,000 |
| largest change the JIT makes among the cases above, % | | 26 | under 20 |

### The stop rule at the record: the ring's FFI budget per request against what the ring removes (ns per request, post of 200 B)

Budget = one `io_uring_enter` (priced as the 6-argument FFI `syscall(getpid)`) shared by the requests of a turn + one SQE written in place (14 fields) + 1.5 CQEs (the send's and the receive's) + `FFI::string` of the request + `FFI::memcpy` of the response. Removed = a `fwrite` + `fread` of 200 B plus the skeleton's `fcntl` and `epoll_pwait` calls per request (counted above) priced as a read that finds nothing. The prudent floor prices each of the `recvfrom`, `sendto`, `fcntl` and `epoll_pwait` calls of a request as a bare `getmypid()`.

| Requests per turn | JIT | budget | removed (unix pair) | removed (TCP loopback) | prudent floor | passes against the unix pair? |
|---|---|---|---|---|---|---|
| 1 | off | 708 | 1172 | 2729 | 785 | yes, 1.7x (under the floor) |
| 8 | off | 382 | 1172 | 2729 | 785 | yes, 3.1x (under the floor) |
| 32 | off | 362 | 1172 | 2729 | 785 | yes, 3.2x (under the floor) |
| 1 | on | 616 | 1149 | 2664 | 729 | yes, 1.9x (under the floor) |
| 8 | on | 329 | 1149 | 2664 | 729 | yes, 3.5x (under the floor) |
| 32 | on | 310 | 1149 | 2664 | 729 | yes, 3.7x (under the floor) |

### The ring's no-op server against DIY's, `GET /noop` (`macro.sh`, 30 s after a 10 s warm-up, 1 CPU, `--pre-vus` = `--max-vus` = rate / 5)

| Run | valid | other containers | offered req/s | achieved req/s | µs CPU/req | p95 ms | p99 ms | dropped iterations | requests per turn (the server's own count, busy seconds) |
|---|---|---|---|---|---|---|---|---|---|
| diy-7000-1 | true | 0 | 7000 | 6999.4 | 21.26 | 0.42 | 1.26 | 0 | - |
| ring-7000-1 | true | 0 | 7000 | 6999.2 | 20.48 | 0.36 | 0.81 | 0 | 1.03 (40 busy seconds) |
| diy-7000-2 | true | 0 | 7000 | 6998.8 | 20.98 | 0.37 | 0.87 | 0 | - |
| ring-7000-2 | true | 0 | 7000 | 6998.9 | 20.29 | 0.36 | 0.76 | 0 | 1.04 (39 busy seconds) |
| diy-7000-3 | true | 0 | 7000 | 6999.3 | 20.76 | 0.33 | 0.74 | 0 | - |
| ring-7000-3 | true | 0 | 7000 | 6999.3 | 20.06 | 0.35 | 0.66 | 0 | 1.02 (39 busy seconds) |
| diy-24000 | true | 0 | 24000 | 23994.9 | 11.9 | 0.67 | 10.45 | 0 | - |
| ring-24000 | true | 0 | 24000 | 23995.7 | 11.4 | 0.62 | 8.85 | 0 | 1.15 (40 busy seconds) |
| ring-24000-minwait | true | 0 | 24000 | 23982.5 | 9.97 | 5.62 | 31.71 | 0 | 6.19 (39 busy seconds) |

At 7,000 req/s: DIY 21.26, 20.98, 20.76 µs/req (median 20.98), ring 20.48, 20.29, 20.06 (median 20.29): the ring minus DIY is -0.69 µs/req (-3.3 %). DIY's own spread over its 3 runs is 0.5 µs/req: no A/A floor was measured at this shape (the step lab's floors are for the realistic mode).

### Turns of each loop at 7,000 req/s, two ways (extra runs, not counted: another container reads the server from outside)

The ring's turn count is its own (the `ring:` lines of the counted runs above): about one request per turn. DIY prints no turn count, so its turns are bounded from outside: (a) the voluntary context switches of the server process (a loop that blocks in its wait is one switch per turn, a wait that finds events ready does not block, so the switches are at most the turns and the requests per turn are at most the requests per switch), read every 3 s without tracing; (b) `strace -c -f` on the loop's wait for 12 s (`epoll_pwait` for DIY, `io_uring_enter` for the ring): a true count, but strace stops the server at every syscall, so the traced loop is slower and batches more (the traced run's µs/req is higher): also an upper bound.

| Server | (a) voluntary switches per second (median of the busy intervals) | (a) requests per switch (an upper bound of the requests per turn) | (b) traced waits per second | (b) requests per turn while traced | the server's own count, untraced (requests per turn) |
|---|---|---|---|---|---|
| diy | 2396 | 2.92 | 1740 | 4.02 | - |
| ring | 2712 | 2.58 | 6863 | 1.02 | 1.03 |

### Idle connections held by the ring server (`conns.sh`: the client opens them one at a time, each answered once, then holds them; nofile 65,535)

| Run | step (connections) | held | server's own fds | Pss MiB | Pss_Anon MiB | memory.current MiB | established (VM) | fresh request ms | other containers |
|---|---|---|---|---|---|---|---|---|---|
| ring-1-ring | 1000 | 1000 | 10 | 22.98 | 12.28 | 266.6 | 1000 | 0.4 | 0 |
| ring-1-ring | 10000 | 10000 | 10 | 28.98 | 18.28 | 305.3 | 10000 | 0.2 | 0 |
| ring-1-ring | 30000 | 30000 | 10 | 28.98 | 18.28 | 378.1 | 30000 | 0.2 | 0 |
| ring-1-ring | 60000 | 60000 | 10 | 29 | 18.28 | 487.3 | 60000 | 0.2 | 0 |
| ring-2-rings | 1000 | 1000 | 11 | 25.79 | 14.34 | 270.9 | 1000 | 0.2 | 0 |
| ring-2-rings | 30000 | 30000 | 11 | 31.8 | 20.34 | 382.4 | 30000 | 0.1 | 0 |
| ring-2-rings | 60000 | 60000 | 11 | 31.82 | 20.34 | 491.6 | 60000 | 0.2 | 0 |
| ring-2-rings | 70000 | 70000 | 11 | 41.89 | 30.34 | 538.1 | 70000 | 0.7 | 0 |
| ring-2-rings | 80000 | 80000 | 11 | 41.9 | 30.34 | 574.5 | 80000 | 1.0 | 0 |
| DIY, the bake-off's run | 60000 | 60000 | about 60,012 (one per connection) | 102.02 | 91.61 | 557.1 | 60000 | 0.7 | - |

| Run | max held and answered | stopped because | Pss per connection KiB | Pss_Anon per connection KiB | memory.current per connection KiB | baseline Pss / memory.current MiB |
|---|---|---|---|---|---|---|
| ring-1-ring | 60000 | no ceiling: every planned step held | 0.07 | 0.07 | 3.8 | 22.9 / 262.8 |
| ring-2-rings | 80000 | no ceiling: every planned step held | 0.2 | 0.2 | 3.93 | 23.7 / 265.2 |
| conns-diy-8.5 | 65000 | request timeout | 1.48 | 1.48 | 5.19 | 16.5 / 254.5 |

### S1-d without a warm-up: the close count against k6's requests (60,000 idle, soft limit 60,000, 12,000 req/s, `s = 0.02`, 60 s)

Valid true, other containers 0: 779441 `Connection: close` responses against 779441 k6 requests (difference 0, 0 %).
<!-- END summarize -->

## The reading

**The noise.** The skeleton against itself at 24,000 req/s (telemetry off): paired differences of -0.26, +2.57, -0.16, -0.27 and -0.06 µs/req, so
the floor is **2.57 µs/req** (9.8 % of a run), and it is one pair: the run behind it (b-2, 28.5 µs/req, p99 51 ms, 96.7 % of offered) is the
only run of the ten under the 97 % rule, and the other four pairs sit within 0.3 µs. At 12,000 req/s (telemetry on) the floor is **1.43 µs/req**
(5.2 %), from one pair as well (-1.43; the others within 0.45). The quiet VM gives the baseline's 97 %: at 24,000, 96.7 to 97.8 % of offered
(median 97.6 %, the baseline's hold got 97.3 %); at 12,000, 99.0 to 99.3 %. An earlier smoke at 24,000 on a busy VM got 92.8 to 95.6 %.

**Syscalls.** The skeleton makes 5.64 syscalls per request at 2,000 req/s: one `recvfrom` and one `sendto` (the write family is exactly 1),
2.46 `fcntl` (the largest line, not explained here), 0.58 `pwrite64` (the WAL; the mix is 7.8 % writes, so
about 7 a write if they all come from those requests), 0.53 `epoll_pwait` (about 1.9 requests per wait, while traced), 0.07 `pread64`; no
`epoll_ctl`, no error. With `APP_SOFT_CONN_LIMIT=0` (every request reconnects) it is 13.16: one `accept`, `close`, `shutdown` and `ppoll` more,
two `epoll_ctl` and two `fcntl` more, and almost no `epoll_pwait` (the loop is never idle between connections). A reconnect is 7.5 syscalls,
at least 1.2 µs at the 157 ns of a bare syscall: the rest of its 6.6 µs is the kernel's handshake and teardown and PHP's work around them.

**One reconnect costs 6.62 µs.** S1-a (the skeleton) 27.95 µs/req, S1-d 34.58 at 12,000 req/s with 60,000 idle: +6.62, +8.77, +6.38, +6.62,
+6.40, every pair the same sign, far beyond the floor of 1.43 ("beyond the noise"). The +8.77 pair is the S1-d run with a p99 of 13.6 ms (the other
four S1-d runs 6.2 to 6.5), and it does not move the median. The close count equals k6's requests: 0.02 % apart in every round after the warm-up's nominal
requests, and exactly equal (779,441 against 779,441) in the run without a warm-up. Latency: p99 6.4 ms against 5.4. The cost is 23.7 % of the
skeleton's µs/req.

**The fd wall.** With 64,000 idle connections and 4,535 VUs on top, 68,535 users want a connection and one process has 65,535 descriptors.
The skeleton holds them (fds peak 65,535, open peak 65,523, 5 accept pauses) and fails the way the hard limit makes it fail: the clients that
cannot get a descriptor wait in the backlog and give up. k6 counted 21,628 dial timeouts (code 1211) and 4,097 request timeouts (1050), the
step served 4,098 req/s of the 12,001 offered (34.2 %), 2.03 % errors, 12 seconds with a latency above 100 ms and one of 60 s. S1-d with a soft
limit of 64,000 passes: 11,928 req/s (99.4 %), 0 errors, 0 accept pauses, the descriptors never above 64,229, an open peak of 65,470, p99 11.4 ms,
3 stalled seconds (the worst 218 ms), every one of k6's 3.65 million requests closed (3,726,421 closes, the warm-up included). So the process
served 68,535 users at once with fewer than 65,535 descriptors. (The skeleton's 40.7 µs/req there is a run that spends its CPU on timeouts and
accept pauses, with the probes on: read it as nothing but a failing run.)

**At the bench's sizes.** The model: each user's connection is one of N; S1-d never closes an idle connection, so the first 64,000 users to
connect keep theirs and every request of the other N - 64,000 reconnects (the same share as a set of the 64,000 most recently used connections
under requests spread evenly over the users: a request finds its connection only if it is among them). A user makes one request per 9.45 s.
Times 6.62 µs: **+2.38 µs/req at 100,000 users (8.5 % of the skeleton's 27.95), +3.79 at 150,000 (13.6 %), +4.50 at 200,000 (16.1 %)**.
**At 150,000 users it is not above 15 %**, so the second variant (several processes) is not built. The margin is thin and says so: 15 % of
27.95 is 4.19 µs, which a reconnect cost of 7.31 µs would reach, and only the one outlier pair is above it; with the skeleton's 26.1 µs at
24,000 req/s as the denominator it is 14.5 %. Two limits of the model: the cost is measured at 12,000 req/s (the bench's rates, 10,600 to
21,200 req/s, may batch accepts differently), and the 1,500 descriptors the limit leaves for the reconnecting connections are enough only
while few are open at once (an estimate: 21,000 req/s times a few ms is about 100; the fd-wall run, with 4,535 VUs, paused accepts 0 times).

**The ring.** `GET /noop` at 7,000 req/s: the ring 20.48, 20.29, 20.06 µs/req against DIY's 21.26, 20.98, 20.76 in the same rounds: **0.69 µs
(3.3 %) lower, every pair the same sign**, p99 0.7 to 0.8 ms against 0.7 to 1.3 (DIY's own spread over its three runs is 0.5 µs; there is no A/A
floor at this shape, so call it a small win, not a settled one). It buys that little because a turn handles 1.03 requests: the ring pays one
`io_uring_enter` per request, and the kernel's TCP work, which both pay, is most of the 20 µs. DIY handles at most 2.9 requests per turn (an
upper bound). At 24,000 req/s (one run each): DIY 11.90, the ring 11.40 (-4.2 %, 1.15 requests per turn), the ring with
`URING_MIN_COMPLETE=8 URING_MIN_WAIT_US=100` **9.97 (-16.2 % against DIY, 6.19 requests per turn) with a p99 of 31.7 ms** against 10.5 for DIY and
8.9 for the ring by default: the batching knob buys 1.4 µs/req (12.5 % of the ring's) and costs 23 ms of p99. On memory it is far ahead of
DIY: 10 descriptors for 60,000 connections (DIY: one each, about 60,012), 0.07 KiB of Pss per connection against 1.48, and a second ring holds
**80,000** connections with 11 descriptors (0.2 KiB each), where one DIY process stops at 65,523. The ring's `memory.current` per connection (3.8
KiB) is the kernel's socket memory, which DIY pays too (5.19 KiB).

**The FFI micro (record, 5 processes, quiet VM).** A call to `syscall(getpid)` costs 35 to 37 ns more than `getmypid()`, not 150 to 500; a
CData field write 23 to 28 ns; `FFI::memcpy` and `FFI::string` of 200 B 59 to 80 ns, of 5 KB 147 to 167; `pack()` of an SQE 111 to 134 ns; a
`fwrite` + `fread` of 200 B 2.0 µs on loopback TCP and 0.5 µs on a unix pair. The JIT changes the small cases by up to 31 % (up to 26 % among the
cases the prediction names: `FFI::memcpy` of 200 B). The stop rule passes at every point: at 8 requests per turn the ring's budget is 329 to 382 ns against 1,149 to 1,172 removed
(unix pair, 3.1 to 3.5 times) and 729 to 785 for the prudent floor; at one request per turn 616 to 708 against 1,149 to 1,172, still
under the floor (729 to 785). The measured ring spends one request per turn, so the 1-request row is the one that applies at 7,000 req/s.

## Did the predictions hold?

Predictions 1 to 8 are judged here. 9 to 13 wait for the next two results folders (the CPU steps, the steps together) and the x86 calibration;
14 to 17 wait for the Swoole entries' folder.

| # | Verdict | The measured value |
|---|---|---|
| 1 | **Partly.** One read and one write per request, no `epoll_ctl` per request, no `fsync` per request (0.001 `fdatasync`, at checkpoints): held. 2 to 4 in total: **missed** (5.64). `epoll_wait` under 0.5 per request: **missed, barely** (0.53). Writes add 1 to 3: **missed** if read per write (about 7; 0.58 per request over the mix). | 5.64 syscalls per request; `fcntl` 2.46 is the surprise. The kernel's 30 % being TCP work and not entries is consistent (5.6 entries at about 150 ns is under 1 µs of 27), not measured here. |
| 2 | **Held.** | S1-a 27.95 µs/req at 12,000 req/s (25 to 30). |
| 3 | **Missed, below.** | One reconnect 6.62 µs (8 to 20); S1-d 34.58 µs/req (35 to 50). |
| 4 | **Not measured.** The second variant is not built: S1-d stays under 15 % at 150,000 users. | |
| 5 | **Held.** | Skeleton: 21,628 dial timeouts, 4,097 request timeouts, 5 accept pauses, fds 65,535, 34.2 % of the offered rate. S1-d: 0 errors, 0 accept pauses, fds 64,229, 68,535 users at once. |
| 6 | **Half.** 100,000 users held (2 to 8); 150,000 **missed, below** (5 to 15); S1-d over the second variant: held, by the rule above. | +2.38 and +3.79 µs/req (8.5 % and 13.6 %). |
| 7 | **Partly.** Held: field write 23 to 28 ns, `memcpy` and `string` of 200 B 59 to 80 ns, `pack()` 111 to 134 ns, `fwrite` + `fread` 2.0 µs on TCP, the stop rule. **Missed:** `syscall(getpid)` over `getmypid()` is 35 to 37 ns (150 to 500); the JIT moves `memcpy` of 200 B by 26 % (under 20); 5 KB `memcpy` is 147 with the JIT on (150 to 600), 2 % under. | |
| 8 | **Mostly.** 60,000 held on one ring with 10 descriptors (under 100): held. Cost 15 to 25 µs/req on `/noop` at 7,000: held (20.06 to 20.48; DIY 20.76 to 21.26, not the 21.88 recorded in the bake-off). Stress with 0 mismatches: the spike's own result, not rerun. **Missed:** the second ring was reached (80,000 connections, 11 descriptors). | |

## The choice

**S1-d, with the soft limit near 64,000, is the S1 variant the next results use.** It is the only variant measured past the wall: 68,535
users on 65,535 descriptors, 0 errors, 0 accept pauses. It costs 6.62 µs per reconnect, so +2.4 µs/req at 100,000 users and +3.8 at 150,000
(13.6 %, under the 15 % line), and the several-processes variant stays unbuilt. The ring is not an S1 variant: it is a spike on a no-op server,
3 % under DIY at 7,000 req/s, and moving the application onto it is a project of its own; what it adds is 60,000 connections on 10 descriptors
and 80,000 on two rings, and a batching knob that trades 23 ms of p99 for 1.4 µs/req, worth a look when the loop itself is the target. In the realistic runs of the
next steps its limit stays above the idle connections plus k6's VUs, so it never fires and the runs measure the steps alone.
