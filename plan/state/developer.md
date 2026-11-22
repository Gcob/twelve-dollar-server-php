# Developer: phase 4, the realistic baseline

**State:** scope 2 done (commit 47e4728, on top of scope 1's `64af809`): `lab/realistic.sh` (staircase, hold, calibrate), the aggregator, the k6 copy of the bench's load.js, 8 new checks in `lab/check.sh` (full `bash lab/check.sh` 44/44 ok). Scope 1 stays as it was (challenge suite `passed=42 failed=0`, shellcheck clean).

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

1. Scope 3 (idle connections, eviction option in `lab_start_app`) and the measuring scopes build on `lab/realistic.sh`: `run_measured` is the one function that runs a k6 stream with its aggregator; the per-second table is `results.per_second` in the JSON (`agg_per_second` in `lab/macro/aggregate-lib.php`).
2. Before any measurement that counts: re-run `--calibrate` on a quiet VM (23 other projects' containers were running during these smoke runs) and set `--lag-gate`, `--vu-cap` and the scale from it.

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

## Questions for the project manager

- Nothing blocking. To settle before the measuring scope: k6 costs about 300 us of CPU per request with the CSV stream on (it falls with the rate), so 20,000 req/s takes about 5 to 6 of the 8 CPUs that k6 and the aggregator share. I did not measure above 2,000 req/s. If it does not fit on a quiet VM, the options are fewer tags per CSV row (k6's `systemTags`), or a lower top rate for the staircase; the cap and the scale ignore k6's CPU today.

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
