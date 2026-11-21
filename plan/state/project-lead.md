# Project manager: phase 2, lab setup

**State:** 🏁 phase 2 delivered at 11:43: 6/6 scopes, both final reviews OK at pass 2, `lab/check.sh` 16/16 on `ec0f3fa`. Stop: no phase 3 (D12).

## Resolved config

**Also read `CLAUDE.local.md`** (git-ignored, repo root): pace rules (read usage before each agent, land at weekly 98 %), developers commit and the PM pushes after `git fetch` + `git status -sb` (behind: stop, no `pull --rebase`).

Skill defaults (`autonomous-run/pipeline.yml`), no run override file. Changes from D12:

- no worktree: this checkout, `main`; every git command `git -C <repo root> ...`, alone in its call;
- one commit per scope, explicit `git add` per file, pushed after each commit (`git pull --rebase` first, never
  `--force`); no co-authored-by line;
- the repo is public: no private details, no absolute home paths in committed files;
- `plan/notes.md` belongs to the planning session; the run owns the rest of `plan/`;
- one phase per run: stop after phase 2.
- developer: sonnet, high · pr-reviewer: sonnet, max 2 relaunches · blind-reviewer: opus, max 1 relaunch.

## Developers

| Scope | Agent id | State |
|-------|----------|-------|
| 1     | ad0345bdbd54bc416 | done `7643677`, pushed |
| 2     | ae7153a7b06d7be23 | done `aef8c0b`, pushed |
| 3     | a84a7d43b2bb4f619 | done `c584d41`, pushed |
| 4     | ad96bd86862e37b02 | done `8151a5e` + `cad0e84`, pushed |
| 5     | a587078e149d24e5c | done `13291fd` + `d2ff24e`, pushed |
| 6     | a3d56f754bcf88e0c | done `c3a487b`, pushed |
| blind-reviewer | a4e43f1a957a902ad | pass 2 OK (11:41) |
| pr-reviewer | a8125c8756bdfff08 | pass 2 OK (11:27) |
| 5 (fixes)   | a587078e149d24e5c | R1 R2 R4 R7 fixed: `cc2ca4f`, `f5a122c` |

## Verified

- Scope 1: `lab/seed.sh` prints OK, data ignored, `lab/check.sh` 2/2. **Proof:** rerun by the PM 09:27.
- Push over HTTPS was refused (403, wrong account); the remote is now the SSH alias and the planning session pushed `85978ab` and `7643677`. **Proof:** `git remote -v`, 09:33.

## Assumed

- Docker Desktop's VM exposes 12 vCPUs and cgroup v2 (`docker info`, 09:22); a `--cpuset-cpus` pin inside the VM
  doesn't pin to a physical core of the M3 Pro (P or E core): a noise source to watch in scope 6.

## Dead ends

- Writing times in `run.md` from memory: they drifted 15 min ahead (the planning session caught it at 10:24). Every time now comes from `date '+%H:%M'` or `git log`.

Rien.

## Decisions on the way

- D13: 8.3 from source as a control (in `decisions.md`).
- D14 (Jacob, via the planning session): branch and worktree per phase from phase 3.
- Q7 (run, not blocking): Swoole doesn't build on 8.6; the 8.6 image has no Swoole.
- Questions point skipped: Q7 and Q8 touch phases 3 and 4, not phase 2's code; carried to delivery.
- Scope 5 resent once: k6 dropped iterations with idle VUs (VM stalls); fix `d2ff24e` pre-allocates rate/10 VUs. PM reruns at 10:51: 2 valid, 36.45 and 37.45 µs/req.
- Scope 4 resent once: per-run spread hid a 2x swing between processes (PM reran 8.4 JIT on 4 times: 27.8, 13.5, 28.0, 27.3 ns). Fix `cad0e84`: K processes per case. Q8 (run, not blocking): how to measure through the Mac's noise.
- The lab lives in `lab/`; results in `lab/results/`, committed; `lab/data/` ignored.
- `lab/check.sh` is the lab's "full suite".

## Review triage

- R1 🟠 pr-reviewer, `lab/lib.sh:54` file_update_protection: fix, scope 5 developer (11:24).
- R2 🟡 zend.assertions: fix with R1 (cheap, protects D13's control).
- R3 🟡 Q8 numbers: fixed by the PM in plan.md.
- R4, R7 🟡: fix (docs, one commit).
- R5, R6 🟡: left (no failure scenario that changes a number).
- R8 ⚠️: Q9 in plan.md.
- R9 🟠 blind (micro_summarize reads process 0 only), R10 🟡 MIT credit, R11 🟡 8 doc items: all to fix, one developer (scope 5's, broadest context, avoids two writers on lab/README.md), 11:35.

## Suggested skills

`autonomous-run`, `plan-format`, `markdown`.

## Where to look

- `reference/twelve-dollar-server-challenge/submissions/php-swoole-mattsplat/install.sh`: the Swoole build to copy.
  `@a47aa5e`
- `reference/twelve-dollar-server-challenge/seed/make-seed.sh`: the seed, writes next to itself. `@a47aa5e`

## Plan read up to

`plan.md`, `decisions.md` D1 to D13, 2026-11-21 09:30.

## Next steps

1. Nothing in this run. Phase 3 starts from a new run with D14's branch and worktree, after Jacob answers Q8 and Q9.

## Retro

1. **What I lacked:** the pace and push rules (`CLAUDE.local.md`) arrived mid-run; the HTTPS remote pushed as the
   wrong account (403) until the planning session switched it to SSH.
2. **What I guessed:** that Q7 to Q9 could skip the questions point because they touch phases 3 and 4, not phase 2's
   code. Nobody confirmed it.
3. **Where I lost time:** I wrote `run.md` times from memory and they ran 15 min fast (caught by the planning
   session). Two checks I trusted from developers failed on my own rerun (scopes 4 and 5): rerunning every "Done when"
   myself was worth it both times.
4. **Could be deterministic:** a small script that fills run.md's time and SHA columns from `date` and `git log`;
   the numbers quoted in Q8 were wrong against the JSON (the `pr-reviewer` caught it): quote from a summary script,
   never from a developer's report.
5. **What the plan should have decided:** the request rate of the method (Q9).
6. **Blind spot:** the macro harness proves the PHP flags, not that the server's script was cached with the JIT on.
