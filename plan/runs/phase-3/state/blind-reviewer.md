# Blind reviewer: phase-3-claude

**State:** delta pass 2 done on `phase-3-claude` at b216364 (d0bf2bc..b216364). Verdict OK (D1 to D6 fixed, 3 new 🟡).
Reports: `plan/reviews/BLIND-2026-11-21-1831.md` (pass 1), `-1848` (pass 2), `-2217` (delta), `-2229` (delta pass 2).

## Verified

- Delta 2: `summarize.sh` at b216364 regenerates `README.md:109-350` byte for byte. **Proof:** `diff`, no difference.
- Delta 2: with no input and a stdin that never closes, `summarize.sh` exits 5 with a `jq` error and doesn't hang. **Proof:** run in an empty scratch folder with a FIFO as stdin.

- Delta: `summarize.sh` at d0bf2bc regenerates `lab/results/2026-11-21-bake-off/README.md:105-330` byte for byte. **Proof:** `diff` of its output against those lines, no difference.
- Delta: no `/Users/`, `/home/` or email in the 134 committed files. **Proof:** grep over `git diff --name-only 9aadddc..d0bf2bc`.
- Delta: the counting rule is valid and `other_containers == 0`, 3 counted runs per group, and the invalid originals are left out. **Proof:** `summarize.sh:17`, the "every run" table.

- Pass 2: the parser test now has 34 cases, as `check.sh` expects. **Proof:** `git show 9aadddc`, 3 bad cases + 1 handler case.
- Pass 2: when `Pss_Anon` is missing, the value is 0 and the `> 0` checks fail. **Proof:** `probe.sh` awk `END {print p+0, a+0}`, `check.sh` asserts.

- The DIY parser's 30 cases match the count `check.sh` expects. **Proof:** `lab/check/diy-parser-test.php` read, cases counted.
- The seed's `posts` table has 500,000 rows, ids 1 to 500,000 (`posts.js` assumes so). **Proof:** `sqlite3` on `lab/data/feed.db`.
- Seed page counts: posts 21,077, likes_post_id_idx 5,913, users 639 (4 KiB pages). **Proof:** `dbstat` query.
- Workerman 5.2.4 (the reference clone) has no idle keep-alive timer. **Proof:** grep of `TcpConnection.php` and `Http.php`.

## Assumed

- Delta: no steal-time accounting in Docker Desktop's arm64 VM, so host stalls get charged to the server's cgroup (D2). Not checked.
- Delta: the predictions match commit 4e3a8a5. Not checked (it is under `plan/`, closed to me).

- Pss in `smaps_rollup` includes the SQLite mmap pages, so Pss under load grows with the DB pages touched (item 1). Not
  measured under k6.

## Dead ends

Nothing.

## Decisions along the way

- `mktemp -d` dirs left behind by the checks: dropped, it is the existing pattern of `check.sh`.
- `D15` at `lab/README.md:213`: predates the branch, not raised.

## My remarks

| # | Sev | `file:line` | Status |
|---|-----|-------------|--------|
| 1 | 🟠 | `lab/servers/handler.php:52`, `lab/macro/probe.sh:42-53`, `lab/README.md:274` | fixed (9aadddc) |
| 2 | 🟡 | `lab/README.md:384` | fixed (9aadddc) |
| 3 | 🟡 | `lab/conformance.sh:10` | fixed (9aadddc) |
| 4 | 🟡 | `lab/README.md:103` | fixed (9aadddc) |
| 5 | 🟡 | `lab/images/install-extras.sh:25` | fixed (9aadddc) |
| 6 | 🟡 | `lab/servers/diy-connection.php:141-142` | fixed (9aadddc) |
| 7 | 🟡 | `lab/servers/diy-connection.php:183-187` | fixed (9aadddc) |
| 8 | 🟡 | `lab/servers/diy-connection.php:39` | fixed (9aadddc) |
| 9 | 🟡 | `lab/check.sh:49` | left |
| 10 | 🟡 | `lab/servers/workerman-caches.php` | left |
| 11 | 💡 | `lab/macro/k6/posts.js:5-6` | left |
| 12 | 🟡 | `lab/README.md:424` (memory.current includes the copy's page cache) | open (pass 2) |
| D1 | 🟠 | `lab/results/2026-11-21-bake-off/README.md:132-134`, `:379-383`, `:446-447` (2nd finalist on a 1.5 % gap) | fixed (2b54788/b216364) |
| D2 | 🟡 | `lab/results/2026-11-21-bake-off/README.md:354-357`, `:459-462` (paused vCPU argument) | fixed (2b54788/b216364) |
| D3 | 🟡 | `lab/results/2026-11-21-bake-off/README.md:376-378` (prediction 4, judged on medians only) | fixed (2b54788/b216364) |
| D4 | 🟡 | `lab/results/2026-11-21-bake-off/README.md:465-466` (spread "4 to 9 %") | fixed (2b54788/b216364) |
| D5 | 🟡 | `lab/results/2026-11-21-bake-off/summarize.sh:34` and the other `jq -n ... inputs` calls (hang on stdin) | fixed (2b54788/b216364) |
| D6 | 🟡 | `lab/results/2026-11-21-bake-off/README.md:29` (`runtimes.md` without its path) | fixed (2b54788/b216364) |
| D7 | 🟡 | `lab/results/2026-11-21-bake-off/README.md:492`, `:453` (stalls "100 to 450 ms, 700 and 1,400 VUs", stale) | open (delta 2) |
| D8 | 🟡 | `lab/results/2026-11-21-bake-off/README.md:497-499` ("depends on the route and the rate") | open (delta 2) |
| D9 | 🟡 | `lab/results/2026-11-21-bake-off/README.md:408`, `:499` ("the brief's rule") | open (delta 2) |

## Next steps

1. On another delta: read only the new commits, rerun `summarize.sh` and diff it against the README, check D7 to D9.

## Questions for the project manager

Nothing.

## Rétro

Delta 2: in the d0bf2bc pass I missed that "at 700 VUs and at 1,400" was already wrong (the invalid 9,500 runs were at
1,900). I checked the counts and the latencies but not the VUs of that sentence. Lesson: check every number of a
sentence against the table, the units and conditions included. Running the script with no input in a scratch folder
(a FIFO as stdin) proved D5 in 20 s.

Delta (results): the fastest check was mechanical. I ran `summarize.sh` and diffed its output against the README
(identical), which proves every table in one step. A `check.sh` case could do the same, so a README table can never drift
from its data (where: `lab/check.sh`, a check that runs every `lab/results/*/summarize.sh` and diffs). The judgment items
(D1, D2) came from reading the claims against the README's own 5 % rule, which no tool can see.

Pass 2: the commit-only scope (one SHA) made it a 15-minute read. A rerun given the statuses without reasons was enough
to check each fix against its item. Nothing new to add about the method.

1. **What I was missing:** the repo has no `CLAUDE.md` or project skills, so the only conventions were the lab README and
   the existing scripts. I judged against those (for example, the `mktemp -d` pattern in `check.sh`).
2. **What I guessed:** that Pss counts the mmap'd SQLite pages at the scale I estimated (item 1). Not measured: a `/noop`
   run against a `/posts` run would settle it.
3. **Where I lost time:** the diff is 3,278 lines in 28 files. Reading `lab/README.md` (257 added lines) mostly repeated
   the code. Proof: `git diff --stat`.
4. **A useless or contradictory instruction:** nothing.
5. **What could have been deterministic:** the doc/code count drift (item 3: "two pipelined" against three cases) and the
   README's "every measuring script" claim (item 2) are the kind of thing a check could hold. For example, a `check.sh`
   case that greps `micro.sh` for `lab_other_containers` once the README claims it.
6. **What the plan should have decided:** impression: which memory figure is the bake-off's comparison metric (full
   Pss, anonymous Pss or `memory.current`). The code picked one, and the README justifies it.
7. **A blind spot:** the `/posts` checks only assert that the memory numbers are above 0 (`check.sh`, `max_pss_mib > 0`),
   so nobody checks what the number is made of.
