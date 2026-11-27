# Phase 8's levers on x86 (AWS `c5.2xlarge`)

The step-lab series of phase 8 on one AWS `c5.2xlarge` (Intel Xeon, x86-64) in the lab's realistic mode at the bench's
shape (`s = 0.02`, 60,000 idle connections, 7,500 req/s, the server on one vCPU with its hyperthread sibling idle), booted
on the bench's kernel (6.8): the reference's A/A floor, the feed micro on both SQLites, the tuned SQLite's pair if the micro
calls for it, our io_uring ring's pair, and the winners together. The reference is phase 7's submission as it is. This
series decides: every step runs whatever the Mac series finds. This file is written in two steps: the predictions first
(before the launch), then the runs and the reading.

## Predictions

Written by the project manager on 2026-11-26 at 15:10, revised at 15:26, before any phase 8 run (the lines of this
session; the others belong to other folders).

> x86 numbers on AWS `c5.2xlarge` (the lab session), PHP 8.5, the reference phase 7's submission.
>
> 5. **The reference's A/A floor on x86** at 7,500 req/s: 1.0 to 3.0 µs/req; the reference at 54 to 60 µs/req (5b's
>    S1-b read 57.75 on the same box type, with telemetry on; the submission has none).
> 7. **The ring:** **−6 to −12 µs/req** against the reference (−11 to −22 %), beyond the floor in 3 pairs: S1-b's
>    second process gone (+7.44 on the Xeon in 5b) and 1 to 4 µs of syscalls; chosen.
> 9. **The tuned SQLite:** the feed micro 8 to 18 % under Ubuntu's 3.45.1; the pair −1 to −5 µs/req; beyond the floor
>    with about 50 % confidence.
> 13. **Cost and time:** the lab session 2 to 3 h, under 2 USD.

Written now (2026-11-26 21:30, before the launch): the box boots kernel 6.8, the bench's; the predictions above were written
for the session whatever its kernel.

## Result in one paragraph

On the AWS kernel 6.8 (`6.8.0-1070-aws`) the reference holds a floor of **0.60 µs/req** (10 of 10 runs valid, reference
**55.3 µs/req**), the tuned SQLite is **−7.33 µs/req** (13.3 %) against the reference in 3 of 3 pairs, beyond the floor,
and the feed micro called for it (−16.4 %; the bar is 4.56 µs/req). **The ring could not be measured:** on this kernel
`IORING_REGISTER_PBUF_RING` answers `EINVAL` to a C program on liburing 2.5 as well as to our FFI call, so the app does
not boot on it. The attempt to move to Ubuntu's generic 6.8 kernel (`linux-image-generic`, what a droplet runs) ended in a
kernel panic at boot (root device not found), so the session was torn down. No ring pair, no pair of the winners together.

## Plan of the runs

One instance, from the branch's commit `87469ec` (sent with `git archive`, so no tracked file was edited while the runs
went: the lab's code is `62fc877` plus comment-only commits), the challenge's repository cloned at `162699a`, `lab/seed.sh`,
`bash lab/build.sh 8.5` and `bash lab/build.sh 8.5-sqlite` on the box (never `docker save`: `-march=native`). Every pair is
`lab/steplab.sh --image 8.5 --rate 7500 --think-scale 0.02 --idle 60000 --seconds 60 --vu-cap 5400 --warmup 750,60
--seccomp-unconfined` with `LAB_CPU_LAYOUT=x86-8`, the alternating order, and `--expect-loop` on every variant; `docker ps`
printed 0 before each step. The reference is always
`--variant ref= --server-variant ref=submissions/php-Gcob/server.php --variant-args "ref=--ext pcntl --ext sockets --ext event" --expect-loop ref=epoll`.

1. **`aa-7500/`:** `ref` against `ref2` (the same file and arguments), 5 pairs; its floor is `bash lab/steplab-floor.sh aa-7500`
   and every later step used `--floor-from lab/results/2026-11-26-x86-levers/aa-7500`.
2. **`feed-micro/`:** `bash lab/micro.sh lab/micro/benches/feed.php --images 8.5,8.5-sqlite --jit on --jit-buffer-size 32M`
   (`opcache.jit=tracing` with the submission's 32M buffer), 5 process rounds per image.
3. **`sqlite-7500/`:** `ref` against `sqlite` (`--server-variant sqlite=submissions/php-Gcob/server.php
   --variant-args "sqlite=--image 8.5-sqlite --ext pcntl --ext sockets --ext event" --expect-loop sqlite=epoll`), 1 pair,
   then 2 more (`--first-round 2 --pairs 2`) because the first beat the floor.
4. **`ring-7500/` and `together-7500/`:** not run (see "The ring on 6.8").

The stage scripts are kept in the private factory repository.

## The machine

| | |
|---|---|
| Instance | AWS `c5.2xlarge`, one box, 8 vCPUs (4 cores, 2 threads each), 15.6 GiB, the lab's `x86-8` layout (server on one core's thread, its sibling idle) |
| CPU | Intel Xeon Platinum 8275CL @ 3.00 GHz |
| OS and kernel | Ubuntu 24.04.5, kernel **6.8.0-1070-aws** (`linux-image-aws-lts-24.04`, GRUB set to its entry; the box first booted 7.0.0-1018-aws) |
| Docker | 29.10.1, `cgroupfs` driver |
| `io_uring_disabled` | 0 |
| Transparent huge pages | `madvise` |
| Image builds | `8.5` 233 s; `8.5-sqlite` 250 s (PGO training on this CPU: `generated: 50000 users, 500000 posts, 1998591 likes`, `training: 70072 statements`, one profile, no missing-profile warning) |

## What differed from the plan

- **The ring was not measured** (below); `ring-7500/` and `together-7500/` do not exist.
- **The generic kernel test** (asked for after the ring's failure): installed `linux-image-generic` 6.8.0-151, GRUB set to
  its entry, reboot. The boot panicked: `VFS: Cannot open root device "PARTUUID=..." or unknown-block(0,0): error -6`
  (the generic kernel has no disk driver for the instance's NVMe volume built in, and the image boots without an initrd).
  Nothing could be run on it; the box was torn down at once. The SQLite steps ran on 6.8.0-1070-aws.
- The A/A floor (0.60) is below the 1.0 to 3.0 predicted, so the floor rule is a stricter test than expected.
- The micro runs with `--jit-buffer-size 32M` (the submission's) and not the micro's default 64M.

## The ring on 6.8

- `lab/challenge-test.sh --image 8.5 --seccomp-unconfined --ext sockets --env APP_RING=1 --env APP_RINGS=3`: the server
  exits at once with `io_uring refused: buffer_ring 22` (22 is `EINVAL`, from `io_uring_register` with
  `IORING_REGISTER_PBUF_RING`); the fallback to the DIY loop needs `pcntl`, `posix` and `event`, which that check does not
  load. The stress (`lab/stress.sh --app`) fails the same way. 42/42 and the stress were not reached.
- The same with `URING_RECV_BUFFERS` 256, 1024 and 2.
- **It is the kernel, not our call:** a C program on liburing 2.5 (`io_uring_queue_init` works, then
  `io_uring_setup_buf_ring(&ring, 8, 0, 0, &ret)` returns `-22`, and so does `io_uring_register_buf_ring` on a
  `posix_memalign` page with bgid 5). Our FFI call passes a 40-byte `io_uring_buf_reg` that is right (page-aligned
  address, 8 entries, bgid 0, flags 0, reserved fields 0) with `nr_args` 1; even `IORING_UNREGISTER_PBUF_RING` of a group
  that does not exist answers `EINVAL` (it should be `ENOENT`), while `IORING_REGISTER_PERSONALITY` works on the same ring.
  The ring's other calls (setup, the sparse file table) work; only the provided buffer ring is refused.

## Tables

### The reference against itself (`ref` and `ref2`, the submission's server file twice, 7,500 req/s, `s = 0.02`, 60,000 idle, 5 pairs)

| Run | position in its round | valid | other containers | idle held at the end | closed by the server | loop | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ref2-1 | 1 | true | 0 | 60000 | 0 | epoll | 7399.3 | 98.6 % | 54.99 | 6.68 | 19.5 | pass |
| ref-1 | 2 | true | 0 | 60000 | 0 | epoll | 7399 | 98.6 % | 55.29 | 6.68 | 17.83 | pass |
| ref-2 | 1 | true | 0 | 60000 | 0 | epoll | 7411.4 | 98.8 % | 55.07 | 6.78 | 17.83 | pass |
| ref2-2 | 2 | true | 0 | 60000 | 0 | epoll | 7402.4 | 98.6 % | 55.23 | 6.48 | 18.1 | pass |
| ref2-3 | 1 | true | 0 | 60000 | 0 | epoll | 7411.1 | 98.7 % | 55.68 | 6.2 | 17.57 | pass |
| ref-3 | 2 | true | 0 | 60000 | 0 | epoll | 7406.6 | 98.7 % | 55.44 | 6.2 | 18.93 | pass |
| ref-4 | 1 | true | 0 | 60000 | 0 | epoll | 7406.4 | 98.7 % | 55.26 | 6.29 | 17.31 | pass |
| ref2-4 | 2 | true | 0 | 60000 | 0 | epoll | 7410.8 | 98.7 % | 55.1 | 6.38 | 18.1 | pass |
| ref2-5 | 1 | true | 0 | 60000 | 0 | epoll | 7408.1 | 98.7 % | 54.9 | 6.1 | 17.31 | pass |
| ref-5 | 2 | true | 0 | 60000 | 0 | epoll | 7406.9 | 98.7 % | 55.4 | 5.84 | 18.37 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |
|---|---|---|---|---|---|---|---|
| ref2-1 | 0.32 | 1.93 | 37.02 % | 0.03 % | 1.254 | 0 | 0 |
| ref-1 | 1.27 | 1.33 | 35.92 % | 0.00 % | 1.108 | 27727 | 0 |
| ref-2 | 2.38 | 1.94 | 36.07 % | 0.00 % | 1.175 | 26717 | 0 |
| ref2-2 | 1.94 | 1.74 | 35.87 % | 0.00 % | 1.314 | 26733 | 0 |
| ref2-3 | 2.04 | 1.46 | 36.83 % | 0.00 % | 1.102 | 26744 | 0 |
| ref-3 | 2.63 | 1.99 | 36.39 % | 0.03 % | 1.187 | 26738 | 0 |
| ref-4 | 2.13 | 2.09 | 35.55 % | 0.00 % | 1.075 | 26733 | 0 |
| ref2-4 | 2.83 | 1.73 | 36.55 % | 0.00 % | 1.165 | 26739 | 0 |
| ref2-5 | 1.63 | 2.02 | 35.11 % | 0.00 % | 1.156 | 26742 | 0 |
| ref-5 | 2.08 | 1.94 | 35.93 % | 0.00 % | 1.146 | 26750 | 0 |

Valid runs: 10 of 10. The reference's median over its runs: **55.29 µs/req**.

The floor, 5 paired differences: median -0.16 µs, interquartile range 0.45 µs, **floor 0.6 µs/req** (|median| + IQR).

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  ref2           yes       7399.3        55     6.68     19.5         0   1.93     1.25  pass
    1  ref            yes         7399      55.3     6.68    17.83     27727   1.33     1.11  pass
    2  ref            yes       7411.4      55.1     6.78    17.83     26717   1.94     1.18  pass
    2  ref2           yes       7402.4      55.2     6.48     18.1     26733   1.74     1.31  pass
    3  ref2           yes       7411.1      55.7      6.2    17.57     26744   1.46      1.1  pass
    3  ref            yes       7406.6      55.4      6.2    18.93     26738   1.99     1.19  pass
    4  ref            yes       7406.4      55.3     6.29    17.31     26733   2.09     1.08  pass
    4  ref2           yes       7410.8      55.1     6.38     18.1     26739   1.73     1.17  pass
    5  ref2           yes       7408.1      54.9      6.1    17.31     26742   2.02     1.16  pass
    5  ref            yes       7406.9      55.4     5.84    18.37     26750   1.94     1.15  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
ref               5/5      0      55.3      55.1 to 55.4    17.83  reference                      -  reference
ref2              5/5      0      55.1      54.9 to 55.7     18.1  -0.3 +0.2 +0.2 -0.2 -0.5      -0.2  within the noise

Floor: 0.603 us, from aa-7500: |median -0.155| + interquartile range 0.447 of 5 paired differences (quartiles by linear interpolation, inclusive)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.603 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### The feed micro on Ubuntu's SQLite (`8.5`, 3.45.1) and the tuned one (`8.5-sqlite`, 3.54.1), JIT tracing

| Case | `8.5` ns | its processes (min to max) | `8.5-sqlite` ns | its processes (min to max) | saving ns | saving % |
|---|---|---|---|---|---|---|
| feed/reference/assoc | 60361.4 | 60169.1 to 60943.8 | 50442.9 | 50242.3 to 50537.3 | 9918.6 | 16.4 % |
| post/reference/assoc | 6561.5 | 6471.8 to 6696.3 | 5662.1 | 5598.8 to 5785.7 | 899.4 | 13.7 % |
| feed/reference/assoc, APP_PRAGMAS=mmap-off | 58873.3 | 58788 to 59083.5 | 47949.5 | 47656.1 to 51306.8 | 10923.9 | 18.6 % |

**The bar** (the saving per feed times the feeds a request, against the A/A floor): (60361.4 - 50442.9) ns = 9918.6 ns a feed = 9.919 µs; × 0.46 feeds a request = **4.563 µs/req**; the floor is 0.603 µs/req: the bar reaches the floor.

### The tuned SQLite against the reference (`8.5-sqlite`, same server file, 7,500 req/s, 1 pair, 2 more if it beats the floor)

| Run | position in its round | valid | other containers | idle held at the end | closed by the server | loop | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| sqlite-1 | 1 | true | 0 | 60000 | 0 | epoll | 7408.3 | 98.7 % | 47.77 | 6.1 | 17.57 | pass |
| ref-1 | 2 | true | 0 | 60000 | 0 | epoll | 7405.1 | 98.7 % | 55.49 | 6.68 | 18.1 | pass |
| ref-2 | 1 | true | 0 | 60000 | 0 | epoll | 7386.6 | 98.4 % | 55.21 | 6.78 | 19.21 | pass |
| sqlite-2 | 2 | true | 0 | 60000 | 0 | epoll | 7397.7 | 98.6 % | 48.19 | 6.98 | 19.79 | pass |
| sqlite-3 | 1 | true | 0 | 60000 | 0 | epoll | 7409.5 | 98.7 % | 47.76 | 6.1 | 17.31 | pass |
| ref-3 | 2 | true | 0 | 60000 | 0 | epoll | 7405.8 | 98.7 % | 55.09 | 6.38 | 18.1 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |
|---|---|---|---|---|---|---|---|
| sqlite-1 | 0.85 | 1.64 | 35.04 % | 0.00 % | 1.232 | 0 | 0 |
| ref-1 | 2.16 | 2.09 | 35.47 % | 0.00 % | 1.164 | 27732 | 0 |
| ref-2 | 1.16 | 2.01 | 35.17 % | 0.03 % | 1.053 | 26723 | 0 |
| sqlite-2 | 2.27 | 1.52 | 35.27 % | 0.00 % | 1.247 | 27732 | 0 |
| sqlite-3 | 1.85 | 1.50 | 35.24 % | 0.00 % | 1.204 | 26722 | 0 |
| ref-3 | 1.53 | 1.96 | 35.99 % | 0.00 % | 1.161 | 26747 | 0 |

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  sqlite         yes       7408.3      47.8      6.1    17.57         0   1.64     1.23  pass
    1  ref            yes       7405.1      55.5     6.68     18.1     27732   2.09     1.16  pass
    2  ref            yes       7386.6      55.2     6.78    19.21     26723   2.01     1.05  pass
    2  sqlite         yes       7397.7      48.2     6.98    19.79     27732   1.52     1.25  pass
    3  sqlite         yes       7409.5      47.8      6.1    17.31     26722    1.5      1.2  pass
    3  ref            yes       7405.8      55.1     6.38     18.1     26747   1.96     1.16  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
ref               3/3      0      55.2      55.1 to 55.5     18.1  reference                      -  reference
sqlite            3/3      0      47.8      47.8 to 48.2    17.57  -7.7 -7 -7.3                -7.3  beyond the noise

Floor: 0.603 us, from aa-7500: |median -0.155| + interquartile range 0.447 of 5 paired differences (quartiles by linear interpolation, inclusive)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.603 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

- **sqlite**: median 47.77 µs/req against the reference's 55.21; paired differences -7.72, -7.02, -7.33, **median -7.33 µs/req (-13.27 %)**; bench estimate 86800 × 55.21 ÷ 47.77 = **100325 users** (x86 on a shared host, not the bench).

## One line per lever

| Lever | µs/req against the reference | Beyond the floor (0.603)? | Chosen on x86? | Bench estimate (`86,800 × ref ÷ lever`) |
|---|---|---|---|---|
| Tuned SQLite (`8.5-sqlite`, 3.54.1, PGO) | **−7.33** (47.77 against 55.21; pairs −7.72, −7.02, −7.33) | yes, 3 of 3 pairs, every one more than 11 times the floor | **chosen**: the micro said 16.4 % on the feed (bar 4.56 µs/req, above the floor), the pairs gave 13.3 % of the request; it is a gain of the version, the compile options, `-march=native` and the profile together | 100,325 users (x86 on a shared host, not the bench) |
| Ring (`APP_RING=1 APP_RINGS=3`) | not measured | not measured | **not chosen, not rejected**: it does not run on `6.8.0-1070-aws` | not measured |
| Both together | not run | | | |

The bar's arithmetic: the micro's saving on `feed/reference/assoc` is 60,361.4 − 50,442.9 = 9,918.6 ns a feed
(−16.4 %); a request carries 0.46 feeds (one feed per bench loop of about 2.17 requests), so 9.9186 µs × 0.46 =
4.563 µs/req. The pair measured 7.33 µs/req: more than the bar, because the micro times the feed alone and the posts
(`post/reference/assoc`, −13.7 %, 0.9 µs a post) and the writes add to it, and the micro's loop has no network.

## The predictions judged

- **5, the A/A floor and the reference:** the floor is **0.60** µs/req against 1.0 to 3.0 predicted: lower than expected
  (the 10 runs sit within 54.9 and 55.7). The reference at **55.3** µs/req is inside 54 to 60: right.
- **7, the ring (−6 to −12, chosen):** not judged, the ring does not boot on this kernel.
- **9, the tuned SQLite:** the feed micro **−16.4 %**, inside 8 to 18 %: right. The pair **−7.33** µs/req, outside −1 to
  −5: wrong, by 2.3 µs too small a gain predicted; beyond the floor in 3 of 3 pairs (the 50 % confidence went well).
- **13, cost and time:** the session ran about 1 h 26 min (launch 21:30, torn down 22:56), 2 to 3 h predicted;
  about 0.5 USD at the on-demand price of the type, under 2 USD: right on the cost, faster than predicted because the ring
  steps did not run.
