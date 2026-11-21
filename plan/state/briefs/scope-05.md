# Brief: scope 5/7, Workerman bake-off server, caches off and on

**Worktree:** `phase-3-claude` (absolute path in your prompt) · **Run folder:** `plan/` of the main checkout
**Planned commit:** `feat(lab): Workerman bake-off server, caches off and on`

**Read first:** [common.md](common.md), then `plan/state/developer.md` (scopes 1 to 4, above all scope 4's handover:
the extensions, their load order, the two Workerman trees, the boot check).

**Summary:** the second bake-off server: Workerman 5.2.4 on the shared handler, on the Event loop, runnable on both
trees (caches patched out, and stock).

**Today:** `lab/servers/handler.php` (shared handler, scope 2), `lab/servers/bake-swoole.php` (the Swoole adapter: the
model to follow), `conformance.sh`, `macro.sh` and `conns.sh` with `--ext`, `--env`, `--label`. Scope 4 put `pcntl`,
`sockets`, `event` (shared, loaded with `--ext`) and Workerman under `/opt/workerman/stock` and `/opt/workerman/nocache`
(each with `autoload.php`) in the source images, and a throwaway boot check.

**Expected:**

- **`lab/servers/bake-workerman.php`:** loads `/opt/workerman/$WORKERMAN_TREE/autoload.php` (`WORKERMAN_TREE` from the
  environment, `nocache` by default; any other value: exit with a clear message). An HTTP `Worker` on `0.0.0.0:$PORT`,
  `count = 1`, `Worker::$eventLoopClass` set to the Event loop explicitly (refuse to start if `event` isn't loaded:
  never fall back to Select), no daemon, `start` passed in argv by the script itself if missing (the harnesses run
  `php <file>`), pid, status and log files under `/tmp` (the `/lab` mount is read-only), listen backlog 4,096 through
  the context option Workerman supports, `TCP_NODELAY` on (Workerman sets it itself on the listening socket when
  `sockets` is loaded: make sure it does). `onMessage` calls the handler with the request's method, path and body and
  sends its status and body with `Content-Type: application/json`, the way Workerman's own docs do it (a `Response`
  object, or a string; pick the one Workerman users would write, and say which). Prints at boot the tree, the loop
  class, and one socket line in the same format as the Swoole server's (`backlog=… tcp_nodelay=…`), read back from the
  listening socket with `socket_get_option` on `socket_import_stream`, so the harnesses copy it into their JSON.
- **The harnesses** run it with `--ext pcntl --ext sockets --ext event` (that order) and `--env WORKERMAN_TREE=…`,
  `--label nocache` or `--label stock`. If a harness needs a change to run a server that forks (Workerman's master and
  worker are both in the cgroup; `macro.sh`'s Pss sum must cover both processes), make it, with a check.
- **`lab/check.sh`:** conformance on both trees, and a 5 s macro run on the nocache tree with `posts.js` that must be
  VALID. Remove scope 4's throwaway boot fixture if this server makes it redundant (say so).
- **`lab/README.md`:** the Workerman server, how to run each tree, the processes it runs.

**Done when:** `bash lab/conformance.sh --image 8.5 --server lab/servers/bake-workerman.php --ext pcntl --ext sockets
--ext event --env WORKERMAN_TREE=nocache` prints every case `ok`, and the same with `WORKERMAN_TREE=stock`;
`lab/macro.sh --image 8.5 --server lab/servers/bake-workerman.php` (same `--ext`, `--env`, a `--label`) at 7,000 req/s
for 20 s is VALID on `--path /noop` and with `--script lab/macro/k6/posts.js`, for both trees (4 runs); during a run
the server's processes' `/proc/<pid>/maps` show `event.so` and no `swoole.so` (print it from the probe or a one-off
`docker exec`, and report it); the boot line shows the Event loop and `tcp_nodelay=1`; `lab/check.sh` passes (`N/N ok`).

**Seams and cases to test:**

- Conformance cases on both trees (red first: run the conformance before the server exists).
- An unknown `WORKERMAN_TREE` exits with a clear message; a run without `event` loaded refuses to start.
- The JSON of a macro run records the tree (`label`, `env`) and the socket line.
- A smoke `conns.sh` run (`--steps 200,500 --max 500`) on the nocache tree exits 0 with 500 held (no check needed,
  report it): it proves the connection harness sees both processes.

**Tests to imitate:** `lab/check.sh` → `check_conformance_bake_swoole`, `check_macro_bake_swoole_posts_is_valid`.

**Decisions that touch you:**

- Workerman runs with its 5 caches patched out (`nocache`); one run with them on (`stock`) shows what they buy.
- Workerman runs on ext-event; one worker (`count = 1`); the master and the worker both count (CPU and memory).
- Every server: backlog 4,096 and `TCP_NODELAY` on, printed at boot; each runtime keeps its own response headers.
- Smoke runs on a busy VM are not measurements: never commit result files (use `--out` to a temp path).

**Out of scope:** DIY (scope 6), the measurements (scope 7), any change to Workerman's source beyond scope 4's patch.

**Where to look:** `lab/servers/bake-swoole.php` and `handler.php`; `lab/lib.sh` → `lab_start_server`;
`reference/workerman/src/Worker.php` (771-779 pid/log files, 824-834 loop choice, 1121-1132 argv, 2523-2533
`TCP_NODELAY`), `reference/workerman/src/Protocols/Http.php` (`encode`). SHAs in `plan/state/developer.md`.

**Come back to me if:** Workerman can't run with one worker under the harness without changing its source, a
decision is missing, or the "Done when" doesn't pass after 3 tries.

## Notes from scope 4 (before launch)

- Scope 4 found that Workerman 5.2.4 keeps an HTTP connection open for 60 s whatever a `Connection: close` header says
  (request or response); only `$connection->close($response)` closes. If a conformance case or the handler path
  relies on the server closing, handle it in the adapter the way a Workerman user would, and report what you did.
