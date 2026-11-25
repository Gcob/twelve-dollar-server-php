# $12 server challenge in PHP

**Status:** 🔵 Phase 7 running (the score on x86, [details/phase-7.md](details/phase-7.md)): scopes 1 and 2 done (no AWS); ⏸️ the AWS session waits for your go (🔴) · approved on 2026-11-21 · snapshot 2026-11-21-0920 ·
**Round:** 7
**Since your last read:** phase 7 is planned from your two choices (D89 machines, D90 search), and its plan review
is settled (D92 to D101). Four scopes: the search driver with a local smoke, the two boxes' setup scripts, the AWS
session itself, one labelled paragraph in the submission's README. Two changes to your shape: the vCPU is turned off
through EC2's CPU options at launch rather than taken offline after boot (same core, D91); and the load box's type comes
from k6's memory per VU, measured in scope 1 (Q20, D93), because on AWS the search should reach about 140,000 VUs, past a
`c5.4xlarge`'s memory. One question needs you before the session: Q22, opening port 80 to the internet for the session
if EC2's connection tracking would be the wall. The review also found the bench box is a Synteq VPS (Xeon 8260), not a
DigitalOcean droplet (`LEADERBOARD.md`): the score is compared with it (D96). Nothing is created on AWS before your go:
the 🔴 comes once scopes 1 and 2 are ready.
**Project:** this repo, `plan/` · **Submission:** `submissions/php-Gcob/` (D80) · **Jira:** none

## 👉 Your turn

> **Answer freely:** a letter or `ok`, your own choice (`other: …`), `?` if it's unclear, or
> `badly framed: …` if an option is missing or the question doesn't hold.

**🔴 The AWS go for phase 7's session:** in the AWS console (your personal account), create a policy from the
factory's `aws/phase-7-score-policy.json` (name it `twelve-dollar-phase-7-score`), attach it to your CLI user (profile
`jacob-perso`), then say **go**. It allows only a `c5.large` and an `m5.4xlarge` in `ca-central-1`, a placement group,
a security group and a key pair, everything tagged `project=twelve-dollar-server`, and starting, stopping and deleting
only what carries that tag. The session: a dry run first, then 2 h 30 to 3 h 30, under 5 USD; both boxes stop
themselves after 4 hours; at the end `teardown.sh --verify` must show nothing left, and a 🔴 asks you to delete the
policy. **Q22** (port 80 opened to the internet only if EC2's connection tracking would be the wall) is best answered
before the go; without an answer the session stays closed and names the table if it binds.

**🟠 Delete the AWS policy `twelve-dollar-x86-calibration`** (detach it from your CLI user, then delete it): scope 9
is done and `teardown.sh --verify` shows nothing tagged left (only the terminated instance).

### Q18/19 [run, lab] : a series driver and a host-state line in the lab, first thing in 5b?

Six measuring scopes rewrote the same script (quiet check, dated start and end, one `steplab.sh` per series, the gap
between runs), and four could not explain a slow series: `other_containers: 0` was true while the Mac ran 25 % slower
(09:16) and the Xeon failed the 97 % rule at 43 % CPU.

- **A.** 5b's first scope adds `lab/stages.sh` (the series driver) and a host line in each run's JSON (load, the VM's
  CPU, steal on x86, the disk's fsync time). **For:** every later scope saves its script and can tell a slow day
  from slow code. **Against:** one small scope before the first measurement.
- **B.** Leave it; each scope writes its own script. **For:** nothing to build. **Against:** the same 10 lines again,
  and slow days stay unexplained.

**Recommendation:** A. **Flips if:** 5b has few measuring scopes: B.

**Answer:** A (Jacob, decision board, 23:01). D68.

### Q19/19 [run, method] : rotate the order in a round (ABBA) and settle the floor rule once, before 5b measures?

The reference always runs first in a round, and the A/A pairs show an order effect of about -0.2 µs. The floor at
24,000 req/s was 2.57 µs because of one run that failed the 97 % rule (0.27 without it), and D66 then kept variant
runs that failed the same rule. Both reviewers asked for one rule, written before the pairs.

**Question:** before 5b measures anything, should `steplab.sh` alternate which side runs first, and should one floor
rule cover every pair?

- **A.** `steplab.sh` alternates the order (reference first, then variant first), and one rule for every pair, A/A
  included: a run that fails the 97 % rule counts, and the floor is the median of the A/A differences plus their
  spread.
  **Aims at:** verdicts with no order bias, the same rule on both sides.
  **For:** a 0.5 µs variant is neither hidden nor faked by the order. **Against:** new A/A pairs at each rate.
- **B.** Keep today's order and floor, and say it in each README.
  **Aims at:** 5b's numbers comparable pair for pair with 5a's.
  **For:** nothing to rebuild or recalibrate. **Against:** a variant of about 0.5 µs stays invisible or looks real
  by chance.

**Confidence:** A 75 % · B 25 %

**Recommendation:** A: the steps left in 5b (S7, S2, the loop) are small, so the noise rule decides them.

**Flips if:** 5b must compare its numbers to 5a's pair for pair.

**Meanwhile:** coded as A in 5b's scope 2 with a `FIXME(pending)` (run rules), made precise by the plan review
(D71): runs the harness marks invalid stay out as today, the quartiles are inclusive (0.36 µs on 5a's A/A at 24,000),
and round 1 runs the reference last so a one-pair screen has the order bias against the variant. B is `--order fixed`
plus a typed `--floor` (the largest A/A difference). **First result (2026-11-24, 7a):** the A/A at 24,000 in
alternating order gives a floor of 0.864 µs/req (median +0.08, interquartile range 0.78): the first run of a round
still costs 0.2 to 0.3 µs more, and alternating turns that bias into spread instead of a one-sided error. Under B it
would have stayed a one-sided bias of about -0.2 µs with a floor near 0.27 (`lab/results/2026-11-24-cpu-steps-5b/`).

**Answer:**

### Q20/22 [run, machines] : the load box's type from k6's measured memory per VU, not the `c5.4xlarge` as named?

The lab measured k6 at 0.343 MiB a VU. On AWS the server's core costs about 1.57 times less per request than the
bench box (5a's calibration), so its CPU wall should sit near 125,000 to 140,000 users, not the bench's 83,000 to
88,000. A `c5.4xlarge` (32 GiB) holds about 85,000 VUs: k6 would be the wall, and the search would end "at least
85,000, bound by k6".

**Question:** should the load box be sized to hold 160,000 VUs at the memory per VU scope 1 measures with the real
`load.js`?

- **A.** Sized from the measure: up to 0.16 MiB a VU the `c5.4xlarge`, up to 0.33 an `m5.4xlarge` (64 GiB), above an
  `r5.4xlarge` (128 GiB); all three have 16 vCPUs. The policy names only the type chosen.
  **Aims at:** the server's real wall, measured.
  **For:** the search ends on the server, not on k6; same core count as the bench's 16-core generators.
  **Against:** 10 to 40 % more an hour for the load box than a `c5.4xlarge` (cents to a dollar for the session).
- **B.** `c5.4xlarge`, as you named it.
  **Aims at:** the cheapest box that holds the bench's forecast.
  **For:** your shape unchanged. **Against:** the search likely stops near 85,000 on k6, and the server's wall stays
  unmeasured.

**Confidence:** A 80 % · B 20 %

**Recommendation:** A, because the session exists to find the server's wall, and k6's memory decides whether a
`c5.4xlarge` can reach it.

**Flips if:** you'd rather keep the cost lowest and accept "at least 85,000, bound by k6".

**Meanwhile:** coded as A (D93): the policy holds `c5.large` and the type scope 1's measure picks, before you attach
it; B is one line in the policy and in `launch.sh`.

**Answer:**

### Q21/22 [run, submission] : one labelled paragraph with our AWS score in the submission's README?

Phase 6 kept "Results: not scored yet": an estimate in the PR's README reads as a claim. Phase 7 gives a measured
number, but on AWS, not on the bench's droplet.

**Question:** should the submission's README state our own AWS run, labelled as not the bench's score?

- **A.** One paragraph in "Results": our own run on AWS, the boxes, the users held 5 minutes, the wall, that the AWS
  core costs about 1.5 times less per request than the bench box (estimated from two entries), a link to the results
  folder. No bench
  estimate as a claim.
  **Aims at:** a reviewer sees what we measured and how.
  **For:** honest data, linked; Arjay sees we ran his `load.js` unchanged. **Against:** a number in the PR that isn't
  his; a reader may skip the label.
- **B.** Keep "not scored yet"; the AWS number stays in `lab/results/` only.
  **Aims at:** a PR that claims nothing the bench hasn't measured.
  **For:** no risk of reading as a claim. **Against:** the README hides our best evidence.

**Confidence:** A 60 % · B 40 %

**Recommendation:** A, because the number is measured with Arjay's own script and says what it is.

**Flips if:** you'd rather the PR state nothing Arjay hasn't measured himself.

**Meanwhile:** coded as A in scope 4 (no `FIXME` in the README: it's the PR's text; B is one paragraph removed).

**Answer:**

### Q22/22 [aws, network] : open port 80 to the internet for the session, if EC2's connection tracking would be the wall?

EC2's security groups track each connection in the network card. With the session's rules (SSH from your address,
all TCP between the two boxes), every k6 connection is tracked, and a `c5.large`'s limit isn't published; the bench
box has no such table. If it runs out, the search ends on a wall only AWS has. AWS stops tracking a flow when the rule
allows it from `0.0.0.0/0`.

**Question:** if the server box's `conntrack_allowance_available`, read right after launch, is under 220,000 (1.5 times
the search's top), may port 80 on the server's security group open to `0.0.0.0/0` for the session?

- **A.** Yes, only in that case: measured first, opened only if the number says so, closed with the group at teardown.
  **Aims at:** the server's own wall, not AWS's table.
  **For:** opens nothing unless needed. **Against:** the submission answers the internet for up to 3 hours (scanners
  add a few requests to the measurement).
- **B.** No: everything stays tracked, and the table is named as the wall if it binds.
  **Aims at:** no port open to the internet.
  **For:** nothing exposed. **Against:** the search may end on AWS's table, and the server's wall stays unmeasured.

**Confidence:** A 65 % · B 35 %

**Recommendation:** A, because it opens the port only when the measured allowance would otherwise decide the score.

**Flips if:** you'd rather never expose a port of your account to the internet.

**Meanwhile:** coded as B until you answer (D100): opening a port to the internet needs your yes. The allowance is
read and sampled either way.

**Answer:**

---

Answered questions: [questions/](questions/), the latest in
[2026-11-23-1919.ronde-5.md](questions/2026-11-23-1919.ronde-5.md).

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
| 8 | Ring (D76, D84) | First a screen of off-the-shelf io_uring (Swoole's `uring_socket`, an audit of ext-mrloop); then, unless one wins, an io_uring loop in pure PHP through FFI to `liburing-ffi`; a SQLite built with PGO, the single-post plan checked | Each lever's µs/req against phase 7's; a new score if they win |
| 9 | Submit          | The PR to the challenge repo                                | CI green                                                |

**Decisions:** 101 active, in [decisions.md](decisions.md). D5 changes how to read the step lab: every prior-art number
is a prediction we re-measure, not an answer.

### Phase 7 scopes (running)

Detail, seams, cases and the predictions in [details/phase-7.md](details/phase-7.md). One commit each, on branch
`phase-7-claude` (D14). Scope 3 is the AWS session: it needs your go.

| # | Commit                                                    | Done when (short)                                                        |
|---|-----------------------------------------------------------|--------------------------------------------------------------------------|
| 1 | `feat(lab): the score search, driven from the load box`   | the local smoke runs the warm-up and the search small, one forced fail, ends on a passing hold; `check_score` and its fixtures; a changed `load.js` refused; k6's MiB a VU measured (D93) |
| 2 | `feat(lab): the two boxes, set up the bench's way`        | the server and load boxes' setup, controller and samplers; the unit verified; `launch.sh --print` and `teardown.sh --verify` with placement groups (factory) |
| 3 | `docs(lab): the score on x86, Arjay's search`             | the predictions committed before the launch; the setup proofs; every k6 run and decision; the score or the measured wall; the differences from the bench (D96); `TEARDOWN CLEAN` |
| 4 | `docs(submission): our own run on AWS, labelled`          | one paragraph in "Results", labelled not the bench's score, linked (Q21, coded A) |

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
- [Phase 2's run](runs/phase-2/run.md), [phase 3's](runs/phase-3/run.md), [phase 4's](runs/phase-4/run.md), [phase 5a's](runs/phase-5a/run.md), [phase 5b's](runs/phase-5b/run.md) and [phase 6's](runs/phase-6/run.md): progress, reviews and retro, with
  their `state/`.
