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
- **D11:** (the factory's working files are private since 2026-11-22, see D48) the whole plan (plan, decisions, details, questions, notes) lives in this repo under `plan/` and is
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
  9,500 req/s (100,000 users) ([Q9](questions/2026-11-21-1411.ronde-2.md)). D40 corrects the users: a
  steady 7,000 req/s is about 66,000 users, 9,500 about 90,000; the rates stay.
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
  mean loop time, latency left out). Users are mapped from the achieved rate (9.45 users per req/s, D40), never from
  the VU count. Why: with think time scaled by `s`, latency weighs `1/s` times more in a VU's loop, so
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
- **D36:** the realistic mode's sizes: 60,000 idle keep-alive connections held by phase 3's connection client, k6's VUs
  on top, all sockets under the server's 65,535 fds (the VU cap and the think scale: D39). The baseline: warm-up, a staircase that stops at the
  first failing step, then 3 holds of 5 minutes at the highest passing step (the median counts) and 1 hold one step
  above; a fresh seed copy for every run (project manager, phase 4, 2026-11-22).
- **D37:** `lab/check.sh` runs every `lab/results/*/summarize.sh` and checks that each line it prints is in that
  folder's README, so a results README can't drift from its raw files. Phase 4 adds it as its last scope, so it also
  covers the baseline's folder ([round 3](questions/2026-11-22-1049.ronde-3.md), Jacob's `ok` to the retro's item).
- **D38:** in the realistic mode, k6 binds its own source addresses (`--local-ips`, for example 127.0.1.1 to 127.0.1.4),
  recorded in the JSON. The idle client `bind()`s each port before it connects, and a port reserved that way is skipped
  by every unbound `connect()`: with 60,000 held, k6 from 127.0.0.1 would get about 500 ports. If k6 1.8.3 refuses
  loopback local IPs, the idle client sets `IP_BIND_ADDRESS_NO_PORT` instead. Never a VM-wide `ip_local_port_range`
  change (plan review, settled by the project manager, phase 4, 2026-11-22, [PLAN-2026-11-22-1110](reviews/PLAN-2026-11-22-1110.md) item 1).
- **D39:** the VU cap and the think scale come from calibration: k6's MiB per VU (measured with D41's stream running,
  D44) sets the cap at (VM memory − 2 GiB for the server − the idle client − 1 GiB of margin) / MiB per VU, and never
  above the server's free fds (65,535 − the idle connections − the server's own, about 5,400 with 60,000 idle); the scale `s` is then picked so 20,000 req/s fits under
  the cap, so the staircase always reaches a failing step. The k6 container gets a `--memory` limit, so an overrun fails
  k6 cleanly instead of making the VM swap. The calibration also records achieved against offered at low load and k6's
  CPU, so the 97 % rule's margin (about `0.29 × s` s of mean latency per request) is known next to `s` (plan review,
  settled by the project manager, phase 4, 2026-11-22, [PLAN-2026-11-22-1110](reviews/PLAN-2026-11-22-1110.md) items 2 and 9).
- **D40:** a steady load maps to users at 9.45 per req/s (20.5 s of think time over 2.17 requests per loop). The
  leaderboard's 10.8 is a whole-run ratio: its k6 rate includes the 60 s ramp-up and the 30 s ramp-down (about 10.7 in
  theory, 10.2 to 10.84 observed). 10.8 stays only to read the leaderboard's req/s column. So the 71,000 record is about
  7,500 steady req/s, and 🤝's `users ≈ 9.2 million / µs per request` becomes about 8.0 million (plan review, settled by
  the project manager, phase 4, 2026-11-22, [PLAN-2026-11-22-1110](reviews/PLAN-2026-11-22-1110.md) item 3).
- **D41:** per-step and per-second numbers come from one k6 scenario (`ramping-vus`) streamed live: k6's CSV output into
  a FIFO, read by an aggregator that keeps per-second latency histograms per endpoint (log buckets, under 1 % error), so
  a step's p95 and p99 merge its seconds' histograms. Nothing raw goes to disk during a measured run. The harness stops
  k6 at the first failing step and handles k6's exit 99 (thresholds failed) as a result, not a harness failure. If the
  aggregator can't keep up (k6 blocks), fall back to one scenario per step (plan review, settled by the project manager,
  phase 4, 2026-11-22, [PLAN-2026-11-22-1110](reviews/PLAN-2026-11-22-1110.md) items 4 and 18).
- **D42:** one seed-copy function in `lab/lib.sh`, used by `challenge-test.sh`, `realistic.sh` and `macro.sh`: it copies
  the seed with `cp` inside the server container (so its page cache is charged to the server's cgroup, like the
  bake-off's), `fsync`s it, and with `--cold` evicts its pages (`POSIX_FADV_DONTNEED` skips dirty pages, hence the
  `fsync`). Scope 1 builds the copy, scope 3 adds `--cold` and wires `macro.sh` behind a named switch (`--fresh-db`), so
  Q10's `posts.js` reruns run the skeleton and the bake-off servers, which copy their own seed, don't get a second one (plan review, settled by the project manager, phase 4, 2026-11-22, [PLAN-2026-11-22-1110](reviews/PLAN-2026-11-22-1110.md) items 5, 11 and 12).
- **D43:** before the profile ranks the steps, a calibration fixture proves where Excimer puts a C function's samples:
  a route that spends a known share of CPU in one internal function (`hash('sha256', ...)` in a loop) against a PHP
  loop, profiled with the JIT on and off; its share must land on the internal frame within a stated tolerance. The
  README says where libevent's and `epoll_wait`'s time lands. So that "attributed to the caller" still means "attributed
  to the step", the skeleton keeps each step's work in its own function (the JWT check, the validation, each query, the
  JSON building, the response), named by what it does, and the fold's rules map those functions (plan review, settled
  by the project manager, phase 4, 2026-11-22, [PLAN-2026-11-22-1110](reviews/PLAN-2026-11-22-1110.md) item 6, and
  [PLAN-2026-11-22-1116-delta](reviews/PLAN-2026-11-22-1116-delta.md)).
- **D44:** D41's stream is guarded, because k6 buffers samples in memory when the reader falls behind instead of
  slowing its VUs: k6's MiB per VU is calibrated with the stream on; a scope 2 case replays a recorded CSV at the rows of
  40,000 req/s through the aggregator; and every measured run is invalid, with that reason, when the aggregator's lag
  (newest sample time against the clock) passes its gate or k6's memory passes its budget. k6's CSV flushes every
  second by default, so the gate is the lag measured in calibration plus 2 s, with `K6_CSV_SAVE_INTERVAL` lowered. The
  aggregator runs in its own container on k6's CPUs, outside k6's memory budget. If the replay is too slow, the
  reader skips every line but `http_req_duration` and `http_reqs` before parsing (plan review delta, settled by the
  project manager, phase 4, 2026-11-22, [PLAN-2026-11-22-1116-delta](reviews/PLAN-2026-11-22-1116-delta.md)).
- **D45:** a realistic step is generator-bound, and invalid, when k6 and the aggregator use more than 80 % of their
  8 CPUs on it. Scope 2 measured k6 at about 300 µs of CPU per request with the CSV stream on (falling with the rate,
  measured up to 2,000 req/s): 20,000 req/s could need 5 to 6 CPUs. If the baseline's top steps cross the line, k6
  sends fewer tags per CSV row (`systemTags`) before the top rate is lowered (project manager, phase 4, 2026-11-22,
  scope 2's question).
- **D46:** two settings for the baseline, from scope 3's smoke runs (busy VM, not measurements): the skeleton passed
  every step up to 17,816 req/s with 60,000 idle connections, and 19,565 req/s at the VU cap, so its knee may sit above
  the 20,000 req/s that D39's scale reaches. **The scale:** if the staircase reaches the cap with no failing step, `s`
  is lowered (more req/s per VU, same VUs) until it fails, within D45's line; if k6 hits D45 before the server fails,
  the baseline is reported as "at least" that rate, and a second load generator becomes a question for Jacob. **The lag
  gate:** k6's CSV flush lags 2.4 to 3.9 s at 18,000 req/s (the replay reads 480,000 rows/s in 1 s, so the reader isn't
  the cause), so D44's gate is the lag calibrated at the top rate plus 2 s: 6 s. A lag that keeps growing is what the
  gate is for, not a steady one (project manager, phase 4, 2026-11-22, scope 3's questions).
- **D47:** the baseline's held rate depends on the think scale, so the step lab carries the **µs of CPU per request**
  (27.15, median of 3 holds) and the profile, not the held rate. At `s = 0.02` the skeleton holds 23,386 req/s
  (221,002 users at 9.45) with its CPU 63 % busy: the 97 % rule fails on k6's own loop overhead plus a 2.2 ms mean
  latency, not on the server, and a smaller `s` hits k6's overhead sooner. The held rate is reported as "at least
  23,386 req/s at `s = 0.02`", never as the server's capacity. The baseline stays at 24,000 offered (the hold one step
  above passes too: a conservative reading), with no new holds. Three 60 s cost runs that missed the 97 % rule by 0.1
  to 0.3 points count for their µs per request, which the rule doesn't measure (project manager, phase 4, 2026-11-22,
  scope 5's questions).
- **D48:** since 2026-11-22, the factory's working files are private: `run.md`, `run.yml`, `state/`, `reviews/`,
  `runs/` and `snapshots/` live in a private repo next to this one, reached through git-ignored symlinks under `plan/`,
  along with raw machine diagnostics and the push guard's denylist. The plan, the decisions, the notes, the details,
  the questions, the code and the lab's results stay public. A push guard (`tools/public-guard.sh`, before every push
  and in `lab/check.sh`) refuses e-mail addresses, home paths and the denylist's words. Changes D11; the earlier
  versions of the moved files stay in this repo's history (Jacob, 2026-11-22 18:31 and 18:35,
  [notes.md](notes.md)).
- **D49:** the step lab (phase 5) judges each variant on its **µs of CPU per request** (the median of its runs) and
  its profile, with the per-second p99 beside it when a variant changes latency without changing µs/req (group commit,
  for example). The held rate is measured again only at the end of phase 5, on the chosen variants together: at
  `s = 0.02` it is k6's floor, not the server's (D47), and one process caps the real bench near 71,000 users whatever
  the CPU. No second load generator and no change to the pass rule (Jacob, 2026-11-22 20:42,
  [Q11](questions/2026-11-22-2042.ronde-3.md)).
- **D50:** the step lab is split in two runs. **5a** (this run): S1 (S1-d and S1-b), the io_uring spike, a syscall
  count per request, S6, S8 and S9, the chosen variants together with their held rate (D49), and the x86 calibration
  if Jacob says go. **5b:** S7, S2, the event loop, S4, S3, S5, the PHP version and the FFI driver to `libsqlite3`
  (the spike's FFI numbers come first). 5a holds the walls and 75 % of the profile; 12 scopes is already the longest
  run so far ([Q13](plan.md), `run`, project manager, phase 5, 2026-11-22).
- **D51:** the step lab compares variants with `lab/steplab.sh`: fresh 60 s realistic runs, interleaved by round
  (A B A B ...), 60,000 idle connections, no per-second probes, telemetry off, one offered rate per step (12,000 req/s
  for S1, so that a reconnect on every request fits in the CPU; 24,000 for the CPU steps, the baseline's). An A/A
  calibration comes first (the skeleton against itself, 5 pairs at each rate): it gives the noise and the floor, the
  largest absolute paired difference of its 5 pairs. A variant gets 3 pairs (5 for S9's). A variant's number is the median µs/req of its runs; the verdict reads the
  paired differences (each run against the reference's run of the same round): "beyond the noise" when every pair has
  the same sign and the median difference passes the floor. A variant predicted under the floor is judged on its micro
  bench or its syscall count, the macro only checking that it costs nothing. Why: with the baseline's noise (σ about
  0.5 µs a run), "the median difference against the reference's spread" called identical variants different 17 % of
  the time at 3 runs and caught a real 1 µs only 61 % of the time; with the largest A/A difference as the floor and
  every pair agreeing in sign, about 3 % (project manager, phase 5, 2026-11-22, revised after the plan review and its
  delta, [PLAN-2026-11-22-2110](reviews/PLAN-2026-11-22-2110.md) item 4,
  [PLAN-2026-11-22-2116-delta](reviews/PLAN-2026-11-22-2116-delta.md) item 1).
- **D52:** the io_uring spike passes its gate: the bench builds and starts a submission on the box itself, with
  systemd as user `deploy` (`LimitNOFILE=65535`, `CAP_NET_BIND_SERVICE`), not in Docker (`LEADERBOARD.md`, "How each
  entry is scored"), and more than 30 io_uring entries are scored there. In the lab, only an io_uring server runs with
  Docker's seccomp filter off (`--security-opt seccomp=unconfined`), which is closer to the bench than a custom
  profile (project manager, phase 5, 2026-11-22).
- **D53:** S1-d's shape: `APP_SOFT_CONN_LIMIT=<n>`; a response built while more than `n` client connections are
  open (strictly more: the `n`-th keeps alive) carries `Connection: close`, and the server closes that connection once
  the response is written. An idle connection is never closed (S1-c scored 0). S1-d's runs set `n` to their idle
  count, so the idle connections stay and every k6 request reconnects (`n = 0` would close the idle ones after their
  first `GET /health`, and a closed idle connection makes a realistic run invalid). Separately, when `accept` fails for
  lack of fds, the listening event pauses until a connection closes instead of spinning: a fix in every server on the
  DIY loop, not a variant (project manager, phase 5, 2026-11-22, revised after the plan review,
  [PLAN-2026-11-22-2110](reviews/PLAN-2026-11-22-2110.md) items 2 and 14).
- **D54:** syscalls are counted with `strace -c -f` attached from a sidecar container during a fixed low-rate run
  (2,000 req/s), divided by the requests of the same window. Only the counts are kept: strace slows the server, so its
  times say nothing about the server's (project manager, phase 5, 2026-11-22).
- **D55:** the x86 calibration runs the lab as the Mac does on one `c5.2xlarge` (`m5.2xlarge` if none), the server on
  one vCPU whose hyperthread sibling stays idle, k6 on the others: µs/req of the same two configurations on the Xeon and
  on the Mac at one rate. Nothing is created before Jacob's go; the temporary IAM policy waits in the factory
  ([notes.md](notes.md) 20:39; project manager, phase 5, 2026-11-22).
- **D56:** the io_uring spike proves the fail-fast answer on one ring: 60,000 connections held on one ring while the
  process's own fds stay under 100 (direct descriptors take no fd), the stress test and the µs/req. A ring's fixed-file
  table can't be larger than `RLIMIT_NOFILE` (the kernel answers `EMFILE`; the reference's io_uring entries run 8 to 10
  rings for that reason), so 80,000 connections need two rings: a stretch goal inside the same time box. If FFI's cost
  eats the gain on one ring, a second ring changes nothing ([Q15](plan.md), `run`; plan review, settled by the
  project manager, phase 5, 2026-11-22, [PLAN-2026-11-22-2110](reviews/PLAN-2026-11-22-2110.md) item 1).
- **D57:** a harness that a measuring scope will use is smoked at the real shape in the scope that builds it, before
  the quiet VM: scope 1 runs one steplab pair at 60,000 idle and 24,000 req/s; scope 2 a 5-minute churn at the fd
  wall's shape (64,000 idle, soft limit 64,000, 12,000 req/s). Every runner that churns connections counts the
  TIME_WAITs on k6's source addresses before each run and waits for them to drain (the VM's ports are 55000 to 65535,
  about 10,500 per k6 address) (plan review, settled by the project manager, phase 5, 2026-11-22,
  [PLAN-2026-11-22-2110](reviews/PLAN-2026-11-22-2110.md) item 3).
- **D58:** group commit finds the end of a loop turn by driving the loop itself: with `APP_GROUP_COMMIT=1`,
  `EventBase::loop(LOOP_ONCE)` in a loop, the flush after each call. A zero-timeout timer added during a callback runs
  only after the next turn's I/O callbacks in libevent, so it would flush a turn late. Unset, `dispatch()` as today
  (plan review, settled by the project manager, phase 5, 2026-11-22,
  [PLAN-2026-11-22-2110](reviews/PLAN-2026-11-22-2110.md) item 5).
- **D59:** with group commit, a connection whose write waits for the flush stops parsing until that write's response
  is in its write buffer, so pipelined responses stay in request order. The flush resumes the connections it paused
  (their responses, then the bytes waiting in their read buffer, their events re-armed) and commits again until nothing
  is queued, so two pipelined writes on one connection don't stall. k6 never pipelines, so it costs the bench
  nothing (plan review, settled by the project manager, phase 5, 2026-11-22,
  [PLAN-2026-11-22-2110](reviews/PLAN-2026-11-22-2110.md) item 6, and
  [PLAN-2026-11-22-2116-delta](reviews/PLAN-2026-11-22-2116-delta.md) item 2).

## History

Nothing yet.
