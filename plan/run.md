# Run: phase 3, runtime bake-off

**Pace:** 🟢 full · 5-hour 44 % · weekly 18 % at 16:25 · 5-hour resets 18:30 · away

**Status:** 🔵 Running
**Progress:** step 1/7, scope 6 (DIY) since 18:03; scopes 1 to 5 pushed; ext-event built on 8.6 too; plan review OK (delta) at 16:48; scope 1 done and pushed at 16:34 · started 2026-11-21 16:24
**Since your last read:** scope 2 smoke numbers on a busy VM (not results): Swoole 21 µs/req on `/noop`, 31 on posts at 7k. phase 2's run is archived in [runs/phase-2/](runs/phase-2/run.md). Phase 3 is planned in
[details/phase-3.md](details/phase-3.md), predictions written at 16:29 before any measurement; D17 to D20 taken while
you're away.
**👉 Your turn:** Q7 and 1 action (quiet the Docker VM before scope 7) in [plan.md](plan.md), not blocking yet. · **Branch:** `phase-3-claude` (worktree, D14)

## Steps

| #   | Step              | State       | Start | End | Detail |
|-----|-------------------|-------------|-------|-----|--------|
| 0   | Plan review       | done        | 16:29 | 16:48 | full: NOT_OK (1 🔴, 3 🟠), settled as D21 to D24 at 16:44; delta: OK at 16:48, 4 🟡 folded in |
| 1   | Scopes            | in progress | 16:31 |     | 5/7, scope 6 since 18:03 |
| 2   | Questions         | to do       |       |     |     |
| 3   | Lab suite         | to do       |       |     | `lab/check.sh` |
| 4   | `pr-reviewer`     | to do       |       |     |     |
| 5   | `blind-reviewer`  | to do       |       |     |     |
| 6   | Delivery          | to do       |       |     | branch pushed, not merged |

## Scopes

| #   | State | Start | End | Lines | Checks | SHA | Fixes |
|-----|-------|-------|-----|-------|--------|-----|-------|
| 1   | done | 16:31 | 16:33 | +55 -3 | shellcheck ok, check.sh 18/18 (PM rerun) | `a0477ba` |       |
| 2   | done | 16:45 | 16:55 | +837 -37 | conformance 8/8, VALID at 7k on both routes, check.sh 21/21 (PM rerun) | `0d74fda` | delta 🟡 1-3 (relaunch 16:47) |
| 3   | done | 16:59 | 17:12 | +821 -3 | 10k held, nofile 2048 ceiling 2,035 (timeout), check.sh 24/24 (PM rerun) | `deeb8d1` |       |
| 4   | done | 17:15 | 17:50 | +636 -16 | php-info 8.5/8.6 event 3.2.0 + Workerman, caches 5/5, boots on both trees, check.sh 26/26 (PM rerun) | `8c8f7cc` |       |
| 5   | done | 17:53 | 18:01 | +136 -50 | conformance 8/8 on both trees, 4 macro runs VALID, check.sh 28/28 (PM rerun) | `ad52342` |       |
| 6   | in progress | 18:03 |     |       |        |     |       |
| 7   | to do |       |     |       |        |     |       |

## Reviews

### `plan-reviewer`, full · 16:30 to 16:42 · NOT_OK

**Report:** [PLAN-2026-11-21-1635.md](reviews/PLAN-2026-11-21-1635.md). 5 questions, each settled with the reviewer's
own pick (D21 to D24, and scope 4's Done-when now boots a Workerman); the 10 🟡 folded into `details/phase-3.md`.

- **🔴 Workerman can't start: no `pcntl` in the images.** Settled: D21, `pcntl`, `sockets`, `event` as shared
  extensions in scope 4, whose Done-when now starts a `Worker`.
- **🟠 Listen backlog unset (DIY would get PHP's 32).** Settled: D22, 4,096 and `TCP_NODELAY` everywhere; the client
  opens connections one at a time.
- **🟠 Max connections and stop reasons could be wrong** (no "refused" on Linux, the accept queue counted as
  established, `TIME_WAIT` between runs). Settled: D23, counted by the client, client errors fail the run.
- **🟠 The partial-write case never forces a partial write.** Settled: D24, a socket-pair test in scope 6.
- **🟡** D19 miscounted Workerman's headers (3, no `Server`); the spec's 404/400 messages; the caches are static
  locals; Workerman's `start` argv and pid files; Pss instead of VmRSS; predictions 7 and 8 against the prior art
  (revised at 16:44, still before any measurement); `micro.sh` dropped from the quiet-VM rule; the VM had 7, then
  23, other containers running (action in `plan.md`).

### `plan-reviewer`, delta · 16:46 to 16:48 · OK

**Report:** [PLAN-2026-11-21-1650-delta.md](reviews/PLAN-2026-11-21-1650-delta.md). D21 to D24 settle the full
review's 🔴 and 🟠. 4 🟡, all folded in: each server prints its backlog and `TCP_NODELAY` at boot for the JSON; peak
Pss sampled during the run; `other_containers` counts every container that isn't the run's own; DIY loads `sockets`
before `event`. The first three went to scope 2's developer as a relaunch.
