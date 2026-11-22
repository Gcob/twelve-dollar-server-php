# $12 server challenge in PHP: decisions

## Active

- **D1:** no Nginx and no PHP-FPM. PHP runs the fastest way we can find: a long-running process that serves HTTP itself,
  in direct mode on port 80 (Jacob, 2026-11-21).
- **D2:** every score comparison uses `docs/leaderboard-par-langage.md` (snapshot of 2026-11-21). The real-PHP record to
  beat is 71,000 users (Swoole, #24 and #28) (Jacob, 2026-11-21).
- **D3:** we plan before we code: use cases, then a UML sequence per use case, then, for every step, the ways to
  implement it and a measurement of each (Jacob, 2026-11-21).
- **D4:** the project is a git repo in `www-perso/twelve-dollar-server-challenge/`. What we clone to read or compare
  (the challenge repo, other submissions) goes in `reference/`, ignored by git (Jacob, 2026-11-21).
- **D5:** we re-measure everything ourselves. A prior-art number is a prediction to check, never an answer
  ([Q1](questions/2026-11-21-0856.ronde-1.md)).
- **D6:** the bake-off runs Swoole, Workerman and our own loop and parser. RoadRunner, FrankenPHP and OpenSwoole are
  out. Workerman only once it's clear of rule 5 ([Q2](questions/2026-11-21-0856.ronde-1.md)).
- **D7:** we measure in a Docker container on the Mac, and move to x86 machines in the cloud (AWS EC2) when a result
  needs it ([Q3](questions/2026-11-21-0856.ronde-1.md)).
- **D8:** the PHP version is a measured variant: 8.3, 8.4, 8.5 and 8.6 ([Q4](questions/2026-11-21-0856.ronde-1.md),
  other exit).
- **D9:** the UML diagrams stay in Mermaid, in the Markdown ([Q5](questions/2026-11-21-0856.ronde-1.md)).
- **D10:** Workerman runs in the bake-off with its 5 request caches patched out in `build.sh`; one extra run with the
  caches on shows what they buy ([Q6](questions/2026-11-21-0914.ronde-1.md)).
- **D11:** the whole plan (plan, decisions, details, questions, notes) lives in this repo under `plan/` and is
  committed in public, for transparency. Anything about other people's private exchanges (`communications/`) stays
  out, ignored by git (Jacob, 2026-11-21).
- **D12:** (the "no worktree, code on `main`" part is replaced by D14 from phase 3) the work runs as an autonomous run (skill `autonomous-run`) with three changes: the
  project manager is its own session and Jacob talks to it through the planning session; the team commits **and
  pushes** on `main` of this repo, in this checkout, with no worktree (the plan, the decision board and the code stay
  in one place); one phase per run, with a stop at the end of each phase so Jacob sees its results before the next
  one. The planning session owns `plan/notes.md`; the project manager owns the rest of `plan/` (Jacob asked for the project-manager session and allowed the team to commit and push, 2026-11-21;
  working on `main` with no worktree, and one phase per run, are Claude's choices, logged in `notes.md`).
- **D13:** PHP 8.3 is built from source too, with the same configure flags as 8.4 to 8.6, next to the apt 8.3 that
  both Swoole entries used. Without it, "8.4 is faster than 8.3" could just mean "our build flags beat Ubuntu's"
  (project manager, phase 2, 2026-11-21).
- **D14:** from phase 3, the code goes on a branch per phase (`phase-N-claude`) in its own worktree, created by the
  planning session before the run starts. `plan/` stays on `main`, written and committed from the main checkout. The
  phase's branch merges into `main` after its final reviews: Jacob merges, or tells the project manager to. Replaces
  the "no worktree" part of D12; phase 2 stays on `main` (Jacob, 2026-11-21, [notes.md](notes.md) 09:45).
- **D15:** the lab measures on a quiet Docker VM: the other projects' containers are stopped and no image builds run
  during a measurement. Rerun that way, the micro sample's two levels went away (1 UNSTABLE row of 40 instead of 28),
  so numbers from a busy VM are remeasured before any comparison ([Q8](questions/2026-11-21-1411.ronde-2.md)).
- **D16:** phases 3 and 4 compare variants at about 7,000 req/s (a 75,000-user score), and the finalists also at
  9,500 req/s (100,000 users) ([Q9](questions/2026-11-21-1411.ronde-2.md)).
- **D17:** the phase 3 bake-off runs on PHP 8.5: the newest version all three runtimes build on (Swoole stops at 8.5,
  Q7), from source with the lab's flags (D13). Workerman and DIY also get one information run on 8.6 if ext-event
  builds there (project manager, phase 3, 2026-11-21, while Jacob was away).
- **D18:** Workerman and DIY run on ext-event (libevent, epoll). PHP's `stream_select` is capped at 1,024 fds, so
  Workerman's default loop would fail the connection test; the same loop for both leaves the framework and the parser
  as their only difference (project manager, phase 3, 2026-11-21).
- **D19:** in the bake-off each runtime keeps its own response headers (Swoole 5, Workerman 3, DIY 2); the results
  record the exact response bytes. Fewer header bytes are part of what a runtime can save (project manager, phase 3,
  2026-11-21).
- **D20:** the bake-off has two routes: `GET /noop` (the runtime alone) and `GET /posts/:id` (plus one indexed read with
  the spec's query). `/health` would add a third of the runs for a point between the two (project manager, phase 3,
  2026-11-21).
- **D21:** the source images get `pcntl`, `sockets` and `event` as shared extensions built with `phpize` from the same
  pinned tarballs, in a new last layer, loaded per server. Workerman refuses to start without `pcntl` and skips
  `TCP_NODELAY` without `sockets`; D13's configure flags stay untouched (plan review, settled by the project manager,
  phase 3, 2026-11-21).
- **D22:** every bake-off server gets listen backlog 4,096 and `TCP_NODELAY` on, recorded with the results. PHP's
  default backlog of 32 for a DIY server would rank the harness, not the runtime (plan review, settled by the
  project manager, phase 3, 2026-11-21).
- **D23:** max connections is counted by the client: the connections answered and still open. `/proc/net/tcp` is a
  cross-check (it also counts the accept queue); a client-side error fails the run instead of looking like a ceiling
  (plan review, settled by the project manager, phase 3, 2026-11-21).
- **D24:** DIY's partial write is tested on a socket pair whose peer doesn't read, not end to end: loopback buffers
  autotune to megabytes, so an end-to-end case could pass without one (plan review, settled by the project manager,
  phase 3, 2026-11-21).
- **D25:** the bake-off runs every run with twice the default VUs (`--pre-vus` and `--max-vus` at rate / 5: 1,400 at
  7,000 req/s, 1,900 at 9,500), on both routes and all runtimes. At rate / 10, stalls of 100 to 300 ms dropped
  iterations on `posts.js` (4 of 8 posts runs invalid, none of 11 `/noop` runs); their cause isn't separated (host, or
  the server's database reads), and the extra VUs absorb a stall whatever its cause. The cost: twice the connections
  under load, which moves Swoole's memory under load (a memory comparison must fix k6's connection count). The first
  try at rate / 10 is kept and shown, not counted (scope 7, settled by the project manager, phase 3, 2026-11-21).
- **D26:** PHP 8.6 gets the micro benches only; the Swoole servers run on 8.3 to 8.5, and we revisit when a Swoole
  release supports 8.6 ([Q7](questions/2026-11-22-1049.ronde-3.md)).
- **D27:** phase 4 is "realistic first": a walking skeleton of the 5 endpoints on the DIY server, a realistic mode of the
  lab (the bench's own journey, think time scaled, plus the bench's idle connections), the baseline it holds, and a
  profile under that load. The step lab (S1 to S9) becomes phase 5, in the order the profile gives; submission, score
  and submit become phases 6, 7 and 8. Where D16 says "phase 4", read the step lab, now phase 5. Phase 4 stops after
  the profile (D12) (Jacob, 2026-11-22 10:49, [notes.md](notes.md) "test the way Arjay tests").
- **D28:** the posts stalls of the bake-off (Q10) are measured inside phase 4's realistic runs: per-second latency, cold
  versus warm page cache, `gc_status()` and SQLite's page cache (or the page faults that stand for it), under the bench's
  real hot set (the newest posts, read from the feed), and once more under the bake-off's `posts.js` to tell a lab
  artifact from a real stall ([Q10](questions/2026-11-22-1049.ronde-3.md), answered A by the shape of phase 4).
- **D29:** rule 5, as the challenge's author ruled on 2026-11-15 (`LEADERBOARD.md`, "Rule flags from code review"):
  every request does its own reads. No read is shared by several requests, whether merged (identical reads) or batched
  (one `IN (...)` for several requests' ids). Group commit for writes stays allowed (rule 6), each response waiting for
  its commit (Jacob, 2026-11-22, [notes.md](notes.md) 10:41).
- **D30:** S9 gets two new variants for the step lab: a group commit with one batch per turn of the event loop (no
  timer), and a background checkpointer (a separate process running `PRAGMA wal_checkpoint(PASSIVE)` on a timer, with
  the server's `wal_autocheckpoint` off) (Jacob, 2026-11-22, [notes.md](notes.md) 10:33).
- **D31:** in the realistic mode, a step passes when it meets the bench's thresholds (p95 under 500 ms, p99 under 1 s,
  errors under 1 %) **and** its VUs achieve at least 97 % of the request rate they offer (their count over the journey's
  mean loop time, latency left out). Users are mapped from the achieved rate (10.8 users per req/s, the leaderboard's
  ratio), never from the VU count. Why: with think time scaled by `s`, latency weighs `1/s` times more in a VU's loop, so
  the thresholds alone pass loads far past saturation (at `s = 0.02`, an average latency of 500 ms needs about 3.6 times
  the VUs of the knee; in the real bench, 1.05 times) (project manager, phase 4, 2026-11-22).
- **D32:** the skeleton reads its config like a submission: it opens `SQLITE_PATH` (never copies it) and reads
  `JWT_SECRET`, `HOST` and `PORT`. The lab gives every run a fresh copy of the seed on the server container's own disk.
  The bake-off's files keep working (its `check.sh` checks stay green), and its numbers stay reproducible at their
  commit (project manager, phase 4, 2026-11-22).
- **D33:** the profiler is Excimer (PECL, sampling on CPU time), built in the images like ext-event (sha256 pinned, loaded
  only with `--ext excimer`). The kernel's part comes from the cgroup's `system_usec` against `user_usec`; `perf` only if
  it runs without changing anything VM-wide. A profiled run never gives a µs/req of the baseline: its cost is measured
  against an unprofiled run instead (project manager, phase 4, 2026-11-22).
- **D34:** the skeleton prints one telemetry line per second with `APP_TELEMETRY=1` (requests per endpoint, its longest
  callback, `gc_status()` counters, the WAL's size, minor and major page faults). It's on in every phase 4 run; its cost
  is measured once, on against off at the same rate (project manager, phase 4, 2026-11-22).
- **D35:** the baseline runs the DIY server only (the cheapest per request in the bake-off) on PHP 8.5 (D17), on the
  Mac: the users it maps to are an arm64 number, not a score (D7) (project manager, phase 4, 2026-11-22).
- **D36:** the realistic mode's sizes: 60,000 idle keep-alive connections held by phase 3's connection client, at most
  3,000 k6 VUs (k6's memory in a 7.75 GiB VM, and 63,000 sockets in all stay under the server's 65,535 fds), a think
  scale picked by calibration so the knee needs at most 2,500 VUs. The baseline: warm-up, a staircase that stops at the
  first failing step, then 3 holds of 5 minutes at the highest passing step (the median counts) and 1 hold one step
  above; a fresh seed copy for every run (project manager, phase 4, 2026-11-22).
- **D37:** `lab/check.sh` runs every `lab/results/*/summarize.sh` and checks that each line it prints is in that
  folder's README, so a results README can't drift from its raw files. Phase 4 adds it as its last scope, so it also
  covers the baseline's folder ([round 3](questions/2026-11-22-1049.ronde-3.md), Jacob's `ok` to the retro's item).

## History

Nothing yet.
