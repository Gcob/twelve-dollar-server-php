# Project manager: phase 2, lab setup

**State:** scope 1 briefed, developer starting.

## Resolved config

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
| 1     |          |       |

## Verified

Rien.

## Assumed

- Docker Desktop's VM exposes 12 vCPUs and cgroup v2 (`docker info`, 09:22); a `--cpuset-cpus` pin inside the VM
  doesn't pin to a physical core of the M3 Pro (P or E core): a noise source to watch in scope 6.

## Dead ends

Rien.

## Decisions on the way

- D13: 8.3 from source as a control (in `decisions.md`).
- The lab lives in `lab/`; results in `lab/results/`, committed; `lab/data/` ignored.
- `lab/check.sh` is the lab's "full suite".

## Review triage

Rien.

## Suggested skills

`autonomous-run`, `plan-format`, `markdown`.

## Where to look

- `reference/twelve-dollar-server-challenge/submissions/php-swoole-mattsplat/install.sh`: the Swoole build to copy.
  `@a47aa5e`
- `reference/twelve-dollar-server-challenge/seed/make-seed.sh`: the seed, writes next to itself. `@a47aa5e`

## Plan read up to

`plan.md`, `decisions.md` D1 to D13, 2026-11-21 09:30.

## Next steps

1. Scope 1, then 2 to 6 in order.

## Retro

(at delivery)
