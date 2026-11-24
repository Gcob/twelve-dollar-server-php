# S1-b and the reconnect on x86

Phase 5b's x86 session, on one AWS `c5.2xlarge` (Intel Xeon, x86-64), in the lab's realistic mode with the Mac's shape: `s = 0.02`, 60,000 idle
connections, the server on one vCPU with its hyperthread sibling idle, 2 GiB, PHP 8.5, 7,500 req/s (the rate 5a's staircase found the Xeon holds).
It prices what the bench's sizes (100,000 and 150,000 users) need: the cost of one reconnect a second time, the cost of two processes on one port
(S1-b) against one (S1-a), and from them the choice between S1-d (a soft limit that closes a share of the connections) and S1-b. These are x86 numbers
on a shared cloud host, not a score. This file is written in two steps: the predictions first (before any run), then the runs and the reading.

## Predictions (D5)

Copied unchanged from the phase's plan, section "Predictions (D5)": 12 is judged here; 13 is not applicable (5b chose no CPU variant, so its
configuration is 5a's and there is no x86 pair of the two). The others belong to other folders of the phase.

Written by the project manager on 2026-11-23 at 23:24, before any phase 5b measurement. Arm64, Docker Desktop on an
M3 Pro, quiet VM, PHP 8.5, the reference `APP_PRAGMAS=mmap-off` (25.0 to 25.6 µs/req at 24,000 req/s in 5a's pairs),
unless a line says otherwise.

12. **x86, S1:** the second reconnect pair within 10 % of 23.69 µs; S1-b's 2 workers cost +5 to +15 % per request on
    the Xeon, less than S1-d's +25 % at 150,000 users: S1-b chosen for the bench's sizes.
13. **x86, the configuration:** 5b's 6 to 15 % under 5a's on the Xeon; the bench estimate 71 to 80 µs/req.
    (Not applicable: 5b chose no CPU variant, its configuration is 5a's.)

## Plan of the runs

One instance, three calls, from the code of the branch's commit `de2a596` (sent with `git archive`, so no tracked file was edited while they ran)
and the challenge's repository cloned at the commit the seed was built from. Every call is `lab/steplab.sh --image 8.5 --rate 7500 --think-scale 0.02 --idle 60000
--seconds 60 --vu-cap 5400` with `LAB_CPU_LAYOUT=x86-8`, the warm-up of a tenth of the rate for 60 s, the alternating order, both variants with
`APP_PRAGMAS=mmap-off,APP_TELEMETRY=1` (the phase's reference, and telemetry so the closes are counted), and `--floor-from` the x86 pairs of 5a's calibration:

1. **`reconnect/`, the second reconnect pair:** `s1a` against `s1d-every` (`APP_SOFT_CONN_LIMIT=60000`, equal to the idle count, so every request of k6
   reconnects), one pair. The server's `Connection: close` count must be about k6's requests plus the warm-up's.
2. **`s1b-7500/`, S1-b against S1-a:** `s1a` against `s1b` (the same plus `APP_WORKERS=2`), `--ext sockets --ext event --ext pcntl` on both sides (so the only
   difference is the second process), 3 pairs. The server's own log was followed from outside (`docker logs -f`, one file a run, from before the series started) and each process's `requests`
   summed into `s1b-7500/served.json`: both pids must have served in every S1-b run.
3. **`s1b-7500/memory/`:** one run of each variant after the series with the sampler on (`lab/realistic.sh --hold 7500,60`, the same flags, no `--no-series`):
   `memory.current` and `Pss_Anon` peaks. The step lab's runs keep no sampler, so memory is one run each, not a pair.
4. **The floor.** The only x86 near-A/A is 5a's skeleton against S1-d that never fired (3 pairs, fixed order): floor **0.386 µs/req**. The Mac's A/A at 24,000 req/s in
   the alternating order (0.864) is the cautious reading, and each verdict below is printed against both. No A/A was run on the instance: S1-b's expected gap is several µs.
5. **`summarize.sh`** regenerates every table below from the JSON files, `s1b-7500/served.json`, 5a's `x86-calibration` folder and 5b's Mac A/A.

Between the calls: 63 s (reconnect to S1-b) and 5 s (S1-b to the memory runs, which have their own 90 s pause before each run).
No `lab/check.sh` and no image build ran during a call. Raw diagnostics (instance and group identifiers, addresses, the key) are in the factory's private run log, not here.

## The machine

| | |
|---|---|
| Instance | AWS `c5.2xlarge`, `ca-central-1`, Ubuntu 24.04 (kernel 7.0 aws), Docker Engine 29.10 (Docker's apt repository), 8 vCPUs, 15.6 GiB |
| CPU model (`/proc/cpuinfo`) | Intel(R) Xeon(R) Platinum 8275CL CPU @ 3.00 GHz |
| Layout (`LAB_CPU_LAYOUT=x86-8`) | siblings read on the instance: `0,4` `1,5` `2,6` `3,7`. Server on vCPU `1`, its sibling `5` idle, k6, the idle client and the aggregator on `0,2,3,4,6,7`, the probe on `0,4` |
| Limits | the lab's: 1 CPU, 2 GiB, no swap, 65,535 fds a process; host network |
| Docker's cgroup driver | `cgroupfs` (the lab's probe reads `/sys/fs/cgroup/docker/<id>`), set by the bootstrap script as in 5a |
| Built there | `php-lab:8.5` (232 s), the seed |
| Lived | 43 minutes, one instance, nothing else on it (`other_containers: 0` in every run below) |

## What differed from the plan of the runs

- **No series driver:** the three calls were typed one after the other, not run by `lab/stages.sh` (the instance has no `stages.json`); each call's command line is in
  its JSON (`steplab.command`) and its `steplab.log`. The gap between calls was kept at 60 s or more.
- **The memory runs are outside the pairs** (above): one run each, `realistic.sh` directly, a 90 s pause before each (it has no TIME_WAIT gate). Their µs/req (50.23 and 58.13)
  are read only for memory.
- **Telemetry on in both variants of every pair**, as in the S1 series, so the closes are counted; the extra cost is in both sides.
- **The reconnect pair's reference is `mmap-off`** (50.40 µs/req), 5a's was the bare skeleton (53.54): the reconnect's price is the difference of a pair, so the two prices compare, the two references do not.
- **The Mac's reconnect and S1-b numbers** quoted below are the ones of `lab/results/2026-11-24-cpu-steps-5b` (5.91 µs a reconnect at 7,500 req/s; S1-b +2.14 µs at 12,000 req/s).

## Results

<!-- BEGIN summarize -->
### The second reconnect pair (S1-a against S1-d with every request reconnecting, `APP_SOFT_CONN_LIMIT=60000`, `APP_PRAGMAS=mmap-off`, telemetry on, 7,500 req/s, one round)

| Run | position in its round | valid | other containers | idle held at the end | closed by the server | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|
| s1d-every-1 | 1 | true | 0 | 60000 | 0 | 7372.3 | 98.2 % | 73.84 | 10.59 | 20.69 | pass |
| s1a-1 | 2 | true | 0 | 60000 | 0 | 7381.3 | 98.4 % | 50.4 | 10.91 | 21.96 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |
|---|---|---|---|---|---|---|---|
| s1d-every-1 | 2.13 | 3.06 | 52.98 % | 0.00 % | 1.048 | 0 | 0 |
| s1a-1 | 1.26 | 1.46 | 35.48 % | 0.00 % | 0.995 | 4549 | 51 |

S1-d with every request reconnecting: the server sent 533314 `Connection: close` responses; k6 made 484222 requests, plus the warm-up's nominal 48750 (its rate times its plateau plus half its 10 s ramp; the server counts its whole life): a difference of 342, 0.06 % of the closes, so every request reconnected.

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  s1d-every      yes       7372.3      73.8    10.59    20.69         0   3.06     1.05  pass
    1  s1a            yes       7381.3      50.4    10.91    21.96      4549   1.46        1  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
s1a               1/1      0      50.4      50.4 to 50.4    21.96  reference                      -  reference
s1d-every         1/1      0      73.8      73.8 to 73.8    20.69  +23.4                      +23.4  screen: not better in one pair

Floor: 0.386 us, from lab/results/2026-11-23-x86-calibration/pairs: |median -0.142| + interquartile range 0.244 of 3 paired differences (quartiles by linear interpolation, inclusive)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.386 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### The reconnect's price on the Xeon: this pair against 5a's

| Pair | reference µs/req | every request reconnecting µs/req | one reconnect costs µs | against 5a's |
|---|---|---|---|---|
| 5a, the skeleton (no `mmap-off`) | 53.54 | 77.23 | 23.69 | - |
| this folder, S1-a (`mmap-off`) | 50.4 | 73.84 | 23.44 | -1.05 % (within 10 %) |

Mean of the two pairs: **23.56 µs a reconnect** (the price the S1 rule below uses). The two pairs are one pair each: a screen apiece (floor 0.386 µs/req), their gap is -0.25 µs.

### S1-b against S1-a at 7,500 req/s (`APP_WORKERS=2` against one process, `APP_PRAGMAS=mmap-off`, telemetry on, `s = 0.02`, 60,000 idle, 3 pairs)

| Run | position in its round | valid | other containers | idle held at the end | closed by the server | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|
| s1b-1 | 1 | true | 0 | 60000 | 0 | 7399.5 | 98.6 % | 57.75 | 6.98 | 18.37 | pass |
| s1a-1 | 2 | true | 0 | 60000 | 0 | 7398.4 | 98.6 % | 50.31 | 9.26 | 19.5 | pass |
| s1a-2 | 1 | true | 0 | 60000 | 0 | 7386 | 98.4 % | 50.77 | 10.28 | 19.79 | pass |
| s1b-2 | 2 | true | 0 | 60000 | 0 | 7411.9 | 98.8 % | 57.06 | 6.01 | 17.05 | pass |
| s1b-3 | 1 | true | 0 | 60000 | 0 | 7389.8 | 98.5 % | 57.92 | 8.1 | 20.39 | pass |
| s1a-3 | 2 | true | 0 | 60000 | 0 | 7388.9 | 98.5 % | 50.13 | 9.98 | 20.09 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |
|---|---|---|---|---|---|---|---|
| s1b-1 | 0.50 | 1.84 | 37.89 % | 0.00 % | 1.298 | 0 | 0 |
| s1a-1 | 2.37 | 2.43 | 35.74 % | 0.00 % | 0.978 | 27732 | 0 |
| s1a-2 | 3.15 | 2.07 | 36.18 % | 0.00 % | 1.106 | 26857 | 0 |
| s1b-2 | 2.36 | 2.03 | 35.98 % | 0.00 % | 1.052 | 26854 | 0 |
| s1b-3 | 3.10 | 2.43 | 37.46 % | 0.00 % | 1.049 | 26863 | 0 |
| s1a-3 | 2.02 | 1.69 | 35.58 % | 0.00 % | 0.978 | 26856 | 0 |

Over the 6 runs: load on the plateau 1.69 to 2.43, the VM's CPU busy 35.58 to 37.89 %, steal 0.00 to 0.00 %, `fsync` 0.978 to 1.298 ms.

The pairs (S1-b minus S1-a, the order alternates: round 1 runs S1-b first, round 2 S1-a first, round 3 S1-b first):

| Round | order | S1-a µs/req | S1-b µs/req | S1-b minus S1-a µs | as a share of S1-a |
|---|---|---|---|---|---|
| 1 | s1b then s1a | 50.31 | 57.75 | +7.44 | +14.78 % |
| 2 | s1a then s1b | 50.77 | 57.06 | +6.29 | +12.39 % |
| 3 | s1b then s1a | 50.13 | 57.92 | +7.8 | +15.55 % |

Medians: S1-a 50.31 µs/req, S1-b 57.75 µs/req. Paired differences +7.44, +6.29, +7.8, **median +7.44 µs/req, +14.78 % of the median S1-a**. Achieved over offered: 98.4 % to 98.8 %; runs under the 97 % rule: 0 of 6.

Both processes served, from the server's own log (the telemetry line each process prints every second, `requests` summed over the run's whole life: the warm-up, the plateau and one request per idle connection):

| Run | processes | requests counted by each process | seconds in which each counted a request | share of the first |
|---|---|---|---|---|
| s1b-1 | 2 | 299393 and 295832 | 167 and 168 | 50.3 % |
| s1b-2 | 2 | 294272 and 301473 | 168 and 167 | 49.4 % |
| s1b-3 | 2 | 299023 and 295603 | 168 and 167 | 50.3 % |
| memory/s1b | 2 | 303344 and 289453 | 169 and 170 | 51.2 % |

Memory of one run of each variant, with the sampler on (`--no-series` off; 7,500 req/s for 60 s after the warm-up, 60,000 idle; not a pair, not counted):

| Variant | valid | achieved req/s | µs CPU/req | memory.current peak MiB | Pss_Anon peak MiB | file descriptors peak | processes |
|---|---|---|---|---|---|---|---|
| s1a | true | 7348.4 | 50.23 | 588.9 | 102.2 | 61430 | 1 |
| s1b | true | 7364.6 | 58.13 | 582.7 | 94.9 | 61453 | 2 |

The same series against the Xeon's floor (5a's skeleton against S1-d that never fired, the only x86 near-A/A):

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  s1b            yes       7399.5      57.7     6.98    18.37         0   1.84      1.3  pass
    1  s1a            yes       7398.4      50.3     9.26     19.5     27732   2.43     0.98  pass
    2  s1a            yes         7386      50.8    10.28    19.79     26857   2.07     1.11  pass
    2  s1b            yes       7411.9      57.1     6.01    17.05     26854   2.03     1.05  pass
    3  s1b            yes       7389.8      57.9      8.1    20.39     26863   2.43     1.05  pass
    3  s1a            yes       7388.9      50.1     9.98    20.09     26856   1.69     0.98  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
s1a               3/3      0      50.3      50.1 to 50.8    19.79  reference                      -  reference
s1b               3/3      0      57.7      57.1 to 57.9    18.37  +7.4 +6.3 +7.8              +7.4  beyond the noise

Floor: 0.386 us, from lab/results/2026-11-23-x86-calibration/pairs: |median -0.142| + interquartile range 0.244 of 3 paired differences (quartiles by linear interpolation, inclusive)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.386 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

And against the Mac's floor (the A/A at 24,000 req/s of 5b), the cautious reading:

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  s1b            yes       7399.5      57.7     6.98    18.37         0   1.84      1.3  pass
    1  s1a            yes       7398.4      50.3     9.26     19.5     27732   2.43     0.98  pass
    2  s1a            yes         7386      50.8    10.28    19.79     26857   2.07     1.11  pass
    2  s1b            yes       7411.9      57.1     6.01    17.05     26854   2.03     1.05  pass
    3  s1b            yes       7389.8      57.9      8.1    20.39     26863   2.43     1.05  pass
    3  s1a            yes       7388.9      50.1     9.98    20.09     26856   1.69     0.98  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
s1a               3/3      0      50.3      50.1 to 50.8    19.79  reference                      -  reference
s1b               3/3      0      57.7      57.1 to 57.9    18.37  +7.4 +6.3 +7.8              +7.4  beyond the noise

Floor: 0.864 us, from lab/results/2026-11-24-cpu-steps-5b/aa-24000: |median 0.083| + interquartile range 0.78 of 5 paired differences (quartiles by linear interpolation, inclusive)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.864 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### The S1 rule at the bench's sizes (soft limit 64000 a process; a share 1 - 64000 / N of the requests reconnect when a process holds N users)

The reconnect price is 23.56 µs (the mean of the two Xeon pairs), S1-a costs 50.31 µs/req (the median of the series' S1-a runs), S1-b with 2 processes adds +7.44 µs/req measured (14.8 % of S1-a).

- **S1-d:** one process holds all N users, so it adds `share(N) × price`.
- **S1-b, 2 processes:** the kernel splits the users about in half, so each holds N / 2; it adds the measured 7.44 µs, and a share `1 - 64000 / (N / 2)` of the requests reconnect when N / 2 is over 64000 (S1-d in each process).
- **S1-b, 3 processes (a projection, not measured):** each extra process adds the measured 7.44 µs, so 3 processes add 14.87 µs; N / 3 stays under 64000 up to 192000 users, so no reconnect.

| Users N | S1-d adds | S1-b with 2 processes adds | S1-b with 3 processes adds (projection) |
|---|---|---|---|
| 100000 | 8.48 µs (16.9 % of S1-a) | 7.44 µs (14.8 % of S1-a) | 14.87 µs (29.6 % of S1-a) |
| 150000 | 13.51 µs (26.9 % of S1-a) | 10.89 µs (21.7 % of S1-a) | 14.87 µs (29.6 % of S1-a) |

At 100000 users S1-b with 2 processes is cheaper than S1-d by 1.05 µs.
At 150000 users S1-b with 2 processes is cheaper than S1-d by 2.62 µs.

S1-d adds 26.9 % at 150,000 users: over the 15 % line.

S1-b break-even against S1-d: the two add the same at a share of 31.6 % of requests reconnecting, that is N = 93518 users.

### Memory at 150,000 users on a 2048 MiB box (from the memory runs above and a connection's 6.67 KiB)

Each variant's `memory.current` peak with 60,000 idle: S1-a 588.9 MiB (Pss_Anon 102.2), S1-b 582.7 MiB (Pss_Anon 94.9); S1-b minus S1-a -6.21 MiB (one run each, not a pair). 90,000 more connections at 6.67 KiB are 586.2 MiB.

| At 150,000 users | memory.current MiB | of the 2048 MiB box |
|---|---|---|
| S1-d, 1 process | 1175.2 | 57.4 % |
| S1-b, 2 processes | 1169 | 57.1 % |
| S1-b, 3 processes (a projection: a process is counted as the extra memory S1-b measured over S1-a when that is positive, 0 MiB here) | 1169 | 57.1 % |

### The bench estimate (S1-a's Xeon µs/req times 1.57, 5a's Xeon-to-bench factor)

S1-a on the Xeon: 50.31 µs/req (median of the 4 S1-a runs of this folder: 50.36). Times 1.57: **79 µs/req on the bench** (79.1 with every S1-a run), against 5a's 83.9 for the skeleton (no `mmap-off`).

With the chosen S1 (S1-b, 2 processes, the soft limit in each) on top of S1-a, through the same factor: 90.7 µs/req at 100,000 users (+7.44 µs added) and 96.1 µs/req at 150,000 users (+10.89 µs added).
<!-- END summarize -->

## The reading

- **The reconnect: 23.44 µs, 1.05 % under 5a's 23.69, so within the 10 %.** This pair (S1-a 50.40, every request reconnecting 73.84) and 5a's (53.54 and 77.23) give a mean of **23.56 µs
  a reconnect**. The close count agrees: 533,314 `Connection: close` responses against k6's 484,222 requests plus the warm-up's nominal 48,750, 342 apart (0.06 %): every request reconnected.
  The two pairs differ by 0.25 µs, two thirds of the 0.386 floor: the price is stable across the two references (with and without `mmap-off`). On the Mac at the same rate a reconnect is 5.91 µs, so the Xeon pays 4.0 times.
- **S1-b's cost on the Xeon: +7.44 µs a request, +14.8 % of S1-a** (pairs +7.44, +6.29, +7.80, that is +14.8, +12.4 and +15.6 %; S1-a 50.31, S1-b 57.75). Every pair has the same sign and the smallest
  (6.29) is 16 times the Xeon floor (0.386) and 7.3 times the Mac's cautious one (0.864): "beyond the noise" on both readings. On the Mac the same switch costs +2.14 µs (+8.6 %): the Xeon pays 3.5 times in µs and 1.7 times in share. Both processes served
  in every S1-b run (49.4 to 50.3 % of the requests in the first process; 51.2 % in the memory run).
- **Memory: S1-b holds no more than S1-a.** `memory.current` peak 582.7 MiB against 588.9 MiB, `Pss_Anon` 94.9 against 102.2 MiB, file descriptors 61,453 against 61,430, with 60,000 idle connections (one run each, not a
  pair: the 6 MiB difference is not read as a saving). The second process's own memory (its SQLite cache, its loop) is under the run-to-run difference; the kernel's socket memory is the same total, and the database's page cache is the kernel's, shared by both processes.
- **The S1 rule** (the tables above, `1 - 64,000 / N` of the requests reconnect when a process holds N users, price 23.56 µs):
  - **100,000 users:** S1-d adds 8.48 µs (16.9 % of S1-a); S1-b with 2 processes adds 7.44 µs (14.8 %), each process holding 50,000 users, under its soft limit, so no reconnect. S1-b is cheaper by 1.05 µs.
  - **150,000 users:** S1-d adds 13.51 µs (26.9 %). S1-b with 2 processes, each holding 75,000 users and each with the soft limit (so 14.7 % of the requests reconnect), adds 7.44 + 3.45 = 10.89 µs (21.7 %): cheaper by 2.62 µs.
    Three processes would hold 50,000 each and need no soft limit, but **that is a projection**, not a measurement: each extra process is counted as the measured 7.44 µs, so 14.87 µs (29.6 %), dearer than two processes with the soft limit. It stays a projection because
    the cost of a third process was not measured, and it could be less than the second's.
  - S1-b and S1-d add the same at N = 93,518 users (a share of 31.6 % of the requests reconnecting); S1-d is cheaper below it, S1-b above.
  - **S1-d adds more than 15 % at 150,000 users (26.9 %), so it does not stay.** S1-b with 2 processes adds fewer µs at both sizes, so it is chosen; it still adds 21.7 % at 150,000 users, over the 15 % line, so the io_uring ring is not made unnecessary by this, but the rule's trigger for asking about it (S1-b dearer than S1-d at both sizes) did not fire.
- **Memory at 150,000 users on the 2 GiB box:** about 1,175 MiB for S1-d and 1,169 MiB for S1-b (57 % of the box): the 60,000-connection runs' `memory.current` plus 90,000 more connections at 6.67 KiB (5a's DIY figure: 1.48 KiB of the process's Pss and 5.19 KiB of kernel memory).
  The two are within 1 %: the second process costs no measurable memory, so memory does not separate them; neither is near the box's limit. This is an extrapolation from the 60,000-connection runs, not a measurement at 150,000.
- **The caveats of the choice.** (1) The margin at 100,000 users is 1.05 µs (2.1 % of S1-a): it rests on a reconnect price from two pairs and an S1-b cost from three, so "S1-b is cheaper at 100,000" is a close call, a tie in practice, and it grows with N (2.62 µs at 150,000).
  (2) The price of a reconnect with two processes is assumed to be the one measured with one; (3) 150,000 users in two processes is a model: each process's soft limit closes a connection after a response when it holds more than 64,000, as S1-d does in one process in 5a's series, and the kernel's split of the users was
  50.3 % and 49.4 % in the runs here (not forced).
- **The bench estimate:** S1-a's 50.31 µs/req on the Xeon times 1.57 is **79.0 µs/req on the bench** (79.1 with the four S1-a runs), against 5a's 83.9 for the skeleton without `mmap-off` (-6 %). With the chosen S1 on top: 90.7 µs/req at 100,000 users and 96.1 at 150,000. The factor 1.57 comes from the two Swoole entries (the leaderboard's 94 and 101 µs over the Xeon's 57.7 and 67.3), not from a reconnecting server: those two lines are an estimate, not a prediction of the bench's score.

## Did the predictions hold?

12 is the one this folder judges; 13 is not applicable.

12. **Held on all three parts, with one edge.** The second reconnect pair is 23.44 µs, 1.05 % under 23.69 (inside 10 %). S1-b's 2 workers cost +14.8 % per request (inside +5 to +15 %; the third pair, +15.6 %, is just over, the median is not),
    less than S1-d's +26.9 % at 150,000 users (the +25 % predicted was a little low), and S1-b is chosen. Two readings the prediction does not make: with the soft limit in each process S1-b adds 21.7 % at 150,000 users, not 14.8 %, and at 100,000 users the two are 1.05 µs apart.
13. **Not applicable.** 5b chose no CPU variant, so its configuration is 5a's and there is no pair to compare. For the record, S1-a's bench estimate (79.0 µs/req) falls inside the 71 to 80 range, as an estimate of the reference alone.

## The choice

| Step | Chosen | Why |
|---|---|---|
| S1 accept connections, at the bench's sizes (100,000 to 150,000 users) | **S1-b: 2 processes on one port (`APP_WORKERS=2`), each with the soft limit (`APP_SOFT_CONN_LIMIT=64000`)** | it adds 7.44 µs a request at 100,000 users (S1-d 8.48) and 10.89 at 150,000 (S1-d 13.51); S1-d adds 26.9 % at 150,000, over the 15 % line, so it does not stay. Below 93,518 users S1-d would be cheaper. Memory is the same (about 1.17 GiB at 150,000 users, 57 % of the box) |
