# Phase 2: lab setup

**Done when:** a no-op Swoole server in the lab container gives a CPU µs/req number from the macro harness at a
fixed request rate, and the micro harness runs on PHP 8.3, 8.4, 8.5 and 8.6 (or a documented failure for a version
that can't build Swoole). Then the run stops: no phase 3 (D12).

Everything lives in `lab/` at the repo root. Generated data (`lab/data/`) is ignored by git. Measured results are
committed in `lab/results/`, one folder per measurement, with the raw outputs.

## Scopes

| #   | Commit                                                         | Done when                                                                                                                                                                 |
|-----|----------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| 1   | `chore(seed): build the seed database outside git`             | `lab/seed.sh` prints `OK: … content sha256 matches`, `lab/data/feed.db` and `lab/data/tokens.json` exist, and `git status --porcelain` lists neither                       |
| 2   | `feat(lab): PHP 8.3 lab image with Swoole 6.2.6`               | `lab/build.sh 8.3-apt` builds `php-lab:8.3-apt`; `lab/run.sh 8.3-apt php-info` prints PHP 8.3, Swoole 6.2.6, SQLite and OPcache; the limits check prints 1 CPU, 2 GiB, no swap, 65535 fds |
| 3   | `feat(lab): PHP 8.3 to 8.6 from source with Swoole`            | `lab/build.sh <v>` builds `php-lab:<v>` for 8.3, 8.4, 8.5 and 8.6 from sha256-pinned php.net tarballs; `lab/run.sh <v> php-info` prints each version with Swoole 6.2.6, or the build failure is documented and the image builds without Swoole |
| 4   | `feat(lab): micro benchmark harness, JIT on and off`           | `lab/micro.sh lab/micro/benches/sample.php` prints, for every image and JIT on and off, the median ns/op and its spread, and fails if the JIT state isn't the one requested |
| 5   | `feat(lab): macro harness with k6 and a no-op Swoole server`   | `lab/macro.sh` against the no-op server at 2,000 req/s for 30 s prints requests, µs CPU/req, p95, p99, error rate, dropped iterations and peak RSS, with 0 errors and 0 dropped iterations |
| 6   | `docs(lab): first number, the no-op Swoole server`             | `lab/results/<date>-noop-swoole/README.md` holds the prediction (written before the run), then the median µs/req and spread per rate, 3 interleaved repeats each, raw outputs next to it |

Vertical slices: each scope ends with a command that answers. Scope 5 brings the no-op server because the macro
harness can't be checked without a server to load.

**The lab's suite:** `lab/check.sh`, started in scope 1, each scope adds its smoke check (seed present, images print
their versions, a 1-iteration micro run, a 5 s macro run). It's the "full suite" of the skill, run before the reviews.

## Shared rules for every scope

- **Docker Desktop on the Mac** (arm64, 12 vCPUs in its VM, cgroup v2). Every container that measures runs with
  `--cpus=1 --memory=2g --memory-swap=2g --ulimit nofile=65535:65535 --network host` and a `--cpuset-cpus` pin
  (D7, [measuring.md](measuring.md)).
- **CPU layout in the Docker VM:** server on CPU 2, micro benches on CPU 2, k6 on CPUs 4 to 11. CPUs 0 and 1 stay to
  the VM's own work. One place defines it (a `lab/lib.sh` or equivalent), every script reads it.
- **Pinned versions:** every download has its sha256 in the repo, and the build fails if it doesn't match. Images by
  tag plus digest where the registry gives one (k6, Ubuntu).
- **Public repo:** no absolute `/Users/...` path, no email, no account id in committed files. Paths relative to the
  repo root.
- **`reference/` is read-only:** scripts copy what they need out of it, they never write into it.
- **Build times:** each image build records how long it took (`lab/results/build-times.md`): phase 5 needs it to
  judge the install time of a PHP compiled from source.

## Scope 1: seed

- **Seam:** `lab/seed.sh`.
- **What:** copy `seed/generate.mjs`, `seed/make-seed.sh` and `schema.sql` from `reference/twelve-dollar-server-challenge/`
  into a temporary build folder under `lab/data/`, run it there, keep `feed.db` and `tokens.json` in `lab/data/`,
  remove the rest. Node 24 and sqlite3 3.54 on the Mac.
- **Cases:** a second run rebuilds and still prints OK; the script fails loudly when `reference/` is missing (it says
  how to clone it); `lab/data/` is in `.gitignore`.

## Scope 2: PHP 8.3 image

- **Seams:** `lab/build.sh <variant>`, `lab/run.sh <variant> <command…>`, the `php-info` command inside the image.
- **What:** Ubuntu 24.04 (pinned digest), apt `php8.3-cli php8.3-dev php8.3-sqlite3 php8.3-mbstring php8.3-opcache`,
  Swoole 6.2.6 built from its GitHub source tarball, sha256 pinned, `./configure --disable-brotli --disable-zstd`, like
  `reference/twelve-dollar-server-challenge/submissions/php-swoole-mattsplat/install.sh`. The install is a script
  the Dockerfile runs, so phase 5 can reuse it as `install.sh`. Swoole isn't enabled globally: the server loads it with
  `-d extension=swoole`, like the entries.
- **`php-info`:** prints PHP version, Swoole version, SQLite version, OPcache present, JIT available, and the
  extensions the steps need (`pdo_sqlite`, `mbstring`, `sodium`, `ffi`, `ctype`, `iconv`). A missing one is listed,
  not fatal: S4 to S6 will say if they need it.
- **Limits check:** inside `lab/run.sh`, `cat /sys/fs/cgroup/cpu.max` gives `100000 100000`, `memory.max`
  `2147483648`, `memory.swap.max` `0`, `ulimit -n` `65535`.
- **Cases:** wrong sha256 fails the build; an unknown variant fails `lab/build.sh` with the list of known ones.

## Scope 3: PHP from source

- **What:** one Dockerfile with build args (`PHP_VERSION`, `PHP_SHA256`, `WITH_SWOOLE`), tarballs from php.net with
  the sha256 that php.net publishes, pinned in the repo. The latest patch release of each branch as of 2026-11-21.
- **Configure:** the minimum the steps need, the same for every version: CLI only, `pdo_sqlite` (system
  `libsqlite3`), `mbstring`, `sodium`, `ffi`, `ctype`, `iconv`, OPcache (and its JIT), `-O2` like the distro builds.
  No FPM, no CGI. The exact flags go in the Dockerfile with a one-line why each.
- **8.3 from source too (D13):** the control that separates "newer PHP" from "Ubuntu's build flags".
- **8.6:** Swoole 6.2.6 doesn't announce 8.6 support. If it fails: save the build error in
  `lab/results/swoole-on-php-8.6.md`, build the 8.6 image with `WITH_SWOOLE=0` so the micro harness still runs, and
  try `6.3.0-rc2` once on 8.6 for information only (pinned sha256, not adopted: it goes in the same file).
- **Cases:** each image passes `php-info`; same configure flags across versions (the script prints them, the check
  compares them).

## Scope 4: micro harness

- **Seams:** `lab/micro.sh <bench-file> [--images a,b] [--jit on|off|both]`, and the bench file format.
- **A bench file** declares named cases; each case has a `check` (correctness, run once before timing, a failure
  stops the case) and a `run` (the code timed).
- **Timing:** warm-up (at least 1 s or 10 % of the iterations), then `hrtime(true)` around N iterations, 10 repeats,
  the median ns/op and the spread (min and max, or interquartile range). The loop's own cost (an empty case) is
  measured and shown, not silently subtracted.
- **OPcache on for the CLI:** `opcache.enable_cli=1`. JIT on: `opcache.jit=tracing` with a buffer; JIT off:
  `opcache.jit=disable` (or `0` on 8.3, whichever that version accepts). The harness reads
  `opcache_get_status()['jit']` and fails if the state isn't the one requested.
- **Pinned to CPU 2** with the lab's limits, one image at a time (never two benches at once on the same CPU).
- **Output:** one table (image, PHP version, JIT, case, median ns/op, spread) and a JSON file per run in
  `lab/results/` or a path given on the command line.
- **`sample.php`:** two cheap cases with a correctness check each (for example `json_encode` of a small array and
  `ctype_digit` on an id), enough to prove the harness, not a step result.
- **Cases:** a failing `check` stops that case with its message; JIT mismatch exits non-zero; an unknown image exits
  non-zero.

## Scope 5: macro harness

- **Seams:** `lab/macro.sh --image <v> --server <php file> --rate <req/s> --duration <s> [--warmup <s>]
  [--script <k6 js>]`, and the no-op server `lab/servers/noop-swoole.php`.
- **No-op server:** Swoole, `SWOOLE_BASE`, `worker_num => 1`, `enable_coroutine => false`, `http_parse_post`,
  `http_parse_cookie`, `http_parse_files` and `http_compression` off, like both entries. Answers 200
  `{"status":"ok"}` with `Content-Type: application/json` to every request. Port 8080 (the VM's port 80 may be
  taken; the port doesn't change the measure). PHP flags like mattsplat's `start.sh`, JIT on.
- **k6:** `grafana/k6` pinned by tag and digest, in its own container, `--network host`, pinned to CPUs 4 to 11.
  `constant-arrival-rate` at the requested rate, enough `preAllocatedVUs` that `dropped_iterations` stays 0.
- **CPU per request:** warm-up run first, then `cpu.stat` (`usage_usec`) of the server's cgroup read with
  `docker exec` before and after the measured run, divided by the measured run's request count (k6 summary export).
- **Also reported:** achieved req/s, p95, p99, error rate, dropped iterations, VUs used (so connections), peak RSS
  (`memory.peak` of the cgroup, and the PHP process's `VmHWM`), and k6's own CPU, to show k6 wasn't the bottleneck.
- **Output:** a human table and a JSON file with every number and the exact command.
- **Cases:** dropped iterations above 0 or errors above 0 make the run "invalid" in the output (still printed); the
  server container is always removed at the end, even on failure (trap).

## Scope 6: first number

- **Prediction first (D5):** written in the results README before any run. See "Predictions" below.
- **Runs:** image `8.3-apt`, rates 1,000, 3,000 and 6,000 req/s, 30 s measured after a 10 s warm-up, 3 repeats
  interleaved (1k, 3k, 6k, 1k, 3k, 6k, …) because the host drifts.
- **Record:** median µs/req and spread per rate, p95, p99, peak RSS, VUs, k6 CPU, the Docker Desktop and kernel
  versions, the exact commands. Then a "Did the prediction hold?" paragraph.

## Predictions for the first number (D5)

Written by the project manager on 2026-11-21, before scope 6 runs.

- **mattsplat:** about 18 µs/req, closed loop, 64 connections, no think time, 1 Apple Silicon core, with the whole
  API (mostly SQLite reads). A no-op does no SQLite and no JSON of rows, so it should cost **less than 18 µs/req**.
- **tzimpel:** 50 to 60 µs/req at a fixed rate on the real mix on Apple Silicon. A fixed rate costs more per request
  than a closed loop (fewer requests per `epoll_wait`, more wake-ups), so the no-op at a fixed rate could land above
  mattsplat's closed-loop number.
- **Our prediction:** **8 to 20 µs/req** at 3,000 req/s, and **higher per request at 1,000 req/s than at 6,000**
  (fixed costs per wake-up spread over fewer requests). Peak RSS under 50 MB with a few hundred connections.
