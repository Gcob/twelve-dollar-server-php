# Brief: scope 5/6, the macro harness with k6 and a no-op Swoole server

**Repo (no worktree, work on `main`):** the repo root, `www-perso/twelve-dollar-server-challenge/` under the home
folder. **Run folder:** `plan/` in that repo.
**Planned commit:** `feat(lab): macro harness with k6 and a no-op Swoole server`

## How this run differs from your agent file

- **Write in English** everywhere: `plan/state/developer.md`, your answer, code, comments, commits.
- **No worktree:** you work in the repo's own checkout, on `main`. Every git command is `git -C <absolute repo path>
  ...`, alone in its Bash call, path written in full (no `~`, no variable).
- **Commit, don't push:** one commit, `git add` each file by name (never `git add .`), no co-authored-by line. The
  project manager pushes after checking your commit.
- **Another session may edit `plan/notes.md` and the project manager edits other files in `plan/`:** never stage
  them, never stash, reset or switch branches.
- **The repo is public:** no absolute `/Users/...` path, email or account id in any committed file.
- **`reference/` is read-only.**

## The scope

**Summary:** a script that loads a PHP server running in a lab container with k6 at a fixed request rate, and
reports the server's CPU µs per request, its latency and its memory; plus the no-op Swoole server to check it with.

**Today:** scopes 1 to 4 made the seed, the images (`8.3-apt`, `8.3`, `8.4`, `8.5`, `8.6`), `lab/lib.sh` (CPU
layout: server on CPU 2, k6 on CPUs 4 to 11), `lab/build.sh`, `lab/run.sh`, `lab/check.sh` and the micro harness.
Read the handovers in `plan/state/developer.md`.

**Expected:**

- **`lab/servers/noop-swoole.php`:** Swoole HTTP server, `SWOOLE_BASE`, `worker_num => 1`,
  `enable_coroutine => false`, `http_parse_post`, `http_parse_cookie`, `http_parse_files` and `http_compression` off,
  like both Swoole entries. Answers **200** `{"status":"ok"}` with `Content-Type: application/json` to every
  request. Listens on `0.0.0.0:8080` (the port doesn't change the measure; the VM's 80 may be taken). PHP flags like
  the entries' `start.sh`: `-d extension=swoole -d memory_limit=-1 -d opcache.enable_cli=1 -d opcache.jit=tracing
  -d opcache.jit_buffer_size=32M`. Logs off or minimal (no per-request log).
- **k6:** the `grafana/k6` image pinned by tag **and** digest (latest stable 1.x, arm64 available), in its own
  container, `--network host`, pinned to the k6 CPUs from `lab/lib.sh`, no CPU limit of its own. A default script
  (for example `lab/macro/k6/fixed-rate.js`) with the `constant-arrival-rate` executor: rate, duration, target URL
  and VU counts from env vars; enough `preAllocatedVUs` (and `maxVUs`) that `dropped_iterations` stays 0 at the
  requested rate. Each VU keeps its own keep-alive connection: the VUs used are the open connections, report them.
- **`lab/macro.sh --image <variant> --server <php file> --rate <req/s> --duration <s> [--warmup <s>]
  [--script <k6 js>] [--out <path>]`:**
  1. starts the server container (the lab's limits and pin, `--network host`, a fixed container name), waits until
     it answers;
  2. a warm-up k6 run (default 10 s, same rate);
  3. reads the server cgroup's `cpu.stat` `usage_usec`, runs the measured k6 run, reads it again;
  4. **µs CPU per request** = the `usage_usec` delta divided by the measured run's request count (from k6's
     `--summary-export` JSON or `handleSummary`);
  5. also reports: requested and achieved req/s, p50, p95, p99, max, the error rate, `dropped_iterations`, VUs used,
     **peak RSS** (the cgroup's `memory.peak`, and the PHP process's `VmHWM` from `/proc/<pid>/status`, both:
     `memory.peak` counts page cache, `VmHWM` doesn't), and **k6's own CPU** over the measured run (its container's
     `cpu.stat` delta, as a % of one CPU) so we can see k6 wasn't the bottleneck;
  6. always removes the server container at the end, even on failure (`trap`).
- **How you read `cpu.stat` matters:** a `docker exec <server> cat /sys/fs/cgroup/cpu.stat` runs inside the server's
  cgroup, so its own CPU lands in the measure. Either read it from outside the cgroup (a helper container that sees
  the host's cgroup tree, for example), or measure what a `docker exec` read costs (two reads back to back on an idle
  server) and show that cost in the output. Your call; say which in the README and the handover.
- **Validity:** a run with errors above 0 % or `dropped_iterations` above 0 is still printed, but marked
  **invalid** in the table and the JSON.
- **Output:** a short human table and a JSON file with every number, the image digest, the k6 version, the Docker
  Desktop and VM kernel versions, and the exact command. Default path under `lab/results/` (dated); `--out`
  overrides.
- **`lab/check.sh`:** a 5 s macro run on the no-op server at a low rate, which must be valid.
- **`lab/README.md`:** a "Macro benchmarks" section: the command, the CPU layout, how µs/req is computed, the
  validity rules.

**Done when (from the plan, word for word):** `lab/macro.sh` against the no-op server at 2,000 req/s for 30 s prints
requests, µs CPU/req, p95, p99, error rate, dropped iterations and peak RSS, with 0 errors and 0 dropped iterations.

**Cases to check:** a run at a rate the VU counts can't hold is marked invalid (force it once with a tiny
`maxVUs`); the server container is gone after a failed run (kill k6 mid-run once, or point it at a wrong port);
`lab/check.sh` passes in full. Don't commit the outputs of these trial runs; scope 6 records the real first number.

**Environment:** Docker Desktop on an Apple M3 Pro (linux/arm64), 12 vCPUs in Docker's VM, cgroup v2. **Never run k6
on macOS itself:** Docker Desktop's port forwarding from macOS into its VM goes through a userspace proxy and would
pollute every number. Server and k6 both on `--network host`, inside the VM.

**Decisions that touch you:**

- D1: no Nginx, no FPM: the server is a long-running PHP process serving HTTP itself.
- D5: prior-art numbers are predictions; the output must say where and how it ran.
- D7: Docker on the Mac, host network only, server and k6 on separate pinned CPUs.
- Measuring method (from the plan): fixed rate, not max rate; µs CPU per request from the cgroup's `cpu.stat`
  (`usage_usec`) before and after, divided by the requests: the leaderboard's own metric; p95 and p99 and the error
  rate; peak RSS of the server's cgroup.

**Out of scope:** the first real number with repeats (scope 6), any real route or SQLite (phase 3), the connection
ceiling test (phase 3).

**Where to look:** `reference/twelve-dollar-server-challenge/submissions/php-swoole-mattsplat/server.php` (Swoole
settings, near the end) and `start.sh`; `reference/twelve-dollar-server-challenge/submissions/php-swoole-tzimpel/`
(how it measured µs/req at a fixed rate, if it has scripts for it); `reference/twelve-dollar-server-challenge/bench/load.js`
(the leaderboard's k6 script, for k6 options it sets).

**Read first:** `plan/state/developer.md`.

**Come back to me if:** a decision is missing from this brief, or the "Done when" doesn't pass after 3 tries.

## Relaunches

- **2026-11-21 10:30:** the PM's rerun on `8.3-apt` at 2,000 req/s was INVALID: 36 dropped iterations with 9 of
  200 VUs used (PRE_VUS 50), latency max 36.54 ms. Asked: 5 repeats to count the drops, find why k6 drops with idle
  VUs, fix it if it's k6 or the harness, else report and propose a validity rule (the PM decides).
