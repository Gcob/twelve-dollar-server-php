# $12 server challenge in PHP

**Status:** 🔵 Phase 4 running (realistic baseline) · 1 question open (not blocking) · approved on 2026-11-21 · snapshot
2026-11-21-0920 · **Round:** 3
**Since your last read:** the baseline is measured (scope 5): the skeleton holds **23,386 req/s, about 221,000
users at 9.45**, with 60,000 idle connections, at **27.15 µs of CPU per request** (median of 3 five-minute holds, p99
28 ms, arm64 on the Mac, not a score). That rate is a floor set by the harness, not the server (its CPU is 63 % busy
there, D47). SQLite is 52 % of the CPU, the response write 20 %, JSON 10 %. 6 of 12 predictions held: the server is
2 to 3 times cheaper than predicted. The measuring is over: your containers can come back. Progress in
[run.md](run.md).
**Project:** this repo, `plan/` · **Submission:**
`submissions/php-<runtime>-Gcob/` · **Jira:** none

## 👉 Your turn

> **Answer freely:** a letter or `ok`, your own choice (`other: …`), `?` if it's unclear, or
> `badly framed: …` if an option is missing or the question doesn't hold.

### ✅ Q12/12 [run, public-history] : your 23 container names are in the branch's pushed history: rewrite it?

**Blocking the delivery** (not the fixes, which go on). The blind-reviewer found that 2 calibration JSON files of scope
2 (`lab/results/2026-11-22-realistic-calibration/scale-0.03-*.json` and `scale-0.1-*.json`, key
`other_containers.names`) list the names of your 23 other Docker containers. They ran on the busy VM, and the harness
recorded the names. They are on the public branch `phase-4-claude` since commit `47e4728`, pushed at about 12:28.
`main` and its history are clean. A fix-forward commit removes them from the files and makes the harness record only
the count, but the old commit keeps them, and the rules forbid me to rewrite pushed history or force-push.

**Question:** what do we do with the branch's history?

- **A.** Rewrite the branch so `47e4728` never held the names (a rebase that scrubs the two files), then force-push
  `phase-4-claude`, with your explicit OK for that one force push (or you run it).
  **Aims at:** names gone from every ref, per-scope commits kept for your review and the merge.
  **For:** the branch is yours alone, nobody builds on it; the SHAs in `run.md` get rewritten once.
  **Against:** a force push, against the usual rule; GitHub may still serve the old commits by SHA until its garbage
  collection (GitHub support can purge them on request).
- **B.** Keep the history, squash-merge the branch into `main`, then delete the remote branch.
  **Aims at:** no force push.
  **For:** `main` never holds the names.
  **Against:** `main` loses the per-scope commits; the old commits stay reachable by SHA for a while, like A.
- **C.** Fix forward only.
  **Aims at:** no history work.
  **For:** nothing to rewrite.
  **Against:** the names stay in the public history for good, and in `main` after a normal merge.

**Confidence:** A 70 % · B 25 % · C 5 %

**Recommendation:** A: it keeps the review history and removes the names from every branch, for one force push on a
branch only this run uses.

**Flips if:** you'd rather not make an exception to "never force-push": then B.

**Stopgap, if you want them off GitHub right now:** delete the remote branch (`git push origin --delete
phase-4-claude`); I push it again, cleaned, after your answer.

**Answer:** A, through the planning session at 18:25: "Please, fix the leak by yourself". The planning session
deleted the remote branch; the project manager rewrites the branch locally (no commit holds the names, `47e4728`
included), checks every commit with `git log -S`, and pushes the clean branch again (no force needed: the remote
branch is gone).

### Q11/12 [run, step-lab-metric] : the held rate is the harness's floor: is CPU per request enough to judge phase 5?

Not blocking: phase 4 delivers either way, and the answer shapes phase 5's plan. At `s = 0.02` the skeleton holds
at least 23,386 req/s with its CPU only 63 % busy: the 97 % rule fails on k6's own loop overhead, not on the server
(D47). So in phase 5, a step variant that saves CPU won't move the held rate: only µs of CPU per request (and the
profile) can tell variants apart. The rule also sits on its edge at 24,000 (4 runs of 17 failed at 96.7 to 97.0 %).
And with one process, the fd wall caps the real bench near 71,000 users whatever the CPU (the baseline README's
step order puts S1-d or S1-b first). Raised by the final `pr-reviewer`
([PR-2026-11-22-1755](reviews/PR-2026-11-22-1755.md), "Plan à revoir").

**Question:** what does the step lab judge a variant on?

- **A.** µs of CPU per request (median of runs) and the profile; the held rate is measured again only at the end of
  phase 5, on the chosen variants together.
  **Aims at:** a sharp, reproducible number per variant, as phase 2's micro benches did.
  **For:** no new tooling; CPU per request is what the server controls; the fd wall makes the one-process rate moot
  past about 7,500 req/s anyway.
  **Against:** latency effects (stalls, queueing) don't show in µs/req; they need the per-second series beside it.
- **B.** Add a second load generator (another machine) first, so the staircase finds the server's own knee.
  **Aims at:** a held rate that is the server's, not k6's.
  **For:** the bench's real pass rule then judges each variant.
  **Against:** new hardware and setup before any step is measured; the Mac's numbers still aren't the x86 score.
- **C.** Change the pass rule for the lab (for example 95 % achieved, or judge on the server's CPU at a fixed rate).
  **Aims at:** a held rate the current harness can reach.
  **For:** no new machine.
  **Against:** moves away from what the bench judges; the knee would still depend on `s`.

**Confidence:** A 75 % · B 15 % · C 10 %

**Recommendation:** A: the server's CPU per request is the lever the step lab pulls, and the score on the real bench
is set by the fd wall first, then by CPU.

**Flips if:** a variant changes latency without changing µs/req (for example group commit): then its per-second
p99 joins the judgment, still without B.

**Answer:** I don't know, should we continue the lab on my ryzen 9 pc tower? It has 64 go RAM DDR5 + RTX4700, we could maybe try to create a VM or something. It is on Windows though

### ✅ Quiet Docker VM for scope 5 (run, answered 13:27)

- [x] **Stop your 23 other containers, then say "go"** (D15). They came back when Docker's VM restarted at 11:18
  (restart policy `always`). Scopes 1 to 4 are code and smoke runs; scope 5 measures the baseline (about 1.5 to 2 hours
  of runs) and can't start while they run. Stopping them earlier is fine: scope 4 doesn't need them.

  **Answer:** done at 13:27: Jacob asked the planning session to stop them for the weekend; their restart policy is now
  `unless-stopped`, so a VM reboot won't bring them back. "Go" for scope 5.

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
| 5 | Step lab        | Each step S1 to S9, its variants measured, in the profile's order | Each step has a chosen variant and its numbers          |
| 6 | Submission      | The chosen variants together                                | `test/run.sh` passes 42/42                              |
| 7 | Score           | `bench/load.js` ramps, x86 calibration                      | More than 71,000 held for 5 minutes                     |
| 8 | Submit          | The PR to the challenge repo                                | CI green                                                |

**Decisions:** 47 active, in [decisions.md](decisions.md). D5 changes how to read the step lab: every prior-art number
is a prediction we re-measure, not an answer.

### Phase 4 scopes (running)

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

- **io_uring and reading SQLite's B-trees directly:** not reachable from PHP without writing C. FFI to `libsqlite3`
  stays a variant of S6.

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
- [Phase 2's run](runs/phase-2/run.md) and [phase 3's run](runs/phase-3/run.md): progress, reviews and retro, with
  their `state/`.
