# Developer: phase 3, runtime bake-off

**State:** scope 4 done (`8c8f7cc`), scope 3 done (`deeb8d1`), scope 2 done (`0d74fda`), scope 1 done (`a0477ba`). Phase 2's handovers are in `plan/runs/phase-2/state/developer.md` (read its "Où regarder"
and "Impasses" if you touch `macro.sh`, `micro.sh`, `seed.sh` or the images).

## Verified

- Scope 1: `check_shellcheck` failed before the fixes (SC2034 on `lib.sh` variables and `sha` in check.sh, SC1007 on `pre_vus= max_vus=` in macro.sh, SC2148 on `lib.sh`), passed after. The fixture first exited 0 with SC2086 (info level, and a literal-valued variable), then exited 1 with SC2046. Full `bash lab/check.sh`: 18/18 ok (39 s).

- Scope 2, conformance (red first): `lab/conformance.sh --server lab/servers/bake-swoole.php` failed with "file not found" before the server existed; against the fixture `lab/check/fixtures/wrong-swoole.php` (text/plain "ok" to everything) 7 of 8 cases printed `FAIL  <case>: <why>` and exit 1, containers removed; then green on `bake-swoole.php` (8 cases ok, socket line `backlog=4096 open_tcp_nodelay=1`). Full `bash lab/check.sh`: 21/21 ok. Before the fix, `check_shellcheck` failed on SC2034 (`REPO`, `LAB_INI` unused in conformance.sh).
- Scope 2, one php process in the Swoole container (listed `/proc` of the running server: pid 1 only), so the PDO handle opened before `$server->start()` is the one that serves.
- Scope 2, Done-when runs, 8.5, 7000 req/s, 20 s, warm-up 10 s, quiet-VM warning on (23 other containers): `/noop` 21.05 us/req VALID (140,004 requests, 0 errors, 0 dropped, k6 at 99.6 % of one CPU); `posts.js` 31.22 us/req VALID (139,994 requests). Not measurements: other containers were running.
- Scope 3, `lab/conns.sh` runs (8.5, `bake-swoole.php`, 23 other containers running, so not measurements): `--max 10000` exit 0, 3 rows all ok, max 10,000, Pss slope 69.14 KiB/conn, memory.current slope 72.98 KiB/conn, baseline Pss 22.28 MiB / memory.current 257.54 MiB. Twice in a row: both exit 0, source addresses 127.0.0.6 then 127.0.0.7 (the second skips the first's TIME_WAIT). `--server-nofile 2048 --steps 1000,3000`: exit 0, step 1000 ok, ceiling at step 3000 with 2,035 held, reason `request timeout`. `--server-nofile 256 --steps 100,300`: ceiling with 243 held, `request timeout`. Default steps (full run, 36 s): 65,000 held, step 66000 stopped at 65,522 held (`request timeout`), Pss slope 12.97 KiB/conn, memory.current slope 16.81 KiB/conn, no OOM (memory.current 1.58 GiB at 65.5k). Server killed by hand (`docker kill`) during step 20000: reason `server died (exit code 137)`, exit 0, containers removed. Client `nofile` forced to 300: harness failure exit 1 with the client's message, containers removed. `--max 100` with `--steps 500` and `--steps 5,3`: exit 2.
- Scope 3, red first: `check_conns_back_to_back` failed with "both runs started from the same source address" against a client mutated to ignore the busy addresses, passed after restoring it. The other two new checks were written after the harness had been run by hand many times (no red run: they pass on the first call). A bug found by running: the client printed a PHP fatal into the events file (blank line, then text), the orchestrator took it for an event; fixed with `display_errors=stderr` and a check that every line is JSON. Full `bash lab/check.sh`: 24/24 ok (84 s).
- Scope 3, `server OOM-killed` is never reached in my runs (65.5k held connections peak at 1.58 GiB). That branch (`docker inspect .State.OOMKilled`, `memory.events oom_kill`) is untested.

- Scope 4, caches script: red first against two unpatched trees (stock copied out of the image and mounted over `/opt/workerman/nocache`): the 5 `nocache` lines printed `filled   <- expected empty`, exit 1; then green on the real trees, exit 0. (I ran it green first, then the red: the script itself was written green-first because the patch had to exist.) First run failed because of my fixture (Content-Length 11 for a 12-byte body: Workerman answered 400 and the second feed never reached onMessage); the script now fails with "onMessage ran N times, expected 2".
- Scope 4, patch failing, by hand, build of a copy of `lab/images/` with a broken patch (`docker build`, tag `php-lab-scratch:N`, no image left): (1) a context line changed, `patch --fuzz=0` printed `Hunk #1 FAILED at 684` and the build stopped with `BUILD FAILED: lab/images/workerman-nocache.patch does not apply cleanly to Workerman 5.2.4`, docker exit 1; (2) the `Http.php` file diff removed (applies cleanly): `BUILD FAILED: the patched Workerman tree still has a request cache static:` then `src/Protocols/Http.php:116:        static $cache = [];`, docker exit 1.
- Scope 4, boot check: green on both trees (0.7 s for both). Red: same check with `event` not loaded (`LAB_EXT=(pcntl sockets)`): fails after 15 tries (47 s) with the worker's stack trace in the message. Before that a first version of the check hung for 2 minutes per tree: Workerman keeps an HTTP connection alive for 60 s (see Raw learnings).
- Scope 4, builds: `php-info` on 8.3, 8.4, 8.5, 8.6: `pcntl: present`, `sockets: present`, `event: 3.2.0`, `workerman: 5.2.4 (stock, nocache)` (8.5 and 8.6 read by hand; 8.3 and 8.4 by `check_source_extras`). `event` builds on 8.6 (`EventBase::getMethod()` returns `epoll`), so there is no `lab/results/event-on-php-8.6.md`. Full `bash lab/check.sh`: 26/26 ok (87 s). `check_shellcheck` failed first on SC2034 (unused `want_event`, `i`, and the `LAB_*` arrays the helpers read), fixed.

## Assumed

Rien.

## Dead ends

- (phase 2) `sqlite3 lab/data/feed.db ...` leaves `-wal`/`-shm` files: open with `file:<path>?immutable=1`.
- (phase 2) A server file saved less than 2 s before it starts runs without OPcache/JIT unless
  `opcache.file_update_protection=0` (already in `LAB_SERVER_PHP_FLAGS`).

## Decisions on the way

- **Scope 1, fixture uses SC2046, not SC2086:** shellcheck rates SC2086 "info", below the `warning` level the lab lints at, so the fixture would pass. `echo $(date)` gives a warning-level SC2046 (unquoted command substitution). The fixture says why in a comment.
- **Scope 1, image tag:** `koalaman/shellcheck:v0.11.0` with the index digest (`stable` points at the same 0.11.0 but under another digest, `bb596a0d...`, so the version tag is what is pinned).
- **Scope 1, lint fixes (no behavior change):** `lib.sh` gets a file-level `# shellcheck shell=bash disable=SC2034` (sourced file, no shebang, its variables are read by the sourcers); `macro.sh` `pre_vus= max_vus=` becomes `pre_vus="" max_vus=""`; `check_source_image` reads the unused field into `_` instead of `sha`.

- **Scope 2, case names:** conformance prints `ok    <case>` / `FAIL  <case>: <why>` (check.sh style), with cases `noop`, `post 1`, `errors`, `keep-alive`, `pipelining`, `split request`, `body then reuse`, `response bytes`. The brief's "case 8" (TCP_NODELAY) is the last line, `socket settings the server printed at boot: ...`, from the server's `socket:` boot line (Relances 1).
- **Scope 2, handler API:** `handler_boot()` = `handler_copy_db()` + `handler_open_db()`; `handler_handle(method, path, body): [status, body]`. State is a global `$handler_stmt`. A path with `?query` is cut at `?`. The copy is `/tmp/feed.db` inside the container, the source `/lab/data/feed.db`. Scopes 5/6: a forking runtime calls the copy once before forking and the open in each worker.
- **Scope 2, lib.sh API:** `LAB_SERVER_PHP_FLAGS` no longer holds `-d extension=swoole`; `lab_build_php_flags` (reads arrays `LAB_EXT`, `LAB_INI`, fills `LAB_PHP_FLAGS`), `lab_start_server <name> <variant> <port> <server in container>` (reads `LAB`, `LAB_PHP_FLAGS`, array `LAB_ENV`; mounts `lab/data` read-only), `lab_in_container_path`, `lab_other_containers <own name>...`, `lab_socket_line <container>`. Every measuring script from now on: call `lab_other_containers` with its own container names just before measuring.
- **Scope 2, JSON shape (macro):** `label`, `other_containers {count, names}`, `server.ext`, `server.env`, `server.socket {backlog, open_tcp_nodelay}` (null when the server prints no `socket:` line, e.g. noop-swoole), `results.memory.under_load {samples q1..q3 {pss_kb, cgroup_current}, max_pss_mib, max_cgroup_current_mib}`. `other_containers` excludes only this run's own three containers (Relances 3), so a second lab run counts.
- **Scope 2, Pss:** new probe command `probe.sh memory-now <server id>`.
- **Scope 2, memory.peak:** a server that copies the seed has `memory.peak` about 497 MiB (page cache of the copy) against about 12 for noop; VmHWM about 265 MiB (mmap of the 256 MiB). Pss under load: 74 MiB (`/noop`) to 182 MiB (`/posts/<id>`, the mmapped pages being touched). Compare runtimes on Pss, not on `memory.peak`.
- **Scope 2, posts.js** takes only the origin of `TARGET_URL`, so `--path /posts/1` is the right readiness path (it reads the database).
- **Scope 2, check.sh:** the default-out file name is tested (label in the name) and the file removed by the check.
- **Scope 3, ports per source address:** the VM's `ip_local_port_range` is `55000 65535` (10,536 ports), not the 32768-60999 of the brief: 7 source addresses for 66k connections. The client reads the file and keeps 500 ports in reserve (10,036 per address).
- **Scope 3, back to back: next free address, not a wait.** The client takes the lowest address from 127.0.0.2 that is the local address of no socket (`/proc/net/tcp`, any state), so a second run skips the first's TIME_WAIT addresses and never waits. It waits (5 s steps, up to 70 s, logged) only if all 253 are taken. In practice a bind did not even fail when I forced the reuse of an address in TIME_WAIT (tcp_tw_reuse is 2 on loopback): the check proves the skipping, not a failure that exists.
- **Scope 3, driving the client:** `docker exec -i` in the background, commands (`step <total>`, `quit`) on a FIFO, events as JSON lines in a file the script polls. The client holds all sockets between steps.
- **Scope 3, ceiling reasons** (strings in the JSON `results.ceiling.reason`): `connect timeout`, `request timeout`, `connection reset`, `connection closed by the server (EOF)`, `held connection closed by the server (EOF)`, `connection refused`, `bad answer`, `fresh request failed (HTTP n, x ms)`, `server OOM-killed`, `server died (exit code N)`. Precedence: died, OOM, client failure, held closed, fresh request. A server out of fds always shows as `request timeout`.
- **Scope 3, JSON shape (conns):** `command`, `label`, `other_containers`, `host`, `server {variant, php_version, swoole_version, file, port, ext, env, nofile, socket}`, `client {nofile, port_range, ports_per_address, source_addresses}`, `max_option`, `steps_planned`, `results {max_connections, max_connections_step, held_at_stop, ceiling|null, reason_stopped, baseline {pss_kb, cgroup_current_bytes}, memory_per_connection {held_steps_used, pss_kib_per_connection, cgroup_current_kib_per_connection}}`, `steps[] {target, held, client {event as the client sent it}, probe {pss_kb, cgroup_current, oom_kill, tcp_established, fresh_http_code, fresh_ms}|null, ceiling_reason}`. `held` of a failing step is the count after the client's sweep (all 1,000 are gone after a server kill: 0).
- **Scope 3, a step reads memory 1 s after the client is done** (`SETTLE_S`), and the baseline after a one-connection request closed 0.3 s earlier.
- **Scope 3, shared code touched:** `lab_start_server` reads `LAB_SERVER_NOFILE` (empty by default); `probe.sh` gets `memory-events <id>` and `fresh-request <port> <path>`. macro.sh and conformance.sh unchanged. `lab/conns.sh` starts its probe itself (a copy of macro.sh's `docker run`), not through a shared function.
- **Scope 3, ports:** `conns.sh` uses port 18100 by default (macro 18080, conformance 18090).
- **Scope 3, Swoole memory is not linear in connections:** Pss slope 69 KiB/conn from 1k to 10k, about 5.5 KiB/conn from 20k to 65k (859 to 1,099 MiB). A single slope hides it: the table matters. Scope 7 should decide what it reports (the brief's slope is over all held steps).

## Raw learnings

- macOS ships bash 3.2: no `mapfile`, no `${var,,}`. `lab/check.sh` runs under it, so use `while read` loops.
- A comment that starts with `# shellcheck ` followed by anything is parsed as a directive (`# shellcheck check ...` broke the scan with SC1073). Word comments so they do not start with `shellcheck `.

- Scope 2: BSD `sed -i`/`sed` on macOS refuses `sed '/x/d; s/..'` patterns that GNU accepts when chained with `&&` after a failure: use python3 for multi-line edits of scripts.
- Scope 2: zsh does not word-split `$args` in `for args in "a b"; do cmd $args`: the loop ran nothing silently. Run each Done-when command by hand.
- Scope 2: inside the macro/conformance containers, `docker exec <client> php client.php poll <port>` is the readiness check that also lets bash look at the server container between tries.
- Scope 3: `json_encode` returns `false` on a non-UTF-8 byte (printed as a blank line); a PHP fatal goes to stdout by default in the CLI and lands in whatever file stdout is: run the client with `display_errors=stderr`.
- Scope 3: `stream_socket_client` failing on EMFILE gives errno 0 and an empty message; an unknown errno is a harness failure with the fd limit in the message.
- Scope 3: `docker run --ulimit nofile=65535:65535 --ulimit nofile=256:256` (the same name twice): the last one wins, which is how `--server-nofile` overrides `LAB_RESOURCE_FLAGS`.
- Scope 3: PHP sockets have a read buffer of 8 KiB each by default (500 MiB for 65k): `stream_set_read_buffer($fp, 0)`.
- Scope 3: a `time bash ... | grep` in zsh hides the exit code of the first command (`PIPESTATUS` is empty after `time`): capture `$?` with a redirect to a file.

- Scope 4: **Workerman keeps an HTTP connection alive for 60 s** whatever the request's `Connection: close` or the response's `Connection: close` header says (checked: a raw socket got `Connection: keep-alive`, then silence; with the response header set it still waited 60 s). `$connection->close($response)` sends then closes. Anything that reads "until the server closes" (PHP's `file_get_contents('http://...')`) hangs a minute. Scope 5's conformance cases must not count on the server closing.
- Scope 4: Workerman's master binds the listen port before its worker is forked: a worker that dies at boot (here: `Event` loop class with ext-event not loaded) leaves a port that accepts and never answers, so a readiness poll needs a short socket timeout (`default_socket_timeout=2`).
- Scope 4: the old Docker build cache for the PHP and Swoole layers was gone (no layer reused on the first rebuild of each image), so the four rebuilds include a full PHP + Swoole build. A rebuild after a `php-info` change took under 1 s (all earlier layers reused). The extras layer alone: 11.5 to 14 s.
- Scope 4: macOS `sed -i` with a `#` delimiter and a `"` in the pattern failed silently-ish (`extra characters at the end of l command`) and the `;` after it let a 130 s build start with the old `lib.sh`: use python3 for edits, and `&&` between an edit and a build.

## Where to look

- `lab/check.sh` → `lab_bash_scripts`, `shellcheck_run`, `check_shellcheck*`: what is scanned (every `*.sh` and every bash/sh shebang under `lab/`, minus `lab/data` and `lab/check/fixtures`). A new script is picked up on its own. `@a0477ba`
- `lab/lib.sh` → `LAB_SHELLCHECK_IMAGE`. `@a0477ba`
- `lab/macro.sh`: arguments, the three containers (server, k6, probe), the jq program that builds the JSON.
  `lab/macro/probe.sh`: what is read from outside the cgroups. `@b14068f`
- `lab/lib.sh` → `LAB_SERVER_PHP_FLAGS`, `LAB_CPUSET_*`, `LAB_RESOURCE_FLAGS`, `LAB_K6_IMAGE`. `@b14068f`
- `lab/check.sh` → `CHECKS`: where each scope adds its smoke check. `@b14068f`
- `lab/servers/noop-swoole.php`: the floor server, reads `PORT`. `@b14068f`

- `lab/servers/handler.php`, `lab/servers/bake-swoole.php`: the shared handler and the Swoole bake-off server. `@0d74fda`
- `lab/conformance.sh`, `lab/conformance/client.php`: the conformance test (raw sockets), its fixture `lab/check/fixtures/wrong-swoole.php`. `@0d74fda`
- `lab/lib.sh` → `lab_build_php_flags`, `lab_start_server`, `lab_other_containers`, `lab_socket_line`: the shared start logic. `@0d74fda`
- `lab/macro/k6/posts.js`, `lab/macro/probe.sh` → `memory-now`. `@0d74fda`
- `lab/conns.sh`, `lab/conns/client.php`: the connection test and its client (events, FIFO, address rotation). `@deeb8d1`
- `lab/macro/probe.sh` → `memory-events`, `fresh-request`; `lab/lib.sh` → `LAB_SERVER_NOFILE` in `lab_start_server`. `@deeb8d1`
- `lab/check.sh` → `check_conns_holds_steps`, `check_conns_finds_ceiling`, `check_conns_back_to_back`. `@deeb8d1`

- `lab/images/install-extras.sh`, `lab/images/workerman-nocache.patch`, `lab/images/Dockerfile.src` (last layer, `ARG WITH_EVENT`): pcntl, sockets, event, the two Workerman trees, the fail-loud patch step. `@8c8f7cc`
- `lab/servers/workerman-caches.php`: child per tree, `ReflectionMethod::getStaticVariables()`. `@8c8f7cc`
- `lab/check/fixtures/workerman-hello.php`, `lab/check.sh` → `check_source_extras`, `check_workerman_caches`, `check_workerman_boots`: how a Workerman server boots under the lab (argv, `/tmp` files, `close()` after send). `@8c8f7cc`
- `lab/lib.sh` → `lab_source_release` now prints a 4th field, `WITH_EVENT`. `@8c8f7cc`

## Next steps

1. Scope 5.

## Handover of scope 4

**Created:**

- Image layer (every source image, not `8.3-apt`): `/usr/local/lib/php/extensions/no-debug-non-zts-*/{pcntl,sockets,event}.so`, none enabled globally. Load order: `-d extension=pcntl -d extension=sockets -d extension=event` (sockets before event: event declares it as a dependency).
- Workerman trees: `/opt/workerman/{stock,nocache}/{workerman,coroutine,autoload.php}`. A server file does `require '/opt/workerman/<tree>/autoload.php';`. Both trees declare the same classes: one process loads one tree only. Autoloader maps `Workerman\Coroutine\` to the coroutine `src/` and `Workerman\` to workerman `src/` then coroutine `src/`.
- `lab_source_release <v>` prints `<php> <sha> <WITH_SWOOLE> <WITH_EVENT>`; `build.sh` passes `--build-arg WITH_EVENT`. All four are 1 (event builds on 8.6).
- `php-info`: new last lines `pcntl:`, `sockets:`, `event:`, `workerman:`; it loads the `.so` files it finds (sockets before event). The phase-2 lines are unchanged (the existing checks pass).
- `lab/check/fixtures/workerman-hello.php` (reads `PORT`, `WORKERMAN_TREE`): the pattern for scope 5's real server: `$argv = [__FILE__, 'start']`, `Worker::$pidFile/$statusFile/$logFile` in `/tmp`, `Worker::$eventLoopClass = Workerman\Events\Event::class`, `Worker::runAll()`.
- Pinned: PECL event 3.2.0 `fb3d4e3c...1c`, Workerman 5.2.4 `9fb77c17...5f`, coroutine 1.1.7 `23d05337...88` (sha256 computed from my own download: no publisher checksum exists for these; packagist confirms 1.1.7 is the latest coroutine and pecl.php.net 3.2.0 the latest event on 2026-11-21).
- Build times in `lab/results/build-times.md` (8.5 130 s, 8.5 cached 0 s, 8.6 93 s, 8.4 166 s, 8.3 179 s).

**Decisions on the way:**

- The patch deletes the cache blocks and their lookups, rather than turning `static $x` into a local `$x`: a local array would still be written on every request and thrown away, a cost the stock code does not pay in the nocache tree's favour. Behaviour otherwise unchanged (the cached branch of `baseRead()` called `onMessage` then cloned and destroyed the request; the uncached path decodes and calls `onMessage`, as before the cache existed).
- The build also fails if the **stock** tree does not hold exactly 5 `static $requests|$cache` lines (so a Workerman bump that moves them cannot make the "none left" grep pass for nothing). The grep is `static \$(requests|cache)\b` over `src/` of the patched tree.
- `event` is configured `--with-event-core --with-event-extra --enable-event-sockets --without-event-openssl --without-event-pthreads`. event's configure needs `ext/sockets/php_sockets.h` under the PHP include dir; `make install` of a shared sockets does not put it there, so the script copies it from the tarball.
- `pcntl` and `sockets` are built from the tarball re-downloaded in the last layer (the first layer deletes its own copy), same sha256 check.
- The caches script parses its children's output instead of trusting exit codes only, and prints a `<- expected X` marker on a wrong line.
- Boot check uses `docker exec <server> php -r file_get_contents(...)` (the host network of Docker Desktop is the VM's, not the Mac's), port 18110.
- `check_image_8_*` now also run `check_source_extras` (so `php-info` is run twice per image: 8 extra runs).

**Pitfalls:**

- Workerman and `Connection: close` (see Raw learnings), and a dead worker leaving an answering-nothing port.
- `php-info` on `8.3-apt` prints `pcntl`/`sockets` from Ubuntu's PHP and `event: not built`, `workerman: not built`: no check reads these on that image.
- `reference/workerman` is v5.2.4 like the image's tree; the statics sit at 687, 116, 495, 540, 567 there (the brief said 682 for the first; the patch was made against the tarball the image downloads).

## Questions for the project manager

Rien.

## Retro

(one subsection per scope, at the end of each)

### Scope 1

- **What went well:** the red/green loop was cheap: the check itself is the test, and it failed on real findings first.
- **What cost time:** the brief's SC2086 fixture does not fail at `warning` level (info rating), and shellcheck treats a comment starting with `shellcheck ` as a directive. Both found by running it.
- **Next time:** when a brief names a lint code, check its severity in the pinned version first.

### Scope 2

- **What went well:** writing the client first and pointing it at a deliberately wrong server showed the cases failing for the right reason before any real server existed; the real one then passed at once.
- **What cost time:** the mid-task Relances (socket line, Pss, other containers) touched the same jq program and table as my own changes, so macro.sh was edited in two passes; a silent zsh loop made me think the Done-when runs had printed nothing.
- **Next time:** read the brief's Relances section before starting, not after the first tool calls; run Done-when commands one by one in bash, not in a shell loop.

### Scope 3

- **What went well:** the harness worked on its first real run (server, FIFO-driven client, probe, table), so the time went into the edges: kill the server, starve the client of fds, run twice. Each edge found something real (blank event line, errno 0 on EMFILE).
- **What cost time:** the brief's port range (28,232) did not match the VM (10,536), which only mattered because the client reads the file; a PHP fatal landing in the events file looked like a protocol error for two runs.
- **Next time:** check the VM's kernel settings the brief quotes (`ip_local_port_range`, tw_reuse) with one `docker run` before designing around them; write the check for a failure path before the failure path's code, not after.

### Scope 4

- **What went well:** the caches script as a reflection check read the real thing (5 statics, filled or not) instead of timing, so the patch got a clear red and green; trying two broken patches in a scratch build context proved the loud failure without touching the shared images.
- **What cost time:** Workerman's 60 s keep-alive made my first boot check hang 2 minutes per tree (twice, because the first fix, a `Connection: close` header, did nothing); a failed `sed` followed by `;` started a 130 s build on stale input; the old build cache was gone, so each of the four rebuilds was a full one.
- **Next time:** probe a new server's behaviour with one raw-socket request and a clock before writing a check around it; chain edit and build with `&&`; give every readiness poll a short socket timeout.
