# Brief: scope 4/6, the profile

**Read first:** [common.md](common.md), then `plan/state/developer.md` (scopes 1 to 3's handovers).
**Worktree:** `.claude/worktrees/twelve-dollar-server-php/phase-4-claude` under the home folder (your prompt gives the
full path) · **Your handover:** `plan/state/developer.md` in the main checkout.
**Planned commit:** `feat(lab): Excimer profiles folded into the steps S1 to S9`

**Summary:** profile the skeleton under the realistic load with Excimer (a sampling profiler on CPU time), and fold its
samples into the request's steps, so the next phase knows which step costs the most per request and per endpoint.

**The steps** (what the table's rows mean): S1 accept connections; S2 read and parse the request; S3 route; S4 verify
the JWT; S5 validate the input; S6 query SQLite; S7 build the JSON; S8 write the response; S9 durability (commit,
checkpoint). Plus "event loop" (the loop's own code and `EventBase::dispatch` with nothing under it) and
"unclassified".

**Today:** the skeleton (`lab/app/app.php`, `lab/app/server.php` on `lab/servers/diy-server.php` and
`diy-connection.php`) keeps each step in its own function (see scope 1's handover for the names). `lab/realistic.sh`
(scopes 2 and 3) runs the bench's journey with idle connections and per-second series. The images' last layer
(`lab/images/install-extras.sh`, called from `Dockerfile.src`) builds `pcntl`, `sockets` and PECL `event` with
`phpize`, sha256 pinned, with a `WITH_EVENT` switch; `lab/images/php-info` prints the extensions. Excimer is not in the
images.

**Expected:**

- **Excimer in the images:** the PECL `excimer` tarball, latest stable today, sha256 pinned, built with `phpize` in a
  **new layer after** the `install-extras.sh` layer (its own small script; rebuilding the existing layer would rerun its
  `apt-get update` and could move libevent between the scopes and the measurement), with a `WITH_EXCIMER` switch like
  `WITH_EVENT` (8.6 may not build it: then save the error in `lab/results/excimer-on-php-8.6.md` and build 8.6 without
  it). Never enabled globally: loaded with `--ext excimer`. `php-info` prints `excimer: <version>` (or `not built`).
  Rebuild the source images (`bash lab/build.sh <v>`). Every phase 2 and 3 `php-info` line stays the same.
- **In the server:** with `APP_PROFILE=<path in the container>` (and `APP_PROFILE_PERIOD`, default 0.001 s of CPU), an
  `ExcimerProfiler` on `EXCIMER_CPU` starts before the first request. The servers have no signal handling and are
  removed with `docker rm -f`, and `/lab` is read-only: so flush the collapsed stacks (`formatCollapsed()`) to the
  container's own disk **on a timer** (an `Event` timer on the loop, every few seconds, or at a fixed request count),
  and the harness copies the file out (`docker exec cat`) before it removes the container. `realistic.sh` (and
  `macro.sh`) take `--profile <out file>`, which loads `excimer`, sets the env and fetches the file.
- **The fold:** `lab/profile/fold.php <collapsed> [--rules <file>] [--us-per-req <n>]` maps each sample to a step with
  a committed rules file `lab/profile/steps.rules` (a frame name or prefix → a step), **the innermost matching frame
  wins**. Per endpoint: by the route function on the stack; a sample with no route function (read, parse, write, the
  loop) counts in "shared". Output: one table, rows = steps (S1 to S9, event loop, unclassified), columns = each
  endpoint, shared, all (share of samples, and µs per request when `--us-per-req` is given). The shares sum to 100 %.
- **The kernel:** the cgroup's `user_usec` and `system_usec` over the profiled window, printed with the table (the
  harness reads them at the window's edges). Kernel time spent inside a syscall shows inside the PHP frame that made it
  (`fread`, `fwrite`, `stream_socket_accept`): the README says so.
- **The calibration of Excimer (important):** Excimer takes its sample at the next VM interrupt check, and its docs
  say time in a C function is "attributed to the caller". The ranking of the next phase rests on knowing which. Build a
  fixture (a small script or route under `lab/check/fixtures/` or `lab/profile/`) that spends a known share of its CPU
  in one internal function (`hash('sha256', ...)` in a loop, measured by `hrtime` without the profiler) against a PHP
  loop, and profile it **with the JIT on and off**. Report where the internal function's samples land and how far its
  share is from the expected one. If they land on the caller, the rules file maps the step functions (each step has
  its own function, so "attributed to the caller" still means "attributed to the step"), and the README says so. Also
  say where libevent's and `epoll_wait`'s time lands.
- **`lab/check.sh`:** `php-info` shows `excimer`; the fold on a small committed fixture of collapsed stacks gives known
  shares; an unknown frame lands in unclassified; a 20 s profiled realistic smoke gives a table with every endpoint;
  the calibration fixture, JIT on and off, within its tolerance.
- **`lab/README.md`:** the profiler, the fold, the rules, the calibration's result, how to read the table.

**Key interfaces:** `--ext excimer`, `APP_PROFILE`, `APP_PROFILE_PERIOD`, `--profile` in the harnesses,
`lab/profile/fold.php`, `lab/profile/steps.rules`.

**Done when:** `lab/run.sh 8.5 php-info` prints `excimer: <version>`; a 20 s profiled realistic run writes the
collapsed stacks and `lab/profile/fold.php` prints one table (rows S1 to S9, the event loop, unclassified; columns per
endpoint and all), the shares summing to 100 % and unclassified under 5 %, plus the cgroup's user and system split for
the same window; the calibration fixture puts its internal function's share on that frame within 5 points of the
expected share, JIT on and off (or, if Excimer attributes it to the caller, the README and the rules show the step
functions carry it, and you tell me); `bash lab/check.sh` is all `ok`.

**Seams and cases to test:** the `lab/check.sh` bullet's cases; one run with the profiler and one without at the same
load, to give a first idea of Excimer's cost (a smoke, not the measurement).

**Tests to imitate:** `check_source_extras` (an extension in the images), scope 2 and 3's realistic checks,
`lab/check/aggregate-test.php` (a PHP test on fixtures).

**Decisions that touch you:** Excimer on CPU time, built like ext-event in its own layer with a switch, loaded only with
`--ext`; the kernel's part from `system_usec`; a profiled run never gives a µs/req of the baseline (its cost is measured
against an unprofiled run); each step in its own function, and a calibration fixture proves where samples land.

**Image builds and the Docker VM:** an image build is fine now (no measurement is running). Other projects'
containers are running: never stop them. Never remove or retag the `php-lab:*` images except by rebuilding them with
`lab/build.sh`.

**Out of scope:** any measurement that counts (scope 5); any change to what the app does or how fast it is; `perf`
(only if it runs without changing anything VM-wide: not needed here).

**Where to look:** `lab/images/install-extras.sh`, `Dockerfile.src`, `php-info`, `lab/build.sh`, `lab/lib.sh`
(`lab_source_release` and its switches); `lab/realistic.sh`; the app's step functions; Excimer's README on GitHub
(wikimedia/mediawiki-php-excimer) for `ExcimerProfiler`, `EXCIMER_CPU`, `formatCollapsed`.

**Come back to me if:** Excimer doesn't build on 8.5, the calibration shows samples land somewhere that neither the
internal frame nor the step function can explain, a decision is missing, or the Done-when doesn't pass after 3 tries.
