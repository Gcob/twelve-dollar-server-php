# Project manager: phase 4, realistic baseline

**State:** plan review full NOT_OK (11:10) → D38-D43; delta NOT_OK (11:14) → D44; delta 2 + final full OK (11:17), 4 🟡 fixed. Scope 1 launched 11:19. Scope 1 brief drafted, not launched.

## Resolved config

**Also read `CLAUDE.local.md`** (git-ignored, repo root): pace (read usage before each agent, land at 🟠: 5-hour over
85 % or weekly 98 %), the PM pushes after `git fetch` + `git status -sb` (behind: stop), developers commit.

Skill defaults (`autonomous-run/pipeline.yml`), no run override file. Changes from D12 and D14:

- **Code:** branch `phase-4-claude`, worktree `.claude/worktrees/twelve-dollar-server-php/phase-4-claude` under the
  home folder (the full absolute path goes in agent prompts, never in a committed file). Created by the planning
  session from `main` at `0eba220`. Every git command in full form `git -C <that path> ...`, alone in its call. The PM
  pushes it with `git -C <that path> push -u origin phase-4-claude`. Never merge.
- **`plan/`:** on `main`, this checkout, committed and pushed by the PM. Never write the worktree's copy of `plan/`.
  `plan/notes.md` belongs to the planning session.
- One commit per scope, explicit `git add` per file, no co-authored-by, never `push --force`.
- The repo is public: no private details, no absolute home paths in committed files.
- One phase per run: stop after phase 4, the profile (D12, D27). Don't start the step lab.
- developer: sonnet, high · pr-reviewer: sonnet, max 2 relaunches · blind-reviewer: opus, max 1 relaunch.
- **D15:** `docker ps` before every measurement; other projects' containers running means no measuring. Never stop
  or remove them; a 🔴 item in 👉 and the turn-end report ask the planning session.
- Jacob may be away: a choice for him becomes a `run` question in 👉 of `plan.md` with a `FIXME(pending)`; stop only
  when truly blocked. Turn-end reports go to the planning session: only what Jacob must answer or do, a block, or the
  delivery.

## Developers

| Scope | Agent id | State |
|-------|----------|-------|
| plan-reviewer | a480e25853b51eccf | full, running since 10:59 |

## Verified

- The worktree is at `0eba220`, clean; its `reference` is a relative symlink to the main checkout's clone (excluded by
  `/reference` in the shared `.git/info/exclude`); `lab/seed.sh` printed `OK ... content sha256 matches` there at 10:53.
- 23 other containers running at 10:52 (D15: no measurement). Docker VM: 12 CPUs, 7.75 GiB.
- The planning session says Jacob stopped his 23 containers at 10:55: the VM is quiet, measuring allowed once the
  plan is ready; still `docker ps` before each measurement, and tell the planning session if one comes back.

## Assumed

- k6 needs under 2 MiB per VU on `load.js` (prediction 12); scope 2's calibration checks it.
- Excimer builds on 8.5 with `phpize` like ext-event.
- `test/test.sh` can reach a server on the VM's host network from the Mac, or runs in a container (scope 1 decides).

## Dead ends

Rien.

## Decisions on the way

- 10:55: phase 3's `run.md`, `run.yml` and `state/` archived in `plan/runs/phase-3/` (links rewritten to `../../`).
- 10:56: Q7 and Q10 moved to `questions/2026-11-22-1049.ronde-3.md`; Round 3.
- 10:57: D31 (the 97 % rule) comes from the arithmetic of a closed model with scaled think time: the number of VUs
  for a 500 ms mean latency over the knee is `1 + 2.17 × 0.5 / (20.5 × s)`: 3.6 at `s = 0.02`, 1.05 at `s = 1`.

## Review triage

- Plan review (full, 11:10): 🔴 ports → D38; 🟠 VU budget → D39; 🟠 10.8 → D40 (9.45); 🟠 k6 per-step/per-second → D41
  (one scenario + live histograms, not one scenario per step: no connection churn between steps); 🟠 macro.sh on the
  skeleton → D42; 🟠 Excimer attribution → D43. 12 🟡 folded into phase-4.md. Predictions 3 and 7 revised 11:12.
- Delta (11:14): 🟠 no backpressure on k6's stream → D44 (reviewer's pick A). 5 🟡 folded (fd cap, per-step functions,
  `--fresh-db`, slow fixture, D16 period).

## Suggested skills

`autonomous-run`, `plan-format`, `markdown`.

## Where to look

- `lab/servers/diy-connection.php`: the DIY parser reads only `Content-Length`, `Connection`, `Transfer-Encoding`; it
  calls the global `handler_handle($method, $path, $body)`. Scope 1 changes this seam. `@0eba220`
- `lab/conns/client.php`: phase 3's idle-connection client, rotating 127.x source addresses; scope 3 reuses it. `@0eba220`
- `lab/lib.sh` → `lab_start_server`: mounts `lab/data` read-only and runs `php <flags> <server>`; the skeleton needs a
  fresh writable copy at `SQLITE_PATH` (D32). `@0eba220`

## Plan read up to

`plan.md`, `decisions.md` D1 to D36, 2026-11-22 10:57.

## Next steps

1. Plan review (full), settle its points.
2. Scope 1 brief and developer.

## Retro

(at the end)
