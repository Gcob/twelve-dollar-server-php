# Phase 4: realistic baseline

**Done when:** `lab/results/<date>-realistic-baseline/README.md` gives, for the walking skeleton (the 5 endpoints on
the DIY server, the simplest variants), under the bench's own journey with 60,000 idle connections held: the highest
load it holds for 5 minutes on the Mac (median of 3 holds), its µs CPU/req, p95 and p99 per endpoint, per-second
latency, memory, the WAL's size over time and the users it maps to; a profile under that load split into S1 to S9 and
the kernel, per endpoint; and Q10's answer (D28). The predictions below were written before any measurement (D5).
Then the run stops: the step lab is phase 5 (D12, D27).

**Where (D14):** code on branch `phase-4-claude`, in its worktree. `plan/` stays on `main`.

**Why this shape (D27):** the lab ranked runtimes at a fixed rate on one route at a time. It is blind to the bench's
mix (`/feed` is 46 % of the requests and isn't measured yet), its connections (most of them idle), its time (5 minutes
of writes: the WAL grows, checkpoints run) and its hot set (the bench only reads the newest posts). Phase 4 measures the
server the way the bench loads it, then profiles it, so phase 5 works on the steps that cost the most.

## Decisions of this phase

From Jacob (D26 to D30) and the project manager (D31 to D36), in [decisions.md](../decisions.md):

- **D29, rule 5:** every request does its own reads; no read shared by several requests, merged or batched with
  `IN (...)`. Group commit for writes stays allowed.
- **D31, the pass rule of the realistic mode:** a step passes on the bench's thresholds **and** an achieved rate of at
  least 97 % of what its VUs offer; users come from the achieved rate (10.8 per req/s). Scaled think time otherwise
  lets the thresholds pass loads far past saturation.
- **D32, the skeleton's contract:** it opens `SQLITE_PATH`, reads `JWT_SECRET`, `HOST`, `PORT`, never copies the
  database. The lab gives each run a fresh copy.
- **D33, Excimer:** sampling on CPU time; the kernel's part from `system_usec`; a profiled run gives no baseline µs/req.
- **D34, telemetry:** one line per second with `APP_TELEMETRY=1`, on in every run, its cost measured once.
- **D35:** DIY only, PHP 8.5, arm64: the mapped users aren't a score.
- **D36, sizes:** 60,000 idle connections, at most 3,000 VUs, a calibrated think scale; staircase, then 3 holds of
  5 minutes (median) and 1 hold one step above; a fresh seed copy per run.

## Scopes

| #   | Commit                                                                 | Done when |
|-----|------------------------------------------------------------------------|-----------|
| 1   | `feat(app): the five endpoints on the DIY loop, the challenge's tests` | `bash lab/challenge-test.sh --image 8.5` prints the challenge's `passed=42 failed=0` and exits 0, twice in a row (a fresh seed copy each time); with a fixture server that answers one golden wrong it exits non-zero and names the failing check; `bash lab/check.sh` is all `ok`, its bake-off checks unchanged |
| 2   | `feat(lab): realistic mode, the bench's journey with scaled think time` | `lab/realistic.sh` on the skeleton, a 3-step staircase of 20 s steps at low load, prints one row per step (VUs, offered and achieved req/s, mapped users, µs CPU/req, p95 and p99 per endpoint and overall, errors, pass or the reason it failed) and exits 0; a step far above capacity fails with the reason `achieved below 97 % of offered`; the JSON holds the think scale, k6's peak memory, `other_containers` and the k6 script's diff against `bench/load.js` is only the scaling and the options |
| 3   | `feat(lab): idle connections and per-second series in the realistic mode` | `lab/realistic.sh --idle 5000` reports 5,000 idle connections held at the start and at the end; its per-second table has one row per second with latency per endpoint (count, p50, p99, max), server CPU, `Pss_Anon`, `memory.current`, WAL bytes, minor and major faults and the server's telemetry (longest callback, GC runs); `--cold` shows the copy's resident pages near 0 before the first request (`fincore`), against the whole file without it; `lab/macro.sh --per-second` prints the same latency series for a fixed-rate run |
| 4   | `feat(lab): Excimer profiles folded into the steps S1 to S9`          | `lab/run.sh 8.5 php-info` prints `excimer: <version>`; a 20 s profiled realistic run writes the collapsed stacks and `lab/profile/fold.php` prints one table (rows S1 to S9, the event loop, unclassified; columns per endpoint and all), the shares summing to 100 % and unclassified under 5 %, plus the cgroup's user and system split for the same window |
| 5   | `docs(lab): the realistic baseline`                                     | `lab/results/<date>-realistic-baseline/README.md` holds the predictions (copied from this file, unchanged), the staircase, the 3 holds and their median, the hold one step above, per-endpoint p95 and p99, per-second latency, memory and WAL over time, the profile table, Q10's runs and answer, telemetry's and Excimer's cost, each prediction marked held or not; every counted run passes and says `other_containers: 0`; `summarize.sh` regenerates its tables |

Vertical slices: scope 1 is the skeleton with the test that proves it (the challenge's own). Scope 2 is the smallest
realistic run end to end (journey, staircase, pass rule) on that skeleton. Scope 3 adds what the bench has that scope 2
doesn't (the idle connections, time) and Q10's instruments. Scope 4 adds the profiler and its fold. Scope 5 only
measures, on a quiet VM (D15).

**The lab's suite:** `lab/check.sh`. Each scope adds its smoke check (scope 1 the challenge's tests, scopes 2 and 3 a
short realistic run, scope 4 a short profiled run and the fold on a fixture). It's the "full suite" of the skill, run
before the reviews.

## Shared rules for every scope

Phases 2 and 3's rules hold ([phase-2.md](phase-2.md), [phase-3.md](phase-3.md), "Shared rules"): limits, the CPU
layout in `lab/lib.sh`, pinned versions with sha256, no absolute `/Users/...` paths, `reference/` read-only,
`other_containers` in every JSON, memory as `Pss`, `Pss_Anon` and `memory.current`. New for phase 4:

- **Rule 5 (D29):** every request runs its own statements. Nothing read for one request answers another.
- **Durability (rule 6):** every write commits before its response; the skeleton has no batching.
- **The challenge's own files are copied, never edited in `reference/`:** a copied file names its source path and
  commit and keeps the MIT credit in `lab/NOTICE.md`.
- **The bake-off stays reproducible:** its servers and `handler.php` keep passing their checks. Code they share with
  the skeleton (`diy-connection.php`) may change if their checks stay green.
- **No image build during a measurement (D15).** Scope 4 rebuilds the images; scope 5 measures only after it.

## Scope 1: the walking skeleton

- **Seams:** `lab/app/` (the app's routes, its JWT check and its server entry, `lab/app/server.php`), the DIY connection
  code (`lab/servers/diy-connection.php`), `lab/challenge-test.sh --image <v> [--server <file>] [--ext <e>]...`, and a
  check in `lab/check.sh`. The developer picks the file split inside `lab/app/`.
- **The contract (D32):** env `SQLITE_PATH`, `JWT_SECRET`, `HOST` (default `0.0.0.0`), `PORT`. The server opens
  `SQLITE_PATH` with the bake-off's pragmas (WAL, `synchronous = NORMAL`, 64 MiB cache, 256 MiB mmap, `temp_store`
  memory, `busy_timeout`), prepares its statements once at boot, and listens only once the database is open. The lab
  copies the seed to the server container's own disk before the server starts (a fresh copy per run), never into
  `lab/data/`.
- **The simplest variants** (the step lab replaces them one by one in phase 5):
  - **S2:** the DIY parser, extended to read `Authorization` and pass it to the app with the method, the path and the
    body; `Content-Type` isn't checked (the spec doesn't ask).
  - **S3:** a route match on the method and the path, in the app.
  - **S4:** a hand-written HS256 check: split on `.`, base64url decode (`strtr` and `base64_decode`), `json_decode` of
    the header (exactly `alg` `HS256`) and the payload, `hash_hmac('sha256', ...)` compared with `hash_equals`, `exp`
    required and in the future. Then the payload: `sub` a positive integer string, `username` a string, else
    `invalid token payload`. Any other failure: `invalid or expired token`. No `Bearer ` prefix: `missing bearer token`.
    Every token is verified (rule 5).
  - **S5:** id with `ctype_digit` and `> 0`; body with `json_decode` (not an object, or `body` not a string: `body is
    required`; invalid JSON: `malformed JSON body`), `trim`, length with `mb_strlen` against 500.
  - **S6:** PDO SQLite, the spec's reference SQL (the post query with `ORDER BY p.created_at DESC, p.id DESC LIMIT 20`
    for the feed, `WHERE p.id = ?` for a post), `INSERT ... RETURNING id, created_at` for a post, `INSERT ... ON
    CONFLICT (user_id, post_id) DO NOTHING` for a like after checking the post exists (SQLite doesn't enforce the
    foreign key), `fetch` with `FETCH_ASSOC`.
  - **S7:** `json_encode` of arrays in the spec's key order, `JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE`.
  - **S8:** the DIY response: status line, `Content-Type: application/json`, `Content-Length`, the body.
  - **S9:** autocommit, one transaction per write, `wal_autocheckpoint` at its default.
- **`/health`:** `SELECT 1`, then `uptime_s` from the boot time; a failing query gives the spec's 503.
- **An exception** in a route gives 500 `internal server error` and the connection serves on (the DIY code already
  does it).
- **The test harness:** starts the server in a lab container on a fresh copy (`--ext sockets --ext event` by default),
  waits for `/health`, runs `reference/twelve-dollar-server-challenge/test/test.sh` unchanged against it with
  `JWT_SECRET` set, prints its output, exits with its code, removes the containers (trap). `test.sh` needs `bash`,
  `curl`, `jq` and `openssl`: the developer runs it where the server's port is reachable (the Mac through Docker
  Desktop, or a container on the host network) and says which in the README.
- **Cases:** the challenge's 42 checks; a fixture server (one golden answer changed) makes the harness exit non-zero;
  the DIY parser test gains `Authorization` and a POST body split across reads; the bake-off checks stay green.

## Scope 2: the realistic mode

- **Seams:** `lab/macro/k6/realistic.js`, `lab/realistic.sh --image <v> --server <file> [--ext <e>]... [--env K=V]...
  [--label <text>] [--think-scale <s>] [--warmup <rate>,<s>] (--staircase <from>,<step>,<to>,<s> | --hold <rate>,<s>)
  [--out <path>]`, and a check in `lab/check.sh`. Rates are in req/s; the harness turns a rate into VUs with the
  journey's mean loop.
- **The k6 script:** `bench/load.js` copied (its path and the challenge's commit in a header, MIT credit in `NOTICE.md`),
  with only two changes: every `sleep(x)` becomes `sleep(x * THINK_SCALE)`, and `options` comes from env (the stages
  of the warm-up, the staircase or the hold, built by the harness). The user loop, the 15 % like, the 2 % post, the
  tokens and the tags stay as they are. The tokens are the seed's `tokens.json`.
- **The journey's numbers:** 2.17 requests per loop, a mean loop of 20.5 s of think time, so one VU offers
  `2.17 / (20.5 × s)` req/s (5.3 at `s = 0.02`).
- **Calibration first** (Arjay's step): 50 VUs for 60 s at the chosen scale, then the largest VU count of the plan
  idle-free, to read k6's memory per VU and its CPU. The default scale is the one that puts 9,500 req/s at 2,500 VUs
  or less (D36); the harness refuses more than 3,000 VUs. Results in the README.
- **The run:** a fresh seed copy, the server, an optional warm-up (not scored), then the staircase or the hold in one
  k6 run (`ramping-vus`), each step a short ramp then a plateau. Per step, on the plateau only: VUs, offered req/s
  (VUs times the per-VU rate), achieved req/s (requests over the plateau), users mapped (10.8 times achieved), µs CPU per
  request from the server's cgroup, p95 and p99 per endpoint (k6's `name` tag) and overall, the error rate, pass or
  fail with its reason (D31). The staircase stops at the first failing step. A hold is one 5-minute plateau.
- **Output:** the table, and a JSON with every step, the think scale, the per-VU rate, k6's peak memory and CPU, the
  server's peak `Pss_Anon` and `memory.current`, `other_containers`, the exact command, and k6's raw summary.
- **Cases:** a passing smoke staircase; a step above capacity fails on the 97 % rule; more than 3,000 VUs is refused
  (exit 2); the containers are removed after any failure; the k6 script's diff against `bench/load.js` contains only
  the scaling and the options (a check greps it).

## Scope 3: the bench's connections and time

- **Seams:** `--idle <n>` and `--cold` in `lab/realistic.sh`, the telemetry of the skeleton (`APP_TELEMETRY=1`, D34),
  a per-second aggregator shared by `realistic.sh` and `macro.sh --per-second`.
- **Idle connections:** phase 3's client (`lab/conns/client.php`) in a hold mode: it opens `<n>` keep-alive
  connections one at a time (one `GET /health` each, answer read), rotating source addresses as in phase 3, before the
  warm-up, and holds them to the end; at the end it sweeps them, and a connection the server closed fails the run.
  The count held at the start and at the end goes in the table and the JSON. With 60,000 held, k6's VUs come on top
  (D36).
- **Per-second series**, one row per second of the run: per endpoint the request count, p50, p99 and max latency (from
  k6's raw samples, kept compressed or aggregated, the developer's call); the server's CPU (`usage_usec` delta),
  `Pss_Anon`, `memory.current`, the WAL's bytes, the server's minor and major page faults (`/proc/<pid>/stat`); and
  the server's telemetry line for that second.
- **Telemetry (D34):** per second, requests per endpoint, the longest single callback of the event loop in ms,
  `gc_status()` runs and collected, the WAL's size, the process's minor and major faults. On stdout, one line, read by
  the harness from the container's log.
- **SQLite's page cache:** `pdo_sqlite` exposes no `sqlite3_db_status`; the page faults stand for it (the database is
  mapped). If the developer finds a way to read SQLite's own hit and miss counters from the server's connection, add
  them.
- **Cold (D28):** `--cold` evicts the copy's pages from the page cache after the copy and before the server opens it
  (`posix_fadvise(DONTNEED)` on the copy only, for example `dd iflag=nocache`); never a VM-wide `drop_caches`. Without
  it, the copy's pages are warm. `fincore` on the copy, before the first request, proves which.
- **`macro.sh --per-second`:** the same latency series for a fixed-rate run, so Q10's rerun of the bake-off's
  `posts.js` is read the same way.
- **Cases:** idle held equals asked at start and end; a fixture that closes an idle connection fails the run with the
  reason; the per-second rows cover the whole run with no gap; cold and warm `fincore` readings differ as expected.

## Scope 4: the profile

- **Excimer (D33):** the PECL tarball, latest stable on 2026-11-22, sha256 pinned, built with `phpize` in the images'
  last layer like ext-event, on every source image; `php-info` prints its version. Loaded only with `--ext excimer`.
- **In the server:** with `APP_PROFILE=<path>` (and `APP_PROFILE_PERIOD`, default 1 ms of CPU time), an
  `ExcimerProfiler` on `EXCIMER_CPU` runs from the first request; the collapsed stacks are written to `<path>` when the
  server stops (or on a timer, the developer's call), into `lab/results/` or the run's output folder.
- **The fold:** `lab/profile/fold.php <collapsed> [--rules <file>]` maps each sample to a step with a committed rules
  file (a frame name, or a prefix, to a step: `fread`, the parser's methods: S2; the route match: S3; the JWT
  functions: S4; validation: S5; `PDOStatement::*` and `PDO::*`: S6; `json_encode`: S7; the response building and
  `fwrite`: S8; a commit: S9; `EventBase::dispatch` alone and the loop's own code: the event loop; accept: S1). The
  innermost matching frame wins. Per endpoint: by the route function on the stack; a sample with no route (read,
  parse, write) counts in "shared". Output: a table of shares per step and per endpoint, plus µs per request per step
  when the run's µs/req is given.
- **The kernel:** the cgroup's `user_usec` and `system_usec` over the profiled window, printed with the table. Kernel
  time spent in a syscall also shows inside the PHP frame that made it (`fread`, `fwrite`, `stream_socket_accept`), the
  README says so.
- **Cases:** the fold on a small committed fixture of collapsed stacks gives known shares; an unknown frame lands in
  unclassified; a 20 s profiled run gives a table with every endpoint present.

## Scope 5: the baseline

- **Before any run:** copy the Predictions section below into the results README, unchanged, and commit nothing else
  first. `docker ps` must show only the lab's containers (D15): otherwise the project manager stops and asks.
- **Image and server:** `8.5`, the skeleton on the DIY loop, `--ext sockets --ext event` (`--ext excimer` added for the
  profiled runs only), `APP_TELEMETRY=1`.
- **Calibration:** k6's memory per VU and CPU (scope 2's method), the think scale, recorded.
- **Staircase:** a fresh run, 60,000 idle connections, warm-up at about 10 % of the expected capacity for 60 s, then
  steps of 1,000 req/s from 3,000 req/s, 60 s plateaus, stopping at the first failing step; then a second staircase of
  250 req/s steps from the last passing step to the failing one.
- **Holds:** 3 holds of 5 minutes at the highest passing rate of the fine staircase, each a fresh run (new seed copy,
  new server, new idle connections); the median of the 3 is the baseline; 1 hold one fine step above. If a hold fails,
  the 3 holds move one fine step down (like the bench's 250-user step down).
- **Profile:** one 60 s run at the baseline's rate with Excimer on, and the same run without it (Excimer's cost).
- **Telemetry's cost:** one fixed-rate pair (`/feed` and `/posts/:id` on a hot id, or the realistic hold's rate) with
  `APP_TELEMETRY=1` and without.
- **Q10 (D28):** the bake-off's `posts.js` on the skeleton at 7,000 req/s with rate / 10 VUs (the setting that dropped
  iterations), `--per-second`, 3 runs warm and 3 cold, interleaved; plus the first 60 s of a cold realistic hold
  against a warm one. A stall is a second whose max latency is over 100 ms; for each, the server's longest callback
  that second tells "inside the server" from "the server wasn't running".
- **The table and `summarize.sh`** build every table from the JSON, like phase 3's. The README links the raw files.
- **Then:** "Did the predictions hold?", one line each, and **the step lab's order**: the steps ranked by their µs per
  request in the profile, which phase 5 follows.

## Predictions (D5)

Written by the project manager on 2026-11-22 at 11:05, before any phase 4 measurement. Arm64, Docker Desktop on an M3
Pro, quiet VM, PHP 8.5, the DIY server, 1 CPU.

**What we start from:** the bake-off's DIY at 7,000 req/s: `/noop` 21.88 µs/req, `/posts/:id` (a different post each
request, all 500,000) 29.14; at 9,500, 17.37 and 27.66. DIY held 65,000 idle connections at 1.48 KiB of `Pss` each
(5.19 KiB of `memory.current`). Not measured yet: `/feed` (20 rows, 20 like counts, about 5 KB of JSON), the writes,
the JWT check. The Swoole entries cost 94 to 101 µs/req on the bench's x86 VM, a slower CPU than the M3.

**How they're judged:** a µs/req is the median of the 3 holds; a range holds if the measured value is inside it; a
share is a profile's share of the server's samples.

1. **The skeleton passes the challenge's 42 tests** with the reference SQL, `json_encode` and a hand-written HS256
   check, on the first full run of scope 1's harness after the code is written (no change needed in the test harness).
2. **µs CPU per request under the realistic mix: 50 to 90.** `/feed` costs 3 to 4 times a post (20 rows and 20 counts
   instead of 1), and is 46 % of the requests: it carries more than half of the CPU.
3. **The held rate (median of 3 holds) is 10,000 to 18,000 req/s, so 108,000 to 194,000 mapped users** on the Mac. This
   is arm64 (D35): the x86 VM's CPU is slower, so it is not a prediction of the score.
4. **The 97 % rule fails before the thresholds:** at the first failing step of the staircase, p95 is still under
   500 ms, and the step fails on its achieved rate. Without D31 the staircase would have passed one or more steps
   further.
5. **p99 at the held rate: under 50 ms on every endpoint**, and the writes (like, post) have the highest p99.
6. **Memory with 60,000 idle connections:** `memory.current` 500 to 800 MiB at the held rate (the bake-off's 254 MiB
   baseline plus 60,000 times 5.19 KiB, plus the WAL and SQLite's cache); `Pss_Anon` under 150 MiB.
7. **The WAL stays under 8 MiB for the whole 5-minute hold**, a sawtooth: `wal_autocheckpoint` at its default (1,000
   pages, about 4 MiB) checkpoints it, and one connection never starves a checkpoint.
8. **The profile's ranking:** S6 (SQLite) is the largest step with 35 to 55 % of the samples; then S8 (write, with the
   kernel's send inside `fwrite`) 10 to 20 %; then S7 (JSON) 10 to 20 %; S2 (read and parse) 5 to 10 %; S4 (JWT) under
   2 % (7.8 % of requests); S3, S5 and S9 under 2 % each. The cgroup's `system_usec` is 25 to 40 % of the CPU.
9. **Q10: the stalls are not the server's.** Under `posts.js` at rate / 10 VUs, stalls over 100 ms may come back, but
   in every stalled second the server's longest callback stays under 20 ms (the server wasn't running, so the host
   stalled it). Under the realistic hot set, warm, no second has a max latency over 100 ms in any of the 3 holds. Cold,
   the first seconds have more major faults and a higher p99, back to the warm level within 30 s.
10. **GC:** under 5 `gc_status()` runs per 5-minute hold, and none in a stalled second.
11. **Costs of the instruments:** telemetry under 2 % of µs/req; Excimer at 1 ms under 5 %.
12. **k6 at 2,500 VUs:** under 2 MiB per VU (the load test is small and its tokens are shared), so the VM's 7.75 GiB
    holds k6, the server and the idle client together.

## Out of scope

- **The step lab (S1 to S9 variants):** phase 5 (D27). The skeleton keeps the simplest variant of every step; nothing
  here tunes it, even where the profile points.
- **Swoole and Workerman under the realistic mode:** the bake-off ranked them; the baseline is DIY's (D35). The harness
  takes any server, so phase 5 can run them.
- **Past the fd wall (S1-d, `Connection: close` near the limit; S1-b, several processes):** phase 5. The realistic mode
  stays at 63,000 sockets, under the 65,535 fds.
- **The full-size run (100,000 users, several generators, x86):** phase 7. Moving to EC2 is a question for Jacob.
- **The submission folder (`install.sh`, `build.sh`, `start.sh`):** phase 6. The skeleton follows the contract so it
  can become one.
- **Group commit and the background checkpointer (D30):** phase 5's S9 variants.
- **PHP 8.6:** micro benches only (D26), in phase 5.
