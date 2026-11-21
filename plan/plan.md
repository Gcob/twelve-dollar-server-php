# $12 server challenge in PHP

**Status:** 🟡 Your turn: 2 questions (not blocking) · approved on 2026-11-21 · snapshot 2026-11-21-0920 · **Round:** 2
**Since your last read:** phase 2 (lab setup) is running: 6 scopes below, progress in [run.md](run.md). New
decisions: D13, PHP 8.3 is also built from source as a control; D14, a branch and worktree per phase from phase 3. Traefik is still 🔶 open in [notes.md](notes.md).
**Project:** this repo, `plan/` · **Submission:**
`submissions/php-<runtime>-Gcob/` · **Jira:** none

## 👉 Your turn

> **Answer freely:** a letter or `ok`, your own choice (`other: …`), `?` if it's unclear, or
> `badly framed: …` if an option is missing or the question doesn't hold.

### Q8/8 [run, lab] : The Mac's micro numbers swing 2x between processes: how do we get numbers we can compare?

**See also:** Q7

The micro harness runs each case in 5 separate processes. On the Mac, 31 of its 40 sample rows swing more than 1.3x
between processes, with two clean levels: `ctype_digit "12345"` on 8.4 with the JIT gives about 13 ns or about 27 ns,
nothing in between. Turning ASLR off didn't change it, and it shows with the JIT off and on an empty loop too
([lab/README.md](../lab/README.md), "Why the spread is across processes"). The most likely cause, not proven: macOS
runs the Docker VM's virtual CPU on a performance core or an efficiency core (the M3 Pro has both), and a process
keeps its core for its short life. Phase 2 is still done (the harness runs and says so honestly), but phase 4 compares
variants that differ by 5 to 20 %, and a 2x coin flip drowns that. The macro numbers of scope 6 may swing the same way.

**In short:** the Mac's numbers flip between two speeds, and we need to choose how to measure through that.

**Question:** how do we make the lab's numbers comparable for phases 3 and 4?

- **A.** A one-hour experiment first: lower Docker Desktop's VM to fewer CPUs (for example 4), rerun the sample, and see
  if the slow level goes away.
  **Aims at:** keeping the Mac (D7), after checking the cheapest explanation.
  **For:** one setting, one rerun: if the slow level disappears, the lab is clean and free.
  **Against:** it changes Docker Desktop for your other containers until you set it back, and it may change nothing.
- **B.** Keep the Mac as it is, run more processes (15 or more) and compare the fast level only (the lower cluster
  of process medians), with the slow level reported next to it.
  **Aims at:** same goal as A, by statistics instead of a setting.
  **For:** no setup, works today.
  **Against:** assumes the slow level is pure noise; if a variant changes which level it lands on, we'd miss it.
- **C.** Move the micro and macro measurements to an x86 EC2 instance now (a `c5` with 1 core, D7's plan).
  **Aims at:** numbers that transfer to the bench VM (Xeon, no performance/efficiency cores).
  **For:** the absolute numbers count only on x86 anyway (D7), and the noise source disappears.
  **Against:** costs per hour, an IAM policy to attach, and setup time; every iteration is slower than on the Mac.

**Confidence:** A 50 % · B 30 % · C 20 %

**Recommendation:** A, then B if A changes nothing: I put "cheap and quick to check" first, because one rerun tells
us if the Mac can be a clean lab.

**Flips if:** scope 6's macro numbers (a whole second of requests per sample) turn out stable across repeats: then
only the micro benches need care, and B alone is enough.

**Answer:**

### Q7/8 [run, php-version] : Swoole doesn't build on PHP 8.6: what do we do with 8.6?

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

**Answer:**

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

**Decisions:** 14 active, in [decisions.md](decisions.md). D5 changes how to read the step lab: every prior-art number
is a prediction we re-measure, not an answer.

### Phase 2 scopes (running)

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
