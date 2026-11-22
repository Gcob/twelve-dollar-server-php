# Developer: phase 4, the realistic baseline

**State:** scope 4 done (commit 4775db8, on top of scope 3's `b47adcf`): Excimer 1.2.6 in the 8.3, 8.4 and 8.5 images (8.6 does not build it), `APP_PROFILE` in the app, `--profile` in `lab/realistic.sh` and `lab/macro.sh`, `lab/profile/fold.php` with `steps.rules`, the calibration, 4 new checks (full `bash lab/check.sh` 57/57 ok: 56 in the full run, and `check_realistic_staircase_passes`, which failed in it because I ran a lab container at the same time, ok alone, shellcheck clean). Scopes 1 to 3 stay as they were.

## Verified

- The challenge's suite on the app, 8.5, fresh copy each run: `passed=42 failed=0`, exit 0, run 1 and run 2 (the first time the app ran, no fix needed). **Proof:** `bash lab/challenge-test.sh --image 8.5` x2.
- A fixture that changes one post (`lab/check/fixtures/wrong-golden-app.php`) exits non-zero with `FAIL GET /posts/250000 == golden` and `passed=41 failed=1`; no `lab-challenge-*` container is left. **Proof:** same command with `--server lab/check/fixtures/wrong-golden-app.php`.
- DIY parser test, red then green: the 5 new `Authorization` / body cases failed with `auth=` empty (the connection did not hand the header over) and the status case failed on `201` ("2\r\n\r\n{}": no status line), then all 40 cases ok after `diy-connection.php` changed. **Proof:** `bash lab/run.sh 8.5 php /lab/check/diy-parser-test.php`.
- App own cases (`lab/check/app-test.php`, 57 cases) were written AFTER the code, not before (the challenge's suite was the red-to-green driver). I checked they bite by mutating `app.php` and restoring it: junk after the signature accepted when `base64_decode` is not strict, `exp` rule weakened, `alg` check removed, `mb_strlen` replaced by `strlen`: each made exactly the expected cases fail.
- macOS cannot reach a host-network container's port (curl from the Mac to a `--network host` php server: `000`), so `test.sh` runs in a container. **Proof:** `docker run --network host php-lab:8.5 php -S ...` then `curl http://127.0.0.1:18555/` from the Mac.
- No local image has bash, curl, jq and openssl together (checked ubuntu, node-alpine, postgres, nginx, minio, php-alpine, hurl, k6); `php-lab:8.5` has all but jq.

## Assumed

- `sync <file>` inside the container really flushes the copy (it exits 0; I did not read the dirty pages before and after).
- The seed copy plus `sync` starts in about 1.5 s here (the whole `challenge-test.sh` took 1.6 s): the copy is fast on this disk. The bench VM may be slower; the harness waits up to 60 s.

## Dead ends

- Pulling a published image with the four tools (`nicolaka/netshoot`) was refused by the permission layer (third-party image); I built `php-lab-tools:1` from the lab's pinned Ubuntu instead (`lab/images/Dockerfile.tools`, apt install of bash curl jq openssl ca-certificates).

## Decisions on the way

- **The 4th argument, not a new contract:** `DiyConnection` calls `handler_handle($method, $target, $body, $authorization)`. The bake-off's `handler_handle(string, string, string)` takes three and PHP ignores the extra argument of a user function, so `bake-diy.php` and `handler.php` are untouched and the bake-off checks stay as they were. The stub of the parser tests takes `string $authorization = ''`.
- **`diy-server.php` extracted from `bake-diy.php`:** the loop (`DiyPeer`, `DiyServer`) plus `diy_listen()` and `diy_socket_line()`, shared by `bake-diy.php` and `lab/app/server.php`. Pure move: the boot lines of `bake-diy.php` are the same (`listening on`, `loop:`, `socket:`), the conformance check on it passes. The "ext-event and ext-sockets must be loaded" message now starts with `diy-server:` instead of `bake-diy:`.
- **Authorization value:** trimmed of spaces and tabs, `''` when absent (reset on every request, so a request never sees the previous one's). No header, `Basic ...`, `bearer ...` (lowercase) and a bare `Bearer` are all `missing bearer token`.
- **Router and `?query`:** a `?query` is cut off the path, like the bake-off handler; `/posts/1/` and `/posts/1/like` on GET are 404; wrong methods on known paths are 404 (out of the spec's scope). `GET /posts/` (empty id) is a 400, like the bake-off handler.
- **JWT:** `base64_decode(..., strict: true)`, so a signature with junk after it is rejected (a non-strict decode ignores the junk and the HMAC would still match). The header is read before the signature is checked, the payload after (any failure is the same message). `exp` must be an int or float, strictly in the future.
- **Statements:** a `$app_db` global array of prepared statements (feed, post, post_insert, post_exists, like_insert, health), prepared in `app_boot`. `post_insert` closes its cursor in a `finally` (a statement left open keeps its write transaction open). `like_insert` reads `rowCount()` of the `ON CONFLICT DO NOTHING`: 1 inserted, 0 already liked (verified by the suite's 201 then 200).
- **Response building:** the app returns `[status, json]` through `response_json` / `response_error`; the status line and headers are `DiyConnection`'s (step 8). An exception from a route reaches the connection's `try/catch`: 500 `{"error":"internal server error"}`, the connection serves on (the parser test covers it with a throwing stub).
- **`lab_start_app`:** `lab_start_server`'s `docker run` became `lab_run_server_container <name> <variant> <port> <command...>`; `lab_start_server` calls it (same flags, same behaviour); `lab_start_app` calls it with `sh -c 'cp "$1" "$2" && sync "$2" && shift 2 && exec php "$@"'`. `LAB_ENV` is passed after `JWT_SECRET` and `SQLITE_PATH`. Constants in `lib.sh`: `LAB_JWT_SECRET`, `LAB_APP_DB` (`/tmp/feed.db`), `LAB_TOOLS_IMAGE` (`php-lab-tools:1`). Scope 3 adds its eviction option to `lab_start_app`.
- **Tools image:** `lab_ensure_tools_image` builds `php-lab-tools:1` on first use. `challenge-test.sh` mounts the real path of `reference/twelve-dollar-server-challenge` (a worktree's `reference` is a symlink, which Docker cannot mount: `cd -P`).
- **Port:** `challenge-test.sh` defaults to 18110 (macro 18080, conformance 18090, conns 18100). Containers `lab-challenge-server` and `lab-challenge-test`.
- **Fixture:** it changes post 250000's body in the database copy and then `require`s the real `lab/app/server.php`, so the harness is tested against the real boot path; post 250000 is not in the feed's 20, so exactly one golden fails.
- **`lab/check.sh`:** `check_diy_parser` now expects 40 cases (was 34); new checks `check_app_cases` (57), `check_challenge_test_passes_on_app` (two runs), `check_challenge_test_fails_on_wrong_golden`.

## Raw learnings

- The challenge's suite passed on the first run of the app: the spec is precise enough that the simplest variant of every step meets it. The cases that mattered (token without `exp`, junk after the signature) are not in `test.sh`: they needed their own test.
- `jq` is missing from every php-lab image and every other local image that has bash and curl: any harness that runs `test.sh` needs the tools image.
- BSD `sed -i` on macOS failed on `s/Content-Length: 15/.../` with an "extra characters" error: python3 for edits (same as phase 3 learned). `$PIPESTATUS` is not usable in zsh.
- Docker Desktop does not publish host-network ports to the Mac (curl got `000`), the brief's fact holds.

## Where to look

- `lab/app/app.php` (routes, JWT, validation, queries, JSON, responses), `lab/app/server.php` (entry). `@64af809`
- `lab/servers/diy-server.php` (the loop, `diy_listen`, `diy_socket_line`), `lab/servers/diy-connection.php` (`Authorization`, statuses 201/401/503). `@64af809`
- `lab/lib.sh` -> `lab_run_server_container`, `lab_start_app`, `lab_ensure_tools_image`. `@64af809`
- `lab/challenge-test.sh`, `lab/images/Dockerfile.tools`, `lab/check/fixtures/wrong-golden-app.php`, `lab/check/app-test.php`. `@64af809`

## Next steps

1. Scope 5 (the measurement) can profile any run with `--profile <file>` (realistic.sh, or macro.sh with `--fresh-db`): the profiled run is for the SHAPE of the cost per step, never for a baseline (Excimer costs CPU: a smoke at 1,000 req/s measured 117.5 us/req unprofiled and 118.4 profiled, inside the noise, but nothing more precise). The unprofiled run comes from the same command without `--profile` and with `--env APP_TELEMETRY=0` if the telemetry's cost must not be in it.
2. Scopes 3's list still stands: re-run `--calibrate` on a quiet VM, set `--lag-gate`, `--vu-cap` and the scale, and read the aggregator's lag at the top steps (3.3 to 3.9 s of 4 s at 18,000 req/s).
3. The telemetry's cost (on against off) is still not measured: `--env APP_TELEMETRY=0` turns it off in `realistic.sh` and in `macro.sh --fresh-db`.
4. What the table cannot say (see "Raw learnings (scope 4)"): S9 is inside S6, `parse` holds the response head's concatenation, and a sample cannot tell `read` from `epoll_wait`.

## Handover of scope 2 (the realistic mode, commit 47e4728)

### Verified (scope 2)

- **Aggregator library, red then green:** `lab/check/aggregate-test.php` (45 cases) first failed on the missing `lab/macro/aggregate-lib.php` (`Failed opening required`), then passed all 45 once the library existed. It bites: `agg_window` returning `[$first, $last]` makes the window case fail, `AGG_GAMMA = 1.05` makes 6 cases fail (restored). **Proof:** `bash lab/run.sh 8.5 php /lab/check/aggregate-test.php`.
- **The harness was written after its first runs, not before** (an integration harness: the checks in `lab/check.sh` came with the code, and each was run alone): `check_realistic_staircase_passes` failed once on my own jq (`Cannot index number with string "key"`, a precedence slip), `check_realistic_calibrates` failed once on a negative per-VU memory with `--calibrate-vus 20,60` (noise bigger than the signal; fixed by making a per-VU cost under the noise bound nothing, and the check uses the default 50,300).
- **Aggregator against k6's own summary** (`check_realistic_staircase_passes`, also by hand on a 3-step run): same request count (3,870 = 3,870), p95 of GET /feed 1.023 vs 1.029 ms, GET /posts/:id 0.843 vs 0.84.
- **Done-when run** (skeleton, 8.5, `--think-scale 0.1 --warmup 50,5 --staircase 100,100,300,20`, exit 0, 23 other containers running):

  ```text
  step    VUs   offered  achieved   users    us/req   p95 ms   p99 ms  errors  result
     1     95     100.6      99.9     944     251.6    1.102    2.218      0%  pass
     2    189     200.1     197.6    1867     192.4    0.963    1.529      0%  pass
     3    284     300.6     302.2    2856     162.5    0.868    1.357      0%  pass
  ```

- **A step above capacity fails and the staircase stops** (fixture `lab/check/fixtures/slow-app.php`, 4 ms a request, `--staircase 100,100,400,8`): step 1 (95 VUs, 100.6 offered, 99 achieved) passes; step 2 (189 VUs, 200.1 offered, 180.2 achieved, p95 152 ms) prints `FAIL: achieved below 97 % of offered`, `STOPPED at step 2`, k6 stopped, exit 0. In `lab/check.sh` the staircase is `60,240,300,8`.
- **Calibration** (60 s plateaus, `--think-scale 0.03`): 50 VUs 72.14 MiB, 300 VUs 143.92 MiB, **0.287 MiB per VU**, 57.8 MiB at rest; a second point at `--think-scale 0.1`, 300 and 2,000 VUs (30 s): 138.87 and 678.07 MiB, **0.317 MiB per VU**. Memory cap 12,100 to 13,400 VUs, fd cap 5,400, so **VU cap 5,400** (bound by fds). **Scale `s` = 0.02858** (5,400 VUs offer 20,000 req/s), margin **8.35 ms** of mean latency per request. achieved/offered 0.995 to 0.998 at low load. Aggregator lag 1.2 to 1.9 s, so the gate is 3.3 to 3.9 s (default 4). JSON in `lab/results/2026-11-22-realistic-calibration/`.
- **k6's ports:** `--local-ips 127.0.1.1-127.0.1.4` is accepted by k6 1.8.3 on loopback and used: the server saw connections from the four addresses (`k6.client_ips_seen` = 36/36/35/35, `probe.sh client-ips`).
- **Replay case:** the recorded CSV (`lab/check/fixtures/k6-rows.csv`, 952 real k6 rows, 90 requests, 10.6 rows per request) replayed at 480,000 rows/s for 10 s: every request counted (453,600 = 453,600), none unparsed, lag 1.0 s, feeder at most 2 ms late; at 1,500,000 rows/s: lag 1.0 s, feeder 0.1 s late. The reader that keeps only `http_req_duration` and `vus` rows (one `preg_match_all` per read) is fast enough: the fallback was never needed.
- **Invalid runs:** `--lag-gate 0.1` gives `INVALID: the aggregator fell behind k6: lag 1.03 s, above the gate of 0.1 s`, exit 3; `--k6-memory 50` gives `INVALID: k6 reached its memory budget (50 MiB of 50 MiB)`, exit 3.
- **Cleanup after a failure, by hand once and now in a check:** `docker kill lab-realistic-server` 6 s into a 60 s hold: exit 1 `the server container died during the run`, no `lab-realistic-*` container and no `lab-realistic-run` volume left.
- **Script diff:** `check_realistic_script_is_the_benchs` passes on the copy, and fails on a copy with `LIKE_PROB = 0.25` and on one with an unscaled sleep (it builds both in a temp dir).

### Assumed (scope 2)

- **The server's CPU per request over a plateau** is read by the aggregator at whole seconds and scaled to the nominal window; I never compared it with `lab/macro.sh`'s number for the same server (the journey is not the fixed-rate one anyway).
- **The first row of k6's `vus` gauge:** the plateau is found from the gauge, which k6 writes once a second; I assumed its value at a tick is the VU count at that instant (true in every run seen: 48, 95, 142 ...).
- **k6 CPU at 20,000 req/s:** extrapolated from 297 us per request at 2,000 req/s (falling with the rate); not run (VU counts above a few hundred were out of scope). At 250 to 300 us it is 5 to 6 of the 8 CPUs k6 and the aggregator share.
- **The idle client's 1 GiB** in the cap's budget is the brief's estimate.

### Dead ends (scope 2)

- **`$PIPESTATUS`-style exit codes through `| tail`:** my smoke runs piped the harness into `tail`, which hid its exit code (`rc=` empty). Redirect to a file, then read `$?`.
- **`awk` `strtonum` in the probe** (`client-ips`): the php-lab images have mawk. The hex address is converted in bash (`$((16#..))`).
- **Waiting with `sleep` in my own shell:** the shell blocks a standalone `sleep` of 100 s; an `until`/`for` loop with `sleep 3` and a `timeout` of 118 s is accepted.

### Decisions on the way (scope 2)

- **`s` is the plateau, in both modes:** `--staircase from,step,to,s` and `--hold rate,s` give the plateau's seconds; the ramp (default a quarter of the plateau, 2 to 10 s, `--ramp`) comes before it, and the window loses its first and last second.
- **The aggregator reads only `http_req_duration` and `vus` rows,** not `http_reqs` as the brief said: a duration row carries the same tags (name, `expected_response`) and one request is one duration row (k6's `http_reqs` count is the same, checked). Unparseable duration rows are counted and invalidate the run.
- **The plateau comes from k6's `vus` gauge,** not from a predicted schedule: k6's CSV timestamps are whole seconds and k6's start time is not known to the second. `agg_window` gives `[first + 1, last)` of the seconds where the gauge reads the step's VUs. A step is judged once a sample of the next second has arrived and both cpu.stat readings exist.
- **CPU per request is read by the aggregator** (`--cgroupns host`, whole-second readings of the server's and k6's `cpu.stat`), not by the harness through `docker exec` (the exec latency of a few hundred ms is 2 % of a 15 s plateau).
- **The FIFO is in a named volume** (`lab-realistic-run`) shared by k6, the aggregator and the probe, opened `r+` by the aggregator (so it never sees an end of file by itself and keeps ticking while k6 starts); the harness writes `#END` after k6 exits. The status and the result are files in the same volume, read through the probe.
- **A failing step is exit 0** (a result, like a ceiling in `conns.sh`); exit 3 is lag, k6's memory or unparsed rows; exit 2 a usage error or VUs above the cap (checked before any container starts).
- **The cap:** the fd side is `65,535 - 60,000 - 135 = 5,400` (the brief's "about 5,400" is that result, `LAB_VU_CAP_FDS`); the server's own fds at boot were measured (`server.fds_open_at_boot` in the JSON). A per-VU memory cost of zero or less (noise) bounds nothing.
- **k6's memory budget** = VM memory - 4 GiB (3,839 MiB here), set as `--memory` on the k6 container; `--k6-memory` overrides it (test hook). Invalid at 95 % of it or on an OOM kill.
- **Extras beyond the brief:** `lab/macro/replay.php` (the replay feeder), `lab/check/fixtures/slow-app.php` (the 4 ms server, a standalone DIY server that answers what the journey reads), `lab/check/fixtures/k6-rows.csv`, `bash lab/check.sh <check name>...` runs only the named checks, `probe.sh poll|fds|client-ips`, `--calibrate-vus`, `--calibrate-seconds`, `--lag-gate` (default 4), `--k6-memory`, `--ramp`, `--port` (default 18120), `--local-ips`.
- **Calibration runs two k6 runs** (one per VU count): ramping-vus initializes all its VUs at the start, so one run with two plateaus would hold the larger memory throughout.
- **The `K6_CSV_SAVE_INTERVAL` is 250 ms.** Lag at low load is 1.2 to 1.9 s anyway (whole-second timestamps).

### Raw learnings (scope 2)

- **k6 1.8.3 costs about 0.3 MiB per VU and 300 to 650 us of CPU per request with the CSV stream on** (759, 389, 297 us at 176, 1,058, 2,117 req/s): the per-VU memory is not the limit, the fds and k6's CPU are. Proof: `lab/results/2026-11-22-realistic-calibration/`.
- **k6's CSV has 12 rows per request** (11.85 on a 1,636-request run) and timestamps in whole seconds; `vus` and `vus_max` come once a second, `http_req_duration` rows carry `name` and `expected_response`.
- **A named-volume FIFO between containers works** (k6 as uid 12345 writes into a `mkfifo -m 666` made by the probe); a bind mount from the Mac was not tried.
- **PHP keeps up with k6's stream easily:** 1,500,000 rows/s (about 140,000 req/s) with `preg_match_all` over a 1 MiB read, JIT on, lag unchanged (1.0 s).
- **k6's `--summary-export` thresholds on submetrics** (`http_req_duration{name:GET /feed}`) are what puts per-endpoint percentiles in the export; `{name:GET /posts/:id}` with a space and slashes works.
- **bash 3.2 gotchas met:** `IFS=$'\t' read` collapses empty fields (tab is whitespace IFS): never print an empty field; no `mapfile`.

### Where to look (scope 2)

- `lab/realistic.sh` (`run_measured`, `options_for`, `run_json`, the calibration `jq`), `lab/macro/aggregate.php` (the process), `lab/macro/aggregate-lib.php` (`Aggregate::feed`, `agg_window`, `agg_summarize`, `agg_per_second`), `lab/macro/replay.php`. `@47e4728`
- `lab/macro/k6/realistic.js` (the bench's script, header names the commit), `lab/check.sh` (`check_realistic_*`, `check_replay_keeps_up`, `realistic_script_diff`), `lab/macro/probe.sh` (`poll`, `fds`, `client-ips`). `@47e4728`
- `lab/README.md` section "The realistic mode" (numbers, pass rule, calibration). `@47e4728`

## Handover of scope 3 (idle connections, time, cold start, commit b47adcf)

### Verified (scope 3)

- **Aggregator additions, red then green:** 10 new cases in `lab/check/aggregate-test.php` (55 ok in all) first failed on the missing `endpoints` of a second, `$a->errorCodes` and `agg_connection_errors()`, then passed. One case I got wrong myself (my row with `expected=false` carries code 1404): fixed the expectation, not the code. **Proof:** `bash lab/run.sh 8.5 php /lab/check/aggregate-test.php`.
- **Series library, red then green:** `lab/check/series-test.php` (23 cases) failed on the missing `series-lib.php`, then passed. `mxFrame` against a real WAL: the frames read from `-shm` equal `(wal bytes - 32) / (page size + 24)` after 400 rows, and after `wal_checkpoint(RESTART)` plus one row they are 1 to 3 while the file keeps its size (the brief's claim holds). **The byte order is native (little-endian here), not big-endian as the brief said:** the native read matched the file-size arithmetic. **Proof:** same command with `series-test.php`.
- **Telemetry, red then green:** `lab/check/telemetry-test.php` (14 cases) failed on the missing class, then on `nextBoundary()` (written after a real bug, see "Raw learnings"). The app's counting (3 cases added to `app-test.php`, 60 ok in all) was written AFTER the code; I checked it bites by removing one `app_count(` call (the `GET /posts/:id` case failed with the missing endpoint) and restoring it.
- **Checks bite:** with the `dd iflag=nocache` line of `lab_start_app` disabled `check_cold_start_evicts_the_copy` fails (`the cold copy is more than 5 % resident: resident_bytes=249843712 ...`); with the fixture's idle timeout set to 200 s `check_idle_client_hold_mode` and `check_realistic_idle_closed_by_the_server_fails` fail (exit 0, nothing closed). Both restored.
- **The Done-when run** (skeleton on 8.5, `--think-scale 0.0286 --idle 60000 --staircase 2000,2000,18000,20`, 24 other containers running, exit 0): 60,000 held at the start and at the end (the server counted 60,000 and 60,000 established, 60,012 fds open with them), **0 k6 connection errors**, 9 steps all pass up to 4,864 VUs / 17,816 req/s (p95 6.1 ms, p99 13.4 ms at the top), 229 per-second rows, peak fds 64,876. A second run at the cap (`--hold 19900,25`: 5,377 VUs, 19,565 req/s, p95 9.0 ms) peaked at **65,389 open fds** of 65,535, no connection error, lag 2.4 s. JSON: none committed (smoke runs, `lab/results/` untouched).
- **Idle client's memory, measured:** 60,000 connections take **257 MiB** of the client container's `memory.current` (peak 257.4): 44 MiB of heap, 213 MiB of kernel memory (`kernel` in `memory.stat`), the PHP process's RSS is 56 MiB (77 MiB peak during the sweeps), about 4.4 KiB per connection; opening them takes 9.9 s from 6 source addresses. `memory.stat`'s `sock` stays 0. The budget in the k6 memory is now `LAB_IDLE_CLIENT_MIB=512`.
- **Cold and warm `fincore`:** warm 249,843,712 of 249,843,712 bytes (100 %), `--cold` **0 of 249,843,712**; in `macro.sh --fresh-db --cold --per-second` (400 req/s, 8 s, `posts.js`) the series shows 20 to 31 major faults a second and `memory.current` growing from 14 to 25 MiB (the page cache refilling). **Proof:** `check_cold_start_evicts_the_copy`, `check_macro_fresh_db_cold_per_second`.
- **Telemetry against the aggregator:** the telemetry's request count per second matches the aggregator's within about 100 requests a second (19,500 against 19,500 at the cap), and over a run within 3 % (`check_realistic_idle_run`); before the `nextBoundary` fix one line was lost per run (see below).
- **Full suite:** `bash lab/check.sh` 53/53 ok (44 before, 9 new: `check_series_cases`, `check_telemetry_cases`, `check_cold_start_evicts_the_copy`, `check_app_telemetry`, `check_idle_client_hold_mode`, `check_realistic_idle_run`, `check_realistic_idle_closed_by_the_server_fails`, `check_macro_fresh_db_cold_per_second`, `check_macro_cold_needs_fresh_db`). `conns.sh`'s three checks passed unchanged. shellcheck clean.

### Assumed (scope 3)

- **That `dd if=<copy> iflag=nocache count=0` is enough on the bench VM:** on this VM (Linux 6.12, overlayfs on the container's disk) it drops the whole copy; an older kernel without `fadvise` support on overlayfs would leave it resident, and the 5 % guard would make a `--cold` run invalid, not wrong.
- **That the `kernel` field of the client's `memory.stat` is mostly its sockets:** I did not split it; the number that matters is `memory.current`.
- **The telemetry's cost** (two `hrtime` per callback, one timer a second, one `app_count` call per request) is not measured, the brief leaves it to a later run.
- **A step at 6 s plateaus at 50 req/s is noisy:** my first smoke run failed step 1 at 96.5 % achieved (49 against 50.8); `check_realistic_idle_run` uses `--hold 40,12` and asserts nothing about the step.

### Dead ends (scope 3)

- **Reading the WAL index through PHP and `/proc/<pid>/root`:** `fopen` failed with "No such file" while `stat` and `head` worked: PHP resolves the `root` link to `/` and opens the probe's own `/tmp`. The sampler reads the 96 bytes with `head` (one fork a second).
- **`fincore` of util-linux:** not in any lab image (Ubuntu 24.04 moved it to `util-linux-extra`), and I did not touch the shared images. `lab/macro/fincore.php` does the same `mincore(2)` through FFI (`php -d ffi.enable=1`).
- **`select()` in the idle-timeout fixture** is limited to 1,024 descriptors: the checks that use it stay under (200 idle connections).

### Decisions on the way (scope 3)

- **A closed idle connection is INVALID (exit 3), a client that cannot open them all is exit 1:** the brief says "fails the run with that reason". Exit 3 matches the other "printed but invalid" cases and keeps the JSON and the table; failing to open is a harness stop before any load.
- **Hold mode = the same client file with options**, not a new script: `client.php <port> --hold <n> --path <p> --body-regex <pcre> --end-file <f>`; the harness ends the hold by touching the file (no FIFO), the client prints `held` then `ended`. `conns.sh`'s protocol and baseline are untouched.
- **The series rows come from one sampler (`lab/macro/sampler.php`, in the probe container), a merge in PHP (`series-lib.php`, run in the probe container) and shared bash in `lab/series.sh`:** `realistic.sh` and `macro.sh` both source it. The first sample is read at once (the second already running), so the first row is partial and the rows' request counts add up to the aggregator's exactly (checked in `check_macro_fresh_db_cold_per_second`).
- **Rows are per second from `[first sample, last sample)`; a row needs both boundary samples** or `server` is null (never a delta over two seconds). Gauges are the reading at the end of the second, CPU and faults are deltas (CPU scaled to us per second).
- **Telemetry design:** `DiyTelemetry` (`lab/servers/diy-telemetry.php`) wraps the loop's callbacks only when given (null: nothing added to the loop); the app counts per endpoint in `app_count()` (one call per request, a null check when off). A line is for the second its timer was set for (`nextBoundary`), not the clock's.
- **Endpoint names for `macro.sh --per-second`:** the aggregator takes `normalize_names` (URL path, numbers as `:id`) because `posts.js` does not name its requests and the URL differs per post (500,000 names otherwise). `posts.js` is untouched.
- **`error_code` is now captured by the aggregator** (one more group in the duration regexp): `connection_errors` are the 12xx codes. Reported, not a validity rule.
- **`--cold` is invalid above 5 % resident**; telemetry is on unless `--env APP_TELEMETRY=...` is given; `--cold` needs `--fresh-db` in `macro.sh` (exit 2).
- **`macro.sh --fresh-db` defaults `--ext` to `sockets event`** (the app needs them) and waits up to 60 s for the copy.
- **The VU cap and the memory budget use `LAB_IDLE_CLIENT_MIB` (512)** instead of 1 GiB, in the budget and in the calibration's memory cap. The cap stays 5,400 (fds).
- **SQLite's cache counters are not read** (stated in the README): `pdo_sqlite` does not expose `sqlite3_db_status`, and the handle is not reachable from PHP.

### Raw learnings (scope 3)

- **A timer that fires early duplicated a second:** the first telemetry labelled a line `floor(now) - 1`; libevent's timer runs on the loop's clock, so a line fired a fraction of a ms before the boundary took the previous second, `telemetry_parse` (keyed by second) kept the later line and one second of requests (19,492 of 572,873) vanished from the run. Found by summing the telemetry per row against the aggregator's. Fix: the line takes the boundary it was set for. Proof: `big2.json` before (row 21: 137 against 19,695) and `check_realistic_idle_run` after.
- **The aggregator's lag grows with the rate, not with the aggregator:** 3.88 s at 17.7 k req/s (gate 4 s) in one run, 3.3 s and 2.4 s in the others, 1.2 to 1.9 s at low load. The replay at 480,000 rows a second reads in 1.0 s with the old and the new library (checked both), so it is k6's CSV flush under load. Not fixed; a gate of 4 s is close at the top steps.
- **The server does 17,800 req/s on one CPU in this VM:** 29 us of server CPU a request at 18 k req/s (60 us at 2 k), p95 6 ms; the staircase to 4,864 VUs passed every step. The 20,000 req/s the scale targets is within reach of the app, so the first failing step of a later run will tell something.
- **Idle connections cost the server about 1.4 KiB of `Pss_Anon` each** (91 MiB at 60,000, 6 MiB at none) and a `memory.current` peak of 385 to 613 MiB depending on how much of the database's page cache is charged to the cgroup: the 2 GiB are not close.
- **The transparent huge pages** make 40 MiB of new memory 21 minor faults in this VM (the telemetry test says so): a minor-fault count is not a byte count.
- **`docker stats` shows 257 MiB for the client, `ps` 56 MiB:** the kernel's socket structures are in the container's cgroup, not in the process.
- **bash 3.2:** no `mapfile`, `column -t -s` needs a real tab (`$(printf '\t')`), and `shellcheck` run from the repo root does not follow `source=` to `lib.sh` (the check's way): a variable only read in `lib.sh` or `series.sh` needs `# shellcheck disable=SC2034` with its reason; run the local shellcheck from `lab/` AND via `bash lab/check.sh check_shellcheck`.

### Where to look (scope 3)

- `lab/realistic.sh` (`--idle`, `--cold`, `idle_wait`, the `cold_json` and `idle_json` blocks, `run_measured`'s sampler and series), `lab/series.sh` (`sampler_start/stop`, `series_build`, `series_print`). `@b47adcf`
- `lab/macro/sampler.php`, `lab/macro/series-lib.php` (`wal_frames`, `wal_header_frames`, `proc_stat_faults`, `telemetry_parse`, `series_merge`), `lab/macro/series.php`, `lab/macro/fincore.php`. `@b47adcf`
- `lab/servers/diy-telemetry.php` (`DiyTelemetry`, `nextBoundary`), `lab/servers/diy-server.php` (the optional telemetry), `lab/app/app.php` (`app_count`, `app_telemetry_*`), `lab/app/server.php`. `@b47adcf`
- `lab/lib.sh` -> `lab_start_app` (`LAB_COLD`, the `fincore:` line), `lab_fincore_line`; `lab/conns/client.php` (hold mode); `lab/macro.sh` (`--fresh-db`, `--cold`, `--per-second`). `@b47adcf`
- `lab/check/fixtures/idle-timeout-app.php` (a select-loop server that closes connections idle for 2 s). README sections "Idle connections, the per-second series, telemetry and a cold start" and "The challenge app on `macro.sh`". `@b47adcf`

## Handover of scope 4 (the profile, commit 4775db8)

### Verified (scope 4)

- **The image:** `php-lab:8.5` (and 8.3, 8.4) report `excimer: 1.2.6`; the new layer was built after the `install-extras.sh` layer, which stayed `CACHED` in the build log (so libevent did not move). The tarball's sha256 `7b5fe1f6...d034` is pinned and was checked by the build. **Proof:** `bash lab/run.sh 8.5 php-info | grep excimer`, `bash lab/check.sh check_image_8_5`.
- **8.6 does not build Excimer** (two names PHP 8.6 removed: `XtOffsetOf`, `INI_INT`): the error is in `lab/results/excimer-on-php-8.6.md`, the 8.6 image is built with `WITH_EXCIMER=0` (`excimer: not built`), and `--profile --image 8.6` exits 1 with `this image has no Excimer` before any server starts (in `check_realistic_profile_smoke`).
- **Fold, red then green by mutation:** the 24 cases of `lab/check/fold-test.php` were written after the code (I had the design in my head), and bite: with the innermost-frame loop turned outermost-first 9 of them fail (`{"loop":995,"unclassified":5}`). The shares are counted by hand from `lab/check/fixtures/profile-collapsed.txt` (1,000 samples). **Proof:** `bash lab/run.sh 8.5 php /lab/check/fold-test.php`.
- **Calibration** (`lab/profile/calibrate.php`, run by `check_excimer_calibration`): see the README section "Where Excimer's samples land". Numbers: the hash is 28.3 % of the CPU with the JIT on and 33.4 % off (hrtime, no profiler), `calib_hash_step` holds 28.2 % and 33.8 % of the samples (0.1 and 0.4 points), no frame named `hash` exists. libevent spinning: 97.9 % of the samples on the callback's own frame, 2.1 % on the caller of `dispatch()`. Samples add up to the CPU used by the process (0.99 to 1.00), 39 to 70 % of it in the kernel. **Excimer attributes an internal function to its caller**, so the rules map the step functions (the Done-when's second branch).
- **The profiled smoke** (8.5, realistic, `--think-scale 0.1 --warmup 100,5 --hold 300,20 --ramp 3`, 24 other containers running): unclassified 0.0 %, 1,883 samples, cgroup user 1,324 ms and system 625 ms (32 % in the kernel), the samples cover 97 % of that CPU. Shares of all samples: S6 41.5 %, S8 23.6 %, event loop 14.6 %, S2 9.5 %, S7 5.9 %, S1 2.4 %, S4 1.2 %, S3 1.0 %, S5 0.3 %, S9 0. A second one at 1,000 req/s (3,174 samples, 34 % kernel): S6 47.1 %, S8 20.7 %, loop 13.3 %, S2 8.0 %, S7 6.6 %, S1 2.6 %, S4 1.2 %, S3 0.4 %; within `GET /feed`: S6 85.1 %, S7 14.9 %.
- **Excimer's cost, a first smoke** (hold 1,000 req/s, 20 s plateau, 945 VUs, warm-up 100,5, telemetry off in both, two runs each, other containers running): profiled 121.1 and 115.7 us/req, unprofiled 119.0 and 115.9: **+0.9 % on average, inside the noise** (the two runs of the same kind differ by 5 us). Not a measurement.
- **Checks:** `check_fold_cases`, `check_excimer_calibration`, `check_realistic_profile_smoke` (JSON holds the profile, unclassified under 5 %, the table has the five endpoints, shared and all, every journey endpoint has samples, S9 is 0, no container or volume left, 8.6 refused), `check_macro_profile` (and `--profile` without `--fresh-db` is exit 2). The smoke check bites: removing the `route route_like` rule from `steps.rules` makes it fail on the missing column. `check_source_extras` also checks `excimer: 1.2.6` or `not built`.

### Assumed (scope 4)

- **That a samples-over-CPU ratio of 0.97 is Excimer's overhead of timer interrupts and my wait window,** not lost samples: the calibration's loop gives 0.99 to 1.00 on a busy loop, the server's window includes idle seconds where the CPU timer does not tick.
- **That the warm-up and the ramps belong in the profile:** the window is the server's whole life after its first answer. A later phase that wants the plateau alone needs the profiler to reset at the plateau's start (a signal or a second timer file), not done.
- **That two runs of each kind are enough for a first idea of Excimer's cost:** the brief says a smoke.

### Dead ends (scope 4)

- **`{closure:file(line)}` frames:** the first version of the profile named the loop's callbacks `{closure:/lab/servers/diy-server.php(97)}`, the line of the method. I changed `DiyServer` to pass `[$this, 'onReadable']` instead of `$this->onReadable(...)` (see decisions).
- **Editing `lab/realistic.sh` while a run of it was going** (two runs of `cost.sh` were in flight): bash reads a script as it runs. Both runs finished normally (checked their output), but do not do it.
- **`docker run --rm` without `-i` for stdin:** my first fold smoke got an empty stdin and `fold: the profile holds no sample`; the harness uses `docker exec -i`.

### Decisions on the way (scope 4)

- **Named method callables for the loop's callbacks (a change in `lab/servers/diy-server.php`, shared with `bake-diy.php`):** the brief says each step has its own function; the loop's callbacks were first-class closures, which a profile names with the method's line number. `[$this, 'onAccept']` (a private method, called by ext-event from C: it works) gives `DiyServer::onAccept`. With telemetry on, the closure is still wrapped (`$telemetry->timed($this->onReadable(...))`). Behaviour is the same; its cost per call was not measured (ext-event keeps the resolved callable either way). `bake-diy`'s conformance and parser checks pass.
- **S9 has no frame and the row stays at 0:** SQLite commits inside `PDOStatement::execute` (autocommit), so a write's commit and its checkpoint are in `post_insert` / `like_insert`, S6; Excimer cannot split a C call. To measure S9 the app would need an explicit transaction around the write (a change to what the app does, out of scope): the README says so and the table prints a note.
- **Each cell is a share of ALL samples** (the table sums to 100 %, a column total is the endpoint's weight); with `--us-per-req` the cell also gives the microseconds it adds to the average request. A second block gives each column's own shares (the answer to "which step costs the most for `GET /feed`"): I added it because the first block cannot answer that without arithmetic. The brief said "one table": there are two blocks, one command.
- **`--us-per-req` is computed by the harness** = cgroup (user + system) over the window / requests of the window (warm-up + run + one `/health` per idle connection, from k6's summary and the aggregator's count): so it is the profiled server's CPU per request over a window that includes the ramps, the idle second and the warm-up (133 us in the 1,000 req/s smoke against 116 us on its plateau). The fold prints it as an average, never as a baseline.
- **`DiyConnection::close` is S1**, with `onAccept` (accept and close are the connection's lifecycle); the brief's S1 says "accept connections".
- **`DiyConnection::advance` is S8 and `::parse` is S2:** `advance`'s own samples are `fwrite`, `parse`'s own samples are `strpos`/`substr` and the concatenation of the response head and body (S8 work, kept in S2: splitting it needs a function of its own in `diy-connection.php`, which the brief keeps out of scope).
- **`route_health` is S6** (it runs its query inline); the route functions' own samples are S3; `response_error`'s own `json_encode` is S8 (the app's own comment says S8).
- **`--profile` turns the telemetry off** unless `--env APP_TELEMETRY=..` is given, and adds `excimer` to `--ext`; it needs `--fresh-db` on `macro.sh`; `--profile` with `--calibrate` is refused. `--env APP_PROFILE_PERIOD=<s>` changes the period (the JSON records it).
- **One shared script, `lab/profile.sh`** (sourced like `series.sh`): `profile_prepare`, `profile_check_image`, `profile_begin`, `profile_collect`, `profile_print`. The `profile_json` variable is initialised by each harness (`shellcheck` from the repo root does not follow `source`).
- **The fold runs in the probe container** (`docker exec -i probe php fold.php -`): no PHP on the Mac.
- **`lab_source_release` has a 5th field, `WITH_EXCIMER`:** every `read -r ... <<<"$(lab_source_release ..)"` that took the last field had to ignore it (`check.sh`'s two reads, `build.sh`).
- **`lab/results/build-times.md`:** I kept the three rows of the real new-layer builds (14 to 16 s, the other layers cached) and dropped the five rebuilds that only changed `php-info` (0 to 1 s).

### Raw learnings (scope 4)

- **Excimer shows no internal frame, ever.** `fread`, `fwrite`, `PDOStatement::execute`, `hash` are always the calling PHP function's time: the sample is taken at the next VM interrupt check, after the internal call returns. Proof: `calibrate.php hash`, JIT on and off. With the JIT on, a hot loop's samples still land in the function that holds the loop.
- **libevent and `epoll_wait` land on the next callback's own frame.** In the app that is `DiyServer::onReadable` self (118 of 396 samples in my first curl smoke). A callback with a heavy PHP body would hide the loop's share in its own: only a callback that does almost nothing, like `DiyServer::onReadable`, gives a clean loop figure.
- **Samples are conserved:** 3,969 samples against 3,985 ms of CPU (user plus system) in a spinning libevent loop, so the CPU timer counts the kernel's time; a profile is "where the thread's CPU time went", with syscalls inside the frame that made them.
- **At 300 req/s the server costs about 200 us a request, at 1,000 req/s about 117 us, at 18,000 req/s 29 us** (scope 3): a per-request CPU number is meaningless without its rate; a later scope that compares profiles must hold the rate.
- **`GET /feed` is 85 % S6 and 15 % S7 within its own samples; shared work (read, parse, write, loop, accept) is 45 to 51 % of all the server's CPU** at 300 to 1,000 req/s, S6 is 41 to 47 %. So the next phase's biggest levers by this smoke are the shared parts (S8 `fwrite`, S2 `fread` and the parse, the loop) and the feed's query, in that order of size after the query.
- **A `docker exec ... cat` of the profile file costs the server almost nothing but is in the cgroup's window:** the harness reads cpu.stat before it.
- **bash 3.2:** nothing new; the `profile_json=null` line is what `shellcheck` from the repo root wants (same cause as scope 3's SC2034 note).

### Where to look (scope 4)

- `lab/servers/diy-profile.php` (`DiyProfile`: the profiler, the timer, the atomic write), `lab/servers/diy-server.php` (named callables, the `$profile` argument), `lab/app/server.php` (`APP_PROFILE`, `APP_PROFILE_PERIOD`). `@4775db8`
- `lab/profile/fold-lib.php`, `lab/profile/fold.php`, `lab/profile/steps.rules` (the rules, with the reason of each frame), `lab/profile/calibrate.php` (`hash` and `loop` modes). `@4775db8`
- `lab/profile.sh` (the harness side), `lab/realistic.sh` and `lab/macro.sh` (`--profile`), `lab/images/install-excimer.sh`, `Dockerfile.src` (the layer), `lab/lib.sh` (`lab_source_release`'s 5th field), `lab/results/excimer-on-php-8.6.md`. `@4775db8`
- `lab/check/fold-test.php`, `lab/check/fixtures/profile-collapsed.txt`, README section "The profile". `@4775db8`

### Fix of scope 3: the idle-run check's flake (commit fc73cee)

- **Cause found:** `check_series_rows` demanded `server.cpu_usec > 0` in every row. The first row (a partial second, before the load) and the last (after it) can have a true 0: 4 of 9 runs failed on old code, and with the clause named the failures read `server_readings`, row 0 or row 18, `cpu_usec: 0`, all other readings fine. Now the edge rows need `>= 0` and the rows between `> 0`. **Proof:** `idle10.log` before (6 ok of 9 before it was stopped), 10 of 10 ok after (`bash lab/check.sh check_realistic_idle_run` x10).
- **The coordinator's failure came from the other block** (the message `{idle, cold, k6_connection_errors, rows}`), which I never reproduced in about 25 runs; two clauses of it could fail at 40 req/s: the telemetry total within 3 % of the aggregator's (one second at an edge is 5 %), and `.telemetry.requests | to_entries` on a row with a null telemetry (a jq error, so exit 5, same message). Both are fixed whatever it was: every clause is a named boolean, the failure prints the false clause names and the numbers (`telemetry_requests`, `aggregator_requests`, `rows_without_telemetry`, `rows_without_server`, `wal_frames_max`, `longest_callback_max`), and the totals are compared on the rows between the first and the last, within 2 % plus 8 requests (a lost line is a whole second, about 40 requests, so it still fails).
- **The full suite on fc73cee: 56 ok of 57, one FAIL: `check_realistic_stops_at_a_failing_step`** (scope 2's check): its step 1 at 60 req/s against `slow-app.php` achieved 56.3 of 60.3 (93 %, p95 16.8 ms) in that run, and the check passed 5 of 5 alone right after. Same kind of flake as my first smoke run (a short plateau at a low rate is noisy), not touched here; step 1 of that check has a margin of 0.97 against a 4 ms server at 24 % busy, a longer plateau than 8 s or a lower first rate would give it room.

### Second fix of scope 3: the failing-step check's passing step (commit b18af33)

- **Cause, found by a first attempt that did not work:** `check_realistic_stops_at_a_failing_step` failed its step 1 by chance, and not on latency. A first try (`--think-scale 0.2 --staircase 40,260,300,12`, more mean-latency margin: 58 ms) still failed 1 run of 10 at 96.7 % achieved (38.9 of 40.2) with a p95 of 13 ms, far from the margin. The shortfall is in the request COUNT: a 40 to 60 req/s plateau of 8 to 12 s holds 300 to 500 requests, and with random think times that count alone moves by 2 to 3 %, against a 3 % rule.
- **Fix:** `--think-scale 0.2 --staircase 100,200,300,15`: step 1 at 100 req/s (about 1,200 requests in its 12 s of data, 40 to 50 % busy against the 4 ms fixture), step 2 at 300 req/s (above the fixture's 190 to 250 req/s, still fails on the 97 % rule and stops the staircase). About 30 s a run (it was about 25 s). **Proof:** `bash lab/check.sh check_realistic_stops_at_a_failing_step` 10 of 10 ok in a row (the first try: 9 of 10); the full `bash lab/check.sh` on b18af33: 57 of 57 ok, no other flake in that run.
- **Learning:** any check that runs the 97 % rule on a short plateau at a low rate is a coin flip (my first smoke run at 50 req/s and 6 s failed the same way): give such a step at least about 1,000 requests, not only latency room.

## Handover of scope 5 (the realistic baseline, commit 671d87b, with two fixes before it)

Commits: `38fc153` (fix: the run's own idle client counted as another container), `fcf104f` (fix: a long run's rows to jq through files), `671d87b` (the results, `lab/results/2026-11-22-realistic-baseline/`, and a lab README note on k6's memory and the printed lag), `374c75c` (one line of the README's verdict 2: a feed costs 7 posts, not 3 to 4).

### Verified (scope 5)

- **The baseline (median of 3 holds of 5 minutes at 24,000 req/s, `--think-scale 0.02`, 60,000 idle, quiet VM, every run `other_containers: 0`):** 23,386 req/s achieved, 221,002 users at 9.45, 27.15 us CPU/req, p95 11.93 ms, p99 28.29 ms, 0 errors. Hold one fine step above (24,250): passes, 23,625 req/s. 6 of 12 predictions held (1, 4, 7, 10, 11, 12).
- **Calibration:** 0.284 / 0.343 MiB per VU (50 to 300, 300 to 5,000 VUs), cap 5,400 (fds), s 0.02858 for 20,000 req/s at the cap, lag 3.49 s at 5,000 VUs (18,300 req/s) so the gate was set to 5.5 s.
- **Profile (57,666 samples):** S6 51.7 %, S8 20.2 %, S7 9.7 %, S2 8.0 %, loop 6.5 %, S1 1.7 %, S4 1.7 %, S3 0.4 %, S5 0.1 %, S9 0 (inside S6); 30 % of the CPU in the kernel. us/req per step from the unprofiled mean (27.59): 14.3, 5.6, 2.7, 2.2, 1.8 (loop), 0.5, 0.5.
- **Excimer -0.33 %, telemetry -0.05 %** (both inside the noise: the two unprofiled runs differ by 5 %).
- **Q10:** 0 of 53 stalled seconds of the 3 holds had a callback as long as the stall (44 under 20 ms). One `posts.js` run (877 ms) was the server's cgroup throttled by CFS for 325 ms (callbacks of 181 ms). Warm `posts.js` at 700 VUs dropped iterations in 2 of 3 runs, the cold ones in none.
- `summarize.sh` output equals the README's block (`diff` empty, command in the README). `shellcheck` clean on the scripts touched. I did not run `lab/check.sh` (the brief forbids it during the series, and the PM runs the suite): the two harness fixes were each checked by hand (an `--idle 200` hold says `other_containers.count 0`; the long-run jq path ran in every run after, up to 570 s runs of 1,700 rows).

### Assumed (scope 5)

- **That the max lag printed at the end of a run is partly the tail after k6 stops:** read from `aggregate.php` (lines 143 and 144 take the lag again after the end marker), not measured. It is why hold-3 prints 6.3 s against a 5.5 s gate in a valid run.
- **That `Pss_Anon`'s climb from 104 to 160 MiB in a hold is SQLite's 64 MiB page cache filling** (91 idle + 6 + 64 = 161, four holds peak at 158 to 161): consistent, not proven by a longer run.
- **That the stalls of the realistic holds are outside the server** (host, k6, VM): the callbacks say the server's PHP did not run long; they cannot say which of the other three it was. Only the throttled `posts.js` run has a proven cause.
- **That three 60 s runs failing the 97 % rule by 0.1 to 0.3 points can count for cost per request:** valid, `other_containers: 0`, flagged in the README. The brief says every counted run passes: a strict reading wants them rerun (profile-off-2, telemetry-1-on, telemetry-1-off, about 4 minutes each).

### Dead ends and invalid runs (scope 5)

- `invalid/` holds: the first coarse try at s 0.0286 (idle open failed at 7,000 connections right after the 5,000-VU calibration; same command a minute later opened 60,000 in 9.8 s; I never found the cause, suspect TIME_WAIT of k6's run, the runner now waits for `tw` under 500), a run killed by hand to fix the idle bug, a run at s 0.0143 (it died on the jq argument-list bug after 21 minutes), and the s 0.0286 staircase killed by k6's memory budget at step 17 (JSON kept, steps shown in the README).
- **k6's memory grows with the request count** (about 190 bytes a request on top of 0.34 MiB a VU): a run over about 12 M requests is killed at the 4,351 MiB budget. A staircase has to be cut in runs of about 7 steps at 20,000 req/s. In the lab README now.
- **`sleep` and a long loop in a foreground call:** a loop of `sleep 3` with `timeout` 118000 works; past 180 s the shell moves the command to the background.

### Decisions on the way (scope 5)

- **s lowered to 0.02, not to 0.0143:** the plan lowers `s` when the knee is above the cap. 0.02 puts the cap at 28,600 req/s and keeps the 97 % rule's latency margin at 5.8 ms (0.0143 would have set it at 4.1 ms: the staircase would have failed on k6's overhead, not on the server). The baseline is therefore "the rate held at s 0.02", not a server limit (63 % CPU busy at 24,000).
- **The staircase started at 18,000** (the last rate the first, invalid run passed), in two runs, for k6's memory.
- **Holds at 24,000** with the 97 % rule as the brief says, although 4 of 17 runs at that rate failed it (24,000 is on the line: 96.7 to 97.7 % achieved). No step down was needed.
- **Excimer with three runs (off, on, off), telemetry off in all,** so the pair isolates the profiler; the fold's us/req is the mean of the two unprofiled runs.
- **Cold `posts.js` runs with `--warmup 0`** (a warm-up re-warms the copy); realistic cold and warm runs without warm-up, 2 pairs.
- **A stall is a second with a max over 100 ms; "inside" is a longest callback at least as long as the stall, "outside" under 20 ms, "mixed" between.** The README also shows the CFS throttling of the server's cgroup per run: it is what explained the one inside stall.

### Raw learnings (scope 5)

- **The skeleton does 23,400 req/s on one CPU at 63 % busy** (27 us per request, falling from 48 us at 3,000 req/s): the limit the 97 % rule finds is latency spread (p95 12 ms, p99 28 ms, mean 2.2 ms), not CPU. The CPU per request is flat from 18,000 to 24,000 (26.5 to 27.3).
- **Stalls of 100 to 300 ms happen 16 to 21 times per 5 minutes at 24,000 req/s** with callbacks under 50 ms and the cgroup not throttled: someone outside the PHP code. Next step if it matters: see whether k6 (3 CPUs) or the VM does it (a k6-side timer, or `perf sched` in the VM).
- **CFS throttling is real in the macro runs:** `results.server_throttled_usec` (macro JSON) or the cgroup's `cpu.stat` (raw in the realistic JSON). In one `posts.js` run 325 ms of throttle gave an 877 ms stall and 9,193 dropped iterations. The bake-off's stalls may have been this too; its JSON has `server_throttled_usec`.
- **The profile at 24,000 req/s differs from the 1,000 req/s smoke:** S6 51.7 % (47.1), S8 20.2 % (20.7), S7 9.7 % (6.6), S2 8.0 % (8.0), loop 6.5 % (13.3). The loop's share halves with the rate (batching: many events per `epoll_wait`).
- **`GET /posts/:id` is 6.7 % of the samples with 46 % of the requests; `GET /feed` is 47.6 %:** a feed request costs about 28 us and a post request about 4 us (shares over the 46 % of requests each is), so 7 posts, against the predicted 3 to 4.
- **The idle connections cost `Pss_Anon` 91 MiB; the page cache of the database and the WAL cost `memory.current` the rest** (595 to 697 MiB).
- **bash 3.2 and `&` inside `run_in_background`:** the background command returns at once and the task notification fires early: run the script itself in the foreground of the background task.

### Where to look (scope 5)

- `lab/results/2026-11-22-realistic-baseline/README.md` (predictions, deviations, the summarize output, the verdicts, the step lab's order), `summarize.sh`, `run-times.txt`, `invalid/`. `@671d87b`
- `lab/realistic.sh` -> the `runs.json` block before the final `jq` (the argv fix), the `lab_other_containers` call (the idle fix). `@fcf104f`, `@38fc153`
- `lab/README.md` "The guard: lag and memory" (two new bullets). `@671d87b`

## Handover of scope 6 (every results folder regenerates its tables, commit 55c9d2e)

### Verified (scope 6)

- **What the check found:** nothing to fix. `2026-11-21-bake-off` (210 non-empty lines printed), `2026-11-21-noop-swoole` (18) and `2026-11-22-realistic-baseline` (216) each hold every line their `summarize.sh` prints, byte for byte; `2026-11-22-realistic-calibration` has no script and is named as skipped. No README, script or number was changed. The phase 2 folder needed no regeneration.
- **The check bites, by mutation (both restored):** one digit changed in `noop-swoole/README.md` (`3000` to `3001` in the 3000 req/s row) makes `check_results_regenerate` fail and name `| 3000 | 30.16 | 29.9 .. 30.44 | ... |`; the awk's `print; exit` replaced by `next` makes `check_results_check_catches_drift` fail (`expected exit 1 ... got 0`). The checks were written after the function (the fixture and the real folders passed at once), so the mutations are the red.
- **Full suite:** `bash lab/check.sh` 59/59 ok (57 before, 2 new: `check_results_check_catches_drift`, `check_results_regenerate`), no FAIL. shellcheck clean (`check_shellcheck` in the run).

### Decisions on the way (scope 6)

- **`results_check <root>`** (in `lab/check.sh`) takes the results root as its parameter; `check_results_regenerate` gives it `lab/results`, `check_results_check_catches_drift` gives it `lab/check/fixtures/results-drift/`. Per-folder lines (`ok`, `skip`, `FAIL`) go to stderr (a check's stdout is its failure reason), so they show in the terminal during the run.
- **Byte for byte = awk set lookup of whole lines** (README lines first, then the script's output, empty lines ignored). `grep -x` would have taken `|` and `.` as pattern characters (or needed `-F` per line, 266 forks).
- **Extra failures beyond the brief:** a script that exits non-zero, prints nothing, a folder with a script and no README, and a root with no `summarize.sh` at all (a vacuous pass). The summary runs with stdin from `/dev/null` and its stderr dropped.
- **Fixture:** `drifted/` (script prints `| a | 1 |`, an empty line and `| b | 2 | µs |`; its README holds the second line with one more space, so the near copy must not count, and `µ` checks the non-ASCII bytes) and `hand-written/` (README only: must be skipped, not fail). A third case builds a good folder in a temp dir: the passing path is tested too.
- **Needs:** the host's `jq` and Docker (the baseline's summary runs `bash ../../run.sh 8.5 php fold.php`), like the other checks. About 3 s in all.

### Follow-up commit (fd wall note)

- **A paragraph on the fd wall** (221,002 users are CPU-equivalent, about 71,000 on the real bench, S1-d or S1-b first, churn cost first) sits at the top of the baseline README's "The step lab's order", right under the heading and before the ranking intro and table, outside the summarize block. `check_results_regenerate` still ok for the baseline folder (216 lines). Commit 1acc81a.

### Where to look (scope 6)

- `lab/check.sh` -> `results_check`, `check_results_regenerate`, `check_results_check_catches_drift`; `lab/check/fixtures/results-drift/`; `lab/README.md` last paragraph of "Checks". `@55c9d2e`

## Next steps (from scope 5)

1. Decide whether the three 60 s runs that failed the 97 % rule (they are counted for cost) must be rerun, and whether 24,000 req/s at `s = 0.02` is the baseline to carry into the step lab (it is on the rule's edge: 4 of 17 runs failed).
2. The stalls: 16 to 21 seconds over 100 ms per 5 minutes at the baseline, outside the PHP code. Not explained.
3. S9 is still inside S6 (autocommit); S6 is 51.7 % of the CPU: the step lab's biggest lever is the query, then the write (S8) and the JSON (S7).

## Questions for the project manager

- Nothing blocking. To settle before the measuring scope: k6 costs about 300 us of CPU per request with the CSV stream on (it falls with the rate), so 20,000 req/s takes about 5 to 6 of the 8 CPUs that k6 and the aggregator share. I did not measure above 2,000 req/s. If it does not fit on a quiet VM, the options are fewer tags per CSV row (k6's `systemTags`), or a lower top rate for the staircase; the cap and the scale ignore k6's CPU today.

- **From scope 3, nothing blocking.** Two for the measuring scope: (1) the aggregator's lag peaked at 3.9 s of the 4 s gate at 18,000 req/s (2.4 to 3.3 s in the other runs): a measurement at the top steps may come out INVALID on the lag, and a gate of 6 s or fewer CSV rows per request (k6's `systemTags`) are the options, not tried. (2) The deviations from the brief: native byte order for `mxFrame`, `mincore` through FFI instead of util-linux's `fincore`, a closed idle connection is exit 3.

- **From scope 4, nothing blocking.** (1) The brief's "one table" is two blocks (the table of shares of all samples, and each endpoint's own shares): say if you want the second one dropped. (2) The loop callbacks are now named method callables in `diy-server.php` (shared with the bake-off's DIY server): no behaviour change, per-call cost not measured; a re-run of the phase 3 DIY numbers would be the proof if it matters. (3) S9 cannot be separated from S6 without an explicit transaction in the app: the next phase decides if it wants that change.

## Retro

### Scope 1

- **Missing:** nothing about the app; the one gap was the tools for `test.sh` (the brief guessed an image with bash, curl, jq, openssl exists locally: none does; `jq` is in no php-lab image). Found by running `command -v` in every local image.
- **Guessed:** that building `php-lab-tools:1` from the pinned Ubuntu with apt is acceptable once the pull of a published image was refused (no confirmation; it is in the README and in "Dead ends").
- **Lost time:** about 10 minutes waiting on `lab/check.sh` with a `pgrep -f lab/check.sh` loop that matched its own shell (the loop never ended); the suite itself took 2 minutes. A harness-level `until [ -f done ]` file would not have that trap.
- **Useless or contradictory instruction:** the brief says "see it fail first" for every case; for the app, the challenge's suite is the failing test and the app does not exist before it, so the app's own 57 cases came after the code (stated in "Verified", checked by mutation instead).
- **Deterministic:** the extra-agent-side guards that bit me were already there (shellcheck on every script, `check.sh`'s counts). One thing: a test count hard-coded in `check.sh` (`[ "$ok" = 40 ]`) forces an edit of the check with each new case; `check_diy_parser` would be steadier counting `FAIL`-free output plus a floor. Impression.
- **Plan should have decided:** where the 4th handler argument goes (I chose a 4th positional argument that the bake-off handler ignores; the alternative, an array or a request object, would have touched every adapter).
- **Blind spot:** nothing watches that the app and the bake-off handler keep the same pragmas: they are copies of each other (`app_boot` and `handler_open_db`). Impression.

### Scope 2

- **Missing:** nothing in the brief blocked me; one detail was ambiguous: "(65,535 - 60,000 idle - the server's own, about 5,400)" reads as three terms but 5,400 is the result. Resolved by arithmetic (`65,535 - 60,000 = 5,535`, minus about 135).
- **Guessed:** that `--staircase`'s last field is the plateau and not the whole step (no confirmation; stated in "Decisions"); that the exit code of a failing step is 0.
- **Lost time:** about 15 minutes on harness runs piped through `tail` that hid exit codes and on a quoting slip (`for t in "--k6-memory 50 --hold 50,6"` passed as one word); about 10 minutes waiting for foreground commands the shell moves to the background after 120 s (the full suite and the 60 s calibration are over that): run them with `run_in_background` from the start.
- **Useless or contradictory instruction:** the brief asks to see every case fail first; for the harness (bash around three containers) the first run of each piece is the only red/green available, and the 45 aggregator cases were the one real TDD loop (stated in "Verified").
- **Deterministic:** `shellcheck` caught two unused variables (`LAB_INI`, a loop counter) that I would otherwise have read as fine: the local shellcheck run before `lab/check.sh` saved a 10 minute suite round trip. The hard-coded floor of 45 in `check_aggregate_cases` has the same fragility scope 1 noted (it needs an edit per case).
- **Plan should have decided:** whether `s` in `--staircase` is the plateau or the step; whether a failing step is exit 0 or non-zero; whether the first scale measured (0.02858) must keep k6's CPU, not only its memory and the fds, under its budget.
- **Blind spot:** nothing measures k6's own CPU as a limit of the realistic mode: the calibration prints it but the cap and the scale ignore it (impression, from 297 us per request at 2,000 req/s).

### Scope 3

- **Missing:** two facts in the brief were wrong or unavailable: `fincore` (util-linux) is in no lab image (`which fincore` empty in `php-lab:8.5` and the tools image; Ubuntu 24.04 ships it in `util-linux-extra`), and the `mxFrame` byte order (the brief says big-endian, the `-shm` file is native; the WAL test with file-size arithmetic showed it). I found both by running the thing, not in the reading.
- **Guessed:** that a closed idle connection is exit 3 with the JSON kept (the brief says "fails the run"), and that 512 MiB is a fair reserve for the idle client (257 MiB measured, no confirmation).
- **Lost time:** about 20 minutes on `fopen('/proc/<pid>/root/...')` returning "No such file" while `stat` and `head` worked (PHP resolves the magic link, `realpath` showed `/tmp/feed.db-shm` of the probe); about 15 minutes on one telemetry second missing from the runs, found only by summing the telemetry per row against the aggregator's (the timer fired early, two lines shared a second); about 10 minutes of blocked standalone `sleep`s, solved with `until` loops.
- **Useless or contradictory instruction:** the brief says "see every case fail first"; the harness checks (bash around 4 containers) could only be written after their first run, the pure libraries (aggregator, series, telemetry line) did get a red step (stated in "Verified").
- **Deterministic:** `shellcheck` run from `lab/` passed while the check's own run (from the repo root, pinned image) failed on 8 SC2034 (a variable read only in `lib.sh` or `series.sh`, which it does not follow from there): `bash lab/check.sh check_shellcheck` is the reference and takes 10 s, but the brief and `common.md` tell developers to run the local one. Branch it where the brief says "run it locally": the same invocation as `check_shellcheck` (from the repo root, `-w`), e.g. a `lab/shellcheck.sh` that the check and the developers both call. Also the hard-coded floors in `check.sh` (60 and 55 ok cases) need an edit per case again (impression, same as scopes 1 and 2).
- **Plan should have decided:** exit 3 or exit 1 for a closed idle connection; what to do when the aggregator's lag nears its gate at the top steps (3.9 s of 4 s at 18,000 req/s), since a scope 5 measurement would turn INVALID there.
- **Blind spot:** the cost of the telemetry itself and of the sampler is only argued (two `hrtime`, one timer, one fork a second on CPUs 0-1), nobody has measured it yet; and the aggregator's lag at high rates is read once a second in a status file nobody plots (it is in `results.aggregator.max_lag_s` only).

### Scope 4

- **Missing:** nothing blocked me. Two facts the brief could not know and I found by running: Excimer never shows an internal function as a frame (so the brief's "which one" question had a one-line answer), and the loop's first-class-closure callbacks are named by a line number in a profile, which the rules cannot use.
- **Guessed:** that two blocks (shares of all samples, then each endpoint's own shares) are acceptable for "one table" (no confirmation; I asked in "Questions"); that the profile's window may include the warm-up and the ramps; that renaming the callbacks to method callables in the shared `diy-server.php` is within "each step in its own function" (it changes no behaviour, but it is a change to a file the bake-off uses).
- **Lost time:** about 10 minutes on a stray `docker build -q -t x .` I typed by mistake in the worktree root (it failed without an image; no harm); about 5 minutes redoing a zsh-vs-bash slip (`source lib.sh` in the interactive shell, `docker: invalid reference format`: scripts for the lab go in a file run with `bash`); about 12 minutes waiting for the suite twice, and one check failed in the first full run because I ran a lab container (`lab/run.sh` on the server CPU) while it was going.
- **Useless or contradictory instruction:** "see every case fail first": the fold's design was settled before the first line, so the 24 cases were written after it and proved by mutation instead (stated in "Verified"). The brief's "every phase 2 and 3 `php-info` line stays the same" is the one that mattered and it held.
- **Deterministic:** a check that runs `lab/run.sh` while `lab/check.sh` is running disturbs the staircase (a 97 %-of-offered rule at 300 req/s): `lab/check.sh` could take a lock (a `lab-check` file or `flock`) that `lab/run.sh`, `macro.sh` and `realistic.sh` refuse to start under, instead of a note in the brief. Also, `check.sh`'s ok-count floors (24 here) need an edit per case, as scopes 1 to 3 said (impression).
- **Plan should have decided:** whether S9 may be split from S6 by an explicit transaction in the app (it cannot be, as the app is, and the brief asks for the row); whether the profile's window is the whole run or the plateau; whether a profile belongs to a 300 req/s run or a high-rate one (the shares move a little with the rate: S6 41.5 % at 300, 47.1 % at 1,000).
- **Blind spot:** nothing measures Excimer's cost properly: my smoke (two runs of each kind, 118.4 against 117.5 us/req) cannot see a 2 % effect, and the profiler's flush timer (stopped profiler, a 2 s rewrite of a growing file) is not in the profile by design, so its own cost is invisible there. Also the S2/S8 split inside `DiyConnection::parse` (the response head's concatenation) is a known small bias nobody has sized.

### Scope 5

- **Missing:** two facts the brief could not give and that cost runs: k6's memory grows with the request count (the brief and the calibration price k6 per VU only; a 20 minute staircase is killed at 12 M requests), and the long-run `jq` argument limit (macOS 1 MiB). Also the brief's "knee above the cap, lower s" does not say how far to lower it: I chose 0.02 so the 97 % rule's latency margin stays at 5.8 ms.
- **Guessed:** that a staircase may start at 18,000 (not 3,000) and be cut in runs (no confirmation; the first, invalid run showed 3,000 to 18,000 pass); that three 60 s runs failing the 97 % rule by 0.1 to 0.3 points count for cost per request; that "interleaved" Excimer means off, on, off.
- **Lost time:** about 45 minutes in all. The jq argument-list failure threw away a 21 minute staircase (and the run at s 0.0143 before I knew k6's memory was the cause of its early end); the k6 memory kill threw away another 21 minutes; about 4 minutes on a failed idle open; roughly 15 turns of 2-minute waits (the shell blocks standalone `sleep`, a `for ... sleep 3` loop with a 118 s timeout is the workaround).
- **Useless or contradictory instruction:** "no `lab/check.sh` during the series" is right, but nothing in the brief warns that a 20 minute run had never been run: scopes 2 to 4 smoke-tested 20 to 60 s runs, so the length limits (argv, k6 memory) were first met in the measuring scope. The brief's "from 3,000 in 1,000 steps to the failing step" does not fit k6's memory when the knee is high.
- **Deterministic:** a smoke run of 15 to 20 minutes at the real shape (4,000 VUs, 60 s plateaus, idle on) before the measuring scope would have found both limits: put it in scope 3's Done-when for any phase that ends in a long run. Also `realistic.sh` could print k6's memory per step (it has the poll) so a staircase says it is near its budget before the kill, and refuse a staircase whose request count would pass it.
- **Plan should have decided:** how far `s` may be lowered and who accepts that the baseline is then "the rate held at that s" (a knee that depends on `s` is a property of the 97 % rule, not of the server: 63 % CPU busy at the baseline); and whether 24,000 req/s, on the rule's edge (4 of 17 runs failed), is a baseline or an interval.
- **Blind spot:** nothing measures the stalls' cause outside the server (16 to 21 seconds over 100 ms per 5 minutes at 24,000 req/s, callbacks under 50 ms, no throttling): the sampler cannot tell k6 from the VM. Also the per-second series has no CFS throttling column (only the totals in `cpu.stat`), which is what explained the one stall that has a cause.

### Scope 6

- **Missing:** nothing. The brief's guess that the phase 2 README might have drifted was wrong: all three READMEs matched at once (the project manager had checked by hand).
- **Guessed:** that per-folder lines on stderr satisfy "print `ok` per folder" (a check's stdout is only its failure reason in `check.sh`); that a root with no script at all must fail (not in the brief).
- **Lost time:** about 5 minutes on the stale `full.done` file from an earlier session in the scratchpad (my wait loop ended at once and I read an old log), and I again launched the suite with a `&` inside `run_in_background`, which scope 5's own note warns against (the task "completed" at once; I polled the log instead).
- **Useless or contradictory instruction:** "see it fail first": the check passed on the real folders from its first run, so its red is a mutation of a README line, stated in "Verified".
- **Deterministic:** `lab/check.sh` could write its log to a fixed file plus a `done` marker that it deletes at start, so a waiter never mistakes an old run for the current one; and the ok-count floors in `check.sh` already need an edit per case (impression, as scopes 1 to 4).
- **Plan should have decided:** nothing for this scope.
- **Blind spot:** the check proves a README holds the script's lines, not that the prose around the tables (verdicts, predictions) still agrees with them: a number written in a sentence can drift unseen.
