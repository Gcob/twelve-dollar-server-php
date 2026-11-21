# Run: phase 2, lab setup

**Pace:** 🟢 full · 5-hour 35 % · weekly 4 % at 11:38 · weekly resets 2026-11-28 11:00 · away

**Status:** 🏁 Delivered, to review
**Progress:** step 6/6 done · started 2026-11-21 09:22 · delivered 11:43 · paused 10:53 to 11:07 for the weekly quota
**Since your last read:** phase 2 is delivered: both final reviews say OK after fixes, `lab/check.sh` is 16/16.
The first number: **50.2, 30.2 and 21.7 µs CPU/req** at 1k, 3k and 6k req/s (no-op Swoole, arm64). See "Delivery".
**👉 Your turn:** Q8, Q9 and Q7 in [plan.md](plan.md), not blocking (the Mac's noise; the rate; 8.6 without Swoole), and 1 action (shellcheck). · **Snapshot:** `snapshots/2026-11-21-0920/`

## Steps

| #   | Step              | State   | Start | End | Detail |
|-----|-------------------|---------|-------|-----|--------|
| 1   | Scopes            | done    | 09:22 | 11:16 | 6/6 committed and pushed |
| 2   | Questions         | skipped |       |     | Q7 and Q8 are open but touch phases 3 and 4, not this phase's code: carried to delivery |
| 3   | Lab suite         | done    | 11:17 | 11:18 | `lab/check.sh` 15/15, 36 s |
| 4   | `pr-reviewer`     | done    | 11:18 | 11:27 | pass 1 NOT_OK (1 🟠), pass 2 OK |
| 5   | `blind-reviewer`  | done    | 11:31 | 11:41 | pass 1 NOT_OK (1 🟠), pass 2 OK |
| 6   | Delivery          | done    | 11:41 | 11:43 | suite 16/16 on `ec0f3fa`, both reports in `reviews/` |

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

### `blind-reviewer`, pass 1 · 11:31 to 11:35 · NOT_OK

**Report:** [BLIND-2026-11-21-1131.md](reviews/BLIND-2026-11-21-1131.md). It checked the results tables against the 9 JSON
files (exact) and found nothing private.

#### R9 🟠 A micro case that fails its check in a later process still counts

**Scopes:** 4 · **Status:** fixed (`095e7e8`)

`micro_summarize()` (`lab/micro/micro.php:326-345`) only reads the first process's status, and drops a failed later
process silently: a bench whose check passes once then fails (a write to its `feed.db` copy, say) is ranked as a
valid result, exit code 0.

#### R10 🟡 No MIT credit for the code adapted from mattsplat's entry

**Scopes:** 2, 5 · **Status:** fixed (`ec0f3fa`, full text in `lab/NOTICE.md`)

`install-php83-apt.sh` and the Swoole settings of `noop-swoole.php` come from that entry; MIT asks to keep its notice.

#### R11 🟡 Stale or wrong comments and docs (8 items)

**Scopes:** 2 to 6 · **Status:** fixed (`ec0f3fa`)

"Both Swoole entries" is mattsplat's only; the lab's 2 GiB isn't the VM's budget (the VM shares it with the OS); the
micro run time (41 s, not 90 s); stale headers in `fixed-rate.js` and `noop-swoole.php`; `-O2` isn't all of Ubuntu's
flags; "idle between runs" is measured after warm-up; the harness commit should be named (`c3a487b`); the prediction
was also committed before the runs in `85978ab`, which the results README should say.

### `blind-reviewer`, pass 2 · 11:40 to 11:41 · OK

**Report:** [BLIND-2026-11-21-1139.md](reviews/BLIND-2026-11-21-1139.md). R9, R10 and R11 fixed and re-read.

#### R12 🟡 `lab/README.md:99` doesn't name the new fixture

**Scopes:** 4 · **Status:** left

It names only `failing-check.php` as a fixture of `lab/check.sh`, not the new `failing-check-later.php`.

## Delivery

### Since the snapshot

- **D13 (added by the run):** PHP 8.3 is also built from source, with the same flags as 8.4 to 8.6. In the branch:
  the `8.3` image next to `8.3-apt`, and `zend.assertions` and `opcache.file_update_protection` pinned on every lab
  run (R1, R2) so the two 8.3 builds differ only by their build.
- **D14 (yours, via the planning session):** a branch and worktree per phase from phase 3. No effect on phase 2.
- **D12** keeps its text, with a note that its "no worktree" part is replaced by D14 from phase 3.
- **Open `run` questions:** Q8 (the Mac's noise), Q9 (the request rate), Q7 (8.6 without Swoole). None changes
  phase 2's code; Q8 and Q9 shape how phases 3 and 4 measure.

### 3 places to look

- `lab/macro.sh` and `lab/macro/probe.sh`: how µs/req is computed (`cpu.stat` read from outside the cgroups) and when
  a run is valid. Every later number rests on it.
- `lab/micro/micro.php` → `micro_summarize()`: the spread across processes, the UNSTABLE flag and the skip rule
  (R9). The densest logic of the phase.
- `lab/results/2026-11-21-noop-swoole/README.md`: the first number against the prediction, and the caveats (rate and
  connections rise together; the Mac wasn't quiet).

### Expected answers

None: no `FIXME(pending)` in the branch.

### What was done

- A lab under `lab/`: seed, 5 PHP images (8.3 apt; 8.3, 8.4, 8.5, 8.6 from source; Swoole 6.2.6 except on 8.6), a
  micro harness and a k6 macro harness, `lab/check.sh` with 16 smoke checks.
- The first number: the no-op Swoole server costs 50.2, 30.2 and 21.7 µs CPU/req at 1k, 3k and 6k req/s.
- 8 code commits for the 6 scopes plus 4 fix commits from the reviews; about 2,200 lines (plus about 9,000 lines of
  raw result JSON).

### Final reviews

- `pr-reviewer`: NOT_OK at pass 1 (1 🟠), OK at pass 2. [PR-2026-11-21-1119.md](reviews/PR-2026-11-21-1119.md),
  [PR-2026-11-21-1127.md](reviews/PR-2026-11-21-1127.md).
- `blind-reviewer`: NOT_OK at pass 1 (1 🟠), OK at pass 2. [BLIND-2026-11-21-1131.md](reviews/BLIND-2026-11-21-1131.md),
  [BLIND-2026-11-21-1139.md](reviews/BLIND-2026-11-21-1139.md).

### What the phase delivers (the "PR description")

There's no PR: the work is on `main` (D12). This is the description a PR would carry.

**Summary:** phase 2 of the plan: a measuring lab under `lab/` that rebuilds the same data and the same environment
for every measurement, and a first number from it: what a no-op Swoole server costs per request at a fixed rate.

```diff
 lab/
+  seed.sh                  seed database, outside git
+  build.sh, run.sh         php-lab:8.3-apt, 8.3, 8.4, 8.5, 8.6 (Ubuntu 24.04), 1 CPU, 2 GiB
+  micro.sh, micro/         micro benchmarks, JIT on and off, K processes per case
+  macro.sh, macro/         k6 at a fixed rate, CPU read from the cgroup
+  servers/noop-swoole.php  the floor: 200 {"status":"ok"} to everything
+  check.sh                 16 smoke checks
+  results/                 build times, the Swoole-on-8.6 failure, the first number
+  NOTICE.md                MIT notice for the code adapted from mattsplat's entry
```

**Decisions**

- **8.3 is built from source as well as from apt:** otherwise "8.4 is faster than 8.3" could just mean "our build
  flags beat Ubuntu's". For the same reason every lab PHP run pins `zend.assertions=-1` and
  `opcache.file_update_protection=0`.
- **Swoole doesn't build on PHP 8.6** (6.2.6 nor 6.3.0-rc2): the 8.6 image has no Swoole, so only the micro benches
  run on it; the error is saved.
- **The micro harness runs each case in 5 processes and reports the spread across them:** the same case swung 2x
  from one process to the next on this Mac, and a spread inside one process hid it.
- **k6 runs in its own container on the VM's host network, and the CPU is read from a third container:** a port
  forwarded from macOS goes through a userspace proxy, and a read inside the server's cgroup would be part of the
  number.
- **k6 pre-allocates one VU per 10 req/s:** k6 drops an iteration when no VU is idle at that instant, and a stall of
  tens of ms on the VM piled them up. Open connections equal the pre-allocated VUs.

**Proof:** `bash lab/check.sh` prints 16 `ok`. On an Apple M3 Pro in Docker Desktop (arm64, not the bench VM), image
`8.3-apt`: **50.2 µs/req at 1,000 req/s, 30.2 at 3,000 and 21.7 at 6,000**, 9 interleaved runs, all valid. The
prediction of 8 to 20 µs at 3,000 didn't hold; the trend (cheaper per request at a higher rate) and peak RSS under
50 MB did.

**What we learned**

- **The Mac is a noisy lab:** micro numbers sit at one of two levels, 2x apart, from one process to the next (not
  ASLR); macro numbers drifted 35 % in 6 minutes once, then held within 2 to 5 % in the interleaved series. 49
  containers of other projects ran on the VM meanwhile (Q8).
- **A no-op isn't free:** about 16 µs per request plus about 34 ms of CPU per second that doesn't follow the rate,
  so µs/req depends on the rate it's measured at (Q9).
- **"Passes twice" isn't "reliable":** two harness bugs (the hidden 2x spread, the dropped iterations) passed their
  developer's first runs and showed up on the project manager's rerun.

**Left for a later pass:** `lab/macro.sh` reports a k6 that dies at once only after 3/4 of the run (R5); the Swoole
pin is written in two install scripts and `lab/check.sh` (R6); `lab/README.md:99` doesn't name the new fixture (R12).

### The commits

```bash
git -C <repo> log --oneline a47aa5e..ec0f3fa -- lab .gitignore README.md
```

### Review

```bash
git -C <repo> diff a47aa5e..ec0f3fa -- lab .gitignore README.md ':!lab/results/**/*.json' ':!lab/results/*.json'
```

Nothing to merge or close: the work is already on `main` and pushed (D12). From phase 3, D14's branch per phase
brings back a real merge.

## Retro

**For the project** (in 👉 of `plan.md`):

- **`shellcheck` is missing on the Mac:** 4 of 6 developers raised it; `lab/` has about 600 lines of bash. An action
  to install it; phase 3 can add a lint check to `lab/check.sh`.
- **A versioned series runner:** scope 6 ran its 9 interleaved runs from a scratchpad loop, and phase 3 needs the
  same thing (`lab/series.sh` plus a summary script). Raised by the developer and the `pr-reviewer`: a phase 3 scope,
  not a question.
- **Check that the macro server really ran with OPcache and the JIT:** the micro harness proves it
  (`opcache_is_script_cached`), the macro harness only proves the flags (`pr-reviewer`, blind spot). A phase 3 scope.

**For `~/.claude`** (noted in the inbox):

- The `developer`, `pr-reviewer` and `blind-reviewer` agent files assume French, a worktree and a child branch; this
  run overrode all three in every brief (3 agents said so).
- "Run a 'must hold reliably' criterion at least 5 times before saying it passes": the scope 4 and 5 developers both
  learned it the hard way.

**For you (planning):**

- The rate phases 3 and 4 measure at (Q9) could have been decided with the method: it surfaced only once the first
  number showed µs/req depends on the rate.
- Which PHP extensions the source builds should carry (configure defaults vs a minimal build) was guessed by scope 3.
- The project manager wrote times from memory at first and they ran 15 min fast: the planning session caught it.

**Dismissed:** none. 3 minor remarks left (R5, R6, R12), listed above.
