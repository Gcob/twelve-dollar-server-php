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
| plan-reviewer | a480e25853b51eccf | full NOT_OK 11:09; delta NOT_OK 11:14; delta 2 + final full OK 11:17 |
| 1     | afe8ff70047c6f1a9 | done `64af809`, pushed 11:38 (tools image built locally: no pull allowed; handler gets a 4th arg) |
| 2     | a075911b200113f1b | done `47e4728`, pushed 12:31 (k6 ~300 µs CPU/req with the stream → D45) |
| 3     | a1365daa1d690ecf0 | done `b47adcf` 13:12 (60k idle + 5,377 VUs, 19,565 req/s smoke; idle client 257 MiB; lag up to 3.9 s → D46) |
| 4     | ac6145c4f718748e3 | done `4775db8` 13:53 (excimer 1.2.6, not on 8.6; calibration: C time goes to the caller, step functions carry it) |
| 3 (fix) | a1365daa1d690ecf0 | `fc73cee` (edge rows of the series check), `b18af33` (failing-step check's request count), pushed 14:50 |
| 5     | a0693a2b219c3cb46 | done 17:30 |
| 6     | aabebc28f7dcaaba7 | done 17:46; fd-wall note `1acc81a` |
| pr-reviewer | a96493ee11e4c85c3 | OK 18:05 |
| scope 5 (review fixes) | a0693a2b219c3cb46 | since 18:08 |

## Verified

- The worktree is at `0eba220`, clean; its `reference` is a relative symlink to the main checkout's clone (excluded by
  `/reference` in the shared `.git/info/exclude`); `lab/seed.sh` printed `OK ... content sha256 matches` there at 10:53.
- 23 other containers running at 10:52 (D15: no measurement). Docker VM: 12 CPUs, 7.75 GiB.
- The planning session says Jacob stopped his 23 containers at 10:55: the VM is quiet, measuring allowed once the
  plan is ready; still `docker ps` before each measurement, and tell the planning session if one comes back.
- 11:36: the 23 containers are back (the VM booted at 11:18:53 per `/proc/uptime`; they have restart policy
  `always`). Not from this run. No measurement until quiet; the planning session asked Jacob.
- 13:27: stopped again for the weekend at Jacob's request, restart policy now `unless-stopped`; "go" for scope 5.

## Assumed

- k6 needs under 2 MiB per VU on `load.js` (prediction 12); scope 2's calibration checks it.
- Excimer builds on 8.5 with `phpize` like ext-event.
- `test/test.sh` can reach a server on the VM's host network from the Mac, or runs in a container (scope 1 decides).

## Dead ends

Rien.

## Note for scope 5's README

- The predictions were written (10:57, revised 11:12) before any measurement, but scope 3's smoke runs (busy VM,
  13:00) already showed the skeleton passing 17,816 req/s with 60,000 idle: the README must say the predictions predate
  these smoke runs and were not revised after them.

## Decisions on the way

- 10:55: phase 3's `run.md`, `run.yml` and `state/` archived in `plan/runs/phase-3/` (links rewritten to `../../`).
- 10:56: Q7 and Q10 moved to `questions/2026-11-22-1049.ronde-3.md`; Round 3.
- 10:57: D31 (the 97 % rule) comes from the arithmetic of a closed model with scaled think time: the number of VUs
  for a 500 ms mean latency over the knee is `1 + 2.17 × 0.5 / (20.5 × s)`: 3.6 at `s = 0.02`, 1.05 at `s = 1`.

## Scope 4's questions, settled 13:56

- Two blocks in the fold (all samples, then each endpoint's own): keep both.
- The DIY loop's callbacks became `[$this, 'onReadable']` (named frames in the profile) in the shared
  `diy-server.php`, so `bake-diy.php` changed too: conformance and parser checks pass; the bake-off's numbers stay
  reproducible at their commit (D32). Kept; to mention in the PR description.
- S9 has no frame (autocommit commits inside `execute`): it counts in S6, noted in the README; phase 5 splits it.

## Scope 5's questions, settled 17:40

- Three 60 s cost runs missed the 97 % rule by 0.1 to 0.3 points: they count for µs per request, which the rule
  doesn't touch. No rerun (D47).
- The baseline stays 24,000 offered at `s = 0.02` (23,386 achieved): a harness floor, the server 63 % busy; the step
  lab carries µs/req and the profile (D47). No new holds.
- Verified by the PM: predictions block identical to the brief; all 26 counted JSONs `other_containers: 0`
  (`q10-warm-1` and `-3` are `valid: false` for dropped iterations, which is Q10's subject, shown in its table);
  `summarize.sh` 266 lines all in the README; no private path or email in the new files; fixes `38fc153`, `fcf104f` read.
- For the PR description: the final `max_lag_s` printed can pass the gate in a valid run (tail after k6 stops), noted
  in the README; not changed.

## To do before the delivery

- DONE (`1acc81a`) 17:50, from the planning session: the baseline README's "The step lab's order" and run.md's delivery must say
  that the 221,002 users are CPU-equivalent: one process holds at most about 65,500 connections, so the real bench
  caps it near 71,000 users whatever the CPU. S1's fd wall (S1-d or S1-b, phase-4.md "Out of scope") is a gate that
  goes first in phase 5, before the CPU ranking; its cost under churn (an accept and a close per request past the
  limit) is the first thing to measure there. Give it to scope 6's developer after its hand-back, as its own commit
  `docs(lab): ...` (it is editing the worktree now).

- 17:54: Jacob's 23 containers are back (restart policy `always`). A finding that needs a new measurement goes to
  👉 and to the planning session; never stop them. A smoke check that flakes under that load: note it, rerun it
  once alone, and say so in the delivery.

## Review triage

- Plan review (full, 11:10): 🔴 ports → D38; 🟠 VU budget → D39; 🟠 10.8 → D40 (9.45); 🟠 k6 per-step/per-second → D41
  (one scenario + live histograms, not one scenario per step: no connection churn between steps); 🟠 macro.sh on the
  skeleton → D42; 🟠 Excimer attribution → D43. 12 🟡 folded into phase-4.md. Predictions 3 and 7 revised 11:12.
- Delta (11:14): 🟠 no backpressure on k6's stream → D44 (reviewer's pick A). 5 🟡 folded (fd cap, per-step functions,
  `--fresh-db`, slow fixture, D16 period).

- `pr-reviewer` pass 1 (18:05), OK: 🟡 1 to 7 sent to scope 5's developer. 🟡 8 (the `cold_json` jq block in both
  harnesses) set aside: a refactor of working code after the measurement, better done when phase 5 next touches
  them. 🟡 9 (3 % + 0.02 ms aggregator-vs-k6 tolerance): scope 2 set it from its smoke runs (k6's own summary
  rounds and its trend is sampled differently), checks stay stable; not tightened now. "Plan to review" → Q11.

## Suggested skills

`autonomous-run`, `plan-format`, `markdown`.

## Where to look

- `lab/servers/diy-connection.php`: the DIY parser reads only `Content-Length`, `Connection`, `Transfer-Encoding`; it
  calls the global `handler_handle($method, $path, $body)`. Scope 1 changes this seam. `@0eba220`
- `lab/conns/client.php`: phase 3's idle-connection client, rotating 127.x source addresses; scope 3 reuses it. `@0eba220`
- `lab/lib.sh` → `lab_start_server`: mounts `lab/data` read-only and runs `php <flags> <server>`; the skeleton needs a
  fresh writable copy at `SQLITE_PATH` (D32). `@0eba220`

## Plan read up to

`plan.md`, `decisions.md` D1 to D44, 2026-11-22 11:18.

## Next steps

1. Check scope 2, push.
2. Scope 3 brief and developer.

## Retro

(at the end)
