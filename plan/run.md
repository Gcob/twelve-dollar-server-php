# Run: phase 2, lab setup

**Pace:** ⏸️ paused (landed at weekly 98 %) · 5-hour 11 % · weekly 98 % at 10:53 · weekly resets 11:00 · away

**Status:** ⏸️ Paused for quota: resumes after the 11:00 weekly reset (the planning session's heartbeat restarts it)
**Progress:** step 1/6, 5/6 scopes done; scope 6 (first number) not started, brief ready · started 2026-11-21 09:22
**Since your last read:** scope 5 is done and pushed (`d2ff24e`): the no-op Swoole server costs about **30 to 40 µs
CPU/req** at 2,000 req/s, drifting up to 35 % within minutes on this Mac. k6 dropped iterations on VM stalls: fixed
with more pre-allocated VUs. Landed at weekly 98 %: scope 6 waits for the reset.
**👉 Your turn:** Q8 and Q7 in [plan.md](plan.md), not blocking (the Mac's 2x noise; 8.6 without Swoole). · **Snapshot:** `snapshots/2026-11-21-0920/`

## Steps

| #   | Step              | State   | Start | End | Detail |
|-----|-------------------|---------|-------|-----|--------|
| 1   | Scopes            | paused  | 09:22 |     | 5/6    |
| 2   | Questions         | to do   |       |     |        |
| 3   | Lab suite         | to do   |       |     |        |
| 4   | `pr-reviewer`     | to do   |       |     |        |
| 5   | `blind-reviewer`  | to do   |       |     |        |
| 6   | Delivery          | to do   |       |     |        |

## Scopes

Starts are when the developer was launched, ends are the commit times (`git log`).

| #   | State   | Start | End | Lines | Checks | SHA | Fixes |
|-----|---------|-------|-----|-------|--------|-----|-------|
| 1   | done    | 09:24 | 09:26 | +112 -0 | seed OK, check.sh 2/2 | `7643677` |       |
| 2   | done    | 09:27 | 09:30 | +166 -0 | php-info OK, check.sh 4/4 | `aef8c0b` |       |
| 3   | done    | 09:31 | 10:00 | +241 -11 | php-info on 4 images, check.sh 9/9 | `c584d41` |       |
| 4   | done    | 10:01 | 10:19 | +1858 -1260 | 5 images x JIT on/off, 5 procs, check.sh 12/12 | `8151a5e`, `cad0e84` | resend 1 (10:08) |
| 5   | done    | 10:20 | 10:50 | +612 -17 | PM reruns valid x2, check.sh 15/15 | `13291fd`, `d2ff24e` | resend 1 (10:30) |
| 6   | to do   |       |     |       |        |     |       |

## Reviews

Not started.
