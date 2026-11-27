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
A second session booted the generic 6.8 properly (with its initramfs): it refuses `IORING_REGISTER_PBUF_RING` too, while the
older buffers (`PROVIDE_BUFFERS` and a multishot receive) work; see "The ring on the 6.8 kernels, second session".

**Third session (the ring on the older buffers, on `6.8.0-151-generic`):** the app now falls back by itself to the older
provided buffers when the kernel refuses the buffer ring (`URING_BUFFERS=auto`, the default), and its `loop:` line says so
(`ring, 3 rings, legacy buffers`). On the generic 6.8 it passes the challenge's 42 checks and a 200,000-request stress at
pipelines 1 and 16 with 0 mismatches. This kernel's floor is **0.92 µs/req** (6 of 6 runs valid, reference **55.5 µs/req**).
**The ring is −4.49 µs/req (−8.1 %) against the reference, in 3 of 3 pairs, beyond the floor; the ring on the tuned SQLite is
−11.59 µs/req (−21.0 %), 3 of 3 pairs**, and the tuned SQLite alone repeats on this kernel (−7.57, one pair). Bench estimates
(`86,800 × ref ÷ lever`, x86 on a shared host, not the bench): ring 94,454, ring on the tuned SQLite 109,766.

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
4. **`ring-7500/` and `together-7500/`:** not run in the first session (see "The ring on 6.8"); run in the third session on
   `6.8.0-151-generic` (see "The ring on 6.8.0-151-generic, third session").

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

- **The first session did not measure the ring** (below); `ring-7500/` and `together-7500/` come from the third session, on
  another kernel (see "The ring on 6.8.0-151-generic, third session": the kernel each step ran on).
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

## The ring on the 6.8 kernels, second session (the generic 6.8, and the older buffers)

A second short session (one `c5.2xlarge`, about 7 minutes) asked whether Ubuntu's **generic** 6.8 kernel, the one a droplet
runs, accepts the provided buffer ring, and whether the older buffer path works on 6.8. The generic kernel now boots: the
first try panicked because the cloud image boots without an initramfs and `-generic` has its NVMe driver as a module. This
time `linux-image-generic` (6.8.0-151) came with its initramfs (carrying the `nvme` modules), the
`GRUB_FORCE_PARTUUID` line of the image's `40-force-partuuid.cfg` drop-in in `/etc/default/grub.d/` was commented out
(the generated entry then reads `root=UUID=...` and has an `initrd` line), `GRUB_DEFAULT` pointed at the generic entry,
`update-grub`, reboot: back in under a minute on `6.8.0-151-generic`.

| Probe (C, liburing 2.5, a bare ring) | `7.0.0-1018-aws` (the AMI's own) | `6.8.0-1070-aws` | `6.8.0-151-generic` |
|---|---|---|---|
| `IORING_REGISTER_PBUF_RING` (`io_uring_setup_buf_ring`, 8 entries; and `io_uring_register_buf_ring` on an aligned page) | **accepted** | **`EINVAL`** (first session) | **`EINVAL`** |
| `IORING_OP_PROVIDE_BUFFERS` (bgid 1, 8 buffers of 4 KiB), then a multishot receive with `IOSQE_BUFFER_SELECT` on a socketpair: one write of 100 bytes gives a CQE of 100 bytes with `IORING_CQE_F_BUFFER` and `IORING_CQE_F_MORE` | works | not probed | **works** (`res=100 flags=0x3`) |

On `6.8.0-151-generic` the opcode probe (`probe/opcodes.c`) shows the same pattern as in the AWS 6.8 kernel: `IORING_UNREGISTER_PBUF_RING`
of an absent group and `IORING_REGISTER_PBUF_STATUS` also answer `EINVAL` (a kernel that knew them would answer `ENOENT`), while
`IORING_REGISTER_FILE_ALLOC_RANGE` and `IORING_REGISTER_PERSONALITY` work, and the kernel's config has `CONFIG_IO_URING=y`. So
both 6.8 kernels Ubuntu ships refuse the provided buffer ring, and the AMI's 7.0 accepts it. The older buffers (`PROVIDE_BUFFERS`
and the multishot receive) work on the generic 6.8.

Where the session stopped: the brief said that a refusal here ends the session (the ring as built needs `PBUF_RING`), so the
box was torn down after the probes. **No lab image was built, no ring check and no pair ran on `6.8.0-151-generic`: there is
no `aa-generic-7500/`, `ring-7500/` or `together-7500/`.** The kernel each step ran on: the SQLite steps (A/A floor, feed micro,
tuned SQLite pairs) on `6.8.0-1070-aws`; nothing was timed on `6.8.0-151-generic`; the probes above ran on all three kernels.
That box's CPU was an Intel Xeon Platinum 8124M (3.00 GHz, 8 vCPUs), not the 8275CL of the first session.
The probe sources and logs are in `probe/`.

## The ring on 6.8.0-151-generic, third session (the older provided buffers)

A third session (one `c5.2xlarge`, 1 h 25 min) ran the ring on the generic 6.8, the kernel a droplet runs, with the code of
commit `8617faf` (the ring with `URING_BUFFERS=auto`, the default: the buffer ring when the kernel takes it, the older
`PROVIDE_BUFFERS` path when it answers `EINVAL`). Nothing in the pairs sets the buffers: `auto` chose by itself, and the
`--expect-loop "ring=ring, 3 rings, legacy buffers"` of each ring variant would have stopped a run that said anything else.

**The kernel each step ran on.** The first session's steps (A/A floor 0.603, feed micro, the tuned SQLite's 3 pairs) ran on
`6.8.0-1070-aws`. Every step of this session ran on **`6.8.0-151-generic`** (booted with the initramfs by the recipe of the
second session): `aa-generic-7500/`, `ring-7500/`, `together-7500/`, `sqlite-generic-7500/`. The box was an Intel Xeon Platinum
8275CL @ 3.00 GHz (8 vCPUs, 15.6 GiB, Ubuntu 24.04.5, Docker 29.10.1 with `cgroupfs`, `io_uring_disabled` 0), the same model as
the first session's. Builds on the box: `8.5` 235 s, `8.5-sqlite` 249 s (training `70072 statements`). Code: `git archive 8617faf`;
the challenge at `162699a`; `LAB_CPU_LAYOUT=x86-8`, the common flags of the plan above, `--seccomp-unconfined`.

**The ring's correctness on this kernel, before any timing.**

- `bash lab/check.sh check_ring_legacy_buffers check_ring_buffers_loop_line check_rings_auto_chooses_legacy_buffers` (our FFI's older
  path had only run on the Mac's 6.12 and in a C probe of this kernel): `check_ring_legacy_buffers` **ok** (13 of the ring's checks run
  again with `URING_BUFFERS=legacy`: answers equal the DIY loop's, the pool running dry, the re-provides in runs, the soft limit, 3 rings...).
  The other two **fail here, because their premise is a kernel that takes the buffer ring, which this one doesn't**, not because
  of the ring: `check_ring_buffers_loop_line` starts with `URING_BUFFERS=ring`, which this kernel refuses for real (the app exits with
  `io_uring refused: buffer_ring 22`, as designed for that mode), so it never reaches its other two modes; run by hand without that
  first mode (a copy of `check.sh` on the box with `for mode in legacy auto`), it is **ok** for `legacy` and `auto`.
  `check_rings_auto_chooses_legacy_buffers` passes its first two assertions (`auto` with every ring refused: `loop: ring, 3 rings,
  legacy buffers`, the boot line `buffers: the kernel refused the buffer ring (errno 22), the receives use PROVIDE_BUFFERS`, provides
  counted with 0 errors; `URING_BUFFERS=ring` refused: the fallback to the DIY loop) and fails its last one, which hooks a refusal on
  the last ring only and expects the DIY fallback: here the kernel refuses every ring for real, so `auto` correctly chooses the older
  buffers (the line it printed: `loop: ring, 3 rings, legacy buffers`). These two checks assume the other kernel; they stay as they are.
- `lab/challenge-test.sh --image 8.5 --seccomp-unconfined --ext sockets --env APP_RING=1 --env APP_RINGS=3`: **`passed=42 failed=0`**, the
  server's boot line `loop: ring, 3 rings, legacy buffers`.
- `lab/stress.sh --app --env APP_RING=1 --env APP_RINGS=3 --env APP_TELEMETRY=1 --path '/posts/{id}' --connections 1000 --requests 200000
  --procs 4 --pipelines 1,16`: pipeline 1 `sent 200000 matched 200000 mismatches 0 lost 0` (64,844 req/s), pipeline 16 the same (100,773 req/s);
  the loop line is `ring, 3 rings, legacy buffers` there too.

**The pairs** (floor of this kernel: `aa-generic-7500/`'s 0.918 µs/req, larger than the first kernel's 0.603, so 0.918 for every step
below). The tables are below.

| Step | Pairs | Valid | µs/req against the reference | Verdict (floor 0.918) | Bench estimate (`86,800 × ref ÷ lever`) |
|---|---|---|---|---|---|
| A/A (`ref2` against `ref`), `aa-generic-7500/` | 3 | 6 of 6 | median +0.19 (+0.4, −1.1, +0.2); reference 55.47 | floor **0.918** | |
| Ring, `ring-7500/` | 3 (1, then 2 more because the first beat the floor) | 6 of 6 | **−4.49 (−8.1 %)**: −4.49, −5.18, −3.83; 50.91 against 55.4 | **beyond the noise** | 94,454 |
| Ring on `8.5-sqlite`, `together-7500/` | 3 | 6 of 6 | **−11.59 (−21.0 %)**: −11.54, −11.60, −11.59; 43.67 against 55.23 | **beyond the noise** | 109,766 |
| Tuned SQLite, `sqlite-generic-7500/` (check that the gain holds here) | 1 | 2 of 2 | −7.57 (−13.6 %); 48.17 against 55.73 | a screen: beats the floor | 100,433 |

**What it says.**

- **The ring on the older buffers beats the reference on the generic 6.8:** −4.49 µs/req, the three differences between −3.8 and −5.2, every
  one more than 4 times the floor. It is below the prediction (−6 to −12): the older buffers hand a buffer back with a `PROVIDE_BUFFERS`
  submission, which the buffer ring does not need. How much that costs against the buffer ring on the same hardware was not measured
  (the only kernel that takes the buffer ring here is the AMI's 7.0, not tried in this session): the Mac, on 6.12, read 0 to about 1 µs/req.
- **Chosen on x86: yes**, by the rule (3 of 3 pairs beyond the floor, valid runs, loop line as expected). The caveats are the usual ones (a
  shared host, not the bench) and one of kernel: the gain exists on the generic 6.8, whose path is the older buffers; on a kernel that takes
  the buffer ring the code takes it (`auto`), a path timed only on the Mac.
- **Together** is **−11.59 µs/req** (−21.0 %): about the sum of the ring (−4.49) and the tuned SQLite (−7.57 on this kernel, −7.33 on the
  first), so the two levers add up. This pair is what the submission would ship (D128's SQLite plus the ring): bench estimate 109,766 users
  by the rule, against 86,800.
- **The tuned SQLite's gain holds on the generic kernel:** −7.57 µs/req against −7.33 (3 pairs, `6.8.0-1070-aws`); one pair here, a screen.
- The reference costs the same on the three kernels' boxes: 55.3 (`6.8.0-1070-aws`), 55.4 to 55.5 (`6.8.0-151-generic`).

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

### The reference against itself on 6.8.0-151-generic (`ref` and `ref2`, 7,500 req/s, `s = 0.02`, 60,000 idle, 3 pairs)

| Run | position in its round | valid | other containers | idle held at the end | closed by the server | loop | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ref2-1 | 1 | true | 0 | 60000 | 0 | epoll | 7398.5 | 98.6 % | 55.85 | 6.68 | 18.65 | pass |
| ref-1 | 2 | true | 0 | 60000 | 0 | epoll | 7405.7 | 98.7 % | 55.43 | 5.75 | 16.8 | pass |
| ref-2 | 1 | true | 0 | 60000 | 0 | epoll | 7405.3 | 98.7 % | 56.18 | 6.68 | 19.21 | pass |
| ref2-2 | 2 | true | 0 | 60000 | 0 | epoll | 7413.5 | 98.8 % | 55.13 | 5.84 | 17.57 | pass |
| ref2-3 | 1 | true | 0 | 60000 | 0 | epoll | 7406.8 | 98.7 % | 55.66 | 6.29 | 17.05 | pass |
| ref-3 | 2 | true | 0 | 60000 | 0 | epoll | 7405.3 | 98.7 % | 55.47 | 6.1 | 17.83 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |
|---|---|---|---|---|---|---|---|
| ref2-1 | 0.24 | 2.90 | 35.69 % | 0.00 % | 1.043 | 0 | 0 |
| ref-1 | 2.27 | 1.11 | 35.97 % | 0.00 % | 1.043 | 27576 | 0 |
| ref-2 | 1.40 | 2.29 | 36.98 % | 0.00 % | 1.139 | 26736 | 0 |
| ref2-2 | 2.06 | 1.75 | 37.03 % | 0.00 % | 1.093 | 26727 | 0 |
| ref2-3 | 2.15 | 2.74 | 35.50 % | 0.00 % | 1.027 | 26736 | 0 |
| ref-3 | 2.67 | 2.28 | 35.79 % | 0.00 % | 2.681 | 26750 | 0 |

Valid runs: 6 of 6. The reference's median over its runs: **55.47 µs/req**.

The floor on this kernel, 3 paired differences: median +0.19 µs, interquartile range 0.73 µs, floor 0.92 µs/req (|median| + IQR). The floor used below is the larger of this and the first kernel's (0.603): **0.918 µs/req**.

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  ref2           yes       7398.5      55.8     6.68    18.65         0    2.9     1.04  pass
    1  ref            yes       7405.7      55.4     5.75     16.8     27576   1.11     1.04  pass
    2  ref            yes       7405.3      56.2     6.68    19.21     26736   2.29     1.14  pass
    2  ref2           yes       7413.5      55.1     5.84    17.57     26727   1.75     1.09  pass
    3  ref2           yes       7406.8      55.7     6.29    17.05     26736   2.74     1.03  pass
    3  ref            yes       7405.3      55.5      6.1    17.83     26750   2.28     2.68  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
ref               3/3      0      55.5      55.4 to 56.2    17.83  reference                      -  reference
ref2              3/3      0      55.7      55.1 to 55.8    17.57  +0.4 -1.1 +0.2              +0.2  within the noise

Floor: 0.918 us, from aa-generic-7500: |median 0.185| + interquartile range 0.732 of 3 paired differences (quartiles by linear interpolation, inclusive)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.918 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

### The ring against the reference on 6.8.0-151-generic (`APP_RING=1 APP_RINGS=3`, `URING_BUFFERS=auto`, `APP_PRAGMAS=mmap-off`, `APP_SOFT_CONN_LIMIT=192000`, `--server-nofile 32768`, 7,500 req/s)

| Run | position in its round | valid | other containers | idle held at the end | closed by the server | loop | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ring-1 | 1 | true | 0 | 60000 | 0 | ring, 3 rings, legacy buffers | 7399.1 | 98.6 % | 50.91 | 9.4 | 21.64 | pass |
| ref-1 | 2 | true | 0 | 60000 | 0 | epoll | 7405.6 | 98.7 % | 55.4 | 6.38 | 17.57 | pass |
| ref-2 | 1 | true | 0 | 60000 | 0 | epoll | 7407.1 | 98.7 % | 55.15 | 6.68 | 17.83 | pass |
| ring-2 | 2 | true | 0 | 60000 | 0 | ring, 3 rings, legacy buffers | 7393.2 | 98.5 % | 49.97 | 9.83 | 22.63 | pass |
| ring-3 | 1 | true | 0 | 60000 | 0 | ring, 3 rings, legacy buffers | 7385.3 | 98.4 % | 51.65 | 10.13 | 23.31 | pass |
| ref-3 | 2 | true | 0 | 60000 | 0 | epoll | 7404.7 | 98.7 % | 55.48 | 6.29 | 18.65 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |
|---|---|---|---|---|---|---|---|
| ring-1 | 1.91 | 0.48 | 34.79 % | 0.00 % | 0.956 | 26736 | 0 |
| ref-1 | 0.65 | 1.76 | 34.87 % | 0.00 % | 2.178 | 26751 | 0 |
| ref-2 | 1.24 | 2.27 | 35.58 % | 0.00 % | 1.045 | 26753 | 0 |
| ring-2 | 2.67 | 2.27 | 35.92 % | 0.00 % | 1.025 | 27597 | 0 |
| ring-3 | 2.47 | 1.34 | 35.03 % | 0.03 % | 1.012 | 26745 | 0 |
| ref-3 | 2.33 | 2.09 | 36.62 % | 0.00 % | 2.222 | 26754 | 0 |

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  ring           yes       7399.1      50.9      9.4    21.64     26736   0.48     0.96  pass
    1  ref            yes       7405.6      55.4     6.38    17.57     26751   1.76     2.18  pass
    2  ref            yes       7407.1      55.2     6.68    17.83     26753   2.27     1.05  pass
    2  ring           yes       7393.2        50     9.83    22.63     27597   2.27     1.02  pass
    3  ring           yes       7385.3      51.7    10.13    23.31     26745   1.34     1.01  pass
    3  ref            yes       7404.7      55.5     6.29    18.65     26754   2.09     2.22  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
ref               3/3      0      55.4      55.2 to 55.5    17.83  reference                      -  reference
ring              3/3      0      50.9        50 to 51.7    22.63  -4.5 -5.2 -3.8              -4.5  beyond the noise

Floor: 0.918 us (typed with --floor)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.918 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

- **ring**: median 50.91 µs/req against the reference's 55.4; paired differences -4.49, -5.18, -3.83, **median -4.49 µs/req (-8.1 %)**; bench estimate 86800 × 55.4 ÷ 50.91 = **94454 users** (x86 on a shared host, not the bench).

### The ring on the tuned SQLite against the reference on 6.8.0-151-generic (3 pairs)

| Run | position in its round | valid | other containers | idle held at the end | closed by the server | loop | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| ring-1 | 1 | true | 0 | 60000 | 0 | ring, 3 rings, legacy buffers | 7399.4 | 98.6 % | 43.67 | 8.6 | 21.32 | pass |
| ref-1 | 2 | true | 0 | 60000 | 0 | epoll | 7399.6 | 98.6 % | 55.21 | 6.1 | 18.1 | pass |
| ref-2 | 1 | true | 0 | 60000 | 0 | epoll | 7400.6 | 98.6 % | 55.42 | 6.48 | 18.37 | pass |
| ring-2 | 2 | true | 0 | 60000 | 0 | ring, 3 rings, legacy buffers | 7391.9 | 98.5 % | 43.83 | 8.73 | 21.32 | pass |
| ring-3 | 1 | true | 0 | 60000 | 0 | ring, 3 rings, legacy buffers | 7395.9 | 98.5 % | 43.63 | 9.26 | 22.29 | pass |
| ref-3 | 2 | true | 0 | 60000 | 0 | epoll | 7409.4 | 98.7 % | 55.23 | 6.2 | 17.31 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |
|---|---|---|---|---|---|---|---|
| ring-1 | 1.41 | 0.98 | 34.71 % | 0.00 % | 2.076 | 26736 | 0 |
| ref-1 | 2.20 | 2.04 | 34.59 % | 0.00 % | 1.012 | 27732 | 0 |
| ref-2 | 1.70 | 0.90 | 36.43 % | 0.00 % | 0.997 | 26732 | 0 |
| ring-2 | 1.17 | 1.39 | 34.39 % | 0.00 % | 1.013 | 26742 | 0 |
| ring-3 | 1.48 | 0.92 | 34.80 % | 0.00 % | 0.993 | 26749 | 0 |
| ref-3 | 0.93 | 2.15 | 35.79 % | 0.00 % | 1.167 | 26754 | 0 |

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  ring           yes       7399.4      43.7      8.6    21.32     26736   0.98     2.08  pass
    1  ref            yes       7399.6      55.2      6.1     18.1     27732   2.04     1.01  pass
    2  ref            yes       7400.6      55.4     6.48    18.37     26732    0.9        1  pass
    2  ring           yes       7391.9      43.8     8.73    21.32     26742   1.39     1.01  pass
    3  ring           yes       7395.9      43.6     9.26    22.29     26749   0.92     0.99  pass
    3  ref            yes       7409.4      55.2      6.2    17.31     26754   2.15     1.17  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
ref               3/3      0      55.2      55.2 to 55.4     18.1  reference                      -  reference
ring              3/3      0      43.7      43.6 to 43.8    21.32  -11.5 -11.6 -11.6          -11.6  beyond the noise

Floor: 0.918 us (typed with --floor)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.918 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

- **ring**: median 43.67 µs/req against the reference's 55.23; paired differences -11.54, -11.6, -11.59, **median -11.59 µs/req (-20.99 %)**; bench estimate 86800 × 55.23 ÷ 43.67 = **109766 users** (x86 on a shared host, not the bench).

### The tuned SQLite against the reference on 6.8.0-151-generic (`8.5-sqlite`, same server file, 1 pair)

| Run | position in its round | valid | other containers | idle held at the end | closed by the server | loop | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| sqlite-1 | 1 | true | 0 | 60000 | 0 | epoll | 7411.4 | 98.8 % | 48.17 | 5.84 | 17.05 | pass |
| ref-1 | 2 | true | 0 | 60000 | 0 | epoll | 7412.1 | 98.8 % | 55.73 | 6.29 | 17.57 | pass |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |
|---|---|---|---|---|---|---|---|
| sqlite-1 | 2.93 | 1.46 | 35.86 % | 0.00 % | 1.022 | 26747 | 0 |
| ref-1 | 1.88 | 1.44 | 36.10 % | 0.00 % | 1.044 | 26734 | 0 |

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  sqlite         yes       7411.4      48.2     5.84    17.05     26747   1.46     1.02  pass
    1  ref            yes       7412.1      55.7     6.29    17.57     26734   1.44     1.04  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
ref               1/1      0      55.7      55.7 to 55.7    17.57  reference                      -  reference
sqlite            1/1      0      48.2      48.2 to 48.2    17.05  -7.6                        -7.6  screen: beats the floor

Floor: 0.918 us (typed with --floor)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.918 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

- **sqlite**: median 48.17 µs/req against the reference's 55.73; paired differences -7.57, **median -7.57 µs/req (-13.57 %)**; bench estimate 86800 × 55.73 ÷ 48.17 = **100433 users** (x86 on a shared host, not the bench).

## One line per lever

| Lever | µs/req against the reference | Beyond the floor (0.603)? | Chosen on x86? | Bench estimate (`86,800 × ref ÷ lever`) |
|---|---|---|---|---|
| Tuned SQLite (`8.5-sqlite`, 3.54.1, PGO) | **−7.33** (47.77 against 55.21; pairs −7.72, −7.02, −7.33) | yes, 3 of 3 pairs, every one more than 11 times the floor | **chosen**: the micro said 16.4 % on the feed (bar 4.56 µs/req, above the floor), the pairs gave 13.3 % of the request; it is a gain of the version, the compile options, `-march=native` and the profile together | 100,325 users (x86 on a shared host, not the bench) |
| Ring (`APP_RING=1 APP_RINGS=3`), on `6.8.0-151-generic` (floor 0.918) | **−4.49** (50.91 against 55.4; pairs −4.49, −5.18, −3.83) | yes, 3 of 3 pairs, every one more than 4 times the floor | **chosen** on this kernel: it runs there on the older provided buffers (the buffer ring is refused by both Ubuntu 6.8 kernels); on `6.8.0-1070-aws` it was not timed (it refuses the buffer ring too, and `PROVIDE_BUFFERS` was not probed there; the box is gone) | 94,454 users (x86 on a shared host, not the bench) |
| Both together (the ring on the tuned SQLite), on `6.8.0-151-generic` | **−11.59** (43.67 against 55.23; pairs −11.54, −11.60, −11.59) | yes, 3 of 3 pairs, more than 12 times the floor | **chosen**: what the submission would ship (D128's SQLite plus the ring); about the sum of the two | 109,766 users (x86 on a shared host, not the bench) |
| Tuned SQLite again, on `6.8.0-151-generic` | −7.57 (48.17 against 55.73) | one pair: a screen, beats the floor | confirms the first kernel's −7.33 | 100,433 users |

The bar's arithmetic: the micro's saving on `feed/reference/assoc` is 60,361.4 − 50,442.9 = 9,918.6 ns a feed
(−16.4 %); a request carries 0.46 feeds (one feed per bench loop of about 2.17 requests), so 9.9186 µs × 0.46 =
4.563 µs/req. The pair measured 7.33 µs/req: more than the bar, because the micro times the feed alone and the posts
(`post/reference/assoc`, −13.7 %, 0.9 µs a post) and the writes add to it, and the micro's loop has no network.

## The predictions judged

- **5, the A/A floor and the reference:** the floor is **0.60** µs/req against 1.0 to 3.0 predicted: lower than expected
  (the 10 runs sit within 54.9 and 55.7). The reference at **55.3** µs/req is inside 54 to 60: right.
- **7, the ring (−6 to −12, chosen):** judged in the third session, on `6.8.0-151-generic` with the older buffers: **−4.49** µs/req
  (−8.1 %), outside −6 to −12 (and −11 to −22 %): wrong, 1.5 µs too much predicted; beyond the floor in 3 of 3 pairs: right; chosen:
  right. On the first kernel it could not be judged (it did not boot there). The ring on the tuned SQLite, **−11.59**, is the
  combination, which no prediction named.
- **9, the tuned SQLite:** the feed micro **−16.4 %**, inside 8 to 18 %: right. The pair **−7.33** µs/req, outside −1 to
  −5: wrong, by 2.3 µs too small a gain predicted; beyond the floor in 3 of 3 pairs (the 50 % confidence went well).
- **13, cost and time:** the first session ran about 1 h 26 min (launch 21:30, torn down 22:56), 2 to 3 h predicted; about 0.5
  USD at the on-demand price of the type, under 2 USD: right on the cost, faster than predicted because the ring steps did not
  run. The second session took 7 minutes (about 0.05 USD) and the third 1 h 25 min (23:47 to 01:12, about 0.55 USD): the three
  together, about 3 h of box and about 1.2 USD, inside 2 to 3 h and under 2 USD.
