# Phase 6: the submission (`submissions/php-Gcob/`)

**Done when:** the challenge's own `test/run.sh` passes 42/42 on `submissions/php-Gcob/`, installed the way the bench
installs it: a clean `ubuntu:24.04` container, `install.sh` as root, `build.sh` as a normal user `deploy`, started as
`deploy` with `nofile` 65535 and the right to bind port 80 (`CAP_NET_BIND_SERVICE`, nothing else), direct on port 80
(rule 9, no Nginx); the README states the language, the versions, the driver, "direct", the optimizations with the
lab's measured numbers and the rules audit; and one pair in the step lab at 24,000 req/s shows the submission costs
what `lab/app` costs with the same configuration, within the floor (0.864 µs/req), or the reason it doesn't. The
arm64 container on the Mac is enough here: phase 7 runs `install.sh` natively on x86 (D7). The predictions below were
written before any measurement (D5). Then the run stops (D12).

**Plan review:** [PLAN-2026-11-24-1840.md](../reviews/PLAN-2026-11-24-1840.md), NOT_OK (2 🟠, 10 🟡; a first try at
13:45 was stopped by Jacob's pause before its report). Both 🟠 settled by the project manager with the reviewer's own
picks (D85: a CI-runner mode in `lab/submission-test.sh` and full paths for every PHP tool; D86: how a pair outside the
floor is explained), the 🟡 folded in below. Delta: [PLAN-2026-11-24-1855-delta.md](../reviews/PLAN-2026-11-24-1855-delta.md),
OK (2 🟡 folded in: the `--ci` run and the two-sided reading in the scope rows; `sudo` installed in the `--ci`
container, which the pinned image lacks).

**Where (D14):** code on branch `phase-6-claude`, in its worktree. `plan/` stays on `main`. The factory's working
files (`run.md`, `state/`, `reviews/`) are private (D48).

**Why this shape:** phases 2 to 5b chose a variant per step; every number since phase 3 ran on PHP 8.5 from source in
the lab's image, the server started by the lab's scripts with the lab's flags. The bench does none of that: it runs
our `install.sh` on a clean Ubuntu, our `build.sh` as `deploy`, and starts our `start.sh` under systemd. So phase 6 has
three risks, one per slice: **the code** (a clean copy can drift from what the lab measured), **the install** (a build
that works in the lab's Dockerfile can fail on a bare box, or as a user without root), and **the claims** (the README
is what Arjay reviews against rules 5, 6, 7, 10 and 11).

## Decisions of this phase

In [decisions.md](../decisions.md):

- **D78, PHP 8.5 from source** in `install.sh`, the lab's configure flags (D13), ext-event and the other extensions
  from their tarballs, every download sha256 pinned (Jacob, 2026-11-24 13:38).
- **D79, a clean copy:** only the chosen variants, built in (S1-b with the soft limit at 64,000 in each of 2 processes,
  D77; `mmap-off`, D66; the rest as the lab's reference, D70). No switches, no FFI driver, no profiler, no telemetry,
  no checkpointer. `lab/app` stays as it is for phase 8 (Jacob, 2026-11-24 13:38).
- **D80, the folder is `php-Gcob`**, checked again at phase 9 (Jacob, 2026-11-24 13:38).
- **D81, the install's shape:** PHP in its own prefix, `/opt/php-gcob`; Ubuntu's own packages from apt for the
  libraries (no version pin, as the merged PHP entries do), their versions stated in the README; the extensions loaded
  by `start.sh`, never globally; `start.sh` passes the lab's PHP flags exactly; `HOST` and `PORT` default to
  `0.0.0.0` and `80` (project manager).
- **D82, how phase 6 proves the bench's install:** `lab/submission-test.sh`, a clean pinned `ubuntu:24.04` container on
  one CPU and 2 GiB, `deploy` dropped to with `setpriv` and only `CAP_NET_BIND_SERVICE` as an ambient capability, the
  container's unprivileged port floor put back at 1,024 so that the capability is what lets port 80 bind (project
  manager).
- **D85, the CI runner too:** `lab/submission-test.sh --ci` installs Ubuntu's PHP 8.3 first (as the runner image has),
  then `install.sh` with `sudo`'s `PATH`, then `test/run.sh` on `127.0.0.1:3000` as a normal user; `install.sh` calls
  every PHP tool by its full path under `/opt/php-gcob` (project manager, plan review item 1).
- **D86, a pair outside the floor:** 2 more pairs (3 in all), then a one-process profile of each side: the lab's
  server with `APP_PRAGMAS=mmap-off,APP_SOFT_CONN_LIMIT=64000` and `APP_PROFILE`, the submission's code through a
  lab-only entry file under `lab/` that loads its files in one process with the profiler. Built only if needed
  (project manager, plan review item 2).
- **D83, parity:** one `steplab.sh` pair at 24,000 req/s, the lab's server with `APP_WORKERS=2`,
  `APP_SOFT_CONN_LIMIT=64000`, `APP_PRAGMAS=mmap-off` against the submission's server file, same image, same flags
  (project manager).

## Scopes

| #   | Commit                                                                   | Done when |
|-----|--------------------------------------------------------------------------|-----------|
| 1   | `feat(submission): php-Gcob, the chosen variants in a clean copy`         | `bash lab/challenge-test.sh --image 8.5 --server submissions/php-Gcob/server.php --ext pcntl --ext sockets --ext event` (no `--env`) prints `passed=42 failed=0`; the boot lines say 2 workers, the soft limit 64000 per process and `mmap_size=0`; a check sees both pids answer over 200 connections; `check_submission` in `lab/check.sh` passes (below) and fails on its fixtures; `git diff main -- lab/app lab/servers` is empty; a real-shape smoke pair (lab against submission, 24,000 req/s, 60,000 idle, `--allow-busy`) has both runs valid; `lab/check.sh` all `ok` |
| 2   | `feat(submission): install.sh builds PHP 8.5 and its extensions from pinned sources` | `bash lab/submission-test.sh` on a clean `ubuntu:24.04` prints the install's time, `build.sh` ok as `deploy`, `passed=42 failed=0` from the challenge's `test/run.sh` run as `deploy` on port 80, then a second start on `0.0.0.0:80` healthy in under 60 s and answering on the container's own address, every server process owned by `deploy` with `Max open files 65535`, and a negative check (port 80 refused to `deploy` without the capability); exits 0; `bash lab/submission-test.sh --ci` prints `passed=42 failed=0` on `127.0.0.1:3000` (D85); `check_submission` also refuses an unpinned download; `lab/check.sh` all `ok` |
| 3   | `docs(submission): the README and the rules audit`                       | `submissions/php-Gcob/README.md` has the table (language, PHP and its flags, framework none, ext-event and libevent, `pdo_sqlite` and SQLite, dependencies, **direct**), how to run it, the optimizations each with its measured number and a link to its `lab/results/` folder, the rules audit (5, 6, 7, 10, 11: what the code does and where), what isn't measured yet (the score, phase 7); every link resolves to a file of this repo (`check_submission`); `bash tools/public-guard.sh tree` passes |
| 4   | `docs(lab): the submission against the lab, one pair`                    | `lab/results/<date>-submission-parity/README.md`: the predictions copied unchanged, one pair at 24,000 req/s (quiet VM, `stages.sh`, `--floor-from` 5b's A/A), both runs valid, `|sub − lab|` printed by `summarize.sh` and read against 0.864 µs/req (D86); within it, parity; outside it, the reason found before delivery; `summarize.sh` regenerates its tables; `lab/check.sh` all `ok` |

Vertical slices: scope 1 is the code and how the lab runs it (42/42 in the lab's image, the parity pair's
plumbing), scope 2 the bench's way in (a bare Ubuntu, `deploy`, port 80), scope 3 the claims, scope 4 the one
measurement. Scope 3 comes after scope 2 (it cites the install's versions and healthy time); scope 4 needs scope 1
and a quiet VM.

**Quiet VM (D15):** only scope 4 measures. Jacob's other containers run again since this morning: the project
manager never stops or starts them. When scope 4 is ready, a 🔴 item in 👉 asks Jacob for a quiet VM; scopes 2 and 3
go on meanwhile. Scope 1's smoke pair and scope 2's container are not measurements: they run on the busy VM, labelled.

## Shared rules for every scope

- **The submission folder holds only what the challenge's PR will hold:** `install.sh`, `build.sh`, `start.sh`,
  `README.md`, `.gitignore`, the PHP files. No lab script, no test, no fixture in it: those live in `lab/`.
- **The code is a copy, not a fork:** the request path does what `lab/app` does with D83's switches, line for line where
  it can; what goes is only what the switches and the lab's instruments add (variants, telemetry, profiler, group
  commit, checkpointer, FFI, loop presets, the request counter). A behavior change is a question for the project
  manager, not a fix.
- **Correctness first:** 42/42 before anything else.
- **The public guard:** no e-mail, no home path, no factory word in the submission or the results
  (`tools/public-guard.sh`).
- **`lab/app` and `lab/servers` are not touched** (D79): phase 8 builds on them.

## Scope 1: the clean copy

- **Seams:** new `submissions/php-Gcob/` (`server.php`, `app.php`, `workers.php`, the loop and the connection, named
  by the developer; `start.sh`, `build.sh`, `.gitignore`); `lab/lib.sh` and the scripts that start a server
  (`challenge-test.sh`, `realistic.sh`, `steplab.sh`'s `--server-variant`) so that a server file under
  `submissions/` runs as one under `lab/` does (today the file must be under `lab/`, mounted at `/lab`); `lab/check.sh`.
- **From:** `lab/app/server.php`, `app.php`, `workers.php`, `lab/servers/diy-server.php`, `diy-connection.php`, at
  `main` `9d88696`.
- **Built in:** 2 processes on `SO_REUSEPORT` (workers.php's supervisor as it is: a child that ends stops the others
  and the parent exits 1); the soft limit at 64,000 connections in each process (D53's behavior: a response built
  while more than 64,000 are open in that process says `Connection: close`; an idle connection is never closed); the
  accept pause when fds run out; the reference's SQL, `fetchAll` keyed by column, `json_encode` with the same flags;
  the pragmas: WAL, `synchronous = NORMAL`, `busy_timeout = 5000`, `cache_size = -65536`, `mmap_size = 0`,
  `temp_store = MEMORY`; autocommit, each write committed before its response; backlog 4,096 and `TCP_NODELAY`.
- **Configuration:** only SPEC.md's variables. `SQLITE_PATH` and `JWT_SECRET` required (exit 1 with a message);
  `HOST` defaults to `0.0.0.0` and `PORT` to `80` (the direct values of SPEC.md); the database must exist (SQLite
  would make an empty one). No other `getenv`.
- **Boot lines** (stdout, before the first request): workers and pids, `listening on HOST:PORT`, the soft limit per
  process, the pragmas as SQLite reads them back (`journal_mode`, `synchronous`, `mmap_size`, `cache_size`), the loop's
  method, the socket's backlog and `TCP_NODELAY`.
- **`start.sh`:** `cd` to its folder, `exec /opt/php-gcob/bin/php` with, in this order, `-d extension=pcntl -d
  extension=sockets -d extension=event`, then exactly the lab's `LAB_SERVER_PHP_FLAGS` (`memory_limit=-1`, OPcache on
  for the CLI, the tracing JIT, a 32 MiB JIT buffer, `opcache.file_update_protection=0`, `zend.assertions=-1`), then
  `server.php`. The PHP path is D81's prefix (scope 2 installs it there); in the lab, the image's `php` runs the
  same file with the same flags.
- **`build.sh`:** `php -l` on every PHP file with D81's PHP, nothing written. **`.gitignore`:** what a run can leave
  in the folder (none expected; at least `*.log`).
- **The lab's hook:** a server file may also be under the repo's `submissions/` (mounted only when the server file is
  there, so no empty folder appears elsewhere; read-only at
  `/submissions` in the server's container); an unknown path is refused as today.
- **`check_submission` (lab/check.sh):** the submission's PHP calls `getenv` only for the four SPEC.md variables;
  it holds none of the lab's switch names (`APP_WORKERS`, `APP_PRAGMAS`, `APP_SOFT_CONN_LIMIT`, `APP_TELEMETRY`,
  `APP_PROFILE`, `APP_JSON`, `APP_FEED_SQL`, `APP_FETCH`, `APP_DRIVER`, `APP_LOCKING`, `APP_GROUP_COMMIT`,
  `APP_CHECKPOINTER`, `APP_LOOP`) and none of `FFI`, `Excimer`, `DiyTelemetry`, `DiyProfile`, `checkpointer`,
  `group_commit` (a constant like `APP_JSON_FLAGS` or a function `app_boot` stays: the ban is on switches, not on the
  `APP_` prefix, plan review item 3); `start.sh`'s `-d` flags are
  the three extensions plus `LAB_SERVER_PHP_FLAGS`, in order; `php -l` passes in the lab's image; the folder holds no
  file outside the list above. Fixtures make each part fail once.
- **The smoke (D57):** one `steplab.sh` pair at 24,000 req/s, `s = 0.02`, 60,000 idle, 60 s plateau, telemetry off,
  `--ext pcntl --ext sockets --ext event` on both sides: `lab` = `lab/app/server.php` with
  `APP_WORKERS=2,APP_SOFT_CONN_LIMIT=64000,APP_PRAGMAS=mmap-off`; `sub` = `--server-variant
  sub=submissions/php-Gcob/server.php`, no env. `--allow-busy`: a check of the plumbing, never a number.
- **Cases:** 42/42; the boot lines; both pids answer (the copy has no telemetry to name them: hold 200 connections
  open and count each child's sockets in `/proc/<pid>/fd`, both above 0, plan review item 4); `SQLITE_PATH` unset, `JWT_SECRET` unset, a missing database:
  exit 1 with a message, nothing listening; `HOST`/`PORT` unset: `0.0.0.0:80` (checked as root in a container with its own
  network, not the host network: another project publishes port 80 on the VM, plan review item 5); `Connection: close` past the limit (a check with a small limit isn't possible without a switch:
  the developer proves the 64,000 line's path with a unit-level check that builds the connection with a small count,
  or says why it can't, without adding an env var); `check_submission`'s fixtures.

## Scope 2: the bench's install, in a clean container

- **Seams:** `submissions/php-Gcob/install.sh`, new `lab/submission-test.sh`, `lab/check.sh`.
- **`install.sh`** (root, once, `set -euo pipefail`, `DEBIAN_FRONTEND=noninteractive`): apt installs the build tools
  and the libraries the lab's image used (`ca-certificates curl xz-utils build-essential autoconf pkg-config
  libxml2-dev libsqlite3-dev libonig-dev libsodium-dev libffi-dev libevent-dev`; not `libssl-dev`, which only Swoole
  wanted); PHP 8.5.13 from php.net, sha256 `607602ac...785f` (the lab's, `lab/lib.sh`), configured with the lab's
  flags (`lab/images/install-php-src.sh`) except `--prefix=/opt/php-gcob` and its config paths under it; `make -j`
  `nproc`; `pcntl` and `sockets` with `phpize` from the same tarball, `CFLAGS=-O2`; ext-event 3.2.0 from PECL, sha256
  `fb3d4e3c...dc1c`, with the lab's configure flags; the sockets header copied as the lab does; at the end, one line:
  PHP, SQLite, libevent and the extensions' versions, read from the installed PHP (`php -d extension=... -r`). Every
  download is checked with `sha256sum -c` before use; the temporary folder is removed.
- **`lab/submission-test.sh [--keep]`:** a container from the lab's pinned `ubuntu:24.04` digest (the one
  `Dockerfile.src` uses), on one CPU (`--cpuset-cpus`, so `nproc` is 1, like the droplet) and `--memory 2g
  --memory-swap 2g`, with `--sysctl net.ipv4.ip_unprivileged_port_start=1024` (Docker sets it to 0 in a container, which
  would let anyone bind 80) and `--ulimit nofile=65535:65535`. In it: the submission folder copied in (not mounted:
  `deploy` must own it, as a checkout would be), the challenge's `test/` copied unchanged, `lab/data/feed.db` as
  `seed/feed.db`; `install.sh` as root, timed; `curl jq openssl` installed for the test suite **after** `install.sh`
  (so `install.sh` proves it brings its own `curl`); `useradd -m deploy`, the folder at `/srv/php-Gcob` owned by `deploy` (the guard refuses home paths in a
  committed script, plan review item 11); `build.sh` as `deploy`; then, as `deploy`
  through `setpriv --reuid deploy --regid deploy --init-groups --inh-caps +net_bind_service --ambient-caps
  +net_bind_service` (what systemd's `AmbientCapabilities=` gives), `PORT=80 bash test/run.sh <folder>`; then a second
  start, `HOST=0.0.0.0 PORT=80 bash start.sh` on a fresh seed copy, the seconds until `/health` answers, `/health`
  read through the container's non-loopback address, and each server process's user and `Max open files` from
  `/proc/<pid>/limits`; a negative check: as `deploy` without the capability, binding port 80 is refused (it proves
  the sysctl). Prints one summary line per check and exits 0 only if all pass. The container is removed unless
  `--keep`. The `nofile` limit in the container emulates systemd's `LimitNOFILE=65535`; said so in its header.
- **`--ci` (D85):** the same container, but first `apt-get install php8.3-cli php8.3-dev` (what the runner image
  has), then `apt-get install sudo` (the pinned image has none) and `sudo bash install.sh`, the CI's own command, so it runs
  with `sudo`'s secure `PATH` (`/opt/php-gcob/bin` not on it), then `test/run.sh` as a normal
  user other than `deploy` on its defaults (`127.0.0.1:3000`), with the runner's own `nofile`; it proves the extensions
  were built against 8.5 (the server's boot would exit 1 otherwise). `install.sh` names `/opt/php-gcob/bin/phpize`,
  `php-config` and `php` by full path everywhere.
- **`check_submission` grows:** every `curl` in `install.sh` is followed by a `sha256sum -c` of what it fetched;
  shellcheck runs on the submission's three scripts (pinned shellcheck, as for the lab).
- **Cases:** the run above; `install.sh` fails cleanly on a wrong sha256 (a fixture copy with one digit changed,
  stopped before `configure`: the developer may run it only up to the check); the summary lines.

## Scope 3: the README and the rules audit

- **Seams:** `submissions/php-Gcob/README.md`, `lab/check.sh` (`check_submission`: the links).
- **Shape:** like the merged PHP entries' READMEs (a table, Running it, Optimizations and why, Results), plus a section
  **Rules audit**. English. The `markdown` skill's rules.
- **The table:** PHP 8.5.13 built from source (the flags, OPcache and the tracing JIT); framework: none, our own event
  loop on ext-event 3.2.0 (libevent from Ubuntu 24.04); driver `pdo_sqlite` on Ubuntu's SQLite 3.45.1; dependencies:
  none beyond PHP's extensions; **Nginx or direct: direct, `0.0.0.0:80`**.
- **Optimizations and why**, each with its measured number and its results folder: one process per CPU's worth of
  work on one event loop (the bake-off, phase 3); 2 processes on `SO_REUSEPORT` with the soft limit at 64,000 each,
  and why (the fd wall, S1-b against S1-d, D77, x86 numbers); `mmap` off (D66, the pairs); what was measured and **not**
  kept (group commit, exclusive locking, the JSON variants, the FFI driver, the lean parser, PHP 8.4 and 8.6), one line
  each with its number; the method in one paragraph (µs of CPU per request, the A/A floor, link to the lab's README).
- **The supervisor's choice:** one child that ends stops the other and the parent exits 1, no restart: named in the
  README, with why (a crash shows instead of a half server; systemd decides what follows) (plan review item 9).
- **Rules audit:** rule 5 (each request runs its own statements; nothing kept between requests but the prepared
  statements; every JWT's HMAC checked with `hash_equals` on every request; where in `app.php`); rule 6 (WAL,
  `synchronous = NORMAL`, autocommit, the `INSERT ... RETURNING` row fetched and the cursor closed before the 201);
  rule 7 (no hard-coded response; the soft limit is a connection budget any server over its fds needs, it never closes
  an idle connection, and fires on connection count, not on the load test); rule 10 (pinned tarballs, Ubuntu's own
  packages, nothing prebuilt, healthy in N s from scope 2's run); rule 11 (no kernel setting, no pinning; the 2
  processes and the pragmas are inside our own process). Rule 1's "any number of processes" for S1-b.
- **Links:** to this repo on GitHub (`https://github.com/Gcob/twelve-dollar-server-php/...`, the branch `main`), since
  the folder will be read in the challenge's repo; `check_submission` checks each such link's path exists in the
  tree.
- **Not claimed:** a score, or the bench estimate (79 µs/req, 96 at 150,000 users): an estimate in the PR's README
  reads as a claim, so "Results" says only that phase 7 will score it; the measured µs/req on the Mac and the Xeon,
  each with its machine named, stay (plan review item 12).

## Scope 4: parity, one pair

- **Before any run:** the predictions below copied unchanged into
  `lab/results/<date>-submission-parity/README.md`; Jacob's quiet VM (🔴 in 👉); the series through `stages.sh`
  (D68), never `--allow-busy`; no developer runs Docker meanwhile.
- **The pair (D83):** 24,000 req/s, `s = 0.02`, 60,000 idle, 60 s plateau, warm-up a tenth of the rate for 60 s,
  telemetry off, alternating order (round 1 runs the reference last, D71), `--floor-from
  lab/results/2026-11-24-cpu-steps-5b/aa-24000` (0.864 µs/req), `--ext pcntl --ext sockets --ext event` on both sides.
  Reference `lab` = `lab/app/server.php` with `APP_WORKERS=2,APP_SOFT_CONN_LIMIT=64000,APP_PRAGMAS=mmap-off`; variant
  `sub` = `submissions/php-Gcob/server.php` with `APP_SOFT_CONN_LIMIT=64000` given to the harness only (so its VU cap
  and its JSON read the limit as the lab's side does; the copy ignores the variable, `check_submission` proves it reads
  no other; scope 1's hand-back).
- **The floor's caveat:** 5b's A/A ran one process; this pair runs two on one CPU. The README says so; no new A/A
  (D60: one pair is a screen).
- **The verdict, two-sided:** `steplab`'s one-pair screen reads one side only ("not better"), so the README computes
  `|sub − lab|` itself (in `summarize.sh`): under 0.864, parity, delivered. Round 1 runs `sub` first (D71), which adds
  about 0.2 to 0.3 µs to its number: said beside it. Outside the floor, either way: D86 (2 more pairs, then a
  one-process profile of each side), and the copy is fixed or the difference explained before delivery (plan review
  items 2 and 7).
- **`sub`'s run JSONs** say `soft_limit: null` and a VU cap "bound by file descriptors": the harness reads the limit
  from the environment, which the copy doesn't use. Harmless at 24,000 req/s; the README says so (item 10).
- **Run on:** the phase's worktree at the scope's starting commit; `stages.json` records the commit and that no
  tracked file is dirty.

## Predictions (D5)

Written by the project manager on 2026-11-24 at 13:50, before any phase 6 run. Arm64, Docker Desktop on an M3 Pro,
PHP 8.5.13, unless a line says otherwise.

1. **`install.sh` on one CPU** (`nproc` 1, the M3 core): 8 to 20 minutes, PHP's `make` most of it; the droplet's
   slower Xeon core would take 1.5 to 3 times that.
2. **Healthy:** `/health` answers under 2 s after `start.sh` (opening the database and forking 2 processes; no warm-up).
3. **`test/run.sh` in the clean container:** 42/42 on the first try after scope 1's 42/42 in the lab's image; if it
   fails, the cause is the install (a missing extension or library), not the code.
4. **Parity at 24,000 req/s:** both sides 26 to 29 µs/req (the reference `mmap-off` was 25.0 to 25.6 in one process;
   S1-b added 2.14 at 12,000 on the Mac); the submission minus the lab between -0.6 and +0.2 µs/req (the copy drops
   the variant branches, the request counter and the telemetry's null checks: a few function calls a request), so
   within the floor: parity.
5. **The smoke pair of scope 1** (busy VM): both runs valid; no number read.

## Out of scope

- **AWS, the score:** phase 7 (Jacob's go). The run never creates anything there.
- **The ring, the PGO SQLite, the single-post plan:** phase 8 (D76). `lab/app` stays as it is for it.
- **The challenge's repo and its fork:** no fork, no PR, no comment; no `gh` command (phase 9, with Jacob).
- **Renaming the folder:** phase 9 (D80).
- **An Nginx variant:** rule 9 allows it, D1 refuses it.
- **Tuning past the lab's choices:** a new variant goes to phase 8; phase 6 copies, it doesn't optimize.
