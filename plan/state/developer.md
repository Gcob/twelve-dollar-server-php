# Developer: phase 3, runtime bake-off

**State:** scope 6 done (`3e74d76`, review fixes `e1cf918`, `9aadddc`), scope 5 done (`ad52342`), scope 4 done (`8c8f7cc`), scope 3 done (`deeb8d1`), scope 2 done (`0d74fda`), scope 1 done (`a0477ba`). Phase 2's handovers are in `plan/runs/phase-2/state/developer.md` (read its "Où regarder"
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
- Scope 5, conformance (red first): before the server existed, `lab/conformance.sh --server lab/servers/bake-workerman.php ...` printed `file not found` (exit 1). Then green on both trees, 8 cases ok each, socket line `backlog=4096 tcp_nodelay=1`, `/noop` bytes `HTTP/1.1 200 OK`, `Content-Type: application/json`, `Connection: keep-alive`, `Content-Length: 15` (no `Server` header with a `Response` object). Refusals by hand: `WORKERMAN_TREE=bogus` exit 1 with the message; without `event` exit 1 with the message (both before the 250 MB copy). The 3 new checks were written after these hand runs (no separate red run).
- Scope 5, Done-when macro runs (8.5, 7000 req/s, 20 s, warm-up 10 s, 23 other containers running, not measurements), all VALID, 0 errors, 0 dropped: nocache `/noop` 21.69 us/req (140,005 req), nocache posts 29.89 (140,002), stock `/noop` 19.70 (139,998), stock posts 31.52 (139,991). Pss under load: 25.9 MiB (`/noop`), 134 MiB (posts), both trees. JSON of the first run: `label nocache`, `ext [pcntl,sockets,event]`, `env [WORKERMAN_TREE=nocache]`, `socket {backlog 4096, tcp_nodelay 1}`.
- Scope 5, maps during the nocache `/noop` run (`docker exec lab-macro-server`, every `/proc/<pid>/maps`): pid 1 `WorkerMan: master process` and pid 8 `WorkerMan: worker process` each show `event.so` (4 mappings) and `swoole.so` 0. Pss of an idle server by pid: master 12.8 MB, worker 7.1 MB: the harnesses' sums see both (cgroup.procs).
- Scope 5, `conns.sh --steps 200,500 --max 500` on nocache: exit 0, 500 held, Pss 19.4 MiB baseline (master + worker), no container left. Full `bash lab/check.sh`: 28/28 ok (26 before, minus the boot check, plus 3).
- Scope 6, red first: both tests were written before the server. Run with no `diy-connection.php`: `Failed opening required`, exit 255. Then against a stub `DiyConnection` that did nothing: the parser cases printed `FAIL` for the expected reason (`the client received ""`; I read the first 12 lines, where only "no answer before the body is whole" passed, as a stub that answers nothing should) and all 4 partial-write cases failed (`0 of 640075 bytes are still buffered`, `reading should be paused`). Real class: first run 29/30 ok, the failing one was the 8 KiB-terminated case, my fixture: `fread` takes at most 8192 bytes from a socket whatever the length asked, so one `onReadable()` had not seen the blank line yet (the event loop wakes up again; the test helper now reads until the server's end is empty with `stream_select`). Then 30/30 parser, 4/4 partial-write. On this VM a Linux `AF_UNIX` pair takes 212,992 bytes before a write is refused; the 640,075-byte response left 420,811 buffered after the first write.
- Scope 6, conformance on `bake-diy.php`: 8 cases ok, `socket: backlog=4096 tcp_nodelay=1`, `loop: epoll`, `accepted socket: tcp_nodelay=1` (read from the first accepted socket: the option is inherited from the listener). `/noop` bytes: `HTTP/1.1 200 OK`, `Content-Type: application/json`, `Content-Length: 15`, nothing else.
- Scope 6, Done-when macro runs (8.5, 7000 req/s, 20 s, warm-up 10 s, 23 other containers running, not measurements), both VALID, 0 errors, 0 dropped: `/noop` 18.2 us/req (140,002 requests, server 12.5 % of one CPU, Pss 22.4 MiB); posts 26.92 us/req (139,997 requests, server 18.5 %, Pss 130 MiB). For reference the same VM, same conditions, scopes 2 and 5: Swoole 21.05 and 31.22, Workerman nocache 21.69 and 29.89. Result files went to the scratchpad (`--out`), none committed.
- Scope 6, `conns.sh --steps 200,500 --max 500` on `bake-diy.php`: exit 0, 500 held, fresh request 0.5 ms, Pss 16.8 MiB at 200 and 500 (slope 0.2 KiB/conn on 2 steps, which says nothing), memory.current slope 3.91 KiB/conn, no container left.
- Scope 6, boot lines of the three servers (8.5): Swoole `listening on 0.0.0.0:18151` / `socket: backlog=4096 tcp_nodelay=1`; Workerman `tree: nocache` / `loop: Workerman\Events\Event` / `socket: backlog=4096 tcp_nodelay=1`; DIY `listening on 0.0.0.0:18153` / `loop: epoll` / `socket: backlog=4096 tcp_nodelay=1`.
- Scope 6, full `bash lab/check.sh`: 32/32 ok (28 before, plus `check_diy_parser`, `check_diy_partial_write`, `check_conformance_bake_diy`, `check_macro_bake_diy_posts_is_valid`), 117 s. The 4 new checks were written after the tests and the hand runs had passed (no separate red run of the checks).

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
- **Scope 5, Response object, not a string:** `onMessage` sends `new Response($status, ['Content-Type' => 'application/json'], $body)`: the handler gives a status and a string would always answer 200 `text/html` (`Http::encode`). A Workerman user who needs a status and a type writes this.
- **Scope 5, boot output comes from `onWorkerStart`:** the worker holds the inherited listening socket (`getMainSocket()`), so `tree:`, `loop:` and `socket:` lines are printed once there, after the handle is opened. Port is bound by the master before that; the harnesses' readiness polls answer only once the worker serves.
- **Scope 5, backlog is the asked value, not read back:** `socket_get_option` has no backlog option and `/proc/net/tcp` shows 0 in `tx_queue` for a listener here. `tcp_nodelay` is read back. Kernel `somaxconn` on the VM is 4096, so the 4,096 is not clamped. Workerman's own default backlog is 102,400.
- **Scope 5, socket line key:** `tcp_nodelay` (Swoole's is `open_tcp_nodelay`): JSON `server.socket` takes the keys the server prints, so a reader joining the two runtimes must map them.
- **Scope 5, no harness change:** macro.sh, conformance.sh and conns.sh already sum CPU (cgroup), Pss and VmHWM over every pid of the cgroup, so the master is counted. Conformance needed no close from the server (no case reads until EOF).
- **Scope 5, throwaway boot check removed:** `check_workerman_boots` and `check/fixtures/workerman-hello.php` are gone: the conformance check on both trees proves the server boots on each tree with Event and answers. The README keeps the 60 s keep-alive trap.
- **Scope 5, handler split:** `handler_copy_db()` runs in the master before `new Worker`, `handler_open_db()` in `onWorkerStart`.
- **Scope 5, loop not asserted by a check:** the server refuses without `event` and sets `Worker::$eventLoopClass = Event::class`; the boot line prints the class (read it with `docker logs`). No automated check reads the `loop:` line.
- **Scope 6, one connection class, no loop inside:** `DiyConnection` (`lab/servers/diy-connection.php`) takes a non-blocking stream and offers `onReadable()` / `onWritable()` (both return false when the connection is finished), `wantsRead()` / `wantsWrite()`, `pendingBytes()`, `close()`. The loop (`bake-diy.php`, classes `DiyPeer` and `DiyServer`) only turns events on and off from those two `wants` answers. The tests drive it on a socket pair.
- **Scope 6, state per connection is an object** (`DiyPeer`: connection, read event, write event, two booleans of what is armed) allocated at accept; a request allocates only its strings (the parsed fields are properties of the connection, not a returned array). Event callbacks are closures made once (`$this->onReadable(...)`) and the peer travels as the event's `$arg`, so no closure per connection. The peer and its events point at each other: `settle()` frees the events and nulls them before closing the stream, which breaks the cycle at once (no cycle collector run).
- **Scope 6, `DiyConnection` calls the global `handler_handle()`,** like every adapter. The tests define a stub with the same name (`lab/check/diy-lib.php`: echoes `<method> <path> <body>`, and `/big/<n>` answers n bytes of counters) and do not load `handler.php`.
- **Scope 6, one `fread` per readable event, 8,192 bytes:** PHP reads at most 8 KiB from a socket per `fread()` whatever length is asked. The event is level-triggered, so the next callback reads the rest.
- **Scope 6, additions the brief did not list, all in the README:** a `Content-Length` over 1 MiB (or 8+ digits) is a 400 and a close (bounds one connection's memory); two `Content-Length` headers are a 400; the 8 KiB limit counts the blank line, and an unterminated block is cut as soon as it passes 8 KiB; a header line only has to have a name and a colon. While the write buffer is at 1 MiB or more, **already received requests are not answered either** (parsing stops, they wait in the read buffer): without that, one 64 KiB read of pipelined requests could still grow the buffer without bound.
- **Scope 6, HTTP/1.0 with keep-alive:** stays open, answer has no `Connection` header (the brief said "nothing else"), so clients that need the header close on their own. `Connection: close` check is `str_contains` on the lowercased value, so `keep-alive, close` closes.
- **Scope 6, EOF means free now:** a client that half-closes (sends, then shuts its write side) after a request loses an answer the socket had not taken yet; answers the socket takes at once (all of them in practice) go out in the same callback as the request.
- **Scope 6, socket line key renamed in Swoole:** `bake-swoole.php` prints `backlog=4096 tcp_nodelay=1` (was `open_tcp_nodelay`); the Swoole checks in `check.sh`, `conformance.sh`'s comment and the README follow. JSON `server.socket` of a Swoole run is now `{backlog, tcp_nodelay}` like the other two (older result files, if any, kept `open_tcp_nodelay`: none is committed).
- **Scope 6, no signal handling:** the server does not catch SIGTERM (pid 1 in the container ignores it); the harnesses remove containers with `docker rm -f`.

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
- Scope 5: Workerman's `Response` object adds no `Server` header (only `Connection: keep-alive`, `Content-Length`, the headers given); the string path adds `Content-Type: text/html;charset=utf-8` by default.
- Scope 5: zsh again: `for run in ...; do set -- $run` and `[ $k = posts ]` parse-error; a `*.md` glob that matches nothing aborts the command in zsh. Put multi-run loops in a small bash script file. Also a `git rm --cached` after a `;` ran even though the earlier grep failed: it staged a deletion (harmless here, it was the deletion I wanted).
- Scope 5: `/proc/net/tcp` hex port: 18120 is 0x46C8 (I first looked for 0x4960).
- Scope 6: `fread($socket, N)` returns at most 8,192 bytes for any N; `fwrite` on a non-blocking socket that is full returns 0 (no notice) and `@fwrite` on a peer that is gone returns false; `fread` returning `''` is EAGAIN unless `feof()`.
- Scope 6: a `stream_socket_pair` (AF_UNIX) takes 212,992 bytes on this VM before a non-blocking write is refused; ext-event takes a stream resource as the fd of an `Event` and passes it back as the callback's first argument.
- Scope 6: `stream_socket_accept($listener, 0)` on a non-blocking listener returns false (and warns, hence `@`) when the queue is empty: that is the end of the accept loop.

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
- `lab/servers/bake-workerman.php`: the Workerman bake-off server (trees, Event loop, backlog, boot lines). `@ad52342`
- `lab/check.sh` → `check_conformance_bake_workerman`, `check_workerman_server_refuses`, `check_macro_bake_workerman_posts_is_valid`; `lab/README.md` "Bake-off servers". `@ad52342`
- `lab/servers/bake-diy.php`, `lab/servers/diy-connection.php`: the DIY server (loop and `DiyConnection`, parser and write buffer). `@3e74d76`
- `lab/check/diy-lib.php`, `diy-parser-test.php`, `diy-partial-write-test.php`: the two tests, a stub handler and a socket pair helper; `lab/check.sh` → `check_diy_parser`, `check_diy_partial_write`, `check_conformance_bake_diy`, `check_macro_bake_diy_posts_is_valid`. `@3e74d76`

## Next steps

1. Scope 7.

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

## Handover of scope 5

**Created:** `lab/servers/bake-workerman.php` (reads `PORT`, `WORKERMAN_TREE` = `nocache` default or `stock`); three checks in `lab/check.sh`. Removed: `check_workerman_boots` and `check/fixtures/workerman-hello.php`.

**How to run it:** `--ext pcntl --ext sockets --ext event` (that order) `--env WORKERMAN_TREE=<tree> --label <tree>`. Boot prints `tree: ...`, `loop: Workerman\Events\Event`, `socket: backlog=4096 tcp_nodelay=1`.

**For scope 6 (DIY server):** use the same shape: `handler_copy_db()` before any fork, `handler_open_db()` per worker, boot line `socket: backlog=4096 tcp_nodelay=<n>` (key `tcp_nodelay`, read back with `socket_get_option` if `sockets` is loaded). A server file that exits before the copy (bad env) is cheap to check from `lab/run.sh 8.5 env K=V php ...`.

**Pitfalls:** Workerman's master and worker both run: any measurement that reads one pid misses the other (the lab's three scripts read the cgroup). Workerman keeps a connection 60 s whatever `Connection: close` says. For scope 7: nocache vs stock noop differ by about 2 us/req on a busy VM (21.7 vs 19.7: inside the noise, nothing to conclude).

## Handover of scope 6

**Created:** `lab/servers/bake-diy.php` (reads `PORT`; run with `--ext sockets --ext event`, that order), `lab/servers/diy-connection.php` (`DiyConnection`), `lab/check/diy-lib.php`, `diy-parser-test.php`, `diy-partial-write-test.php`, four checks in `lab/check.sh`. Changed: `bake-swoole.php` boot line (`tcp_nodelay`), the Swoole expectations in `check.sh`, `conformance.sh` comment, README.

**How to run it:** `bash lab/macro.sh --image 8.5 --server lab/servers/bake-diy.php --ext sockets --ext event --label diy --rate 7000 --duration 20 --path /posts/1 --script lab/macro/k6/posts.js`. Boot prints `listening on ...`, `loop: epoll`, `socket: backlog=4096 tcp_nodelay=1`, then `accepted socket: tcp_nodelay=1` once, at the first connection. JSON `server.ext` is `["sockets","event"]`.

**For scope 7:** one process, so the server's CPU is the whole cgroup's. Smoke numbers on a busy VM (not measurements): `/noop` 18.2 us/req, posts 26.9, against Swoole 21.1 / 31.2 and Workerman 21.7 / 29.9 under the same conditions. Memory per connection can be compared: DIY memory.current slope 3.9 KiB/conn on 200 to 500 (Pss slope 0.2 KiB/conn, too few connections to mean anything). The macro run holds 700 connections (k6 VUs).

**Pitfalls:** `fread` on a socket gives at most 8 KiB, so a test that calls `onReadable()` once per write must loop until the server's end is empty. The 400 rules are strict (Content-Length twice, over 1 MiB, any Transfer-Encoding): a later phase that adds a client sending any of these needs the parser changed, not the test. At the fd limit the listening event spins (accept fails, fires again): not shed yet.

## Handover of scope 6, review fixes (`e1cf918`)

Three fixes from the pr-reviewer in one commit: (1) the dead `wait` mode of `lab/conformance/client.php` is gone (only `poll` and `run`; header and usage text updated); (2) `bake-workerman.php`'s comment no longer claims a `Server` header (Workerman 5.2.4 adds only Content-Length and Connection with a `Response` object); (3) `conformance.sh` prints `event loop the server printed at boot: <loop>` (read from the `loop:` boot line, nothing printed when there is none) just before the socket line. `check_conformance_bake_workerman` asserts `Workerman\Events\Event` on both trees, and `check_conformance_bake_diy` asserts `epoll`. README updated. Full `bash lab/check.sh`: 32/32 ok. Both new assertions passed on first run (no separate red run); the Workerman conformance by hand printed `event loop the server printed at boot: Workerman\Events\Event`.

## Handover of scope 6, blind-review fixes (`9aadddc`)

- **Pss_Anon:** `probe.sh memory-now` also prints `memory_now pss_anon_kb` (sum of `Pss_Anon` over the cgroup's processes). macro JSON: `results.memory.under_load.samples.*.pss_anon_kb` and `max_pss_anon_mib` (the table line reads `Pss .. (with the mapped database), Pss_Anon .., memory.current ..`). conns JSON: `steps[].probe.pss_anon_kb`, `results.baseline.pss_anon_kb`, `results.memory_per_connection.pss_anon_kib_per_connection`; table gets a `Pss_Anon MiB` column, a Pss_Anon slope and a baseline Pss_Anon. Checks assert `Pss_Anon > 0` and `< Pss` on the posts runs and the conns step. README says runtimes are compared on `Pss_Anon` and `memory.current`, with the reason. Evidence, Swoole 8.5, 7000 req/s, 10 s, warm-up 5 s: `/posts/1` Pss 139.35 MiB, Pss_Anon 12.49 MiB; `/noop` Pss 31.32 MiB, Pss_Anon 12.49 MiB (the same): Pss moves with the database pages touched, Pss_Anon does not. **Result files of earlier runs lack `pss_anon_kb`.**
- **DIY 500:** `handler_handle()` is in `try/catch (Throwable)`: logs one line to stderr, answers `500 {"error":"internal server error"}` (reason phrase added), connection keeps serving. Parser test case (stub `/boom` throws; both in one piece and in two).
- **DIY whitespace before the colon:** a space or tab before the colon, or a line starting with one (obsolete fold), is a 400 and a close. Three parser cases. Red run: against the previous `diy-connection.php` (in a scratch copy of `lab/`) the space and tab cases and the 500 case failed (the fold case already passed: a continuation line has no colon). Parser test is now 34 cases; `check_diy_parser` expects 34.
- **Docs:** README `micro.sh` does not record other containers (said so); `conformance.sh` says three pipelined requests; the "allocates nothing" claims in `diy-connection.php`, `bake-diy.php` and the README now list what a request allocates (its strings, the `explode()` array of header lines, its response); `install-extras.sh` comment on the libevent version now says the Ubuntu archive on build day, and **the next image build rebuilds the extras layer because of that comment (apt could give another libevent): I did not rebuild**; I did not add the libevent version to `php-info`.
- **Workerman 60 s claim was wrong** (scope 4's "Raw learnings" entry too): a raw socket that sent `Connection: close` got its answer (`Connection: keep-alive`) at once, then 100 s of silence with no close from the server; the 60 s was PHP's `default_socket_timeout` on the client. README corrected: Workerman ignores `Connection: close` and keeps the connection open.
- Left alone as asked: items 9, 10, 11. Full `bash lab/check.sh`: 32/32 ok.

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

### Scope 5

- **What went well:** the harnesses already summed over the whole cgroup, so a forking server needed no harness change; the maps and Pss-by-pid one-offs proved it in two `docker exec`s.
- **What cost time:** zsh again (a `set -- $run` loop and an unmatched glob), and I looked for the wrong hex port when I tried to read the backlog back (it turned out `/proc/net/tcp` does not carry it anyway).
- **Next time:** write any multi-run loop as a bash file from the start; before promising a read-back of a kernel value, check on a running container that the file shows it.

### Scope 6

- **What went well:** making the connection class loop-free (a stream in, `wants*` answers out) let both hard behaviours (every byte-position cut, a partial write) be tested on a socket pair in seconds, and the first end-to-end run (conformance) passed at once.
- **What cost time:** one failing case turned out to be my fixture (`fread` returns 8 KiB at most); the 2 macro runs and the full check are the long part (about 6 minutes of waiting in all).
- **Next time:** look up what a PHP stream call returns at its limits (read size, EAGAIN, EPIPE) in a 5-line script before writing the class around it; stub the unit first so the tests show red per case, not a missing-file fatal.
