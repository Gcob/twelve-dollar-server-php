# Developer: phase 2, lab setup

**State:** scope 6 done (commit in the Passation du scope 6); scope 5 done, commit `13291fd`, fixed by `d2ff24e` (VUs and connections), review fixes `cc2ca4f` and `f5a122c`; scope 4 done, commit `8151a5e`, fixed by `cad0e84` (K processes per case); scope 3 `c584d41`; scope 2 `aef8c0b`; scope 1 `7643677`. Scope 1: "Done when" passes (seed OK, both files exist, `git status --porcelain` lists neither).

## Verified

- First run builds and prints `OK: ... content sha256 matches` (14 s on the M3 Pro, not a minute). **Proof:** `bash lab/seed.sh`, exit 0.
- A second run rebuilds and still prints OK, exit 0, `lab/data/` holds only `feed.db` and `tokens.json` afterwards (no `.build`, no `-wal`/`-shm`). **Proof:** `ls -a lab/data` after the run.
- Missing clone: `REFERENCE_DIR=/nonexistent bash lab/seed.sh` prints the FAIL message with the `git clone` command, exit 1, existing seed untouched. **Proof:** run output.
- Failing build: a fake `make-seed.sh` that does `exit 3` makes `lab/seed.sh` exit 3, removes `lab/data/.build`, and leaves the previous `feed.db` byte-identical (md5 before/after). **Proof:** run output.
- `git check-ignore -v lab/data/feed.db` reports `.gitignore:5:/lab/data/`.
- `lab/check.sh`: `ok` twice with a good seed (exit 0); with `feed.db` moved away, two `FAIL` lines, exit 1.
- No `/Users` path in `lab/` or `.gitignore`. **Proof:** `grep -rn "/Users" lab .gitignore` returns nothing.

## Supposé

- `shellcheck` is not installed on this Mac, so the scripts were not linted.

## Verified (scope 2)

- `bash lab/build.sh nope` exits 1 and prints `unknown variant: 'nope'. Known variants: 8.3-apt`. **Proof:** run output.
- Corrupted sha256 (`SHA256=00a97398...`): `docker build` fails at the `RUN bash /tmp/install.sh` step, `lab/build.sh` exits non-zero, no row appended. Restored afterwards (`grep ^SHA256` shows `b0a97398...`). **Proof:** run output.
- `bash lab/build.sh 8.3-apt` builds in 77 s (M3 Pro), row in `lab/results/build-times.md`.
- `bash lab/run.sh 8.3-apt php-info`: php 8.3.6, swoole 6.2.6, sqlite 3.45.1, opcache loaded, jit available, pdo_sqlite/mbstring/sodium/ffi/ctype/iconv all present.
- Limits through `lab/run.sh`: cpu.max `100000 100000`, memory.max `2147483648`, memory.swap.max `0`, `ulimit -n` 65535, `nproc` 1. `/lab` is read-only (touch fails), `/lab/results` writable.
- `bash lab/check.sh`: four `ok`, exit 0.
- No `/Users` in `lab/` or `.gitignore`.

## Verified (scope 3)

- Wrong PHP sha256: `docker build -f Dockerfile.src --build-arg PHP_VERSION=8.4.28 --build-arg PHP_SHA256=000...0 .` fails at `RUN bash /tmp/install.sh` with `php.tar.xz: FAILED` / `did NOT match`. **Proof:** run output.
- First 8.6 build failed in Swoole's `configure` (`Package 'libssl' ... not found`): fixed with `libssl-dev`, then Swoole's `make` failed on 8.6 (see results file). **Proof:** run output.
- `bash lab/run.sh <v> php-info`: 8.3.37, 8.4.28, 8.5.13 with `swoole: 6.2.6`, 8.6.0 with `swoole: not built`; all `sqlite: 3.45.1`, `opcache: loaded`, `jit: available`, the 6 extensions present, no warning on 8.6.
- `bash lab/check.sh`: 9 `ok`, exit 0 (seed 2, apt image, 4 source images, flags check, limits).
- Flags check fails (rc 1) when an image has no flags file (tried with `8.3-apt` in the compared set). A real difference in flags is detected by the string comparison (not exercised on a built image).
- No `/Users` path in `lab/`.

## Verified (scope 5)

- **Done when:** `bash lab/macro.sh --image 8.4 --server lab/servers/noop-swoole.php --rate 2000 --duration 30` (warm-up 10 s default), twice in a row: 60001 and 59998 requests, **38.67 and 37.63 us CPU/req**, p95 0.60 ms both, p99 1.58 and 1.47 ms, error rate 0.00 %, dropped 0, VUs used 13 and 6, memory.peak 14.2 and 12.1 MiB, VmHWM 27.6 and 25.8 MiB, k6 CPU 49.6 and 48.1 % of one CPU, VALID, rc 0. **Proof:** run output. (JSON of these trial runs not committed.)
- 8.3-apt, 2000 req/s, 5 s: 40.29 us/req, valid. A 500 req/s, 5 s run on 8.4 gave **76.5 us/req** (one run): the per-request cost is higher at a low rate; do not compare numbers taken at different rates.
- Invalid: `--rate 20000 --pre-vus 1 --max-vus 1 --duration 5`: 92479 dropped, `INVALID: ... dropped iterations`, JSON `valid: false`, rc 3, table and JSON still printed.
- Cleanup: macro.sh killed with TERM mid-run (rc 143), `pkill k6` mid-run (rc 1, k6 "terminated" in the message), broken k6 script (rc 1), 8.6 image without Swoole (server dies: `Class "Swoole\Http\Server" not found` printed, rc 1): in every case `docker ps -a` shows no `lab-macro-*` container afterwards.
- Refusals: `--port 8080` (taken on the VM by another project's container): `port 8080 is already in use`, rc 1, no container left; a pre-existing container named `lab-macro-k6`: refuses and does NOT remove it; `--server /etc/hosts` and a missing file: refused before any container starts.
- `bash lab/check.sh`: 15 `ok`, 33 s (3 new macro checks: valid noop run, invalid run, cleanup after failure).
- No `/Users` path in the committed files (grep).

## Passation du scope 5

- **Created:** `lab/macro.sh`, `lab/macro/probe.sh` (runs in the probe container), `lab/macro/k6/fixed-rate.js`, `lab/macro/fixtures/broken.js` (fixture of check.sh), `lab/servers/noop-swoole.php`. Changed: `lab/lib.sh` (`LAB_CPUSET_PROBE=0-1`, `LAB_K6_IMAGE`, `LAB_SERVER_PHP_FLAGS`), `lab/check.sh` (`check_macro_noop_is_valid`, `check_macro_marks_invalid_run`, `check_macro_cleans_up_after_failure`), README "Macro benchmarks".
- **Command:** `bash lab/macro.sh --image <v> --server <php file under lab/> --rate <req/s> --duration <s> [--warmup 10] [--script <k6 js under lab/>] [--out <path>] [--port 18080] [--path /] [--pre-vus 50] [--max-vus 200] [--php-ini key=value]...`. A server file or k6 script must be under `lab/` (mounted at `/lab`). Exit 0 valid, 3 invalid (printed and written), 1 failure, 2 usage. Needs `jq` on the Mac.
- **How `cpu.stat` is read (the brief's choice):** from outside the cgroup, by a third container `lab-macro-probe` (`php-lab:<image>`, `--cgroupns host --pid host`, CPUs 0-1), via `docker exec ... bash /lab/macro/probe.sh cpu|memory|port-open|http-answers`. The cgroup of a container is `/sys/fs/cgroup/docker/<full id>/` in this VM. So a read never lands in the server's or k6's CPU. The cost of a read was not measured (not needed). The server's idle cost is measured over 2 s after the warm-up and stored (`server_idle_usec_per_s`: 45 to 290 us/s in trial runs).
- **k6 runs as `docker exec` in a long-lived container** (`--entrypoint sleep`), not as the container's command: an exited container's cgroup is gone, so its `cpu.stat` could not be read after the run. Same container for the warm-up and the measured run; the deltas are taken around the measured run only.
- **k6 pin:** `grafana/k6:1.8.3@sha256:2cd9cd09...8e08` (multi-arch index digest, has arm64 and amd64). **Departure from the usual "latest":** latest is 2.4.0; the brief said 1.x, so I took the latest 1.x (1.8.3). Summary read from `--summary-export` with `--summary-trend-stats avg,min,med,p(90),p(95),p(99),max` on the command line (works with any `--script`). `dropped_iterations` is absent from the summary when 0 (read as 0). VUs used = `vus.max`.
- **Server port default is 18080, not 8080:** 8080 and 80 are taken on this VM's host network by other containers (another project's container publishes 8080; Traefik 80). A server that cannot bind dies, but the "wait until it answers" would have passed against the other server: macro.sh refuses a port that already accepts connections. `noop-swoole.php` reads `PORT` (default 8080 as the brief says); macro.sh passes it.
- **JSON** (`lab/results/macro-<server>-<image>-<rate>rps-<UTC stamp>.json`): `valid`, `invalid_reasons`, `host` (Docker Desktop, engine, VM kernel, cpusets, limits), `server` (image id, PHP, Swoole, flags), `k6` (image by digest, version, rate, VU counts), `results` (requests, achieved rate, `cpu_usec_per_request`, `latency_ms{avg,min,p50,p90,p95,p99,max}`, error rate, dropped, `vus_used`, `window_s`, server and k6 CPU % of one CPU, `server_throttled_usec`, idle, memory), `raw` (the four `cpu.stat` snapshots, memory files, k6's full summaries of the measured run and the warm-up). Nothing is rounded in the JSON; the table rounds to 2 decimals and reads the JSON back.
- **Memory:** `memory.peak` and `VmHWM` differ about 2x (12 vs 26 MiB): kept both as the brief asked, with the explanation labelled as a likely one, not checked. Both cover the server's whole life (warm-up included), not only the measured run.
- **Traps:**
  - Run macro.sh with nothing else on the VM: the Mac runs about 40 other containers; I ran no build or bench in parallel, but did not pause the others. The two 2000 req/s runs agreed within 3 %; scope 4's 2x swing did not show in them (2 runs only).
  - The window of the `usage_usec` delta is the time between two `docker exec` reads (30.3 s for a 30 s run), so it includes a few hundred ms of k6 start and stop.
  - Fixed names `lab-macro-{server,k6,probe}`: two macro runs at once refuse each other (on purpose: they would pollute each other's numbers). A `kill -9` leaves the containers; the error message gives the `docker rm -f`.
  - `printf` table is built from `jq @tsv` read into variables: a `null` would shift the columns, so nulls print as `n/a`.
  - `lab/check.sh` is now 33 s and needs `jq` and the k6 image (pulled on first use).
- **Commit:** `13291fd`.

## Passation du scope 5, reprise `d2ff24e` (replaces what it contradicts above)

- **Why:** the project manager's run on `8.3-apt` at 2000 req/s / 30 s dropped 36 iterations (INVALID) with 9 VUs used of 200.
- **Count with the old defaults (50 VUs, 8.3-apt, 2000 req/s, 30 s):** 4 of 5 runs had drops: 11, 1, 0, 1, 27 (max latency 20.9, 14.2, 12.3, 23.7, 39.6 ms). A 20 s run with 50 VUs: 24 drops (max 36.6 ms). Two of the three big ones fit "stall x rate - VUs": 36.6 ms x 2000 = 73 iterations - 50 VUs = 23 (24 dropped); 39.6 ms gives 29 (27 dropped). The small ones (1 to 11 drops with 14 to 24 ms) are not explained by it.
- **Cause (k6 source, v1.8.3, `lib/executor/ramping_arrival_rate.go` `activeVUPool.TryRunIteration`, used by `constant_arrival_rate.go`):** the iteration is a non-blocking send on an unbuffered channel to a VU goroutine parked on the receive; no parked VU, dropped. Parked VUs are served first-in first-out, so the iterations rotate over **all** pre-allocated VUs. A stall of tens of ms (the run's max latency; on the server or the VM, not located) piles up rate x stall iterations, and the ones beyond the VU count drop. The `vus` gauge max (4 to 20) is only the in-flight peak, which hid it.
- **Fix:** `--pre-vus` and `--max-vus` default to `rate / 10` (at least 50), both equal (an unplanned VU initializes during the run and drops iterations meanwhile). 200 VUs at 2000 req/s. **After:** 6 runs of the Done-when command on 8.3-apt: 6 valid, 0 dropped, including one with max latency 40.6 ms (stall absorbed as latency). Also 200 VUs 3/3 and 500 VUs 8/8 valid in earlier tests.
- **Connections:** open connections = pre-allocated VUs (measured: 50 VUs gave 50 connections, 500 gave 500, with 4 to 8 iterations in flight). The old "VUs used (open connections)" line was wrong. Now `results.vus_used` is documented as the in-flight maximum, and `results.connections_open` (max of 3 samples at 1/4, 1/2, 3/4 of the measured run; `connections_samples` keeps them) counts established sockets on the server's port from the probe (`probe.sh connections <port>`, reads `/proc/net/tcp`).
- **Does the connection count move the cost?** 8.3-apt, 20 s, 3 rounds of 50/200/500 VUs interleaved: 34.4 to 39.9, 34.8 to 36.2, 32.5 to 41.0 us/req: no visible effect in this noise.
- **Host drift worth knowing for scope 6:** the 6 runs of the Done-when command, back to back, gave **29.7, 30.3, 30.7, 31.7, 35.1, 39.9 us/req** (a 35 % climb over about 6 minutes, no code change). Earlier sessions: 37.6 to 43.5 on 8.4/8.3-apt. So a single run is not a number; the spread across runs on this Mac is about 30 %, and it can drift in one direction.
- Invalid message now says how long a stall the VUs absorb and the run's max latency. `lab/check.sh`: 15 `ok`.
- **Commit:** `d2ff24e`. Not changed: the validity rule (any dropped iteration is INVALID).

## Verified (scope 6)

- **Done when:** `lab/results/2026-11-21-noop-swoole/README.md` holds the prediction (written and saved at 16:07:29 UTC, before the first run at 16:07:38), the median and spread per rate, 3 interleaved repeats each, and the 9 raw JSON (+ the 9 printed `.txt`) next to it. **Proof:** the folder; run order in the README's second table.
- **All 9 runs valid on the first series** (rc 0, 0 dropped, 0 % errors), so no rerun and no harness change. 8.3-apt, 30 s after 10 s warm-up, order 1k 3k 6k x 3. Medians us/req: **50.20 (48.16..56.83) at 1k, 30.16 (29.90..30.44) at 3k, 21.66 (21.42..22.42) at 6k.** VmHWM 27.5 / 28.7 / 30.1 MiB, memory.peak 13.3 / 15.3 / 17.8 MiB at 100 / 300 / 600 connections.
- **Prediction:** 8 to 20 us at 3k did NOT hold (30.16, 51 % above the top; 3 runs within 2 %). Trend (1k above 6k) held, 2.3x. RSS under 50 MB held.
- No drift this time: 3k 29.90, 30.16, 30.44 over 6 min; 6k 21.66, 21.42, 22.42. One tail outlier: run 3 at 6k, max 82.9 ms, p99 3.9 ms, still valid.
- `bash lab/check.sh`: 15 `ok` after the series (run once, last).
- No `/Users` path in the folder (grep, README, JSON, txt, script).

## Passation du scope 6

- **Created:** `lab/results/2026-11-21-noop-swoole/` : `README.md` (Prediction, What was measured, Results, Environment, Did the prediction hold?, Surprising), `summarize.sh` (regenerates the two tables from the JSON with jq: `bash lab/results/2026-11-21-noop-swoole/summarize.sh`), `run-<rep>-<rate>rps.json` and `.txt` (9 each). Nothing changed in `lab/macro.sh` or the server: no harness bug found.
- **Decisions en route:** the series loop was a scratchpad script (not committed; the README lists the commands). I renamed the printed tables from hidden `.log-*` files to `run-*.txt`. The JSON `date` is the end of the run: the README column is labelled "Written (UTC)". `summarize.sh` is an addition to the brief (it makes the tables checkable).
- **Traps:** the host was not quiet: 49 containers of other projects running on the VM (not paused), load average 8.2 before and 5.0 after, Virtualization.framework at about 125 % of a CPU before the first run. The numbers were tight anyway; the README says so. A phase 3 comparison should reuse the same rates (1k, 3k, 6k) and the same interleaving. k6 uses 89 % of one CPU at 6k (8 CPUs available): at 12k and above, check that k6 is still not the limit.
- **Hypotheses labelled as such in the README, not checked:** the rate-independent part (about 34 ms of CPU/s from a line through 1k and 6k) comes from per-wake-up work.
- **Commit:** `c3a487b`.

## Passation du scope 5, reprise review (`cc2ca4f`, `f5a122c`)

- **`cc2ca4f` (R1, R2):** `LAB_SERVER_PHP_FLAGS` now ends with `-d opcache.file_update_protection=0 -d zend.assertions=-1`; `micro_ini_flags()` pins `zend.assertions=-1` and `INI_REPORTED` reads it back (`runs[].ini["zend.assertions"]` is `-1` on 8.3-apt and 8.4, checked with a quick run). `lab/macro.sh` now records `server.ini` in the JSON: the ini values PHP reads back with the server's flags in the probe container (`opcache.enable_cli`, `opcache.jit`, `opcache.jit_buffer_size`, `opcache.file_update_protection`, `zend.assertions`, `memory_limit`) plus `jit_on`. It does not prove the server file itself was cached (that would need the server to report it); the flag removes the cause. README says both flags and why. **Effect on earlier numbers:** the first number (scope 6) and the 2,000 req/s trial runs ran without these two flags; the server file was always older than 2 s then, and the noop server has no `assert()`, so no effect expected, not re-measured.
- **`f5a122c` (R4, R7), docs only:** confound sentence in the results README (no number changed; cites the 50/200/500 connection test as pointing the other way, taken at one rate); root README links `lab/README.md`; `lab/README.md` has a "Prerequisites (on the Mac)" section (Docker Desktop, Node 18+ (24 here, upstream says `>= 18`), sqlite3, jq, the clone, curl/git/shasum) and the seed time is "about 15 seconds on an M3 Pro" (measured 14 s).
- `lab/check.sh`: 15 `ok` after the first commit. Not touched, as asked: late failure report in `macro.sh`, the Swoole pin in two places.

## Passation du scope 5, reprise blind review (`095e7e8`, `ec0f3fa`)

- **`095e7e8` (B1):** `micro_summarize()` now scans all the processes and returns the first one that is not `ok` (status, message with "(process N, the ones before it passed)" when N > 1, and `procs`); the per-process `status` is kept in the JSON (`array_diff_key` strips only `case`). Fixture `lab/micro/benches/failing-check-later.php` (check passes in the first process, fails in the next: a file in the container's temp folder, new per `micro.sh` run) and `check_micro_skips_case_failing_in_later_process` (16 `ok` in `lab/check.sh`). **Seen failing first:** with the old `micro_summarize` the case printed a normal row (5.9 ns, `5.9 .. 5.9`), no SKIPPED; with the fix it prints `SKIPPED, check failed: ... (process 2, ...)`. A bench that writes to its database copy still has to recopy it itself: the harness now skips it instead of ranking it.
- **Docs commit (B2 to B10):** `lab/NOTICE.md` holds the challenge's MIT text (copyright "arjaythedev and the challenge contributors"; the entry has no license of its own); the two adapted files carry a two-line credit pointing to it. I did not paste the full license into each file. "both Swoole entries" is now "mattsplat's" everywhere, with tzimpel's differences listed in `lab/README.md` (its `php.ini`, `reactor_num`, `open_tcp_nodelay`, `backlog`, `package_max_length`). `lib.sh` says 2 GiB is not the VM's budget. Micro README: "about 41 s per image and JIT state". `fixed-rate.js` header and defaults match `macro.sh` (default `rate / 10`, at least 50, `MAX_VUS` = `PRE_VUS`; checked with `k6 inspect`: 200/200 at 2000). `noop-swoole.php` header lists the 7 flags. `CFLAGS=-O2` comment now quotes what `dpkg-buildflags` prints in the 8.3-apt image (frame pointers, LTO, stack protector, branch protection). Results README: harness at `c3a487b`, idle measured over 2 s after each run's warm-up, and the prediction line pointing to `85978ab`. No result number changed.

## Impasses

- `sqlite3 lab/data/feed.db "SELECT count(*) ..."` on this Mac leaves `feed.db-wal` and `feed.db-shm` behind (the file is in WAL mode, the last connection does not clean up). `-readonly` fails on it ("unable to open database file"). Fix kept: open with the URI `file:<path>?immutable=1`, which reads without creating anything.

## Décisions en route

- `REFERENCE_DIR` env var overrides the clone path (default `lab/../reference/twelve-dollar-server-challenge`), as the brief suggested for the failure test.
- Build folder is `lab/data/.build/`; the three files are copied with the layout `seed/generate.mjs`, `seed/make-seed.sh`, `schema.sql`, so `make-seed.sh`'s `../schema.sql` resolves.
- The previous seed is removed only after `make-seed.sh` succeeded (a failed build never replaces a good seed).
- `lab/seed.sh` also checks that the three source files exist, so a wrong `REFERENCE_DIR` gives a clear message.

## Passation du scope 1

- **Created:** `lab/seed.sh`, `lab/check.sh` (functions `check_seed_files_exist`, `check_seed_has_posts`, list in `CHECKS`; add a check = write `check_<name>` and add it to `CHECKS`), `lab/README.md` (sections "Seed" and "Checks"), `.gitignore` line `/lab/data/`.
- **Trap:** the last line printed by `make-seed.sh` shows the temporary path of the build (`.../lab/data/.build/seed/feed.db`), which no longer exists after the run. Passed through as the brief asked; the real file is `lab/data/feed.db`. Do not use that printed path.
- **Trap:** any `sqlite3` open of `lab/data/feed.db` without `?immutable=1` creates `-wal`/`-shm` next to it. Later scopes that copy or mount `lab/data/feed.db` should copy it per run anyway (the upstream script says never to serve feed.db directly).
- `lab/check.sh` has no `set -e` on purpose (it must run every check and exit non-zero at the end).
- **Commit:** `7643677`.

## Décisions en route (scope 2)

- sha256 of the Swoole 6.2.6 tarball: `curl -fsSL <github archive url> | shasum -a 256`, done twice, same value `b0a97398d50dc9442d48a71238cafa5f75d2c53d2e35d12a59235f9d52dab718`. Not compared with an independent source (GitHub publishes none for archive tarballs).
- Ubuntu digest pinned is the **multi-arch index** digest `sha256:9c7f200c...3289` of `ubuntu:24.04` (from `docker buildx imagetools inspect`), so the same Dockerfile works on arm64 here and amd64 on the bench VM.
- Layout: `lab/images/Dockerfile.<variant>`, build context `lab/images/` (the Dockerfile copies `install-php83-apt.sh` and `php-info`). Scope 3 adds `Dockerfile.8.3`, ... and puts the variant name in `LAB_VARIANTS`.
- `php-info` is a bash script wrapping `php -r`; it turns on `opcache.enable_cli=1 opcache.jit=tracing` for its own probe, because JIT only reports `on` then. Lines are `name: value`, missing is `missing`.
- `lab/run.sh` mounts `lab/` at `/lab` read-only plus `lab/results` and `lab/data` read-write (data rw so a bench can open SQLite; copy feed.db per run anyway).
- `lab/results/build-times.md` is committed (a table the plan can cite). Docker Desktop version comes from `docker version --format '{{.Server.Platform.Name}}'` (`Docker Desktop 4.76.0 (228118)`; the brief said Docker Desktop 29, that is the engine version 29.5.2).
- `lab/lib.sh` exports `LAB_IMAGE`, `LAB_VARIANTS`, `LAB_CPUSET_SERVER=2`, `LAB_CPUSET_K6=4-11`, `LAB_RESOURCE_FLAGS`, `lab_require_variant`.

## Passation du scope 2

- **Created:** `lab/lib.sh`, `lab/build.sh`, `lab/run.sh`, `lab/images/{Dockerfile.8.3-apt,install-php83-apt.sh,php-info}`, `lab/results/build-times.md`, checks `check_image_8_3_apt` and `check_run_limits` in `lab/check.sh`, README "Images".
- **Trap:** `lab/check.sh` now needs Docker running and the image built; a fresh clone must run `lab/seed.sh` and `lab/build.sh 8.3-apt` first.
- **Trap:** `--network host` needs "host networking" enabled in Docker Desktop for the server to be reachable from the Mac; not needed for scope 2 checks, scope 5 must verify it.
- **Trap:** `ubuntu:24.04` digest pin: if the base image is ever bumped, change the digest in every Dockerfile.
- **Commit:** `aef8c0b`.

## Passation du scope 3

- **Created:** `lab/images/Dockerfile.src` (args `PHP_VERSION`, `PHP_SHA256`, `WITH_SWOOLE`), `lab/images/install-php-src.sh` (the flags, one-line why each, the Swoole build), `lab/results/swoole-on-php-8.6.md`. Changed: `lab/lib.sh` (`LAB_VARIANTS` now `8.3-apt 8.3 8.4 8.5 8.6`, `LAB_SOURCE_VARIANTS`, `lab_source_release <variant>` = "version sha256 with_swoole", the one place to bump a patch release), `lab/build.sh` (source variants, `all`), `lab/images/php-info` (`swoole: not built`, no startup warning when there is no `swoole.so`), `lab/check.sh` (`check_image_8_3` ... `check_image_8_6`, `check_source_flags_match`), README "Images" table.
- **Images:** `php-lab:8.3` = PHP 8.3.37, `8.4` = 8.4.28, `8.5` = 8.5.13, all with Swoole 6.2.6; `8.6` = PHP 8.6.0 **without Swoole** (6.2.6 and 6.3.0-rc2 both fail: `#error "require PHP version 8.5 or earlier"` and removed PHP APIs, details in `lab/results/swoole-on-php-8.6.md`). `lab/lib.sh` has `with_swoole=0` for 8.6: if a Swoole release supports 8.6, flip it to 1 and bump the pin in `install-php-src.sh` (and in `install-php83-apt.sh`: the pin is duplicated).
- **Checksums:** PHP tar.xz sha256 come from `https://www.php.net/releases/?json&version=<branch>` read on 2026-11-21 (8.3.37 `0237af84...`, 8.4.28 `0c8ec360...`, 8.5.13 `607602ac...`, 8.6.0 `5f84beaa...`), pinned in `lab/lib.sh`, and checked by `sha256sum -c` in the build. Swoole 6.3.0-rc2 `3065da13...` computed with `curl | shasum` twice (information only, not in the repo).
- **SQLite:** `libsqlite3-dev` of Ubuntu 24.04, 3.45.1, same as `8.3-apt` (checked in `lab/check.sh`).
- **Flags:** `CFLAGS=-O2 --prefix=/usr/local --with-config-file-path=/usr/local/etc/php --with-config-file-scan-dir=/usr/local/etc/php/conf.d --disable-cgi --disable-fpm --enable-opcache --with-pdo-sqlite --enable-mbstring --with-sodium --with-ffi --enable-ctype --with-iconv`. Everything else is configure's default (dom, xml, sqlite3, tokenizer, filter, session...), no OpenSSL, no zlib, no sockets. The full list is saved in the image at `/usr/local/etc/php/configure-flags`; `lab/check.sh` compares it across the 4 images.
- **Traps:**
  - `--enable-opcache` is accepted but ignored from 8.5 (configure prints `unrecognized options: --enable-opcache`, harmless). Up to 8.4 OPcache is `opcache.so` loaded by `conf.d/opcache.ini`; from 8.5 it is built in. The install script writes the ini only when `opcache.so` exists.
  - Source builds ship no `php.ini`: the servers must pass their settings with `-d` (like `php-info` does).
  - `libssl-dev` is installed only because Swoole's configure demands it (`PKG_CHECK_MODULES libssl`); PHP is not built with OpenSSL.
  - `php -i` does not show `CFLAGS` in "Configure Command", hence the flags file. The compile line in the build log shows `-O2`.
  - `build.sh all` builds one after the other (a build is about 2 to 3 min, never in parallel, so the table is honest). `make -j` is capped at 8.
  - The apt image keeps the old `php-info` baked in until it is rebuilt (the new one only differs for a missing swoole.so).
- **Build times (sequential, M3 Pro, 8 jobs):** 8.3 197 s, 8.4 168 s, 8.5 136 s, 8.6 97 s (no Swoole). The first set of rows was dropped from `build-times.md` after I added the flags file and rebuilt all four.
- **Commit:** `c584d41`.

## Verified (scope 4)

- `bash lab/micro.sh lab/micro/benches/sample.php`: 10 runs (5 images x JIT off/on), every case `ok`, 83 s, rc 0, JSON `lab/results/micro-sample-20261121-1504.json`. In the JSON JIT off reports `on: false`, JIT on reports `on: true, kind: 5 (tracing), buffer_size 67108848` on all 5 images. **Proof:** run output, python read of the JSON.
- Failing check: `lab/micro/benches/failing-check.php` prints `SKIPPED, check failed: expected 4, got 3` for the wrong case, still times the right one and the empty loop, rc 0. (Seen failing first: the first draft crashed on an undefined constant, then passed.)
- JIT mismatch: `--jit on --jit-buffer-size 0` prints `micro: JIT requested on but it is off (opcache.jit=tracing, opcache.jit_buffer_size=0)`, rc 2, no JSON written.
- Unknown image (`--images 8.4,nope`) rc 1 before any container starts, lists the known variants.
- `opcache.jit=disable` is accepted on 8.3.6, 8.3.37, 8.4, 8.5, 8.6 (status `enabled: false`), so no `jit_buffer_size=0` trick is needed for "off".
- OPcache in the CLI: no `opcache.file_cache`; the cache is the process's own shared memory. A file modified less than 2 s ago is NOT cached with the default `opcache.file_update_protection=2` (tested: `opcache_is_script_cached` false, true once the mtime is 10 s old). **Proof:** `php -d opcache.enable_cli=1 -r` in the 8.4 image.
- SQLite path: a throwaway bench with `new PDO('sqlite:' . micro_feed_copy())` ran (`count posts` about 509 us/op); `lab/data` held only `feed.db` and `tokens.json` afterwards. The bench was deleted, not committed.
- `bash lab/check.sh`: 12 `ok`, exit 0, 8.5 s (the 3 new micro checks use `--quick` on 8.4 only).
- No `/Users` path in the committed files (grep).

## Passation du scope 4

- **Created:** `lab/micro.sh`, `lab/micro/micro.php` (orchestrator + worker in one file), `lab/micro/benches/sample.php`, `lab/micro/benches/failing-check.php` (fixture of `lab/check.sh`), `lab/results/micro-sample-20261121-1504.json` (the first run, not quick). Changed: `lab/check.sh` (`check_micro_sample`, `check_micro_skips_failed_case`, `check_micro_refuses_wrong_state`), README "Micro benchmarks".
- **Bench format:** the file returns `['case name' => ['setup' => fn() => $ctx (optional), 'run' => fn($ctx) => $result, 'check' => fn($result, $ctx) => true|false|string message]]`. `check` and `run` are required closures. The harness adds a built-in `(empty loop)` case, first row of every run, never subtracted. `micro_feed_copy()` (defined by the worker before the bench is required) returns a per-container copy of `/lab/data/feed.db`.
- **Design decision:** one fresh PHP process per case (worker), so the tracing JIT's trace of the timing loop is not shared between cases. The orchestrator runs without OPcache and starts `PHP_BINARY -d <flags> micro.php --worker ...`; the ini flags live in `micro_ini_flags()` in `micro.php`. Only `opcache.jit` differs between on and off (buffer 64M in both).
- **Timing:** warm-up 1 s (100 ms quick) that also calibrates N for about 100 ms per repeat (10 ms quick), 10 repeats, median (mean of the 2 middle values), spread = min and max, the JSON keeps the 10 sorted repeats.
- **Output:** table on stdout (header printed once, by the first container); JSON = `{date, command (repo path written `.`), bench, host{docker, arch, cpuset, limits}, runs[{image, image_id, php_version, jit, jit_state, ini, opcache_cache, timing, cases[]}]}`. `image_id` is the local image id (`docker image inspect -f '{{.Id}}'`): a local build has no registry digest.
- **Exit codes:** bad argument or unknown/missing image or bench outside `lab/`: 1. JIT state not the requested one, OPcache off, or script not cached: 2 (fails the whole `micro.sh`, nothing written). A case whose check fails or that throws: reported as SKIPPED, rc stays 0.
- **Traps:**
  - The bench file must be under `lab/` (mounted at `/lab`); `micro.sh` rejects others.
  - Per-run temp folder `lab/results/.micro-<pid>/` is removed by a trap; a killed run may leave it.
  - Spread is wide on cheap cases under load (8.3-apt JIT off empty loop `11.8 .. 42.9` once): another process on the Mac disturbs it. Re-run, and compare medians only when the spread is narrow.
  - `--quick` output is not a result (file name carries `-quick`, JSON `timing.quick: true`).
  - Cases whose JIT-on median is higher than JIT-off exist (json_encode on 8.4: 120 vs 109 is within noise): do not read a gain from one case.
- **First numbers (median ns/op, JIT off / on):** empty loop 11.4 to 13.2 / 4.4 to 5.4; `ctype_digit "12345"` 20.6 to 22.5 / 12.6 to 13.6; `json_encode` small array 102 to 120 / 93 to 109. The JIT removes most of the loop cost, so cheap-case gains are partly the loop's.
- **Commit:** `8151a5e`.

## Passation du scope 4, reprise `cad0e84` (replaces what it contradicts above)

- **Why:** the project manager saw the same case swing 2x between processes (`ctype_digit "12345"` 27.8, 13.5, 28.0, 27.3 ns), hidden by the within-process spread. Each case now runs in K processes (`--procs`, default 5, quick 2), **round by round, both JIT states inside each round** (`micro.php` orchestrator loops `for p, for state, for case`). One container per image now (not per image and JIT state); `micro.sh` passes `--jit both` and `--out-dir`, the container writes `<image>-<state>.json`, `micro.sh` assembles them as before.
- **Reported:** `median_ns` = median of the per-process medians; `min_ns`/`max_ns` = min and max of those; `max_over_min`; `unstable` = max/min > 1.3 (`UNSTABLE_RATIO` in `micro.php`; table note `UNSTABLE xR`). `procs[]` in the JSON keeps each process's `median_ns`, `min_ns`, `max_ns` (within-process), `iterations`, `repeats_ns`. `iterations` in the table = median of the processes' N.
- A case whose check fails or that throws is run once, then not repeated; reported SKIPPED, rc 0.
- Table is printed at the end of an image's rounds (progress lines `process round p of K` go to stderr). A full 5-image run takes about 8 min.
- **README:** the finding with the numbers, hypotheses labelled as such, the ASLR experiment.
- **ASLR experiment (once):** `setarch -R` is refused by the default seccomp profile, so I ran `docker run --security-opt seccomp=unconfined` by hand (outside `lab/run.sh`; script in my scratchpad), 8.4, JIT on, `ctype_digit "12345"`, 12 workers with and 12 without ASLR, alternating. Addresses checked fixed with `setarch -R`. ASLR on: 27.4 28.2 27.5 13.2 13.1 28.0 28.2 13.1 27.2 26.7 28.8 28.3. ASLR off: 27.6 26.7 27.4 28.2 27.0 28.2 13.1 27.1 28.5 27.0 27.5 27.2. Bimodal (about 13 and 27 ns) both ways: ASLR does not explain it. The new full run shows the slow mode with JIT off and on the empty loop too (8.3-apt JIT off `12.0 .. 25.4`), which favours a host/core effect over a JIT one; not proven, and not pursued further.
- **Full run `lab/results/micro-sample-20261121-1512.json`** (replaced the 1504 file): rc 0, 40 rows, 31 of them UNSTABLE; that run caught the slow mode more often than any earlier one (many medians are the slow-mode value). **Consequence for phase 4:** a version or JIT comparison from this harness is only readable when the case is not UNSTABLE, or from the per-process medians. Running with more `--procs`, or on the bench VM, will probably be needed.
- `lab/check.sh`: 12 `ok` (the table-row regex accepts the `UNSTABLE` note).
- **Slip:** I ran `git rm --cached` on the old JSON twice by mistake, and put it back with `git restore --staged` (no content lost); nothing else in the index was touched.
- **Commit:** `cad0e84`.

## Apprentissages bruts

- Upstream `make-seed.sh` takes 14 s here, so the "about a minute" in the brief is pessimistic (proof: `time` output above).
- The `OK:` line prints `$DB`, which is the build folder path, because upstream builds in place. If a later scope wants a truthful line, print its own after the move.

- (scope 2) Cold image build is 77 s: apt about a third, Swoole compile the rest. Proof: `built php-lab:8.3-apt in 77s`.
- (scope 2) A build with a bad checksum leaves no row in `build-times.md` because `set -e` stops before it.

- (scope 4) The first draft put `exit(...)` at the top of `micro.php`, before the constants and functions: constants declared after it do not exist yet. The entry call goes last (a `// Why last` comment says so). Proof: `Undefined constant "INI_REPORTED"` on the first run.
- (scope 4) `continue` in a PHP `do ... while` jumps to the loop condition, which `micro_calibrate` relies on.

## Où regarder

- `lab/macro.sh` : arguments, the three containers, the jq program that builds the JSON (`results`), the table. `lab/macro/probe.sh` : what is read from outside the cgroups. `lab/macro/k6/fixed-rate.js` : the default k6 scenario. `lab/lib.sh` → `LAB_K6_IMAGE`, `LAB_SERVER_PHP_FLAGS`, `LAB_CPUSET_PROBE`. `@13291fd`
- `lab/servers/noop-swoole.php` : the floor server (reads `PORT`). A phase 3 server goes next to it and is passed with `--server`. `@13291fd`
- `lab/seed.sh` : build + move logic, `REFERENCE_DIR` override. `@7643677`
- `lab/lib.sh` : CPU layout, limits, variants. `lab/run.sh` : the one way to run in an image. `@aef8c0b`
- `lab/images/install-php83-apt.sh` : reusable as a submission `install.sh`. `@aef8c0b`
- `lab/check.sh` → `CHECKS` : where later scopes add smoke checks. `@7643677`
- `lab/micro/micro.php` : `micro_ini_flags()` (the OPcache/JIT flags), `micro_worker()` (checks, timing), `micro_orchestrator()` (rows, JSON). `lab/micro.sh` : arguments, one container per (image, JIT), JSON assembly. `@8151a5e`
- `lab/micro/benches/sample.php` : the format in use; a phase 4 bench is a new file next to it. `@8151a5e`
- `reference/twelve-dollar-server-challenge/seed/make-seed.sh` : upstream, reads `$HERE/../schema.sql`, writes `$HERE/feed.db` and `$HERE/tokens.json`. `@7643677`

## Prochaines étapes

00. (scope 5 done) Scope 6: `bash lab/macro.sh --image <v> --server lab/servers/noop-swoole.php --rate 2000 --duration 30 --out <path>`, repeat it (the JSON keeps every raw number, including both `cpu.stat` snapshots and k6's full summaries) and compare the files; no build or bench during a measured run. See the passation of scope 5 for the exit codes and the port.

0. (scope 4 done) Scope 5 (macro harness) and phase 4 benches: `bash lab/micro.sh lab/micro/benches/<step>.php`; see the passation of scope 4 for the bench format. (scope 3 done) Scope 4: the micro harness runs on `php-lab:8.3-apt`, `8.3`, `8.4`, `8.5`, `8.6`; Swoole entries cannot run on 8.6.

1. Scope 3: add `Dockerfile.<v>` and the name in `LAB_VARIANTS` (`lab/lib.sh`); `lab/build.sh` and `lab/run.sh` need no change. Add a `php-info` check per variant in `lab/check.sh`.
2. Scopes 4 and 5: run through `bash lab/run.sh <variant> <cmd>`; `lab/data` and `lab/results` are writable at `/lab/data` and `/lab/results`.

## Questions pour le chargé de projet

Rien.

## Rétro

### Scope 1

- **Ce que j'ai deviné :** that the "final line pass-through" means printing upstream's line as is, even though it shows the build path (impression, no confirmation).
- **Où j'ai perdu du temps :** the `-wal`/`-shm` files that appeared after `lab/check.sh` ran `sqlite3` on the WAL database, found only because I listed `lab/data` after the check. The brief only asked to check the seed script.
- **Ce qui aurait pu être déterministe :** `shellcheck` is missing on the Mac; add it to `lab/` tooling (`brew install shellcheck`) and a check in `lab/check.sh` that lints `lab/*.sh` when available.
- **Ce que le plan aurait dû trancher :** whether the printed `OK:` path should be truthful (see Apprentissages).

### Scope 2

- **Ce que j'ai deviné :** that a multi-arch index digest is the right pin (works on arm64 and amd64); that committing `lab/results/build-times.md` is wanted.
- **Où j'ai perdu du temps :** nowhere significant; the build is 77 s.
- **Ce qui aurait pu être déterministe :** the shellcheck lint (still not installed); the sha256 could be compared with a second source if one existed.
- **Ce que le plan aurait dû trancher :** "Docker Desktop 29" vs the real app version 4.76.0 (29 is the engine): which one the table should show.

### Scope 3

- **Ce que j'ai deviné :** that "the same configure flags" means configure's defaults plus the listed ones (not `--disable-all`); that `tar.xz` is the tarball to pin (php.net publishes gz, bz2 and xz checksums); that `build.sh all` should be sequential.
- **Où j'ai perdu du temps :** the first 8.6 build failed on `libssl` (Swoole configure, not an 8.6 problem), and I overwrote the build log of the real 8.6 Swoole failure, so I had to re-run it in the image (cheap). Rebuilding all four images (about 10 min) after I noticed `php -i` hides `CFLAGS`.
- **Ce qui aurait pu être déterministe :** the flags check could have been designed with the flags file from the start; a one-line `docker run` test of Swoole against a PHP version (`try-swoole.sh` in my scratchpad) would make a future "does Swoole X build on PHP Y" repeatable: worth moving to `lab/` if phase 4 needs it.
- **Ce que le plan aurait dû trancher :** which PHP extensions the entries may use (configure defaults vs a minimal `--disable-all` build), and whether `8.3-apt` vs `8.3` should also share a `php.ini`.

### Scope 4

- **Ce que j'ai deviné :** that a failed check should leave the exit code at 0 (reported and skipped, as the brief says) while a wrong JIT state exits 2; that one process per case is worth the 30 ms (JIT trace sharing between cases, reasoned from how the tracing JIT works, not measured); that `image_id` (local image id) is what "image digest" means for a locally built image.
- **Où j'ai perdu du temps :** the first version (one process per case, spread only inside a process) hid a 2x swing between processes; a second run of the same command would have shown it. Lesson: any harness must be run twice and the two runs compared before the numbers are trusted. The full run was 83 s then, about 8 min now. One crash (constant defined after the `exit`) found on the first run.
- **Ce qui aurait pu être déterministe :** a quick comparison of "all cases in one process" vs "one process per case" would prove the isolation choice; I did not run it. `shellcheck` is still missing for `lab/micro.sh`.
- **Ce que le plan aurait dû trancher :** whether a skipped (failed check) case should fail the run for automation; the noise threshold above which a spread makes a result unusable (I wrote "10 to 15 %" in the README as a rule of thumb).

### Scope 5

- **Ce que j'ai deviné :** that the latest 1.x (1.8.3) is wanted when `latest` is 2.4.0; that a default port other than 8080 is acceptable (8080 was taken); that exit code 3 for an invalid run is wanted (the brief said "printed but marked invalid" and did not say the exit code); that a refusal when a `lab-macro-*` container exists is better than removing it.
- **Où j'ai perdu du temps :** nowhere significant. The one real surprise was port 8080 already in use on the VM's host network, found by the first test run (it would have made the "wait until it answers" pass against another server). The rest worked at the first run: the probe design (`--cgroupns host --pid host`) was checked by hand before writing the script.
- **Ce qui aurait pu être déterministe :** `shellcheck` is still missing (the script is 280 lines of bash). A `lab/doctor.sh` that lists what the lab needs (jq, Docker host networking, free port, k6 image) would replace the notes spread over the READMEs.
- **Ce que le plan aurait dû trancher :** which exit code an invalid run has, and whether the lab may assume the VM's ports 80 and 8080 are free (they are not on this Mac); the k6 major version (1.x vs 2.x).

- (scope 5, reprise) I ran my own "Done when" twice and called it reliable: two runs cannot show a drop that happens in 4 of 5. For any "must hold reliably" criterion, run it 5 times before saying it passes. Proof: the first handover claim vs 4 of 5 runs dropping.

### Scope 6

- **Ce que j'ai deviné :** that the printed `.txt` of each run is worth committing next to the JSON (not asked); that a small `summarize.sh` in the results folder is welcome; that the README may say "MiB" for the RSS (the prediction said MB, I gave both).
- **Où j'ai perdu du temps :** nowhere significant. One slip: a `sed -i` without the empty suffix argument (macOS) broke an `&&` chain and half of the README heredoc was skipped, caught because I read the section titles afterwards. Use `perl -pi -e` here.
- **Ce qui aurait pu être déterministe :** a `lab/series.sh <dir>` (interleaved rates x repeats, one command) and a summary script in `lab/` instead of a scratchpad loop; the next series (phase 3) will need both.
- **Ce que le plan aurait dû trancher :** whether a prediction that fails by 50 % (30 vs 8 to 20) should trigger a closed-loop run to compare with the prior art on equal terms (not done: out of scope).
