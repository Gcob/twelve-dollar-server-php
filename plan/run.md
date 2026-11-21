# Run: phase 2, lab setup

**Pace:** 🟢 full · 5-hour 14 % · weekly 0 % at 11:07 · weekly resets 2026-11-28 11:00 · away

**Status:** 🔵 Running
**Progress:** step 5/6, `blind-reviewer` pass 1 since 11:27 · started 2026-11-21 09:22 · paused 10:53 to 11:07 for the weekly quota
**Since your last read:** the `pr-reviewer` said NOT_OK (1 🟠: the macro server could skip OPcache on a fresh
file), fixed in `cc2ca4f`, then OK on pass 2. New question Q9: which request rate phases 3 and 4 measure at.
**👉 Your turn:** Q8, Q9 and Q7 in [plan.md](plan.md), not blocking (the Mac's noise; the rate; 8.6 without Swoole). · **Snapshot:** `snapshots/2026-11-21-0920/`

## Steps

| #   | Step              | State   | Start | End | Detail |
|-----|-------------------|---------|-------|-----|--------|
| 1   | Scopes            | done    | 09:22 | 11:16 | 6/6 committed and pushed |
| 2   | Questions         | skipped |       |     | Q7 and Q8 are open but touch phases 3 and 4, not this phase's code: carried to delivery |
| 3   | Lab suite         | done    | 11:17 | 11:18 | `lab/check.sh` 15/15, 36 s |
| 4   | `pr-reviewer`     | done    | 11:18 | 11:27 | pass 1 NOT_OK (1 🟠), pass 2 OK |
| 5   | `blind-reviewer`  | running | 11:27 |     | pass 1 |
| 6   | Delivery          | to do   |       |     |        |

## Scopes

Starts are when the developer was launched, ends are the commit times (`git log`).

| #   | State   | Start | End | Lines | Checks | SHA | Fixes |
|-----|---------|-------|-----|-------|--------|-----|-------|
| 1   | done    | 09:24 | 09:26 | +112 -0 | seed OK, check.sh 2/2 | `7643677` |       |
| 2   | done    | 09:27 | 09:30 | +166 -0 | php-info OK, check.sh 4/4 | `aef8c0b` |       |
| 3   | done    | 09:31 | 10:00 | +241 -11 | php-info on 4 images, check.sh 9/9 | `c584d41` |       |
| 4   | done    | 10:01 | 10:19 | +1858 -1260 | 5 images x JIT on/off, 5 procs, check.sh 12/12 | `8151a5e`, `cad0e84` | resend 1 (10:08) |
| 5   | done    | 10:20 | 10:50 | +612 -17 | PM reruns valid x2, check.sh 15/15 | `13291fd`, `d2ff24e` | resend 1 (10:30); R1 R2 R4 R7 (`cc2ca4f`, `f5a122c`) |
| 6   | done    | 11:07 | 11:16 | +4864 -0 | 9/9 runs valid, check.sh 15/15 | `c3a487b` |       |

## Reviews

### `pr-reviewer`, pass 1 · 11:18 to 11:24 · NOT_OK

**Report:** [PR-2026-11-21-1119.md](reviews/PR-2026-11-21-1119.md). All 6 scopes meet their "Done when"; it recomputed
the first number from the JSON and found no private data in any tracked file.

#### R1 🟠 The macro server can run without OPcache or JIT after a recent edit

**Scopes:** 5 · **Status:** fixed (`cc2ca4f`)

`LAB_SERVER_PHP_FLAGS` (`lab/lib.sh:54`) lacks `opcache.file_update_protection=0`. A server file saved less than 2 s
before `lab/macro.sh` starts it isn't cached nor JIT-compiled, and the run still comes out VALID, with nothing in the
JSON to show it. The micro harness already avoids this trap.

#### R2 🟡 `zend.assertions` isn't pinned

**Scopes:** 3, 4, 5 · **Status:** fixed (`cc2ca4f`)

The source images ship no php.ini (assertions on, 1) while Ubuntu's php.ini on `8.3-apt` sets -1: the 8.3 source
against 8.3-apt control (D13) compares two settings, not only two builds.

#### R3 🟡 Q8 quoted wrong numbers

**Scopes:** plan · **Status:** fixed in `plan.md` by the project manager (committed at 11:27)

28 unstable rows of 40, not 31; at 6k the three runs span 4.7 %, not 2 %.

#### R4 🟡 The first number's "per-wake-up" hypothesis is confounded

**Scopes:** 6 · **Status:** fixed (`f5a122c`)

The connections rise with the rate (100, 300, 600), so the rate-independent cost can't be pinned on wake-ups alone.

#### R5 🟡 `macro.sh` reports an immediate k6 failure late

**Scopes:** 5 · **Status:** left

When k6 dies at once, the failure shows only after 3/4 of the duration.

#### R6 🟡 The Swoole pin lives in three places

**Scopes:** 2, 3 · **Status:** left

Two install scripts and `check.sh` each carry `6.2.6`.

#### R7 🟡 Docs: no link to `lab/`, no prerequisites, a wrong seed time

**Scopes:** 1, 2, 5 · **Status:** fixed (`f5a122c`)

The root README doesn't point to `lab/`; `lab/README.md` doesn't list node 24, sqlite3 and jq; the seed takes about
14 s, not "about a minute".

#### R8 ⚠️ Plan to revisit: which request rate?

**Scopes:** plan · **Status:** question to the plan (Q9)

µs/req depends on the rate (50.2, 30.2 and 21.7 at 1k, 3k and 6k), and the plan picks none. A comparison at 2k would
overstate the score's metric by almost 2x.

### `pr-reviewer`, pass 2 · 11:27 to 11:27 · OK

**Report:** [PR-2026-11-21-1127.md](reviews/PR-2026-11-21-1127.md). R1, R2, R4, R7 fixed; R3 fixed in the plan; R5 and R6
left (listed for you); R8 is Q9. No new finding above minor.
