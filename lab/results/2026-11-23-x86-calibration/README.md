# The x86 calibration

The skeleton and S1-d run on one AWS `c5.2xlarge` (Intel Xeon, x86-64), in the lab's realistic mode with the Mac's shape: `s = 0.02`, 60,000 idle
connections, the server on one vCPU with its hyperthread sibling idle, 2 GiB, PHP 8.5. The Mac's Docker VM is busy with other projects'
containers, so no Mac run was made with the instance: the x86 factor was first read against the Mac's existing runs, named below, and the same-rate Mac pair was
run afterwards, on a quiet VM (`mac-same-rate/`). These are x86 numbers on a shared cloud host, not a score. This file is written in two steps: the predictions and the
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
   the Swoole pairs (27.94 and 28.34). The rate difference is said. A same-rate Mac pair (7,500 req/s, the Xeon's flags) was run afterwards, once the VM was quiet: `mac-same-rate/`, and the factor at the same rate sits next to this one.
7. **The end:** the instance terminated (3 hours at most from its launch), its security group and key pair deleted, and the describes of
   the teardown script checked (their output is in the hand-back, not here: it holds ids).

## The machine

| | |
|---|---|
| Instance | AWS `c5.2xlarge`, `ca-central-1`, Ubuntu 24.04 (kernel 7.0 aws), Docker Engine 29.10 (Docker's apt repository), 8 vCPUs, 15.6 GiB |
| CPU model (`/proc/cpuinfo`) | Intel(R) Xeon(R) Platinum 8275CL CPU @ 3.00 GHz |
| Layout (`LAB_CPU_LAYOUT=x86-8`) | siblings read on the instance: `0,4` `1,5` `2,6` `3,7`. Server on vCPU `1`, its sibling `5` idle, k6, the idle client and the aggregator on `0,2,3,4,6,7`, the probe on `0,4` |
| Limits | the lab's: 1 CPU, 2 GiB, no swap, 65,535 fds; host network |
| Built there | `php-lab:8.5` (229 s), `8.3-apt` (100 s), `8.3-apt-tzimpel` (52 s), the seed (its content hash matched) |
| Lived | 1 hour 1 minute, one instance, nothing else on it (`other_containers: 0` in every run below) |

## What differed from the plan of the runs

- **The fixed rate is 7,500 req/s, not the Mac's 12,000 or 24,000.** The skeleton's staircase (4,000 to 10,000 in steps of 2,000, then 7,000 to 8,500 in
  steps of 500) passes at 8,000 with 97.5 % of the offered rate and fails at 8,500 (96.8 %), so 8,000 passes by 0.5 point and the step below, 7,500
  (98.0 %), became the rate. The server is 40 % busy at 7,500 (53.6 µs times 7,500) and 43 % at the knee: the 97 % rule fails on latency, not on the CPU, as it does
  on the Mac at 24,000 (63 % busy). The cause was not isolated: the server's longest callback is 25 to 28 ms in the runs (16 to 28 on the Mac) and a 4 KiB
  synchronous write on the instance's volume takes 2.8 ms (a `dd` with `oflag=dsync`, before the runs), so slow writes inside a callback are a
  suspect, nothing more. The µs/req of the staircase steps are flat (see the table): the rate moves them by under 2 µs.
- **The Mac's same-rate pair was run later, on a quiet VM** (2026-11-23 at 19:38 to 19:51, `docker ps` empty before it, `other_containers: 0` in all six runs): `lab/steplab.sh` with the Xeon's flags
  (`--rate 7500 --vu-cap 5400`, telemetry on in both, S1-d at `APP_SOFT_CONN_LIMIT=65450`), 3 rounds, in `mac-same-rate/`. The Mac's CPU layout is its default, the Xeon's is `x86-8`: the server on one CPU in both.
- **No Mac run with the instance, and no A/A calibration on the instance.** The Mac's Docker VM is busy with other projects' containers. The factor is read against the
  Mac's own skeleton runs at 12,000 req/s with telemetry on (the S1 series' S1-a and the skeleton of each Swoole pair), a different rate from the
  Xeon's 7,500. With no A/A floor no pair is judged: the differences are read next to the skeleton's own spread on the Xeon (six runs, 53.24 to 54.42).
- **Docker's cgroup driver is `cgroupfs` on the instance.** The lab's probe reads `/sys/fs/cgroup/docker/<id>`, which Docker Desktop uses; Docker Engine
  on Ubuntu defaults to systemd's driver (`system.slice/docker-<id>.scope`), and the first staircase stopped at once with "no cgroup directory". A host
  setting (`/etc/docker/daemon.json`), no change to the lab.
- **The ephemeral ports are Ubuntu's 32768 to 60999** (28,232 an address), not the Mac VM's 55000 to 65535 (about 10,500); no `sysctl` was changed. Every
  run leaves 26,000 to 27,700 TIME_WAIT sockets on the busiest address (the idle client's) and the next starts at once: its bind retries are in the tables
  (50 in each run that follows another, 0 after a pause of a minute).
- **Telemetry on in both variants of every pair**, as in the S1 series, so the limit closes are counted; the Swoole entries ignore the variable. S1-d is
  `APP_SOFT_CONN_LIMIT=65450` (above the run's 62,000 connections: it never fires, 0 closes in every run), the only variant the step lab chose; scope 11's
  combined screen (`cache-256m` with `exclusive`) did not confirm. The reconnect pair uses 60,000, as the S1 series did.
- **Swoole entries on `8.3-apt` and `8.3-apt-tzimpel`**, their files unchanged, as in the Mac pairs; the skeleton on PHP 8.5. The JIT is PHP's x86-64 one here, the
  arm64 one on the Mac: it is part of what the factor measures, and nothing here separates it from the CPU.
- Nothing about the instance's identity is in this folder: no id, address, account or key (they are in the private run log).

## Results

<!-- BEGIN summarize -->
### The staircases: the skeleton (PHP 8.5, telemetry on, probes on), `s = 0.02`, 60,000 idle, 60 s steps, the 97 % rule

**coarse** (valid: true, other containers: 0, k6 connection errors: 0, CPU model and layout: x86-8, server cpuset 1, idle sibling 5, k6 cpuset 0,2,3,4,6,7, probe cpuset 0,4)

| Offered req/s | VUs | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|
| 4001 | 756 | 3968.5 | 99.2 % | 55.43 | 0.935 | 8.47 | pass |
| 6002 | 1134 | 5929.8 | 98.8 % | 54.36 | 5.5 | 18.37 | pass |
| 8003 | 1512 | 7780.9 | 97.2 % | 54.49 | 19.209 | 38.673 | pass |
| 10003 | 1890 | 9487.3 | 94.8 % | 53.97 | 36.984 | 73.359 | FAIL: achieved below 97 % of offered |

**fine** (valid: true, other containers: 0, k6 connection errors: 0, CPU model and layout: x86-8, server cpuset 1, idle sibling 5, k6 cpuset 0,2,3,4,6,7, probe cpuset 0,4)

| Offered req/s | VUs | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|
| 7002 | 1323 | 6872.8 | 98.2 % | 53.93 | 10.909 | 22.627 | pass |
| 7505 | 1418 | 7355.2 | 98 % | 53.8 | 13.844 | 25.49 | pass |
| 8003 | 1512 | 7806.2 | 97.5 % | 54.32 | 18.099 | 33.324 | pass |
| 8500 | 1606 | 8225.8 | 96.8 % | 53.7 | 22.967 | 44.219 | FAIL: achieved below 97 % of offered |

### The skeleton against S1-d (`APP_SOFT_CONN_LIMIT=65450`, above the run's connections), 7,500 req/s, 3 rounds, the skeleton first in each round

| Run | valid | other containers | idle held at the end | closed by the server | limit closes | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | idle bind retries | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| skeleton-1 | true | 0 | 60000 | 0 | 0 | 7395.8 | 98.5 % | 53.59 | 9.541 | 18.646 | 50 | pass |
| s1d-1 | true | 0 | 60000 | 0 | 0 | 7383.1 | 98.4 % | 53.38 | 9.977 | 20.388 | 50 | pass |
| skeleton-2 | true | 0 | 60000 | 0 | 0 | 7387.8 | 98.4 % | 53.82 | 9.124 | 20.694 | 50 | pass |
| s1d-2 | true | 0 | 60000 | 0 | 0 | 7382.2 | 98.4 % | 53.68 | 10.433 | 20.694 | 50 | pass |
| skeleton-3 | true | 0 | 60000 | 0 | 0 | 7395.3 | 98.5 % | 53.24 | 9.977 | 20.694 | 50 | pass |
| s1d-3 | true | 0 | 60000 | 0 | 0 | 7392 | 98.5 % | 53.52 | 9.977 | 21.319 | 50 | pass |

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  result
    1  skeleton       yes       7395.8      53.6     9.54    18.65     27732  pass
    1  s1d            yes       7383.1      53.4     9.98    20.39     26703  pass
    2  skeleton       yes       7387.8      53.8     9.12    20.69     26863  pass
    2  s1d            yes       7382.2      53.7    10.43    20.69     26861  pass
    3  skeleton       yes       7395.3      53.2     9.98    20.69     26867  pass
    3  s1d            yes         7392      53.5     9.98    21.32     26878  pass
tw/addr: the most TIME_WAIT sockets on one of k6's source addresses when the run started (0 when the runner did not count)

variants (us is the server's CPU per request over the plateau)
variant         valid median us        min to max   p99 ms  paired differences us     median  verdict
skeleton          3/3      53.6      53.2 to 53.8    20.69  reference                      -  reference
s1d               3/3      53.5      53.4 to 53.7    20.69  -0.2 -0.1 +0.3              -0.1  no floor: not judged: run with --floor <µs> from an A/A calibration

Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least the floor in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### The skeleton against S1-d with every request reconnecting (`APP_SOFT_CONN_LIMIT=60000`), 7,500 req/s, one round

| Run | valid | other containers | idle held at the end | closed by the server | limit closes | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | idle bind retries | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| skeleton-1 | true | 0 | 60000 | 0 | 0 | 7390.9 | 98.5 % | 53.54 | 9.261 | 20.087 | 0 | pass |
| s1d-every-1 | true | 0 | 60000 | 0 | 533307 | 7373.6 | 98.2 % | 77.23 | 10.589 | 21.319 | 50 | pass |

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  result
    1  skeleton       yes       7390.9      53.5     9.26    20.09     26870  pass
    1  s1d-every      yes       7373.6      77.2    10.59    21.32     27732  pass
tw/addr: the most TIME_WAIT sockets on one of k6's source addresses when the run started (0 when the runner did not count)

variants (us is the server's CPU per request over the plateau)
variant         valid median us        min to max   p99 ms  paired differences us     median  verdict
skeleton          1/1      53.5      53.5 to 53.5    20.09  reference                      -  reference
s1d-every         1/1      77.2      77.2 to 77.2    21.32  +23.7                      +23.7  no floor: not judged: run with --floor <µs> from an A/A calibration

Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least the floor in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### php-swoole-mattsplat (unchanged, PHP 8.3 from apt) against the skeleton, 7,500 req/s, one round

| Run | valid | other containers | idle held at the end | closed by the server | limit closes | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | idle bind retries | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| skeleton-1 | true | 0 | 60000 | 0 | 0 | 7394.2 | 98.5 % | 54.42 | 9.541 | 19.79 | 0 | pass |
| php-swoole-mattsplat-1 | true | 0 | 60000 | 0 | - | 7384.7 | 98.4 % | 57.69 | 11.408 | 21.639 | 50 | pass |

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  result
    1  skeleton       yes       7394.2      54.4     9.54    19.79         0  pass
    1  php-swoole-mattsplat yes       7384.7      57.7    11.41    21.64     27732  pass
tw/addr: the most TIME_WAIT sockets on one of k6's source addresses when the run started (0 when the runner did not count)

variants (us is the server's CPU per request over the plateau)
variant         valid median us        min to max   p99 ms  paired differences us     median  verdict
skeleton          1/1      54.4      54.4 to 54.4    19.79  reference                      -  reference
php-swoole-mattsplat    1/1      57.7      57.7 to 57.7    21.64  +3.3                        +3.3  no floor: not judged: run with --floor <µs> from an A/A calibration

Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least the floor in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### php-swoole-tzimpel (unchanged, PHP 8.3 from apt, his Swoole patch) against the skeleton, 7,500 req/s, one round

| Run | valid | other containers | idle held at the end | closed by the server | limit closes | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | idle bind retries | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| skeleton-1 | true | 0 | 60000 | 0 | 0 | 7390.4 | 98.5 % | 53.45 | 10.589 | 20.388 | 0 | pass |
| php-swoole-tzimpel-1 | true | 0 | 60000 | 0 | - | 7409 | 98.7 % | 67.27 | 5.26 | 18.099 | 50 | pass |

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  result
    1  skeleton       yes       7390.4      53.5    10.59    20.39     26872  pass
    1  php-swoole-tzimpel yes         7409      67.3     5.26     18.1     27732  pass
tw/addr: the most TIME_WAIT sockets on one of k6's source addresses when the run started (0 when the runner did not count)

variants (us is the server's CPU per request over the plateau)
variant         valid median us        min to max   p99 ms  paired differences us     median  verdict
skeleton          1/1      53.5      53.5 to 53.5    20.39  reference                      -  reference
php-swoole-tzimpel    1/1      67.3      67.3 to 67.3     18.1  +13.8                      +13.8  no floor: not judged: run with --floor <µs> from an A/A calibration

Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least the floor in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### The x86 factor: the Xeon's skeleton over the Mac's (µs of server CPU per request)

| Mac reference | Mac µs/req (median) | Mac runs | factor (Xeon median over Mac median) |
|---|---|---|---|
| S1 series, S1-a, 12,000 req/s | 27.95 | 5 runs | 1.92 |
| skeleton of the mattsplat pair, 12,000 req/s | 27.94 | 1 run | 1.92 |
| skeleton of the tzimpel pair, 12,000 req/s | 28.34 | 1 run | 1.89 |

The Xeon's skeleton at 7,500 req/s: median **53.57 µs/req** over 6 counted runs (53.59, 53.82, 53.24, 53.54, 54.42, 53.45; min 53.24, max 54.42). The Mac's reference runs are at 12,000 req/s (the Xeon cannot hold that rate, so the rates differ); the Xeon's µs/req in the staircases (probes on) run from 53.7 to 55.4 over rates from 4,000 to 10,000 req/s, so the rate moves them by under 2 µs: the factor is read as rate-free here, not measured at one rate.

Factor against the S1 series: 1.92. The bench estimate of the skeleton (prediction 18) was 88 µs/req on the bench's VM; the Xeon reads 53.6 µs/req, 60.9 % of it.

### The Mac at the Xeon's rate: the skeleton against S1-d (`APP_SOFT_CONN_LIMIT=65450`), 7,500 req/s, 3 rounds, the skeleton first in each round, the Xeon's flags

| Run | valid | other containers | idle held at the end | closed by the server | limit closes | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | idle bind retries | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| skeleton-1 | true | 0 | 60000 | 0 | 0 | 7449.1 | 99.3 % | 34.48 | 1.187 | 5.105 | 200 | pass |
| s1d-1 | true | 0 | 60000 | 0 | 0 | 7452.9 | 99.3 % | 33.68 | 0.855 | 3.905 | 150 | pass |
| skeleton-2 | true | 0 | 60000 | 0 | 0 | 7451.4 | 99.3 % | 33.34 | 0.771 | 4.334 | 150 | pass |
| s1d-2 | true | 0 | 60000 | 0 | 0 | 7457.4 | 99.4 % | 33.15 | 0.684 | 3.735 | 150 | pass |
| skeleton-3 | true | 0 | 60000 | 0 | 0 | 7460.3 | 99.4 % | 33.27 | 0.782 | 3.847 | 150 | pass |
| s1d-3 | true | 0 | 60000 | 0 | 0 | 7444.2 | 99.2 % | 33 | 1.038 | 4.532 | 150 | pass |

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  result
    1  skeleton       yes       7449.1      34.5     1.19     5.11     10036  pass
    1  s1d            yes       7452.9      33.7     0.86     3.91      7022  pass
    2  skeleton       yes       7451.4      33.3     0.77     4.33      9199  pass
    2  s1d            yes       7457.4      33.1     0.68     3.74      9149  pass
    3  skeleton       yes       7460.3      33.3     0.78     3.85      9174  pass
    3  s1d            yes       7444.2        33     1.04     4.53      9144  pass
tw/addr: the most TIME_WAIT sockets on one of k6's source addresses when the run started (0 when the runner did not count)

variants (us is the server's CPU per request over the plateau)
variant         valid median us        min to max   p99 ms  paired differences us     median  verdict
skeleton          3/3      33.3      33.3 to 34.5     4.33  reference                      -  reference
s1d               3/3      33.1        33 to 33.7     3.91  -0.8 -0.2 -0.3              -0.3  no floor: not judged: run with --floor <µs> from an A/A calibration

Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least the floor in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### The x86 factor at the same rate: the Xeon's skeleton over the Mac's, both at 7,500 req/s with telemetry on

| Reading | Xeon µs/req | Mac µs/req | factor |
|---|---|---|---|
| median of the skeleton runs (Xeon: its 6 counted runs; Mac: its 3) | 53.57 | 33.34 | 1.61 |
| the 3 skeleton runs of the pairs, by round | 53.59, 53.82, 53.24 | 34.48, 33.34, 33.27 | 1.55, 1.61, 1.6 |

The 12,000-based factor above is 1.92 (the Mac's S1-a, 27.95 µs/req at 12,000 req/s); at 7,500 req/s the Mac's own skeleton costs 33.34 µs/req, 19.3 % more than at 12,000, so a rate-free factor was not right on the Mac side: the Mac's µs/req fall with the rate (impression: the CPU the loop spends on waking up for few requests counts for more per request), the Xeon's do not (53.7 to 55.4 over 4,000 to 10,000). Both factors are kept; the same-rate one is the measured one.

### The reconnect's price on the Xeon and S1-d's cost at the bench's sizes

S1-d with every request reconnecting: the server sent 533307 `Connection: close` responses; k6 made 484385 requests, plus the warm-up's nominal 48750 (its rate times its plateau plus half its 10 s ramp; the server counts its whole life): a difference of 172, 0.03 % of the closes, so every request reconnected.

One pair: the skeleton 53.54, S1-d with every request reconnecting 77.23 µs/req: **one reconnect costs 23.69 µs on the Xeon** (44.2 % of the skeleton's median). The Mac's was 6.62 µs (median of 5 pairs, S1 series): 3.58 times.

S1-d with the soft limit L = 64,000 never closes an idle connection, so a share 1 - L / N of the requests reconnect (the S1 series' model). Added µs/req = share times the cost of one reconnect; the share of the skeleton is read against the Xeon's median above.

| Users N | share that reconnect | added µs/req on the Xeon | as a share of the Xeon skeleton | the Mac's added µs/req (6.62) | above 15 %? |
|---|---|---|---|---|---|
| 100000 | 36 % | 8.53 | 15.9 % | 2.38 | yes |
| 150000 | 57.3 % | 13.58 | 25.4 % | 3.8 | yes |
| 200000 | 68 % | 16.11 | 30.1 % | 4.5 | yes |

### The Swoole entries on the Xeon against the Mac

| Entry | Xeon µs/req (its pair) | its pair's skeleton on the Xeon | entry over skeleton | Mac µs/req (scope-13 pair) | Xeon over Mac | bench µs/req (leaderboard) | bench over Xeon |
|---|---|---|---|---|---|---|---|
| php-swoole-mattsplat | 57.69 | 54.42 | 1.06 | 29.2 | 1.98 | 94 | 1.63 |
| php-swoole-tzimpel | 67.27 | 53.45 | 1.26 | 32.77 | 2.05 | 101 | 1.5 |

Through the Xeon, the leaderboard's 94 and 101 µs/req are 1.63 and 1.5 times the Xeon's entries (mean 1.57). The skeleton's Xeon median 53.57 µs/req times that mean is **83.9 µs/req on the bench** (87.3 and 80.4 with each factor alone), against 88 through the Mac (prediction 18, scope 13's factors).
<!-- END summarize -->

## The reading

- **At the same rate the x86 factor is 1.61, not 1.92.** The Mac's skeleton at 7,500 req/s (the Xeon's rate, the same flags, `mac-same-rate/`) costs 33.34 µs/req (34.48, 33.34, 33.27, a spread of 1.2), against the
  Xeon's 53.57: **1.61** (1.55, 1.61 and 1.60 round by round). The 1.92 below divides by the Mac's 27.95 at 12,000 req/s, and the Mac's cost is not rate-free: it is 19.3 % higher at 7,500 req/s
  (the Xeon's staircase steps are flat from 4,000 to 10,000 req/s, 53.7 to 55.4, which is what made a rate-free factor look right). Both factors are kept, the 12,000-based one and the same-rate one; the same-rate one is the measured
  one for a Xeon that cannot hold 12,000. S1-d, never firing, on the Mac at this rate: 33.68, 33.15 and 33.00 against the skeleton's 34.48, 33.34 and 33.27 (paired differences -0.80, -0.19, -0.27), 0 limit closes: no
  cost, as on the Xeon (no floor at this rate, so no verdict). The reconnect's 3.58 times (23.69 on the Xeon against the Mac's 6.62) compares a Xeon at 7,500 with a Mac at the S1 series' rate; it was not remeasured at the same rate
  (if the Mac's reconnect cost has the same 19 % rise at 7,500, the ratio would be nearer 3.0: an impression, not a run).
- **The x86 factor is 1.92 against the Mac at 12,000 req/s.** The skeleton costs **53.57 µs/req** on the Xeon (median of six runs, 53.24 to 54.42, at 7,500 req/s with 60,000 idle) against the
  Mac's 27.95 (S1-a, five runs) and 27.94 and 28.34 (the skeletons of the Swoole pairs): 1.92, 1.92 and 1.89. The rates differ (7,500 against 12,000); the
  Xeon's µs/req do not move with the rate in the staircase, so the factor was read as rate-free, but the Mac's do move with it (the first bullet): the same-rate
  factor is 1.61, from the Mac pair run afterwards.
- **S1-d that never fires costs nothing the Xeon sees:** 53.4, 53.7 and 53.5 against the skeleton's 53.6, 53.8 and 53.2 (paired differences -0.2, -0.1,
  +0.3), 0 limit closes. No floor, so no verdict; the differences are inside the skeleton's own 0.6 µs spread.
- **One reconnect costs 23.69 µs on the Xeon**, 3.58 times the Mac's 6.62 (one pair: 53.54 against 77.23 µs/req, every request reconnecting, the close count
  within 0.03 % of k6's requests plus the nominal warm-up). That is 44 % of a request. Why it is 3.6 times and the request itself 1.9 times was not looked at:
  most of a reconnect is the kernel's TCP work, so the instance's kernel (7.0) and its mitigations are the first suspects (impression).
- **S1-d at the bench's sizes, with the Xeon's price** (the S1 series' model, a share `1 - 64,000 / N` of the requests reconnect): **+8.53 µs/req at 100,000
  users (15.9 % of the Xeon's skeleton), +13.58 at 150,000 (25.4 %), +16.11 at 200,000 (30.1 %)**, against the Mac's +2.38, +3.8 and +4.5 (8.5, 13.6 and 16.1 %).
  The Mac's 13.6 % at 150,000 stayed under the 15 % line that builds S1-b; the Xeon's 25.4 % is over it. The line is crossed with margin: the reconnect would have
  to cost under 14.0 µs (instead of 23.69) to give 15 % at 150,000. It is one pair, though, and the model is the S1 series', not a run at 150,000 users.
- **The Swoole entries on the Xeon:** php-swoole-mattsplat 57.69 µs/req against its pair's skeleton 54.42 (+3.3, +6 %; the Mac's +1.3, +4.5 %); php-swoole-tzimpel
  67.27 against 53.45 (+13.8, +26 %; the Mac's +4.4, +15.6 %). Xeon over Mac: 1.98 and 2.05 (the skeleton 1.92). The order of the three is the Mac's, and
  tzimpel's gap to the skeleton is wider on x86; one pair each, no floor.
- **The bench through the Xeon:** the leaderboard's 94 and 101 µs/req are 1.63 and 1.50 times the Xeon's entries, so the bench's VM is about 1.5 to 1.6 times
  slower per request than this core with its sibling idle (impression for why: a shared vCPU, a different CPU generation). The skeleton's Xeon median times
  the mean (1.57) gives **83.9 µs/req on the bench (80.4 to 87.3)**, against 88 through the Mac: the two routes agree within 5 %. At that cost one CPU gives
  about 11,900 req/s, or 112,000 users at 9.45 users per request a second (arithmetic at 100 % of the CPU; a real run passes the 97 % rule well before).

## Did the predictions hold?

| # | Verdict | Measured |
|---|---|---|
| 13 | **Half.** | Held on the 12,000-based factor (1.92, 1.89 to 1.92 by Mac reference, inside 1.8 to 3). Missed below at the same rate: 1.61 (the Xeon's 53.57 over the Mac's 33.34 at 7,500 req/s), under 1.8. |
| 17 | **Half, the factor now below its range.** | The factor part, 1.7 to 2.7: 1.92 held on the 12,000 basis, 1.61 missed below at the same rate. The bench estimate of 45 to 75 µs/req stays missed above (scope 13 already had 88; the Xeon route gives 83.9). |
| 18 | **Missed, below.** | 1.92 times the Mac at 12,000 req/s and 1.61 at the same rate, not 2.9 to 3.4; the skeleton 53.57 µs/req on the Xeon, not about 88 (that is the bench's VM, 1.5 to 1.6 times slower than this core, not the Xeon). |

## Follow-ups

- A reconnect pair on the Mac at 7,500 req/s (the S1-d variant with `APP_SOFT_CONN_LIMIT=60000`), to compare the reconnect's 3.58 times at one rate: the same-rate pair did the skeleton and the S1-d that never fires, not the reconnect.
- The S1-b question (build or not) now depends on which machine the 15 % line is read on: the Mac says 13.6 % at 150,000 users, the Xeon 25.4 %. A second reconnect
  pair on the Xeon, or a run at the real user count, would tighten the 23.69 µs.
- Why the 97 % rule fails on the Xeon at 43 % CPU (see "What differed"): the longest callbacks and the volume's write latency were not separated.
