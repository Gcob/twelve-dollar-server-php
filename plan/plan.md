# $12 server challenge in PHP

**Status:** 🔄 Phase 8: both levers chosen on x86: the tuned SQLite (D128, in the submission) and the ring on the
older provided buffers, Ubuntu's 6.8 refusing the buffer ring (D130, D131: −4.49 µs/req, together −11.59); the ring
goes into the submission tonight (scope 7b), then the score session waits for your go (scope 9)
**Round:** 8
**Since your last read:** both levers won on x86. The tuned SQLite (D128) and the ring (D131: Ubuntu's 6.8 refuses its
buffer ring, so it uses the older provided buffers, D130) are both in the submission now: together −11.59 µs/req
against phase 7's 55.2 (−21 %, bench estimate about 109,800 against 86,800). The full suite is green and the
`pr-reviewer` gave OK on scopes 1 to 8; it raised one question for you (Q29, the score boxes' kernel).
**Project:** this repo, `plan/` · **Submission:** `submissions/php-Gcob/` (D80) · **Jira:** none

## 👉 Your turn

One question, Q29: the kernel of the score boxes. Scope 9 also waits for your go: attach
`aws/phase-8-score-policy.json` (factory) and open port 80; and the lab policy can be detached and deleted (no box is
up). Nothing local waits on you: the review's small fixes run tonight (scope 7c), ready for either answer.

### Q29/29 [run, score] : the score boxes' kernel, AWS's 6.8 (D126) or the generic 6.8 where the ring was proven?

D126 boots every phase 8 AWS box on `linux-image-aws-lts-24.04` (6.8.0-1070-aws), your Q27 answer. Since then, that
kernel refused the ring's buffer ring (D129), and the ring was fixed with the older provided buffers and measured on
the generic 6.8 (6.8.0-151-generic, D130, D131): its older path (`PROVIDE_BUFFERS` with a multishot receive) has never
run on the AWS 6.8. If that kernel refused it too, the score box would print `loop: epoll (io_uring refused: …)` and
phase 8's server would run phase 7's loop: the session's central comparison lost, caught by the `loop:` line after the
42 checks, but after the boxes' setup time. The bench is a KVM VPS on "Ubuntu 24.04, kernel 6.8" (`LEADERBOARD.md`),
almost surely the generic flavour. The generic boot recipe works on these boxes (scope 6c, 6d: back in about a minute).
Found by the `pr-reviewer` (pass 1, ⚠️).

**Question:** which 6.8 do the score boxes boot?

- **A.** The generic 6.8 on every score box, by scope 6c's recipe (`linux-image-generic`, its initramfs, the
  `GRUB_FORCE_PARTUUID` drop-in commented out, `GRUB_DEFAULT`), folded into the `mem=2G` reboot as D126 planned.
  **Aims at:** the kernel the ring was measured and proven on, and the bench's likely flavour.
  **For:** no unknown left on the ring's path; the score and the lab pairs on the same kernel. **Against:** a recipe
  that touches GRUB's drop-in (tested twice, on the lab box only); phase 7's score ran on 7.0, so its comparison reads
  the kernel change anyway (as with D126).
- **B.** AWS's 6.8 as D126, plus a one-minute ring probe on each box right after its reboot (the server's boot line
  must say `ring, 3 rings, legacy buffers`); if refused, that box reboots on the generic 6.8 by the same recipe.
  **Aims at:** D126 as you chose it, with the ring's path checked before anything is spent on it.
  **For:** the kernel you picked, unless proven wrong. **Against:** two code paths in the setup; a refusal costs one
  more reboot and mixes kernels across boxes unless both switch.

**Confidence:** A 70 % · B 30 %

**Recommendation:** A, because the ring is the lever under test and the generic 6.8 is where it was proven and where
the bench most likely runs; AWS's flavour adds an unknown for no gain.

**Flips if:** the bench turns out to run an AWS-like or provider kernel rather than `-generic` (then B).

**Meanwhile:** scope 7c gives `lab/score/server-setup.sh --shape` a choice of the two kernels, D126's as the default
until you answer; nothing runs on AWS before your go.

**Answer:**

---

Answered questions: [questions/](questions/), the latest in
[2026-11-26-2035.ronde-8.md](questions/2026-11-26-2035.ronde-8.md).

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
