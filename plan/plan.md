# $12 server challenge in PHP

**Status:** 🏁 Phase 3 delivered, your review · 2 questions (not blocking) · approved
on 2026-11-21 · snapshot 2026-11-21-0920 · **Round:** 2
**Since your last read:** phase 3 is delivered on `phase-3-claude` (pushed, not merged). Per request at 7,000
req/s on posts: DIY 29.14 µs, Swoole 32.83, Workerman nocache 33.32 (Swoole and Workerman tie within the noise; at
9,500 Workerman passes Swoole on posts). All three stop at the fd limit, none on memory. D25 doubled k6's VUs after
posts-only stalls; Q10 asks phase 4 to find their cause. Delivery, review commands and the PR description in
[run.md](run.md#livraison).
**Project:** this repo, `plan/` · **Submission:**
`submissions/php-<runtime>-Gcob/` · **Jira:** none

## 👉 Your turn

> **Answer freely:** a letter or `ok`, your own choice (`other: …`), `?` if it's unclear, or
> `badly framed: …` if an option is missing or the question doesn't hold.

### Q7/9 [run, php-version] : Swoole doesn't build on PHP 8.6: what do we do with 8.6?

Swoole 6.2.6 and 6.3.0-rc2 both stop on `#error "require PHP version 8.5 or earlier"`, then on PHP APIs that 8.6
removed (`ZVAL_IS_NULL`, `zval_dtor`, ...): no trivial fix ([lab/results/swoole-on-php-8.6.md](../lab/results/swoole-on-php-8.6.md)).
The `8.6` image is built without Swoole, so the micro benches (S3 to S7) run on 8.6, but no Swoole server can.
D8 wanted 8.6 measured like the others. Not blocking: phase 2 doesn't need it.

**Question:** how do we treat 8.6 until a Swoole release supports it?

- **A.** Micro benches only on 8.6; the Swoole servers run on 8.3 to 8.5, and we revisit when Swoole ships 8.6.
  **Aims at:** measuring what we can now, without patching anything (D5, rule 10's pinned versions).
  **For:** zero extra work; the micro benches already say whether 8.6 is worth chasing.
  **Against:** no macro number on 8.6 for now, so its effect on the whole server stays a guess.
- **B.** Build Swoole from a pinned commit of its development branch on 8.6, once one builds.
  **Aims at:** the full D8 comparison, macro included.
  **For:** the only way to get a server number on 8.6 soon.
  **Against:** an unreleased Swoole mixes two variables (PHP version and Swoole version), and the submission can't
  ship it if it's not a release.
- **C.** Drop 8.6 from D8.
  **Aims at:** a smaller matrix, less build time.
  **For:** the submission can't use 8.6 with Swoole anyway until a release.
  **Against:** DIY and Workerman (D6) don't need Swoole: 8.6 could still serve them.

**Confidence:** A 75 % · B 20 % · C 5 %

**Recommendation:** A: I put "measure what we can without patching" before the full matrix, because the micro
benches will tell us if 8.6 is worth the effort of B.

**Flips if:** the phase 4 micro benches show 8.6 clearly faster (more than 5 %) than 8.5 on S3 to S7: then B is
worth a try.

**Trail:** 2026-11-21 16:29, phase 3 codes A as the hypothesis: Swoole runs on 8.5 (D17), and Workerman and DIY get
one information run on 8.6 if ext-event builds there. Nothing is patched.

**Answer:**

### Q10 [run, stalls] : the posts route stalls 100 to 450 ms: what causes it, and does phase 4 measure it first?

In the bake-off, 7 runs dropped iterations, **all on `posts.js`**, none of 28 on `/noop`, and 6 of the 7 cost more
server CPU per request than the valid run of their pair (39.36 against 31.62 µs, for one). It may be a
**server-side** stall (SQLite reading from a cold page cache, the mmap of the 250 MB seed, a GC pause) or the host:
without steal accounting a host stall can be charged to the server, and posts runs touch about 108 MiB more guest
memory than `/noop`, so a host under memory pressure could also hit posts only. D25 doubled k6's VUs, which absorbs the stall: the bake-off's µs/req stays
comparable, but **the real bench would see the stall in its p99**. Not blocking: the bake-off's ranking doesn't depend
on it. No measurement tonight.

**Question:** what do we do with it?

- **A.** Phase 4 measures it first, before any posts optimization: posts at rate / 10 VUs with per-second latency, cold
  versus warm page cache, `gc_status()` and SQLite's page-cache counters per run.
  **For:** names the cause before we tune around it; the real bench's p99 is what scores.
  **Against:** a few runs of setup before phase 4's main work.
- **B.** Leave it until the full bench (phase with the 5 endpoints): measure it only if it shows up there.
  **For:** no work on a stall the real load may not produce.
  **Against:** if it's real, every posts number until then hides it.

**Confidence:** A 80 % · B 20 %

**Recommendation:** A: a 450 ms stall is longer than the bench's latency budget, and it's cheap to name now.

**Flips if:** the stall doesn't reproduce at rate / 10 on a quiet VM with a quiet Mac: then it was the host, and B.

**Trail:** 2026-11-21 22:16, raised by the pr-reviewer's delta on scope 7 (item 7) and the planning session; phase 3
codes A as the hypothesis for phase 4's plan. D25 now says the cause isn't separated. 22:21, the blind reviewer's
D2: the cgroup argument against a host cause doesn't hold without steal accounting; the question now names both causes.

**Answer:**

### Phase 3 delivered at 22:36 (run)

**What's established:**

- 13 commits on `phase-3-claude`, pushed: the lab (shared handler, three servers, conformance, connection harness,
  extensions and Workerman in the images) and the bake-off results in `lab/results/2026-11-21-bake-off/`.
  `lab/check.sh` 32/32.
- Both final reviews OK: `pr-reviewer` (delta 2), `blind-reviewer` (delta 2). Every 🟠 fixed.
- The bake-off ran on a quiet Docker VM; the first try (700 VUs) is kept, not counted (D25).

**What I need from you:**

- [ ] **Review and merge `phase-3-claude`** (or ask for its PR): the 3 places to look, the commands and the PR
  description are in [run.md](run.md#livraison).
- [ ] **[run] A check that each results folder regenerates its tables** (from the retro): `lab/check.sh` runs every
  `lab/results/*/summarize.sh` and checks each printed line is in that folder's README. I diffed it by hand at 5
  commits in scope 7. `ok` and phase 4 adds it.

  **Answer:**

- [x] 🔴 **Blocking: quiet the Docker VM, then say "go"** (scope 7, D15). Done at 21:12: 0 other containers, resumed.

- [ ] **[run] Install `shellcheck`** (`brew install shellcheck`): 4 of 6 developers had no linter for the lab's
  ~600 lines of bash. Phase 3 can then add a lint check to `lab/check.sh`.
  Phase 3 runs shellcheck from a pinned Docker image in `lab/check.sh` (scope 1), so this one is only for your editor.

## 🤝 Essentials

**Objective:** beat 71,000 users with real PHP (D2), and understand every step of a request by measuring the ways to
implement it (D3). Done when a submission holds more than 71,000 users for 5 minutes in our own runs, with every
step's choice backed by a measurement.

### What sets the score

- **First wall, connections:** one process is capped at 65,535 fds. The way past it: answer with
  `Connection: close` near the limit, so clients reconnect (HolyPHP did 110k to 145k like that). Closing idle sockets
  silently scored 0 for two entries.
- **Second wall, CPU:** about `users ≈ 9.2 million / µs per request` at 85 % CPU. The Swoole entries were at 94 to
  101 µs on the VM, so about 92,000 users once past the fd wall. Every 10 µs saved is worth 10,000 to 15,000 users.

### Phases

| # | Phase           | Delivers                                                    | Done when                                               |
|---|-----------------|-------------------------------------------------------------|---------------------------------------------------------|
| 1 | Understand      | Use cases, UML sequences, steps and variants                | You approve this plan                                   |
| 2 | Lab setup       | Seed, container, PHP 8.3 to 8.6 (D8), micro and macro harnesses | A no-op Swoole server gives a µs/req number             |
| 3 | Runtime bake-off | Swoole, Workerman, DIY (D6), same handler                  | One table: µs/req, max connections, RSS per connection  |
| 4 | Step lab        | Each step S1 to S9, its variants measured                   | Each step has a chosen variant and its numbers          |
| 5 | Submission      | The chosen variants together                                | `test/run.sh` passes 42/42                              |
| 6 | Score           | `bench/load.js` ramps, x86 calibration                      | More than 71,000 held for 5 minutes                     |
| 7 | Submit          | The PR to the challenge repo                                | CI green                                                |

**Decisions:** 25 active, in [decisions.md](decisions.md). D5 changes how to read the step lab: every prior-art number
is a prediction we re-measure, not an answer.

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
- [Phase 2's run](runs/phase-2/run.md): its progress, reviews and retro, with its `state/`.
