# Project manager: phase 2, lab setup

**State:** 6/6 scopes done; `pr-reviewer` OK at pass 2 (11:27); `blind-reviewer` pass 1 next.

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

## Suggested skills

`autonomous-run`, `plan-format`, `markdown`.

## Where to look

- `reference/twelve-dollar-server-challenge/submissions/php-swoole-mattsplat/install.sh`: the Swoole build to copy.
  `@a47aa5e`
- `reference/twelve-dollar-server-challenge/seed/make-seed.sh`: the seed, writes next to itself. `@a47aa5e`

## Plan read up to

`plan.md`, `decisions.md` D1 to D13, 2026-11-21 09:30.

## Next steps

1. Triage the `pr-reviewer` report, fix through the scope's developer, relaunch (max 2).
2. `blind-reviewer`: give it only the code paths (`lab/`, `.gitignore`) and its two paths; tell it not to read `plan/` (the plan is in the repo here).
3. Delivery: `run.md` Livraison, retro, `run.yml` numbers, notify.

## Retro

(at delivery)
