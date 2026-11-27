# $12 server challenge in PHP

**Status:** ⏸️ Phase 8: every local scope done (1 to 5, and 8's shared part; branch `phase-8-claude` at `62fc877`, pushed), stopped before scope 6, the first AWS session · approved for its local scopes on Jacob's standing go of 2026-11-26 15:10 · snapshot 2026-11-26-1537 · 🔴 Q24 and Q27, then his go
**Round:** 8
**Since your last read:** phase 8's plan is written: 10 scopes, D108 to D115, the predictions. The levers are judged by
their µs per request on x86, against phase 7's submission, cheapest first: the single-post plan read (no timing if
SQLite re-prepares nothing), ext-mrloop audited, Swoole's `uring_socket` one pair, a SQLite built with PGO, then our
own ring through FFI (one process, 3 rings, an epoll fallback). Why µs and not the AWS score: phase 7's box hit the
kernel's TCP memory and EC2's packet allowance near 142,000, while the bench's box hits its CPU near 86,000 (D106).
Then one AWS score session names both servers' ceilings (D107). The plan review (0 🔴, 6 🟠) found the ring measured on
one ring while it ships three, the epoll fallback able to stand in for io_uring unseen, and the AWS kernel (7.0) not
the bench's (6.8): settled in D116 to D120, the kernel and the cross-box pair asked (Q27, Q28).
**Project:** this repo, `plan/` · **Submission:** `submissions/php-Gcob/` (D80) · **Jira:** none

## 👉 Your turn

> **Answer freely:** a letter or `ok`, your own choice (`other: …`), `?` if it's unclear, or
> `badly framed: …` if an option is missing or the question doesn't hold.

Phase 8's plan ([details/phase-8.md](details/phase-8.md)). On your standing go ("Yes, local work only", 15:10),
Q25 is taken by default and the local scopes 1 to 5 run once the plan review is OK. Q24, Q26, Q27 and Q28 shape the
AWS sessions (scopes 6 and 9): they wait for you, and nothing local waits on them.

### Q24/28 [run, measure] : where do phase 8's pairs run, on an AWS x86 lab box or on the Mac?

Phase 8 judges each lever by its µs per request against phase 7's submission, in the step lab's pairs (D51). Your
containers are stopped since 15:20, so the Mac's VM is quiet now. But the Mac is arm64: S1-b cost 8.6 % there and
14.8 % on the Xeon, and the ring's gain is in the same place (the kernel's share and the second process). **New since
the plan (scope 5, 18:15):** at the real shape on the Mac, the ring and phase 7's server cost the same (three smoke
pairs: −1.0, +0.1, −0.3 µs/req, about 32.5 µs/req each). So the Mac can't tell them apart: if the ring wins, it wins on
x86.

**Question:** where do the pairs run?

- **A.** One AWS `c5.2xlarge`, the lab as 5b's x86 session ran it (server on one vCPU, k6 on the others), 7,500
  req/s, a fresh A/A first, then the pairs (D113).
  **Aims at:** x86 numbers, the CPU family of the bench, and your Mac left alone.
  **For:** the decision is made where it counts; the tooling exists (5a, 5b); 2 to 3 hours, under 2 USD. **Against:**
  your go and a policy, one more AWS session before the score's.
- **B.** The Mac's quiet VM (your containers kept stopped 3 to 4 hours more): the pairs there, and x86 only as the
  score session's per-box µs/req (its 1-vCPU boxes can't run the step lab).
  **Aims at:** no AWS until the score.
  **For:** no extra session, no cost. **Against:** the levers are decided on arm64, which may understate the ring's
  gain, and a lever that only wins on x86 could be dropped.

**Confidence:** A 85 % · B 15 %

**Recommendation:** A, because the ring's gain is in the kernel and the second process, which cost almost twice as much
on the Xeon as on the M3, the Mac already shows the two at par, and the session is cheap.

**Flips if:** you'd rather keep AWS to the one score session, and the Mac can stay quiet for an afternoon.

**Meanwhile:** scopes 1 to 5 build and check on the Mac either way; nothing waits on this before scope 6.

**Answer:**

### Q25/28 [run, ring] : the ring on 5a's own syscalls, or on liburing-ffi as D76 names it?

D76 says "an io_uring loop in pure PHP through FFI to `liburing-ffi.so.2`". 5a's spike did it without liburing: raw
`io_uring_setup` and `io_uring_enter` through FFI, the submissions written field by field in the ring's memory (14
fields for about 90 ns), with the memory-ordering design you asked about (notes.md 2026-11-22 18:25). It passed: 0
mismatches in 2,000,000 requests, 80,000 connections on two rings. liburing-ffi would make each prepare one FFI call
(about 35 ns of crossing plus its arguments), and the submit and the barriers would be liburing's C.

**Question:** which base does the ring build on?

- **A.** The spike's own syscalls (D112), liburing-ffi left out.
  **Aims at:** the code that already passed its stress test, no new library to install.
  **For:** measured; nothing added to `install.sh`; same speed as far as the micro bench can tell. **Against:** we
  keep our own copy of liburing's helpers (about 200 lines), and D76's wording changes.
- **B.** liburing-ffi: liburing built from its pinned source in `install.sh` (Ubuntu's 2.5 package may not ship
  `liburing-ffi.so.2`), the prepares and the submit through it.
  **Aims at:** D76 as written, liburing's own C for the ordering.
  **For:** less ring code of ours; the barriers in C. **Against:** a rewrite of a tested loop, one more build in
  `install.sh`, an FFI call per prepare.
- **C.** A, plus a micro bench of liburing-ffi's prepare and submit against the field writes; B only if it's faster.
  **Aims at:** the choice measured.
  **For:** settles it with a number. **Against:** half a scope for a margin the spike's micro already puts under 1 %.

**Confidence:** A 70 % · C 20 % · B 10 %

**Recommendation:** A, because the spike is measured and stress-tested, and with `SINGLE_ISSUER` and `DEFER_TASKRUN`
the kernel touches the queues only inside our own call, so liburing's barriers buy nothing here.

**Flips if:** you want "built on liburing" to be part of the story, or the ring's own code to stay as small as possible.

**Meanwhile:** scope 4 codes A until you answer; B would only change scope 4.

**Answer:** A (taken by default, Jacob away, his go of 2026-11-26 15:10; he may revise). D112.

### Q26/28 [run, score] : the score session's load, two load boxes or one bigger box?

In phase 7, one `m5.4xlarge` (16 vCPUs) held 135,000 k6 users in 43 GiB, and its garbage collector spiked all 16
vCPUs for a few seconds about every 35 s, enough to void the three runs at 142,000 (D104, D105). D107 asks for a load
that doesn't bind. Both options split the users in two k6 halves of about 70,000 (where phase 7's box had 4 to 7
spiked seconds in 120, under the void line), each running the unchanged `load.js`; a run passes when both halves pass,
which is stricter than one k6 (its p95 can't be over both halves' p95).

**Question:** which load?

- **A.** One `m5.8xlarge` (32 vCPUs, 128 GiB) running two k6 containers, each on its own 16 vCPUs and 2 source
  addresses.
  **Aims at:** the simplest driver: both halves started on one box, no SSH between load boxes.
  **For:** one load box to set up; same price as two `m5.4xlarge` (about 1.7 USD an hour). **Against:** both halves
  share one network card and one host.
- **B.** Two `m5.4xlarge`, one k6 each, the driver on the first starting the second over SSH.
  **Aims at:** the bench's shape ("several 16-core load generators").
  **For:** two network cards; closest to the bench. **Against:** a second box to set up and keep in step (the
  plateau is the seconds both report their target), more driver code.

**Confidence:** A 60 % · B 40 %

**Recommendation:** A, because the void came from k6's CPU, not the network (14,000 requests a second of a few KB each is under 1
Gbit/s), and one box keeps the driver simple.

**Flips if:** you want the load to look like the bench's generators, whatever the extra setup.

**Meanwhile:** scope 8 builds A's driver until you answer; B adds the SSH start.

**Answer:**

### Q27/28 [run, measure] : the kernel of the AWS boxes, 7.0 as phase 7, or the bench's 6.8?

Every AWS box so far booted Canonical's current Ubuntu 24.04 image, kernel 7.0 (phase 7's README); the bench runs 6.8
(`LEADERBOARD.md`); the Mac's VM 6.12. The ring's gain is in the kernel's share, and io_uring's network path changed
between 6.8 and 7.0, so in this plan the ring is never measured, nor even run, on the kernel it ships to. (The
batching knob, which needed 6.12, is already out: D120.)

**Question:** which kernel do phase 8's AWS boxes boot?

- **A.** Ubuntu 24.04's GA kernel 6.8 on every box, lab and score: one package and one reboot, folded into the score
  boxes' `mem=` reboot (D91).
  **Aims at:** the bench's kernel for the lever whose gain is in the kernel.
  **For:** the ring proven and measured where it will run. **Against:** the phase 7 server's check against phase 7's
  53.6 µs then also reads the kernel change, not only the box; one more step in the setup scripts.
- **B.** 7.0 as phase 7, plus one 6.8 correctness check of the ring (42/42 and the stress test) on the lab box
  after its pairs.
  **Aims at:** boxes comparable with phase 7, and the ring at least run on 6.8.
  **For:** phase 7's numbers stay directly comparable. **Against:** every µs/req and bench estimate stays a 7.0 number,
  said so.

**Confidence:** A 55 % · B 45 %

**Recommendation:** A, because the ring's whole gain is the kernel's share, and it costs one reboot a box.

**Flips if:** the 6.8 kernel can't be installed on the current image without another image (then B).

**Meanwhile:** nothing local waits on it; it changes only the setup of scopes 6 and 9.

**Answer:**

### Q28/28 [run, score] : the score session's fixed-load pair, across two boxes: how is it read?

D114 puts each server on its own `c5.large` (each installed on a clean box), so the A B B A probes at 101,000 users
alternate boxes as well as servers. Two boxes of the same type can differ by a few percent; 3 % is about 1.6 µs/req,
the size of the tuned SQLite's whole predicted gain.

**Question:** how does the score session separate the server from its box?

- **A.** Both boxes must report the same CPU model (D96), and each runs the same short CPU-only PHP benchmark
  (`/opt/php-gcob/bin/php`, no SQLite, no network) before the probes; the servers' difference is read only beyond
  the boxes' gap, and scope 6's lab pairs stay the decision.
  **Aims at:** a bound on the box, for minutes of work.
  **For:** cheap, no reinstall. **Against:** a CPU micro doesn't see the network card or the kernel's share.
- **B.** No cross-box reading: each server's µs/req at 101,000 is a per-box number, and the comparison of the servers
  is scope 6's alone.
  **Aims at:** saying only what the design can tell.
  **For:** honest and simplest. **Against:** the score session gives no comparison at the bench's shape.

**Confidence:** A 55 % · B 45 %

**Recommendation:** A, because it bounds the box for minutes of work while scope 6 keeps the decision.

**Flips if:** the two boxes land on different CPU models (then B, and the README says so).

**Meanwhile:** nothing local waits on it.

**Answer:**

---

Answered questions: [questions/](questions/), the latest in
[2026-11-26-1500.ronde-7.md](questions/2026-11-26-1500.ronde-7.md).

## 🤝 Essentials

**Objective:** beat 71,000 users with real PHP (D2), and understand every step of a request by measuring the ways to
implement it (D3). Done when a submission holds more than 71,000 users for 5 minutes in our own runs, with every
step's choice backed by a measurement.

### What sets the score

- **First wall, connections:** one process is capped at 65,535 fds. The way past it: answer with
  `Connection: close` near the limit, so clients reconnect (HolyPHP did 110k to 145k like that). Closing idle sockets
  silently scored 0 for two entries.
- **Second wall, CPU:** about `users ≈ 8.0 million / µs per request` at 85 % CPU (D40: 9.45 users per steady req/s; it
  read 9.2 million with the leaderboard's whole-run ratio). The Swoole entries were at 94 to 101 µs on the VM, so about
  82,000 users once past the fd wall. Every 10 µs saved is worth about 8,000 to 13,000 users.

### Phases

| # | Phase           | Delivers                                                    | Done when                                               |
|---|-----------------|-------------------------------------------------------------|---------------------------------------------------------|
| 1 | Understand      | Use cases, UML sequences, steps and variants                | You approve this plan                                   |
| 2 | Lab setup       | Seed, container, PHP 8.3 to 8.6 (D8), micro and macro harnesses | A no-op Swoole server gives a µs/req number             |
| 3 | Runtime bake-off | Swoole, Workerman, DIY (D6), same handler                  | One table: µs/req, max connections, RSS per connection  |
| 4 | Realistic baseline | Skeleton of the 5 endpoints, realistic mode, baseline, profile (D27) | The baseline and its profile, Q10 answered |
| 5 | Step lab        | Each step S1 to S9, its variants measured, in the profile's order (5a, 5b: D50) | Each step has a chosen variant and its numbers          |
| 6 | Submission      | The chosen variants together                                | `test/run.sh` passes 42/42                              |
| 7 | Score           | `bench/load.js` ramps, x86 calibration                      | More than 71,000 held for 5 minutes                     |
| 8 | Ring (D76, D84) | First a screen of off-the-shelf io_uring (Swoole's `uring_socket`, an audit of ext-mrloop); then, unless one wins, an io_uring loop in pure PHP through FFI (on 5a's own syscalls, Q25, D112); a SQLite built with PGO, the single-post plan checked | Each lever's µs/req against phase 7's; a new score if they win |
| 9 | Submit          | The PR to the challenge repo                                | CI green                                                |

**Decisions:** 122 active, in [decisions.md](decisions.md). D5 changes how to read the step lab: every prior-art number
is a prediction we re-measure, not an answer.

### Phase 8 scopes (1 to 5 and 8's shared part done; 6 and 9 need your go)

Detail, seams, cases and the predictions in [details/phase-8.md](details/phase-8.md). One commit each, on branch
`phase-8-claude` (D14). Scopes 6 and 9 are AWS sessions: each needs your go. Scope 7 is skipped if nothing wins.

| #  | Commit                                                                  | Done when (short)                                                        |
|----|-------------------------------------------------------------------------|--------------------------------------------------------------------------|
| 1  | `feat(lab): the single-post plan, read`                                  | the re-prepare count and both plans read; `closed` or `timing needed`    |
| 2  | `feat(lab): a SQLite built from the amalgamation, tuned, with PGO`       | an image whose `pdo_sqlite` runs it, trained on a generated database, 42/42 |
| 3  | `feat(lab): off-the-shelf io_uring, Swoole built and ext-mrloop audited` | our app on Swoole's coroutine server over io_uring 42/42; the audit's verdict |
| 4  | `feat(app): the app on an io_uring ring through FFI`                     | `APP_RING=1` 42/42, conformance, stress 0 mismatches on `/posts/{id}`    |
| 5  | `feat(app): three rings, a close past their capacity, the fallback`      | 150,000 connections in one process under 100 fds; the epoll fallback 42/42 |
| 6  | `docs(lab): phase 8's levers on x86, measured`                           | each lever's µs/req against phase 7's submission, chosen or not (needs your go) |
| 7  | `feat(submission): php-Gcob on the ring` (or the levers that won)        | the clean copy, 42/42 on io_uring, `--ci` with and without the filter; stress, conformance, 150,000 held |
| 8  | `feat(lab): the score search on two load generators and two servers`     | two k6 halves, the fixed-load pair, the new walls, smoked on the Mac     |
| 9  | `docs(lab): the score on x86, phase 7 against phase 8, and their ceilings` | each server's highest hold and its wall (needs your go)                |
| 10 | `docs(submission): the new score, labelled`                              | the README's results paragraph updated                                   |

### Phase 7 scopes (merged)

Detail, seams, cases and the predictions in [details/phase-7.md](details/phase-7.md). One commit each, on branch
`phase-7-claude` (D14). Scope 3 is the AWS session: it needs your go.

| # | Commit                                                    | Done when (short)                                                        |
|---|-----------------------------------------------------------|--------------------------------------------------------------------------|
| 1 | `feat(lab): the score search, driven from the load box`   | the local smoke runs the warm-up and the search small, one forced fail, ends on a passing hold; `check_score` and its fixtures; a changed `load.js` refused; k6's MiB a VU measured (D93) |
| 2 | `feat(lab): the two boxes, set up the bench's way`        | the server and load boxes' setup, controller and samplers; the unit verified; `launch.sh --print` and `teardown.sh --verify` with placement groups (factory) |
| 3 | `docs(lab): the score on x86, Arjay's search`             | the predictions committed before the launch; the setup proofs; every k6 run and decision; the score or the measured wall; the differences from the bench (D96); `TEARDOWN CLEAN` |
| 4 | `docs(submission): our own run on AWS, labelled`          | one paragraph in "Results", labelled not the bench's score, linked (D103) |

### Phase 6 scopes (merged)

Detail, seams, cases and the predictions in [details/phase-6.md](details/phase-6.md). One commit each, on branch
`phase-6-claude` (D14). Scope 4 measures, so it needs a quiet Docker VM (D15).

| # | Commit                                                                   | Done when (short)                                                        |
|---|--------------------------------------------------------------------------|--------------------------------------------------------------------------|
| 1 | `feat(submission): php-Gcob, the chosen variants in a clean copy`         | 42/42 in the lab's image with no switch; 2 workers, soft limit 64,000, `mmap` off; `check_submission` green (D79) |
| 2 | `feat(submission): install.sh builds PHP 8.5 and its extensions from pinned sources` | `lab/submission-test.sh`: clean `ubuntu:24.04`, `install.sh` as root, `test/run.sh` 42/42 as `deploy` on port 80, `nofile` 65535, healthy under 60 s; `--ci` the same on a runner-like box (D78, D81, D82, D85) |
| 3 | `docs(submission): the README and the rules audit`                       | the table, direct, the optimizations with their numbers and links, rules 5, 6, 7, 10, 11 audited; links resolve; the guard passes |
| 4 | `docs(lab): the submission against the lab, one pair`                    | done at 12,000 req/s (D88): +0.17, +1.49, −0.87 µs/req, parity both ways; 24,000 couldn't decide |

### Phase 5b scopes (merged, 8 skipped)

Detail, seams, cases and the predictions in [details/phase-5b.md](details/phase-5b.md). One commit each, on branch
`phase-5b-claude` (D14). Scopes 7 and 8 measure, so they need a quiet Docker VM (D15); scope 9 needs your go for AWS.

| # | Commit                                                         | Done when (short)                                                        |
|---|----------------------------------------------------------------|--------------------------------------------------------------------------|
| 1 | `feat(lab): a series driver and the host's state in each run`  | `stages.sh` runs series with the quiet check and dates; a host line in each run's JSON (D68) |
| 2 | `feat(lab): alternate the order of a round, and one floor rule` | ABBA rounds, `--floor-from` an A/A folder, one rule for every pair (Q19, coded A) |
| 3 | `feat(app): several processes on SO_REUSEPORT`                 | S1-b: `APP_WORKERS=2` passes 42/42, both pids answer (D69)               |
| 4 | `feat(app): JSON built by concatenation or by SQLite`          | `APP_JSON=concat` and `sqlite` 42/42, ns per feed for each                     |
| 5 | `feat(app): parser and event-loop variants`                    | the parse micro bench; `APP_PARSE=lean` only if it saves 20 %; `APP_LOOP` presets 42/42 |
| 6 | `feat(app): an FFI driver to libsqlite3`                       | ns per feed for PDO and FFI; stops at the micro if FFI doesn't win       |
| 7 | `docs(lab): the CPU steps of 5b and S1-b, measured on the Mac` | the A/A floor, each variant's pairs, S1-b's cost, a choice per step      |
| 8 | `docs(lab): the chosen variants together, 5b`                  | **skipped (D75):** no CPU variant chosen, the same configuration as 5a's |
| 9 | `docs(lab): S1-b and the reconnect on x86`                     | done: a reconnect 23.44 µs, S1-b +7.44 µs/req, S1-b chosen               |

### Phase 5a scopes (merged)

Detail, seams, cases and the predictions in [details/phase-5.md](details/phase-5.md). One commit each, on branch
`phase-5-claude` (D14). Scopes 6, 10, 11 and 12 measure, so they need a quiet Docker VM (D15). Each variant is a
switch: unset, the server is phase 4's skeleton.

| #  | Commit                                                                  | Done when (short)                                                        |
|----|-------------------------------------------------------------------------|--------------------------------------------------------------------------|
| 1  | `feat(lab): the step lab's A/B runner and a syscall count`              | interleaved runs with a median per variant and a noise verdict; syscalls per request |
| 2  | `feat(app): Connection: close past a soft connection limit`             | S1-d: closes past the limit, 42/42, more connections over time than fds  |
| 3  | `feat(app): several processes on SO_REUSEPORT`                          | **not built:** S1-d adds 13.6 % at 150,000 users, under D60's 15 %         |
| 4  | `feat(lab): FFI micro benches for an io_uring loop`                     | ns per FFI op, JIT on and off; the spike's stop rule read                |
| 5  | `feat(lab): a no-op server on an io_uring ring through FFI`             | 60,000 connections on one ring with no fd each (stretch: 80,000 on two), 0 mismatches, a µs/req; or a stop and why |
| 6  | `docs(lab): S1 and the io_uring spike, measured`                        | the cost of a reconnect, S1-b's cost, the fd-wall run, the chosen S1     |
| 7  | `feat(app): feed query, fetch and pragma variants`                      | each variant 42/42, ns per feed                                          |
| 8  | `feat(app): response write and syscall variants`                        | each variant 42/42, its syscall count                                    |
| 9  | `feat(app): group commit per loop turn and a background checkpointer`   | one commit per turn, responses after it, a write survives `kill -9`      |
| 10 | `docs(lab): S6, S8 and S9, measured`                                    | each variant's µs/req against the skeleton's, a chosen variant per step  |
| 11 | `docs(lab): the chosen variants together`                               | the new µs/req, profile and held rate                                    |
| 13 | `docs(lab): the two Swoole entries in our realistic mode` (after 6, D61)  | their µs/req, connections and memory; two Mac-to-bench factors           |
| 12 | `docs(lab): the x86 calibration on EC2`                                 | the x86 factor, only with your go (Q14)                                  |

### Phase 4 scopes (delivered)

Detail, seams, cases and the predictions in [details/phase-4.md](details/phase-4.md). One commit each, on branch
`phase-4-claude` (D14). Scope 5 measures, so it needs a quiet Docker VM (D15).

| # | Commit                                                                    | Done when                                                                 |
|---|---------------------------------------------------------------------------|---------------------------------------------------------------------------|
| 1 | `feat(app): the five endpoints on the DIY loop, the challenge's tests`    | `lab/challenge-test.sh` prints the challenge's 42 checks passed, twice    |
| 2 | `feat(lab): realistic mode, the bench's journey with scaled think time`   | a small staircase prints one row per step; a step past capacity fails on the 97 % rule (D31) |
| 3 | `feat(lab): idle connections and per-second series in the realistic mode` | idle connections held start to end; one row per second; cold proven by `fincore` |
| 4 | `feat(lab): Excimer profiles folded into the steps S1 to S9`              | a profiled run folds into S1 to S9, under 5 % unclassified                |
| 5 | `docs(lab): the realistic baseline`                                       | 3 holds and their median, the profile, Q10's answer, predictions judged   |
| 6 | `chore(lab): check that every results folder regenerates its tables`     | `lab/check.sh` runs every `summarize.sh` against its README (D37)         |

### Phase 3 scopes (delivered)

Detail, seams, cases and the predictions in [details/phase-3.md](details/phase-3.md). One commit each, on branch
`phase-3-claude` (D14).

| # | Commit                                                            | Done when                                                                  |
|---|-------------------------------------------------------------------|----------------------------------------------------------------------------|
| 1 | `chore(lab): lint the lab's bash with a pinned shellcheck`        | `lab/check.sh` runs shellcheck in Docker, and a fixture makes it fail       |
| 2 | `feat(lab): shared handler, Swoole bake-off server, conformance`  | conformance all `ok` on Swoole, VALID at 7,000 req/s on both routes         |
| 3 | `feat(lab): idle-connection harness, max connections and RSS`     | `lab/conns.sh` prints steps, max and RSS per connection, finds a low ceiling |
| 4 | `feat(lab): pcntl, sockets, ext-event and Workerman in the images` | caches filled on stock, empty when patched; a Workerman boots on both trees |
| 5 | `feat(lab): Workerman bake-off server, caches off and on`         | conformance all `ok` and VALID at 7,000 on both trees                       |
| 6 | `feat(lab): DIY server, our own loop and parser`                  | conformance all `ok` (partial reads, pipelining), VALID at 7,000            |
| 7 | `docs(lab): the runtime bake-off`                                 | the table: µs/req at 7,000 (and 9,500), max connections, RSS per connection |

### Phase 2 scopes (delivered)

Detail, seams and predictions in [details/phase-2.md](details/phase-2.md). One commit each, pushed on `main`.

| # | Commit                                                       | Done when                                                                 |
|---|--------------------------------------------------------------|---------------------------------------------------------------------------|
| 1 | `chore(seed): build the seed database outside git`           | `lab/seed.sh` prints OK, `feed.db` and `tokens.json` stay out of git      |
| 2 | `feat(lab): PHP 8.3 lab image with Swoole 6.2.6`             | `lab/run.sh 8.3-apt php-info` prints PHP 8.3, Swoole 6.2.6, the limits    |
| 3 | `feat(lab): PHP 8.3 to 8.6 from source with Swoole`          | `php-info` passes on 8.3 to 8.6, or Swoole's failure is documented        |
| 4 | `feat(lab): micro benchmark harness, JIT on and off`         | `lab/micro.sh` prints ns/op on every image, JIT on and off, checked       |
| 5 | `feat(lab): macro harness with k6 and a no-op Swoole server` | `lab/macro.sh` prints µs CPU/req, p95, p99, RSS, 0 errors at 2,000 req/s  |
| 6 | `docs(lab): first number, the no-op Swoole server`           | the prediction, then 3 interleaved repeats at 1k, 3k, 6k req/s            |

### Out of scope

- **Reading SQLite's B-trees directly:** not reachable from PHP without writing C. FFI to `libsqlite3` stays a
  variant of S6 (5b). io_uring came back in through PHP's FFI: phase 5a's spike, up to a no-op server (D52).

## 🤖 For Claude

You don't need to read this part: it's the index of the execution details, in `details/`.

- [Use cases](details/use-cases.md): UC0 to UC6, the traffic mix.
- [Sequences](details/sequences.md): one Mermaid sequence per use case, arrows tagged with their step.
- [Steps](details/steps.md): S1 to S9, the variants and how to measure each.
- [Measuring](details/measuring.md): micro and macro harnesses, profiling, environment.
- [Runtimes](details/runtimes.md): the PHP runtimes in theory, before the bake-off.
- [Prior art](details/prior-art.md): what mattsplat, tzimpel and HolyPHP already measured.
- [Phase 2](details/phase-2.md): the lab scopes, their seams, and the prediction for the first number.
- [Phase 3](details/phase-3.md): the bake-off scopes, their seams and cases, and the predictions.
- [Phase 4](details/phase-4.md): the realistic baseline's scopes, their seams and cases, and the predictions.
- [Phase 5](details/phase-5.md): the step lab's first run (5a): scopes, seams, cases and the predictions.
- [Phase 5b](details/phase-5b.md): the step lab's second run: scopes, seams, cases and the predictions.
- [Phase 6](details/phase-6.md): the submission: scopes, seams, cases and the predictions.
- [Phase 7](details/phase-7.md): the score on x86: scopes, seams, cases and the predictions.
- [Phase 8](details/phase-8.md): the ring: scopes, seams, cases and the predictions.
- [Phase 2's run](runs/phase-2/run.md), [phase 3's](runs/phase-3/run.md), [phase 4's](runs/phase-4/run.md), [phase 5a's](runs/phase-5a/run.md), [phase 5b's](runs/phase-5b/run.md), [phase 6's](runs/phase-6/run.md) and [phase 7's](runs/phase-7/run.md): progress, reviews and retro, with
  their `state/`.
