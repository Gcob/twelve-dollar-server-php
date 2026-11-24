# $12 server challenge in PHP

**Status:** ⏸️ Phase 5b: scopes 1 to 7 delivered (both final reviews OK, branch `phase-5b-claude` pushed, not merged); scope 9 waits for your AWS go · approved on 2026-11-21 · snapshot 2026-11-21-0920 ·
**Round:** 6
**Since your last read:** phase 5b's Mac work is done (scopes 1 to 7, D75): no new CPU variant beats the noise (the
FFI SQLite driver, SQLite-built JSON, a lean parser, the loop presets, PHP 8.4 and 8.6: SQLite's own work is 98 % of a
feed), and S1-b costs +2.14 µs/req (+8.6 %) on the Mac. What's left is x86 (your go, 🔴 below), then the reviews.
Before that: phase 5b started on 2026-11-23 at 23:19 on your "Yes, merge and go". Its plan is in
[details/phase-5b.md](details/phase-5b.md): 9 scopes, the predictions written before any run. Two project-manager
decisions: S1-b is built before the AWS session, so one session prices it with the reconnect (D69), and 5b's
reference is `mmap-off` (D70). Q19 is coded as A until you answer. Progress in [run.md](run.md).
**Project:** this repo, `plan/` · **Submission:** `submissions/php-<runtime>-Gcob/` · **Jira:** none

## 👉 Your turn

> **Answer freely:** a letter or `ok`, your own choice (`other: …`), `?` if it's unclear, or
> `badly framed: …` if an option is missing or the question doesn't hold.

**🔴 Your go for one AWS session (scope 9), blocking only scope 9.** Same shape as 5a's calibration (one `c5.2xlarge`
in `ca-central-1`, about 45 minutes, terminated after; 5a's lived 1 h 01): a second reconnect pair and S1-b against
S1-a (3 pairs), at 7,500 req/s. (No CPU variant was chosen in 5b, so there is no new configuration to compare, D75.) Why it's worth it now: on the Mac S1-b
costs **+2.14 µs/req (+8.6 %)**, a tie with S1-d near 100,000 users and cheaper at 150,000 (S1-d +3.4 to +3.8 µs);
but a reconnect costs **4.0 times** more on the Xeon than on the Mac (23.69 against 5.91 µs, 7a), so the S1 choice is
decided on x86. **What I need:** reattach the factory's `aws/phase-5-x86-calibration-policy.json` to your CLI user and
say "go AWS"; I'll run it right away (scopes 1 to 7 are done, scope 8 is skipped, D75), then you delete the policy.
Without your go, the run delivers scopes 1 to 7 and stops here (⏸️): S1 stays S1-d (5a's choice), and S1-b stays
measured on the Mac only.

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
| 8 | Submit          | The PR to the challenge repo                                | CI green                                                |

**Decisions:** 75 active, in [decisions.md](decisions.md). D5 changes how to read the step lab: every prior-art number
is a prediction we re-measure, not an answer.

### Phase 5b scopes (1 to 7 delivered, 9 waits for your go)

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
| 9 | `docs(lab): S1-b and the reconnect on x86`                     | only with your go: the reconnect and S1-b on a Xeon                      |

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
- [Phase 2's run](runs/phase-2/run.md), [phase 3's](runs/phase-3/run.md), [phase 4's](runs/phase-4/run.md) and [phase 5a's](runs/phase-5a/run.md): progress, reviews and retro, with
  their `state/`.
