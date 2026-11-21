# Brief: scope 2/7, shared handler, Swoole bake-off server, conformance

**Worktree:** `phase-3-claude` (absolute path in your prompt) · **Run folder:** `plan/` of the main checkout
**Planned commit:** `feat(lab): shared handler, Swoole bake-off server, conformance`

**Read first:** [common.md](common.md), then `plan/state/developer.md` (scope 1's handover: bash 3.2 on macOS, no
`mapfile`; a comment starting with `# shellcheck ` is a directive). Then `lab/README.md` (macro harness section).

**Summary:** one handler that every runtime of the bake-off will call, the first bake-off server (Swoole) on it, a
conformance test that proves a server speaks HTTP/1.1 correctly with that handler, a k6 script for `GET /posts/:id`,
and three `macro.sh` options (`--ext`, `--env`, `--label`) plus the quiet-VM record.

**Today:** `lab/macro.sh` loads a server in a lab container with k6 at a fixed rate (three containers: server, k6,
probe). `LAB_SERVER_PHP_FLAGS` in `lab/lib.sh` hard-codes `-d extension=swoole`, and `macro.sh` probes Swoole's
version with it. `lab/servers/noop-swoole.php` answers `{"status":"ok"}` to everything. Scope 1 added shellcheck to
`lab/check.sh` (`a0477ba`): your new scripts are linted automatically.

**Expected:**

- **`lab/servers/handler.php`:** no runtime code. One function (method, path, body in; status and body bytes out),
  plus a boot function that opens the database. Routes, error bodies exactly as the spec
  (`reference/twelve-dollar-server-challenge/SPEC.md`, "Errors": `{"error":"<message>"}`):
  - `GET /noop`: 200 `{"status":"ok"}`, no database;
  - `GET /posts/:id`: the spec's post query with `WHERE p.id = ?` (SPEC.md, the SQL block under "Endpoints"), a PDO
    statement prepared once at boot; 200 `{"post":{"id":…,"body":…,"created_at":…,"author":…,"like_count":…}}`,
    compact JSON, keys in that order, ints as ints; 404 `post not found`; 400 `invalid post id` when `:id` isn't a
    positive integer (`0`, `-1`, `abc`, `1.5`, empty);
  - anything else (other paths, other methods): 404 `not found`.
  - **Database:** at boot the server copies `lab/data/feed.db` (mounted at `/lab/data/feed.db`) to a path inside its
    own container (for example `/tmp/feed.db`) and opens the copy. Never open the file in `lab/data/` itself: it's in
    WAL mode and leaves `-wal`/`-shm` files. Pragmas of mattsplat's entry
    (`reference/.../submissions/php-swoole-mattsplat/server.php` lines 50 to 56: WAL, `synchronous=NORMAL`,
    `busy_timeout`, 64 MiB cache, 256 MiB mmap, `temp_store=MEMORY`).
- **`lab/servers/bake-swoole.php`:** the no-op server's settings (`SWOOLE_BASE`, `worker_num` 1, no coroutine,
  POST/cookie/file parsing and compression off, `backlog` 4096, `max_connection` 65535) plus `open_tcp_nodelay =>
  true`, calling the handler, `Content-Type: application/json`, the status from the handler. Reads `PORT` like the
  no-op server. Prints a line once ready, after the database copy (the copy takes a few seconds: `macro.sh` already
  waits until the server answers; check its timeout is long enough).
- **`lab/conformance.sh --image <v> --server <file> [--ext <e>]... [--env K=V]... [--port N]`:** starts the server in a
  lab container the way `macro.sh` does (reuse or factor the start logic into `lib.sh`, your call), runs a PHP client
  (raw `stream_socket_client`, no curl) in a lab container on the host network, one line per case `ok` or
  `FAIL: <why>`, exit non-zero if any fails, the containers removed whatever happens (trap). Cases:
  1. `/noop`: 200, body `{"status":"ok"}`, `Content-Type: application/json`;
  2. `/posts/1`: equals, **as JSON values**, what `sqlite3` gives for id 1 with the same query (compute the expected
     object on the Mac with `sqlite3 "file:lab/data/feed.db?immutable=1"`, column `username` → key `author`), and its
     keys are in the spec's order;
  3. `/posts/999999999`: 404 `{"error":"post not found"}`; `/posts/abc`, `/posts/0`, `/posts/1.5`: 400
     `{"error":"invalid post id"}`; `/nope`: 404 `{"error":"not found"}`;
  4. two requests on one keep-alive connection, both answered;
  5. two requests pipelined in a single write, both answered in order;
  6. one request split across two writes (cut in the middle of the headers, 50 ms apart), answered;
  7. a `POST /nope` with a `Content-Length` body: 404, and the same connection then serves `GET /noop`;
  8. prints the exact response bytes of `/noop` (headers included) and whether `TCP_NODELAY` is on for the server's
     accepted socket if you can read it (from `/proc/net/tcp` it isn't visible: if there's no clean way, print
     "TCP_NODELAY: set by the server's config" from a value the server prints at start, your call, say which).
- **`lab/macro/k6/posts.js`:** like `fixed-rate.js` (`constant-arrival-rate`, same env vars), the URL `/posts/<id>`
  with the id from a fixed sequence over 1 to 500,000 (the seed's post ids), the same on every run: for example from
  the scenario's iteration counter times a large prime, modulo 500,000, plus 1. No `Math.random`.
- **`macro.sh` options:** `--ext <name>` (repeatable; default `swoole`, which keeps today's behavior), building the
  `-d extension=...` flags from it (move `-d extension=swoole` out of `LAB_SERVER_PHP_FLAGS`); probe Swoole's version
  only when `swoole` is among the extensions; `--env K=V` (repeatable, passed to the server container with `-e`);
  `--label <text>` (in the JSON and in the file name after the server name). The JSON records `ext`, `env` and
  `label`.
- **Quiet VM:** `macro.sh` (and from now on every measuring script) records `other_containers`: the count and names of
  running containers that aren't the lab's own, read just before the measured run. Above 0: a `WARNING: N other
  containers running (...)` line in the output; the run still completes and its validity isn't changed (smoke runs
  aren't measurements).
- **`lab/check.sh`:** a conformance smoke check on `bake-swoole.php` (image `8.5`), and a 5 s macro run of
  `bake-swoole.php` with `posts.js` that must be VALID.
- **`lab/README.md`:** the handler, the conformance test, `posts.js`, the new options, `other_containers`.

**Interfaces:** `handler.php`'s function names are yours; scopes 5 and 6 will call them from Workerman and DIY
adapters, so keep them runtime-free (no Swoole types).

**Done when:** `bash lab/conformance.sh --image 8.5 --server lab/servers/bake-swoole.php` prints every case `ok`;
`lab/macro.sh --image 8.5 --server lab/servers/bake-swoole.php --rate 7000 --duration 20` is VALID on `--path /noop`
and with `--script lab/macro/k6/posts.js`; its JSON holds `other_containers` and the `ext`, `env`, `label` used; the
whole `lab/check.sh` passes (report `N/N ok`).

**Seams and cases to test:**

- Conformance cases 1 to 8 above, red first (write the conformance client before the server, see it fail).
- A conformance failure exits non-zero and names the case; the containers are removed after a failure.
- `macro.sh` with `--env FOO=bar --label test` records both, and the label is in the file name; without `--ext` the
  old no-op Swoole run behaves as before (`check_macro_noop_is_valid` still passes).
- `other_containers` names the running non-lab containers (there are other projects' containers on the VM right now:
  that's a fine live test; never stop them).

**Tests to imitate:** `lab/check.sh` → `check_macro_noop_is_valid`, `check_macro_marks_invalid_run`,
`check_macro_cleans_up_after_failure`.

**Decisions that touch you:**

- Two routes in the bake-off: `GET /noop` (the runtime alone) and `GET /posts/:id` (plus one indexed read).
- The same handler for every runtime; each runtime keeps its own response headers, and the conformance prints the
  exact response bytes.
- Every server: listen backlog 4,096 and `TCP_NODELAY` on.
- A quiet VM for measurements: measuring scripts record the other running containers.

**Out of scope:** the connection harness (scope 3), Workerman and ext-event (scopes 4 and 5), DIY (scope 6), any
measurement for the results (scope 7). Don't touch `noop-swoole.php` or the phase 2 results.

**Where to look:** `lab/macro.sh` (server start, readiness wait, port check, trap, JSON via jq) `@a0477ba`;
`lab/macro/probe.sh` `@b14068f`; `lab/macro/k6/fixed-rate.js` `@b14068f`; `lab/lib.sh` → `LAB_SERVER_PHP_FLAGS`
`@a0477ba`; `lab/run.sh` (mounts, limits) `@b14068f`.

**Come back to me if:** a decision is missing from this brief, the database copy makes the server too slow to start
for `macro.sh`'s wait, or the "Done when" doesn't pass after 3 tries.

## Relances

- **2026-11-21 16:47:** three additions from the delta plan review, same commit:
  1. **Socket settings recorded:** `bake-swoole.php` prints one line at boot with its configured `backlog` and
     `open_tcp_nodelay` (Swoole can't read them back: the images' Swoole isn't built with sockets). `macro.sh` and
     `conformance.sh` copy that line into their output and the JSON (`server.socket`). Conformance case 8 prints it
     instead of guessing `TCP_NODELAY` from the client side.
  2. **Peak memory under load in Pss:** `macro.sh` samples, from the probe, the sum of `Pss` from
     `/proc/<pid>/smaps_rollup` over the server's processes and the cgroup's `memory.current`, at 1/4, 1/2 and 3/4
     of the measured run (like the connection count), keeps the three in the JSON and shows the largest of each in the
     table. Keep `memory.peak` and `VmHWM` as they are.
  3. **`other_containers` = every running container that isn't this run's own** (not "not the lab's"): a lab run
     started from another checkout during a measurement is noise too.
