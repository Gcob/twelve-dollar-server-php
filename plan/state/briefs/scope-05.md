# Brief: scope 5/6, the realistic baseline (measurement)

**Read first:** [common.md](common.md), then `plan/state/developer.md` (scopes 1 to 4's handovers: every harness
option you need is there).
**Worktree:** `.claude/worktrees/twelve-dollar-server-php/phase-4-claude` under the home folder (your prompt gives the
full path) · **Your handover:** `plan/state/developer.md` in the main checkout.
**Planned commit:** `docs(lab): the realistic baseline`

**Summary:** measure the skeleton under the bench's own journey with 60,000 idle connections, on a quiet Docker VM:
the highest load it holds for 5 minutes (median of 3 holds), what each request costs, how latency behaves second by
second, memory and the WAL over time, a profile split into steps, and whether the bake-off's latency stalls are real.
Then write it up in `lab/results/2026-11-22-realistic-baseline/README.md`, with a `summarize.sh` that regenerates its
tables, like `lab/results/2026-11-21-bake-off/`.

**Today:** scopes 1 to 4 built everything: the skeleton (`lab/app/`), `lab/realistic.sh` (staircase, hold, `--idle`,
`--cold`, `--calibrate`, `--profile`, per-second series, the 97 % rule, the lag and memory gate, the VU cap),
`lab/macro.sh --fresh-db --cold --per-second`, the telemetry (`APP_TELEMETRY`), Excimer and `lab/profile/fold.php`.
Scope 2's calibration (busy VM): k6 about 0.3 MiB per VU, VU cap 5,400 (fds, with 60,000 idle), `s` = 0.0286 offers
20,000 req/s at the cap. Scope 3's smoke (busy VM): 17,816 req/s passed with 60,000 idle, 19,565 req/s at the cap.

**Expected, in this order:**

1. **The predictions first:** create the results README with the **Predictions** section of the plan, copied
   **unchanged** (it's below, between the markers), plus a "Plan of the runs" section (this brief's runs), before any
   measured run. Add one line after them: the predictions were written at 10:57 and revised at 11:12, before any
   measurement, and not revised after the smoke runs of scopes 2 and 3 (busy VM), which had already passed 17,816 req/s.
   The predictions keep their D numbers: add the bake-off's line "The D numbers in this section are the decisions in
   `plan/decisions.md`." (the common rule against plan references doesn't apply to this verbatim copy).
2. **Quiet VM, every series:** before each series, `docker ps` must show no container but the lab's own, and every
   counted JSON must say `other_containers: 0`. **If another container is running, stop measuring and tell me at once**
   (`SendMessage` is not available to you: end your work with what's done and the reason). Never stop or remove another
   project's container. No image build and no `lab/check.sh` during the series.
3. **Calibration** on the quiet VM (`realistic.sh --calibrate`, with the stream on): k6's MiB per VU, its CPU, the
   aggregator's lag at low load and at the top rate, achieved against offered at low load; the VU cap; `s`. The lag
   gate is the lag at the top rate plus 2 s (6 s if the top-rate lag is about 4 s).
4. **Staircase:** a fresh run, `--idle 60000`, `APP_TELEMETRY=1`, a warm-up at about 10 % of the expected capacity for
   60 s, then steps of 1,000 req/s from 3,000 req/s, 60 s plateaus, stopping at the first failing step. Then a fine
   staircase of 250 req/s from the last passing rate to the failing one.
   - **A knee above the cap:** if the staircase reaches the VU cap with no failing step, lower `s` (more req/s per VU,
     same VUs) and run it again from the last passing rate. If k6 and the aggregator cross 80 % of their 8 CPUs
     before the server fails, that step is generator-bound and invalid: report the baseline as "at least" the last
     valid passing rate, and say so in your answer (it becomes a question for Jacob: a second load generator).
   - Every step: the 97 % rule, the thresholds, the lag and memory gate, k6's CPU under the line.
5. **Holds:** 3 holds of 5 minutes at the highest passing rate of the fine staircase, each a fresh run (new seed copy,
   new server, new 60,000 idle), `APP_TELEMETRY=1`. The median of the 3 is the baseline. Then 1 hold one fine step
   above. If a hold fails, the 3 holds move one fine step down (like the bench's step down of 250 users).
6. **Profile:** one 60 s run at the baseline's rate with Excimer on (`--profile`), and the same run without it,
   interleaved, so Excimer's cost is known; the fold table with `--us-per-req` from the **unprofiled** run.
7. **Telemetry's cost:** 2 pairs of 60 s runs at the baseline's rate, `APP_TELEMETRY=1` against `0`, interleaved.
8. **Q10:** the bake-off's `lab/macro/k6/posts.js` on the skeleton through `macro.sh --fresh-db --per-second` at
   7,000 req/s with rate / 10 VUs (700, the setting that dropped iterations in the bake-off), 30 s after a 10 s warm-up,
   3 runs warm and 3 cold (`--cold`), interleaved; plus the first 60 s of a cold realistic hold against a warm one at
   the baseline's rate. **A stall** is a second whose max latency is over 100 ms; for each, the server's longest
   callback that second tells "inside the server" (callback ≥ the stall) from "the server wasn't running" (short
   callbacks). Count the stalls per run, warm and cold, and the major faults.
9. **The write-up:** the README holds the predictions, the plan of the runs, then the results: the calibration, both
   staircases (every step), the 3 holds and their median (µs CPU/req, achieved req/s, users at 9.45 per req/s, p95 and
   p99 overall and per endpoint, errors), the hold above, per-second latency (a short excerpt per hold and the stall
   counts; the full series stay in the JSON), memory (`Pss_Anon`, `memory.current`) and the WAL (frames and file bytes)
   over the holds, the profile table (steps × endpoints, µs per request per step) with the user/system split,
   Excimer's and telemetry's cost, Q10's runs and answer, and then **"Did the predictions hold?"**, one line each by the
   rule written with them, and **"The step lab's order"**: the steps ranked by their µs per request in the profile.
   `summarize.sh` regenerates every table from the JSON files next to it (its output, unedited, is in the README).
   Every raw JSON (and the `.txt` of what each run printed, and the collapsed stacks) sits next to the README. Invalid
   runs keep their files and are shown, not counted.

**Done when:** `lab/results/2026-11-22-realistic-baseline/README.md` holds the predictions (copied unchanged), the
staircase, the 3 holds and their median, the hold one step above, per-endpoint p95 and p99, per-second latency, memory
and WAL over time, the profile table, Q10's runs and answer, telemetry's and Excimer's cost, each prediction marked held
or not; every counted run passes and says `other_containers: 0`; `summarize.sh` regenerates its tables (its output
equals the README's tables).

**Decisions that touch you:** quiet VM for every measured run; users at 9.45 per steady req/s; the 97 % rule; VU cap
and `s` from calibration, `s` lowered if the knee is above the cap; the lag gate at the calibrated top-rate lag plus
2 s; a generator-bound step (k6 + aggregator over 80 % of 8 CPUs) is invalid; a profiled run gives no µs/req;
telemetry on in every run; DIY on 8.5; these are arm64 numbers, not a score.

**Out of scope:** changing the app or the harnesses beyond a bug fix that a run reveals (if a harness bug shows, fix
it in a separate small commit `fix(lab): ...` before the series that needs it, and tell me); any step lab variant;
x86.

**Where to look:** `lab/results/2026-11-21-bake-off/README.md` and its `summarize.sh` (the model for the write-up), the
harnesses' READMEs in `lab/README.md`, the handovers.

**Come back to me if:** the VM isn't quiet, the knee is generator-bound, a hold can't pass at any fine step near the
staircase's knee, a harness bug blocks a series, or a run takes far longer than planned (the whole scope should be
about 1.5 to 2 hours of runs).

## The predictions to copy (from `plan/details/phase-4.md`, unchanged)

<!-- BEGIN predictions -->

### Predictions (D5)

Written by the project manager on 2026-11-22 at 10:57, before any phase 4 measurement (commit `b573485`), and revised
at 11:12 after the plan review, still before any measurement: prediction 3 maps users at 9.45 per req/s (D40) instead
of 10.8, and prediction 7 reads the WAL's frames, not its file size. Arm64, Docker Desktop on an M3 Pro, quiet VM, PHP
8.5, the DIY server, 1 CPU.

**What we start from:** the bake-off's DIY at 7,000 req/s: `/noop` 21.88 µs/req, `/posts/:id` (a different post each
request, all 500,000) 29.14; at 9,500, 17.37 and 27.66. DIY held 65,000 idle connections at 1.48 KiB of `Pss` each
(5.19 KiB of `memory.current`). Not measured yet: `/feed` (20 rows, 20 like counts, about 5 KB of JSON), the writes,
the JWT check. The Swoole entries cost 94 to 101 µs/req on the bench's x86 VM, a slower CPU than the M3.

**How they're judged:** a µs/req is the median of the 3 holds; a range holds if the measured value is inside it; a
share is a profile's share of the server's samples.

1. **The skeleton passes the challenge's 42 tests** with the reference SQL, `json_encode` and a hand-written HS256
   check, on the first full run of scope 1's harness after the code is written (no change needed in the test harness).
2. **µs CPU per request under the realistic mix: 50 to 90.** `/feed` costs 3 to 4 times a post (20 rows and 20 counts
   instead of 1), and is 46 % of the requests: it carries more than half of the CPU.
3. **The held rate (median of 3 holds) is 10,000 to 18,000 req/s, so 94,500 to 170,000 mapped users** on the Mac. This
   is arm64 (D35): the x86 VM's CPU is slower, so it is not a prediction of the score.
4. **The 97 % rule fails before the thresholds:** at the first failing step of the staircase, p95 is still under
   500 ms, and the step fails on its achieved rate. Without D31 the staircase would have passed one or more steps
   further.
5. **p99 at the held rate: under 50 ms on every endpoint**, and the writes (like, post) have the highest p99.
6. **Memory with 60,000 idle connections:** `memory.current` 500 to 800 MiB at the held rate (the bake-off's 254 MiB
   baseline plus 60,000 times 5.19 KiB, plus the WAL and SQLite's cache); `Pss_Anon` under 150 MiB.
7. **The WAL's frames in use stay under 2,000 (8 MiB) for the whole 5-minute hold**, a sawtooth: `wal_autocheckpoint`
   at its default (1,000 pages, about 4 MiB) checkpoints it, and one connection never starves a checkpoint. The file
   itself grows to its high-water mark and stays there.
8. **The profile's ranking:** S6 (SQLite) is the largest step with 35 to 55 % of the samples; then S8 (write, with the
   kernel's send inside `fwrite`) 10 to 20 %; then S7 (JSON) 10 to 20 %; S2 (read and parse) 5 to 10 %; S4 (JWT) under
   2 % (7.8 % of requests); S3, S5 and S9 under 2 % each. The cgroup's `system_usec` is 25 to 40 % of the CPU.
9. **Q10: the stalls are not the server's.** Under `posts.js` at rate / 10 VUs, stalls over 100 ms may come back, but
   in every stalled second the server's longest callback stays under 20 ms (the server wasn't running, so the host
   stalled it). Under the realistic hot set, warm, no second has a max latency over 100 ms in any of the 3 holds. Cold,
   the first seconds have more major faults and a higher p99, back to the warm level within 30 s.
10. **GC:** under 5 `gc_status()` runs per 5-minute hold, and none in a stalled second.
11. **Costs of the instruments:** telemetry under 2 % of µs/req; Excimer at 1 ms under 5 %.
12. **k6 at 2,500 VUs:** under 2 MiB per VU (the load test is small and its tokens are shared), so the VM's 7.75 GiB
    holds k6, the server and the idle client together.

<!-- END predictions -->
