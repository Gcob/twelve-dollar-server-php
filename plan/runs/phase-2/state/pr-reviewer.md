# PR reviewer: phase 2, lab setup

**State:** pass 2 done at 11:27. Report: `plan/reviews/PR-2026-11-21-1127.md`. Verdict OK. Pass 1 (`PR-2026-11-21-1119.md`) was NOT_OK (one major, six minor, one plan question).

## Remarks

| # | Where | Severity | Status |
|---|-------|----------|--------|
| 1 | `lab/lib.sh:54` macro server flags lack `opcache.file_update_protection=0` | 🟠 | fixed `cc2ca4f` (flag pinned, `server.ini` in the JSON) |
| 2 | `lab/micro/micro.php:42-52`, `lab/lib.sh:54`: `zend.assertions` not pinned (source images 1, apt image -1) | 🟡 | fixed `cc2ca4f` |
| 3 | `plan/plan.md` Q8: 31 vs 28 unstable rows, "within 2 %" at 6k is 4.7 %, "quieter series" contradicts the results README | 🟡 | fixed in `plan/plan.md` by the project manager, not committed yet |
| 4 | `lab/results/2026-11-21-noop-swoole/README.md:114-118`: connections co-vary with rate | 🟡 | fixed `f5a122c` |
| 5 | `lab/macro.sh:195-199`: no fail-fast when k6 dies at once | 🟡 | left by the project manager, listed for Jacob |
| 6 | Swoole pin written in two install scripts and in `lab/check.sh` | 🟡 | left by the project manager, listed for Jacob |
| 7 | Docs: root `README.md` has no `lab/` link, no prerequisites in `lab/README.md`, "about a minute" vs 14 s | 🟡 | fixed `f5a122c` |
| P1 | ⚠️ plan: at which rate do phases 3 and 4 measure (µs/req is 50, 30, 22 at 1k, 3k, 6k) | question | now Q9 in `plan/plan.md`, not blocking |

## Verified

- Public-repo rule: grep of every tracked file (JSON outputs included) for `/Users/`, home names, emails, account ids, other projects: nothing. **Proof:** `git ls-files | xargs grep`.
- First-number headline figures recomputed from `run-*.json` and the README tables: medians, ms of CPU per second, 1k/6k ratio, the 1k to 6k line, k6 CPU, VmHWM growth, 49 to 149 µs/s idle: all match. **Proof:** arithmetic on the README and the JSON of `run-1-3000rps`.
- The prediction text in the results README is identical to `plan/details/phase-2.md` (commit `85978ab`, before scope 6).
- The micro sample JSON has 28 rows with `max_over_min` above 1.3. **Proof:** `jq '[.runs[].cases[] | select(.max_over_min>1.3)] | length'`.

## Verified (pass 2)

- `cc2ca4f` diff read: flags in `lab/lib.sh`, `server.ini` probe in `lab/macro.sh`, `zend.assertions` in `micro.php`; `f5a122c` diff read: README links, prerequisites, confound paragraph. "Node 18 or later" matches the challenge's own `make-seed.sh`. **Proof:** `git show`, `reference/.../seed/make-seed.sh:6`.
- Q9 in `plan/plan.md` is well framed.

## Supposed

- Nothing was run (git and reading only): `lab/check.sh` 15/15 is the project manager's run at 11:17.
- The effect of `opcache.file_update_protection` on a Swoole server file is from the developer's CLI test (handover, scope 4) and the README, not tested on the macro path.
- `zend.assertions` defaults: PHP's built-in `1` with no `php.ini` and Ubuntu's production ini `-1`, from my knowledge of both, not checked in the images.

## Rétro

(Pass 2: nothing new. The pass 1 points stand. Extra: the fix came in 8 minutes because the findings carried their one-line fix; that format worked.)


1. **What I lacked:** how the run folder maps here (versioned `plan/`, no worktree, parent as a SHA). The task message gave it, so nothing to hunt.
2. **What I guessed:** that Ubuntu's CLI `php.ini` sets `zend.assertions=-1` (impression: no way to run commands to check).
3. **Where I lost time:** `developer.md` is 40 KB; the tool truncated it twice and I read it by `grep` on headings. A short "where to look" at the top of the file would have saved it (it exists near the end, "Où regarder").
4. **Useless or contradictory instruction:** the agent file asks for French and a `git diff <parent>...<branche>` between branches; this run is English and on `main`. The task message overrode both, which worked.
5. **Could be deterministic:** the numbers quoted in `plan/plan.md` Q8 (31 rows, "within 2 %") were wrong against the committed JSON. A `summarize.sh`-style script that prints the figures a question quotes, run before the question is written, would catch it. Same family: `lab/check.sh` could carry a check that `LAB_SERVER_PHP_FLAGS` and the micro ini list agree on the settings that change speed (`zend.assertions`, `opcache.file_update_protection`).
6. **What the plan should have decided:** the rate phases 3 and 4 measure at (P1). It surfaced only once the first number showed µs/req depends on rate.
7. **Blind spot:** nothing checks that a macro run's server had its scripts in OPcache with the JIT on; the micro harness does (`opcache_is_script_cached`), the macro harness trusts the flags. Also `series.sh` (the interleaved loop) lives in a scratchpad: phase 3 will need it again, and it is not versioned.
