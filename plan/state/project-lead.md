# Project manager: phase 3, runtime bake-off

**State:** plan written and pushed (`4e3a8a5`), plan review running, scope 1 developer working.

## Resolved config

**Also read `CLAUDE.local.md`** (git-ignored, repo root): pace (read usage before each agent, land at 🟠: 5-hour over
85 % or weekly 98 %), the PM pushes after `git fetch` + `git status -sb` (behind: stop), developers commit.

Skill defaults (`autonomous-run/pipeline.yml`), no run override file. Changes from D12 and D14:

- **Code:** branch `phase-3-claude`, worktree `.claude/worktrees/twelve-dollar-server-php/phase-3-claude` under the home folder (the full absolute path goes in agent prompts, never in a committed file).
  Every git command in full form `git -C <that path> ...`, alone in its call. The PM pushes it with
  `git -C <that path> push -u origin phase-3-claude`. Never merge.
- **`plan/`:** on `main`, this checkout, committed and pushed by the PM. Never write the worktree's copy of `plan/`.
- One commit per scope, explicit `git add` per file, no co-authored-by, never `push --force`.
- The repo is public: no private details, no absolute home paths in committed files.
- `plan/notes.md` belongs to the planning session.
- One phase per run: stop after phase 3 (D12).
- developer: sonnet, high · pr-reviewer: sonnet, max 2 relaunches · blind-reviewer: opus, max 1 relaunch.
- **D15:** `docker ps` before every measurement; other projects' containers running means no measuring. Never stop
  or remove them.
- Jacob is away: a choice for him becomes a `run` question in 👉 of `plan.md` with a `FIXME(pending)`; stop only when
  truly blocked.

## Developers

| Scope | Agent id | State |
|-------|----------|-------|
| plan-reviewer | aafd6e0f78a1cc771 | running since 16:30 |
| 1     | a912ed904256c9783 | done `a0477ba`, pushed 16:34 (fixture SC2046: SC2086 is info level; tag v0.11.0) |

## Verified

- The worktree is at `b14068f`, clean; its `reference` is a relative symlink to the main checkout's clone, excluded
  in `.git/info/exclude` (shared by both checkouts); `lab/seed.sh` printed OK there. **Proof:** commands at 16:27.
- 0 containers running at 16:24, images `php-lab:8.3-apt`, `8.3` to `8.6` present. **Proof:** `docker ps`, `docker images`.

## Assumed

- ext-event (PECL) builds on 8.5; maybe not on 8.6.
- Workerman 5.2.4 needs `workerman/coroutine` at runtime only through its autoloader (to check in scope 4).

## Dead ends

Rien.

## Decisions on the way

- D17 to D20 (PHP 8.5, ext-event, each runtime's headers, two routes), in `decisions.md`.
- Phase 2's run archived in `plan/runs/phase-2/` (run.md links rewritten to `../../`).

## Review triage

Rien.

## Suggested skills

`autonomous-run`, `plan-format`, `markdown`.

## Where to look

- `lab/macro.sh`: the server-start and probe logic that `conformance.sh` and `conns.sh` reuse. `@b14068f`
- `lab/lib.sh` → `LAB_SERVER_PHP_FLAGS`: loads Swoole for every server today (scope 2 adds `--ext`). `@b14068f`
- `reference/workerman/` (tag v5.2.4): the 5 caches of D10 (runtimes.md lists them). `@4c817de`

## Plan read up to

`plan.md`, `decisions.md` D1 to D20, 2026-11-21 16:30.

## Next steps

1. Plan review, settle its points.
2. Scope 1 brief and developer.

## Retro

(at the end)
