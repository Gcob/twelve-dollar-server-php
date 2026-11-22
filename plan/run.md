# Run: phase 4, realistic baseline

**Pace:** 🟢 full · 5-hour 10 % · weekly 29 % at 17:35 · 5-hour resets 20:20 · away

**Status:** 🔵 Running
**Progress:** step 5/7, history cleaned and pushed, `blind-reviewer` pass 2 next · started 2026-11-22 10:50
**Since your last read:** scope 5 done: the baseline holds 23,386 req/s (about 221,000 users at 9.45) at 27.15 µs
of CPU per request, p99 28 ms, 60,000 idle held (median of 3 holds; arm64, not a score). The rate is a harness floor at
`s = 0.02`, the server 63 % busy (D47). Profile: SQLite 52 %, write 20 %, JSON 10 %. 6 of 12 predictions held.
Q10: the stalls are outside the PHP code. Two harness fixes (`0e7f604`, `52e9792`). Results in
`lab/results/2026-11-22-realistic-baseline/README.md` on the branch.
**👉 Your turn:** Q11 in plan.md, not blocking. The history cleanup is done (below).

## Steps

| #   | Step              | State   | Start | End | Detail |
|-----|-------------------|---------|-------|-----|--------|
| 0   | Plan review       | done    | 10:59 | 11:17 |     | full NOT_OK at 11:10 (1 🔴, 5 🟠), settled as D38 to D43; delta NOT_OK at 11:14 (1 🟠), settled as D44; delta 2 and final full OK at 11:17 |
| 1   | Scopes            | done    | 11:19 | 17:46 | 6/6    |
| 2   | Questions         | done    | 17:40 | 17:40 | none open: scope 5's two settled as D47 |
| 3   | Lab suite         | done    | 17:50 | 17:55 | 59/59 ok on `7d6281a`, no flake (other containers back at 17:54 during it) |
| 4   | `pr-reviewer`     | done    | 17:55 | 18:04 | OK at pass 1: no 🔴 or 🟠, 9 🟡 (7 being fixed), 1 plan question (Q11) |
| 5   | `blind-reviewer`  | running | 18:09 |     | NOT_OK at pass 1 (1 🔴, 2 🟠), fixed 18:47; history cleaned 18:50; pass 2 next |
| 6   | Delivery          | to do   |       |     |        |

## Scopes

| #   | State | Start | End | Lines | Checks | SHA | Fixes |
|-----|-------|-------|-----|-------|--------|-----|-------|
| 1   | done | 11:19 | 11:37 | +1060 -156 | 42/42 twice, broken fixture fails, check.sh 35/35 (PM rerun) | `f840725` |       |
| 2   | done | 11:40 | 12:28 | +8059 -3 | staircase 3/3 pass, slow fixture stops on the 97 % rule, cap 5,400 VUs, s = 0.0286, replay at 480k rows/s, check.sh 44/44 (PM rerun) | `07808e7` |       |
| 3   | done | 12:33 | 13:12 | +1632 -80 | 60,000 idle held start to end with 5,377 VUs (19,565 req/s, smoke), cold `fincore` 0 % vs 100 %, macro `--fresh-db --cold --per-second`, check.sh 53/53 (PM rerun) | `81d9216` |       |
| 4   | done | 13:22 | 13:53 | +1232 -38 | excimer 1.2.6 (not 8.6), fold 0 % unclassified, calibration 0.1 / 0.4 points off (JIT on / off), check.sh 56/57 (PM rerun: `check_realistic_idle_run` flaky, passes alone 3/3) | `6621654` | scope 3's flaky checks fixed: `0cbefb1`, `90a54c7` (10/10 alone each, check.sh 57/57) |
| 5   | done | 14:52 | 17:30 | +443864 -5 (raw JSON) | 3 holds pass, 26 counted runs `other_containers: 0`, `summarize.sh` = README (PM check), predictions copied unchanged | `8fe2ab8`, `60116f0` | harness: `0e7f604`, `52e9792` |
| 6   | done | 17:40 | 17:46 | +87 -0 | 4 folders: 3 `ok`, calibration skipped (no script); drift fixture fails and names the line; check.sh 59/59 (developer) | `be42b8b` | fd-wall note in the baseline README (planning session): `7d6281a`, results check `ok` |

## Reviews

### `plan-reviewer`, full · 10:59 to 11:10 · NOT_OK

**Report:** [PLAN-2026-11-22-1110.md](reviews/PLAN-2026-11-22-1110.md). 6 questions, each settled with the reviewer's
own pick (D38 to D43), and the 12 🟡 folded into `details/phase-4.md`. Predictions 3 and 7 revised at 11:12, still
before any measurement.

- **🔴 With 60,000 idle connections, k6 gets about 500 ports.** The idle client `bind()`s each port, and bound ports
  are skipped by every unbound `connect()`. Settled: D38, k6 binds its own source addresses; scope 3's Done-when now
  runs 60,000 idle with k6 at its cap.
- **🟠 The VU budget doesn't close** (11,400 req/s at most against a predicted knee up to 18,000; 3,000 × 2 MiB plus
  2 GiB is over the VM). Settled: D39, the cap and the scale from calibration, a memory limit on k6.
- **🟠 10.8 users per req/s includes the leaderboard's ramps.** A steady load is 9.45. Settled: D40; D16's users and
  🤝's formula corrected (7,000 req/s is about 66,000 users; about 8.0 million / µs).
- **🟠 No way to get per-step and per-second numbers from k6** without GBs of raw samples on the measured VM. Settled:
  D41, live per-second histograms from a FIFO, nothing raw on disk, k6 stopped at the first failing step.
- **🟠 `macro.sh` can't run the skeleton for Q10.** Settled: D42, one seed-copy function with `--cold`, wired in scope 3.
- **🟠 Nothing proves where Excimer puts a C function's samples under the JIT.** Settled: D43, a calibration fixture
  in scope 4.
- **🟡** profile flushed on a timer and copied out; WAL frames from the `-shm` header; k6's own loop overhead in the
  97 % margin; one sampler loop, no `docker exec` per second; `fsync` before eviction; `cp` inside the server container;
  Excimer in its own layer with a switch; statuses 201, 401, 503; `/health`'s `db` and auth before id; where `test.sh`
  runs; the idle client's path and body; k6's exit 99.

### `plan-reviewer`, delta · 11:12 to 11:14 · NOT_OK

**Report:** [PLAN-2026-11-22-1116-delta.md](reviews/PLAN-2026-11-22-1116-delta.md). D38 to D43 hold; the 🟡 are folded
in correctly.

- **🟠 k6's live stream has no backpressure:** k6 buffers samples in memory when the reader falls behind, so a slow
  aggregator ends in k6 killed by its memory limit mid-staircase, and the plan watched the wrong sign. Settled: D44,
  calibrate with the stream on, a replay case at 40,000 req/s worth of rows, and a lag and memory gate on every
  measured run.
- **🟡** the VU cap also bounded by the server's free fds (about 5,400); one function per step in the skeleton (D43);
  `macro.sh --fresh-db` so the bake-off servers don't get a second copy; a slow fixture server for scope 2's
  above-capacity case; a missing period in D16.

### `plan-reviewer`, delta 2 and final full pass · 11:16 to 11:17 · OK

**Report:** [PLAN-2026-11-22-1120-final.md](reviews/PLAN-2026-11-22-1120-final.md). No 🔴 or 🟠; the scope order
holds. 4 🟡, all fixed in the plan at 11:18: two `{R}` placeholders in D43 and D44; D44's lag gate now the calibrated
lag plus 2 s with `K6_CSV_SAVE_INTERVAL` lowered (k6 flushes its CSV every second); `plan.md`'s "Since your last
read"; the aggregator in its own container, outside k6's memory budget.

### `pr-reviewer`, pass 1 · 17:55 to 18:04 · OK

**Report:** [PR-2026-11-22-1755.md](reviews/PR-2026-11-22-1755.md). No 🔴 or 🟠; it also wrote the PR description.

- **⚠️ Plan to review:** the held rate is the harness's floor (D47), so phase 5 can only tell variants apart by µs per
  request. **Status:** Q11 in plan.md, for Jacob, not blocking.
- **🟡 1 to 4, 6:** four README readings say more than the data (Pss_Anon's cause, "7 times a post", S1 is mostly the
  idle accepts, "at least" missing), and the 11 ms longest callback at 24,000 req/s isn't mentioned. **Status:**
  fixed in `ea30389` (scope 5's developer, 18:05 to 18:08).
- **🟡 5:** the default lag gate is 4 s, under the 5.5 s measured. **Status:** fixed in `ab3dd04` (6 s, D46; realistic checks ok alone).
- **🟡 7:** lab/README's calibration table is typed by hand. **Status:** fixed in `ea30389` (said so).
- **🟡 8, 9:** a duplicated `jq` block, a 3 % tolerance. **Status:** set aside (reasons in project-lead.md).

### `blind-reviewer`, pass 1 · 18:09 to 18:17 · NOT_OK

**Report:** [BLIND-2026-11-22-1809.md](reviews/BLIND-2026-11-22-1809.md).

- **🔴 1 Two calibration JSON files list your 23 other containers' names, on the public branch since `07808e7`.**
  Scope 2's calibration ran on the busy VM and the harness recorded the names. **Scopes:** 2. **Status:** fixed in
  `0706612` (count only, files scrubbed, a check scans every JSON); Q12 = A (18:25): history rewritten by the PM, then pushed again. `main` is clean.
- **🟠 2 The fold can never say "unclassified"**: an unnamed frame takes its named caller's step, so a renamed step
  function would move its cost without a warning. **Scopes:** 4. **Status:** fixed in `c2178cc` (classify by the leaf frame; the baseline stays at 0 % unclassified).
- **🟠 3 The per-second probes may cause part of the p99 and the stalls** (11 ms longest callback each second, only
  with 60,000 idle), and nothing can run without them. **Scopes:** 3, 5. **Status:** fixed in `5deb526`, `af8fe6a` (`--no-series`
  switch, README labels); the hold that separates them needs a quiet VM: phase 5.
- **🟡 6, 7, 9, 10:** fixed in `e7c2d16`. **🟡 4, 5, 8, 11:** set aside (reasons in project-lead.md).

### History cleanup · 18:31 to 19:00 · done

Jacob, 18:31, through the planning session: "please clean master and force push, and make sure the git history has
no leak at all." One-time exception to "never push --force".

- **Backup:** every ref in a bundle outside the repo, never pushed.
- **Audit of every commit and message** (`main`, `phase-4-claude`, `phase-3-claude`): container names in the 2
  calibration JSON files (13 commits, the branch only); 3 short nickname phrases in plan files (`main`); nothing
  else (no email inside a file, no `/Users` path, no key or token, no employer name, no private word in a message).
- **Rewrite:** `git filter-repo --replace-text` on all refs, the names lists dropped from the JSON and the phrases
  replaced by "(names left out)". Only those files changed; commit counts unchanged (`main` 90, branch 82); every
  pattern returns nothing on the 109 rewritten commits. `phase-3-claude` holds no leak and kept its SHA.
- **SHAs:** every SHA from the first leak on changed; the plan and the baseline README point to the new ones
  (`989f932` on the branch).
- **Checks:** `lab/check.sh` 61/61 ok on the rewritten branch.
- **Not rewritten:** the author email in commit metadata is your own git config (personal address), as asked.
- **GitHub** may keep old commits reachable by their SHA for a while; only GitHub Support can purge them: your call.

