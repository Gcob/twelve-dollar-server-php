# Brief: scope 2/6, the realistic mode

**Read first:** [common.md](common.md), then `plan/state/developer.md` (scope 1's handover).
**Worktree:** `.claude/worktrees/twelve-dollar-server-php/phase-4-claude` under the home folder (your prompt gives the
full path) · **Your handover:** `plan/state/developer.md` in the main checkout.
**Planned commit:** `feat(lab): realistic mode, the bench's journey with scaled think time`

**Summary:** load the skeleton the way the challenge's bench does (its own k6 journey: feed, a post from it, 15 % like,
2 % new post, think time between), with the think times scaled down so a few thousand VUs make the bench's request
rate, in a staircase or a hold, and judge each step the way the bench would.

**Today:** the skeleton (`lab/app/server.php` and `lab/app/app.php`, scope 1, `f840725`) passes the challenge's 42
tests. `lab_start_app` in `lab/lib.sh` starts it on a fresh seed copy (`cp` inside the container, `sync`, then the app
with `SQLITE_PATH`); `lab_run_server_container` holds the shared `docker run`. The DIY loop is in
`lab/servers/diy-server.php`, shared by the app and `bake-diy.php`. `lab/challenge-test.sh` runs the tests from a
locally built `php-lab-tools:1` image on the host network (the Mac can't reach a host-network container). `lab/macro.sh` loads a server at a **fixed rate**
(`constant-arrival-rate`) on one route, with k6 in its own container (CPUs `4-11`, pinned image `LAB_K6_IMAGE`), reads
the server's cgroup (`cpu.stat`, memory) from a probe container, and writes a JSON with `other_containers`. Nothing in
the lab runs the bench's journey yet.

**Expected:**

- **The k6 script** `lab/macro/k6/realistic.js`: a copy of `reference/twelve-dollar-server-challenge/bench/load.js`, with
  a header naming its source path and the challenge's commit (`git -C reference/twelve-dollar-server-challenge
  rev-parse HEAD`), and the MIT credit in `lab/NOTICE.md`. **Only two changes:** every `sleep(x)` becomes
  `sleep(x * THINK_SCALE)` (env), and `options` comes from env built by the harness (the stages, and anything the
  harness needs, like thresholds on submetrics). The loop, the 15 % like, the 2 % post, the tokens (the seed's
  `lab/data/tokens.json`) and the `name` tags stay as they are. A check in `lab/check.sh` diffs it against `load.js`
  and fails on any other change.
- **The journey's numbers:** 2.17 requests per loop (1 + 1 + 0.15 + 0.02), 20.5 s of mean think time per loop (5 + 5.5
  + 10), so one VU offers `2.17 / (20.5 × s)` req/s. A steady load is **9.45 users per req/s** (20.5 / 2.17): users are
  always mapped from the achieved rate with 9.45, never from the VUs and never with 10.8 (the leaderboard's 10.8
  includes its ramps).
- **`lab/realistic.sh`**, with `--image <v>` (default 8.5), `--server <file>` (default the skeleton), `--ext <e>`
  (default `sockets`, `event`), `--env K=V`, `--label <text>`, `--think-scale <s>`, `--warmup <rate>,<s>`, one of
  `--staircase <from>,<step>,<to>,<s>` or `--hold <rate>,<s>` (rates in req/s, turned into VUs with the per-VU rate),
  `--vu-cap <n>`, `--out <path>`, and `--calibrate`. It starts the server on a fresh seed copy, runs an optional
  warm-up (not scored), then the staircase or the hold in **one k6 run, one `ramping-vus` scenario**: each step a short
  ramp, then a plateau. Removes every container it started, in every case (trap).
- **Ports:** k6 binds its own source addresses with `--local-ips` (for example `127.0.1.1-127.0.1.4`), recorded in the
  JSON. The next scope holds 60,000 idle connections from a client that `bind()`s its ports, and a bound port is
  skipped by any unbound `connect()`, so k6 from `127.0.0.1` would run out of ports. If k6 1.8.3 refuses loopback
  local IPs, stop and tell me (the fallback is in the idle client, next scope).
- **Per step, on the plateau only:** VUs; offered req/s (VUs × per-VU rate); achieved req/s (requests over the
  plateau); users mapped (9.45 × achieved); µs CPU per request from the server's cgroup (`usage_usec` read at the
  plateau's edges); p95 and p99 per endpoint (the `name` tag) and overall; the error rate; pass or fail with its reason.
  **A step passes** when p95 < 500 ms, p99 < 1 s, errors < 1 % **and** achieved ≥ 97 % of offered. Why the 97 % rule:
  with think time scaled by `s`, latency weighs `1/s` times more in a VU's loop, so the thresholds alone pass loads far
  past saturation (at `s = 0.02`, 3.6 times the knee's VUs). The staircase stops at the first failing step: the
  harness judges each step as it ends and stops k6 there. A hold is one plateau (5 minutes in the measuring scope).
- **Live aggregation, nothing raw on disk:** k6's CSV output goes into a FIFO, read by an aggregator that keeps per
  second and per endpoint a latency histogram (log buckets, under 1 % error), the counts and the errors; a step's p95
  and p99 merge its seconds' histograms. The aggregator runs **in its own container on k6's CPUs** (its memory is not
  in k6's budget). k6's exit 99 (its thresholds failed) is a result, not a harness error.
- **The guard:** k6 doesn't slow down when the reader falls behind, it buffers samples in memory. So the aggregator
  reports its **lag** (the newest sample's time against the clock), the harness reads k6's memory, and a run whose lag
  passes its gate or whose k6 passes its memory budget is invalid with that reason. k6's CSV flushes every second by
  default: lower `K6_CSV_SAVE_INTERVAL`; the gate is the lag measured in calibration plus 2 s. A **replay case** feeds a
  recorded CSV through the aggregator at the rows of 40,000 req/s (about 12 rows per request) and must keep up; if it
  can't, the reader skips every line but `http_req_duration` and `http_reqs` before parsing.
- **Calibration (`--calibrate`):** 50 VUs for 60 s, then a few hundred, **with the stream running**: k6's MiB per VU,
  its CPU, the aggregator's lag, and achieved against offered at low load (k6's own loop overhead eats into the 97 %
  margin). It prints the **VU cap**: (the VM's memory − 2 GiB for the server − the idle client's memory (take 1 GiB
  until the next scope measures it) − 1 GiB of margin) / MiB per VU, and never above the server's free fds (65,535 −
  60,000 idle − the server's own, about 5,400); and the **scale** `s` that puts 20,000 req/s under the cap, with the
  margin the 97 % rule leaves (about `0.29 × s` seconds of mean latency per request). The k6 container gets a
  `--memory` limit at the cap's budget. The harness refuses more VUs than the cap (exit 2). Results in the README.
- **Output:** the table (one row per step) and a JSON: every step, the think scale, the per-VU rate, the VU cap, k6's
  local IPs, k6's peak memory and CPU, the aggregator's max lag, the server's peak `Pss_Anon` and `memory.current`,
  `other_containers`, the exact command, and k6's own summary.
- **`lab/check.sh`:** a short staircase on the skeleton that passes; a step above capacity that fails on the 97 % rule
  and stops the run, against a **fixture server** under `lab/check/fixtures/` that spends a few ms per request (capacity
  a few hundred req/s, so the case stays at low load); the refused VU count; the script diff; the replay case; the
  aggregator's percentiles against k6's own summary on a short run (within the bucket error).
- **`lab/README.md`:** a section on the realistic mode (what it copies, the pass rule, the numbers, the calibration).

**Key interfaces:** `lab/realistic.sh` and its options, `lab/macro/k6/realistic.js` (env `THINK_SCALE` and the
options env), the aggregator (you pick its language: PHP in a php-lab container is fine), the JSON's keys.

**Done when:** `lab/realistic.sh` on the skeleton, a 3-step staircase of 20 s steps at low load, prints one row per
step (VUs, offered and achieved req/s, mapped users, µs CPU/req, p95 and p99 per endpoint and overall, errors, pass or
the reason it failed) and exits 0, its per-step numbers merged from the live per-second histograms; its calibration
prints k6's MiB per VU, the VU cap and `s`; a step far above capacity fails with the reason `achieved below 97 % of
offered` and the staircase stops there; the JSON holds the think scale, k6's peak memory and local IPs,
`other_containers`, and the k6 script's diff against `bench/load.js` is only the scaling and the options;
`bash lab/check.sh` is all `ok`.

**Seams and cases to test:** the cases in the `lab/check.sh` bullet above; plus containers removed after a failure
(kill the server mid-run once by hand and report it).

**Tests to imitate:** `check_macro_marks_invalid_run` and `check_macro_cleans_up_after_failure` in `lab/check.sh`
(invalid run, cleanup); `lab/macro/fixtures/broken.js` (a fixture script).

**Decisions that touch you:** the 97 % rule and users from the achieved rate; 9.45 users per req/s; k6 binds its own
source addresses; the cap and the scale from calibration with a memory limit on k6; one scenario, live histograms,
nothing raw on disk, k6 stopped at the first failing step; the lag and memory gate with a replay case; every run on a
fresh seed copy (scope 1's function); the skeleton only reads its config from env.

**Out of scope:** the idle connections, per-second tables, telemetry, `--cold`, `macro.sh` changes (next scope; but
keep the per-second histograms easy to print, the next scope does it); the profiler; any measurement that counts (smoke
runs only: they are not the baseline); any change to the app beyond what a bug fix needs.

**Where to look:** `lab/macro.sh` (k6 container, probe container, cgroup reads, JSON, validity, exit codes),
`lab/lib.sh` (CPU layout, `LAB_K6_IMAGE`, the seed-copy function from scope 1), `reference/.../bench/load.js`,
`plan/runs/phase-3/state/developer.md` ("VUs and connections" lessons, k6's `dropped_iterations`), scope 1's handover in
`plan/state/developer.md`.

**Come back to me if:** k6 refuses `--local-ips` on loopback, the aggregator can't keep up even with the fast reader,
calibration says the VM can't hold enough VUs for 20,000 req/s at any sensible scale, a decision is missing, or the
Done-when doesn't pass after 3 tries.
