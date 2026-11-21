# Run: phase 2, lab setup

**Pace:** 🟡 steady · 5-hour 9 % · weekly 97 % at 10:25 · weekly resets 11:00 · away

**Status:** 🔵 Running
**Progress:** step 1/6, scope 4/6 (micro harness), sent back at 10:25 · scope since 10:13 · started 2026-11-21 09:22
**Since your last read:** scope 4's micro harness works (`8151a5e`), but the same case on the same image swings
2x from one process to the next (13 vs 27 ns), hidden by the per-run spread. Sent back: repeat each case across processes.
**👉 Your turn:** Q7 in [plan.md](plan.md), not blocking (8.6 without Swoole). · **Snapshot:** `snapshots/2026-11-21-0920/`

## Steps

| #   | Step              | State   | Start | End | Detail |
|-----|-------------------|---------|-------|-----|--------|
| 1   | Scopes            | running | 09:22 |     | 3/6    |
| 2   | Questions         | to do   |       |     |        |
| 3   | Lab suite         | to do   |       |     |        |
| 4   | `pr-reviewer`     | to do   |       |     |        |
| 5   | `blind-reviewer`  | to do   |       |     |        |
| 6   | Delivery          | to do   |       |     |        |

## Scopes

| #   | State   | Start | End | Lines | Checks | SHA | Fixes |
|-----|---------|-------|-----|-------|--------|-----|-------|
| 1   | done    | 09:24 | 09:27 | +112 -0 | seed OK, check.sh 2/2 | `7643677` |       |
| 2   | done    | 09:36 | 09:42 | +166 -0 | php-info OK, check.sh 4/4 | `aef8c0b` |       |
| 3   | done    | 09:44 | 10:12 | +241 -11 | php-info on 4 images, check.sh 9/9 | `c584d41` |       |
| 4   | running | 10:13 |     | +1705 -0 | done-when OK, resent: spread | `8151a5e` | resend 1 |
| 5   | to do   |       |     |       |        |     |       |
| 6   | to do   |       |     |       |        |     |       |

## Reviews

Not started.
