# Run: phase 4, realistic baseline

**Pace:** 🟢 full · 5-hour 10 % · weekly 29 % at 17:35 · 5-hour resets 20:20 · away

**Status:** 🔵 Running
**Progress:** step 1/7, scope 6 (the results check) since 17:40 · started 2026-11-22 10:50
**Since your last read:** scope 5 done: the baseline holds 23,386 req/s (about 221,000 users at 9.45) at 27.15 µs
of CPU per request, p99 28 ms, 60,000 idle held (median of 3 holds; arm64, not a score). The rate is a harness floor at
`s = 0.02`, the server 63 % busy (D47). Profile: SQLite 52 %, write 20 %, JSON 10 %. 6 of 12 predictions held.
Q10: the stalls are outside the PHP code. Two harness fixes (`38fc153`, `fcf104f`). Results in
`lab/results/2026-11-22-realistic-baseline/README.md` on the branch.
**👉 Your turn:** nothing. The measuring is over: your containers can come back.

## Steps

| #   | Step              | State   | Start | End | Detail |
|-----|-------------------|---------|-------|-----|--------|
| 0   | Plan review       | done    | 10:59 | 11:17 |     | full NOT_OK at 11:10 (1 🔴, 5 🟠), settled as D38 to D43; delta NOT_OK at 11:14 (1 🟠), settled as D44; delta 2 and final full OK at 11:17 |
| 1   | Scopes            | running | 11:19 |     | 5/6    |
| 2   | Questions         | to do   |       |     |        |
| 3   | Lab suite         | to do   |       |     |        |
| 4   | `pr-reviewer`     | to do   |       |     |        |
| 5   | `blind-reviewer`  | to do   |       |     |        |
| 6   | Delivery          | to do   |       |     |        |

## Scopes

| #   | State | Start | End | Lines | Checks | SHA | Fixes |
|-----|-------|-------|-----|-------|--------|-----|-------|
| 1   | done | 11:19 | 11:37 | +1060 -156 | 42/42 twice, broken fixture fails, check.sh 35/35 (PM rerun) | `64af809` |       |
| 2   | done | 11:40 | 12:28 | +8059 -3 | staircase 3/3 pass, slow fixture stops on the 97 % rule, cap 5,400 VUs, s = 0.0286, replay at 480k rows/s, check.sh 44/44 (PM rerun) | `47e4728` |       |
| 3   | done | 12:33 | 13:12 | +1632 -80 | 60,000 idle held start to end with 5,377 VUs (19,565 req/s, smoke), cold `fincore` 0 % vs 100 %, macro `--fresh-db --cold --per-second`, check.sh 53/53 (PM rerun) | `b47adcf` |       |
| 4   | done | 13:22 | 13:53 | +1232 -38 | excimer 1.2.6 (not 8.6), fold 0 % unclassified, calibration 0.1 / 0.4 points off (JIT on / off), check.sh 56/57 (PM rerun: `check_realistic_idle_run` flaky, passes alone 3/3) | `4775db8` | scope 3's flaky checks fixed: `fc73cee`, `b18af33` (10/10 alone each, check.sh 57/57) |
| 5   | done | 14:52 | 17:30 | +443864 -5 (raw JSON) | 3 holds pass, 26 counted runs `other_containers: 0`, `summarize.sh` = README (PM check), predictions copied unchanged | `671d87b`, `374c75c` | harness: `38fc153`, `fcf104f` |
| 6   | running | 17:40 |     |       |        |     |       |

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
