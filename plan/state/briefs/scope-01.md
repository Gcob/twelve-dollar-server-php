# Brief: scope 1/5, the walking skeleton

**Read first:** [common.md](common.md) (how phase 4 differs from your agent file), then `plan/state/developer.md` if it
exists.
**Worktree:** `.claude/worktrees/twelve-dollar-server-php/phase-4-claude` under the home folder (your prompt gives the
full path) · **Your handover:** `plan/state/developer.md` in the main checkout.
**Planned commit:** `feat(app): the five endpoints on the DIY loop, the challenge's tests`

**Summary:** the challenge's 5 endpoints served by the lab's DIY server (our own ext-event loop and HTTP parser), with
the simplest variant of every step, passing the challenge's own 42-check test suite.

**Today:** the lab has three bake-off servers (`lab/servers/bake-*.php`) on one shared `handler.php` with two read
routes only (`GET /noop`, `GET /posts/:id`). The DIY server is `lab/servers/bake-diy.php` (ext-event loop) and
`lab/servers/diy-connection.php` (`DiyConnection`: parser, keep-alive, pipelining, partial writes); the connection calls
the global `handler_handle($method, $path, $body)` and reads only `Content-Length`, `Connection` and
`Transfer-Encoding`. `lab/conformance.sh` shows how a harness starts a server in a lab container (`lab/lib.sh` →
`lab_start_server`, which mounts `lab/data` read-only); `lab/check.sh` is the lab's suite (32 checks today).

**Expected:**

- **The app** in a new folder `lab/app/` (you pick the file split): the routes, the JWT check, and the server entry
  `lab/app/server.php` on the DIY loop. It reads its config like a challenge submission: env `SQLITE_PATH` (it opens
  this file, never copies it), `JWT_SECRET`, `HOST` (default `0.0.0.0`), `PORT`. Pragmas as `handler.php`'s (WAL,
  `synchronous = NORMAL`, `busy_timeout`, 64 MiB cache, 256 MiB mmap, `temp_store` memory); statements prepared once at
  boot; it listens only once the database is open. Backlog 4,096 and `TCP_NODELAY` like `bake-diy.php`, with its boot
  lines (`listening on`, `loop:`, `socket: backlog=... tcp_nodelay=...`).
- **The 5 endpoints**, exactly as `reference/twelve-dollar-server-challenge/SPEC.md` says (bytes, key order, error
  table, auth before id). The simplest variant of every step, on purpose (the next phase measures alternatives one by
  one, so don't optimize anything):
  - **S2 parse:** the DIY parser, extended to read `Authorization` and hand it to the app with the method, the path
    and the body.
  - **S3 route:** a plain match on method and path in the app.
  - **One function per step:** keep the JWT check, the validation, each query, the JSON building and the response
    building each in their own function, named by what it does (for example `jwt_verify`, `post_query`,
    `feed_json`). A later scope profiles the server and maps functions to steps: a step inlined into a route function
    couldn't be told apart.
  - **S4 JWT:** hand-written HS256: split on `.` (exactly 3 parts), base64url decode with `strtr` + `base64_decode`,
    `json_decode` the header (its `alg` must be exactly `HS256`) and the payload, `hash_hmac('sha256', "$h.$p",
    JWT_SECRET, true)` compared with `hash_equals`, `exp` required (a token without `exp` is rejected: the challenge's
    reviewers flag that) and in the future. Then the payload: `sub` a string of a positive integer, `username` a string,
    else `invalid token payload`. No header or no `Bearer ` prefix: `missing bearer token`; any other failure:
    `invalid or expired token`. Every token is verified on every request.
  - **S5 validate:** id with `ctype_digit` and `> 0`; body with `json_decode`: invalid JSON gives `malformed JSON
    body`; not an object, or `body` missing or not a string, or empty after `trim`: `body is required`; over 500
    characters after `trim` (`mb_strlen`): `body must be at most 500 characters`.
  - **S6 SQLite:** PDO SQLite with the spec's reference SQL: the post query with `ORDER BY p.created_at DESC, p.id DESC
    LIMIT 20` for `/feed` and `WHERE p.id = ?` for one post (`like_count` from the correlated `count(*)`); `INSERT INTO
    posts (user_id, body) VALUES (?, ?) RETURNING id, created_at` for a new post; for a like, check the post exists
    first (SQLite does not enforce the foreign key), then `INSERT ... ON CONFLICT (user_id, post_id) DO NOTHING`, 201
    when it inserted a row, 200 when not. `FETCH_ASSOC`.
  - **S7 JSON:** `json_encode` of arrays in the spec's key order, `JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE`.
    `id` and `like_count` are JSON integers.
  - **S8 write:** the DIY response (status line, `Content-Type: application/json`, `Content-Length`, body). The DIY
    status map (`DiyConnection::HEAD`) has only 200, 400, 404 and 500: add 201, 401 and 503 (an unknown status today
    builds a response with no status line).
  - **S9 durability:** autocommit, one transaction per write, `wal_autocheckpoint` at its default. Each write is
    committed before its response.
  - **`GET /health`:** `SELECT 1`, then `{"status":"ok","db":"ok","uptime_s":N}` (whole seconds since boot); a failing
    query gives the spec's 503 `{"status":"degraded","db":"unreachable","error":"..."}`.
  - **Auth before id** on `POST /posts/:id/like`: check the token first, so `/posts/abc/like` without a token is 401,
    with a valid token 400.
  - An exception inside a route: 500 `internal server error`, and the connection serves on.
- **A fresh database per run:** one function in `lab/lib.sh` that every harness running the app will use (the next
  scopes reuse it in `realistic.sh` and `macro.sh`, and add an eviction option to it): it copies `lab/data/feed.db`
  **with `cp` inside the server container** (so the copy's page cache is charged to the server's cgroup, like the
  bake-off's), `fsync`s the copy (`sync <file>`), then starts the app with `SQLITE_PATH` set to it. Never write into
  `lab/data/`. The app itself only opens `SQLITE_PATH`.
- **The test harness:** `lab/challenge-test.sh --image <v> [--server <file>] [--ext <e>]...` (defaults: `8.5`,
  `lab/app/server.php`, `--ext sockets --ext event`). It starts the server on a fresh copy, waits for `GET /health`
  (60 s at most, like `test/run.sh`), runs `reference/twelve-dollar-server-challenge/test/test.sh` **unchanged**
  against it with `JWT_SECRET=twelve-dollar-challenge`, prints its output, exits with its code, and removes its
  containers in every case (trap). `test.sh` needs `bash`, `curl`, `jq`, `openssl`. Facts: the lab images have no
  `jq`; macOS reaches a `--network host` container only when Docker Desktop's host networking setting is on, and you
  must not change Docker Desktop's settings. So the likely path is a container on the host network from a small image
  with the four tools, pinned by tag and digest in `lib.sh` like the k6 and shellcheck images (no package install at
  run time). Check what works, and say why in the README.
- **`lab/check.sh`:** a check that runs the challenge's tests on the skeleton, one that the harness fails on a broken
  server (a fixture server under `lab/check/fixtures/` that answers one golden wrong), and the DIY parser test
  (`lab/check/diy-parser-test.php`) gains `Authorization` and a POST body split across reads. Every existing check stays
  green, the bake-off's included (its servers and `handler.php` keep working).
- **`lab/README.md`:** a short section for the app and `challenge-test.sh`.

**Key interfaces:** `lab/app/server.php` (entry), env `SQLITE_PATH`, `JWT_SECRET`, `HOST`, `PORT`; the DIY
connection's call into the app gains the `Authorization` value; `lab/challenge-test.sh`.

**Done when:** `bash lab/challenge-test.sh --image 8.5` prints the challenge's `passed=42 failed=0` and exits 0, twice
in a row (a fresh seed copy each time); with a fixture server that answers one golden wrong it exits non-zero and names
the failing check; `bash lab/check.sh` is all `ok`, its bake-off checks unchanged.

**Seams and cases to test:** the challenge's 42 checks (they cover the golden reads, health, 404s, id validation, the
7 bad tokens, auth before id, the 6 body errors, create, like, read back, feed order); the broken fixture; the parser
cases above; a second run right after the first (a fresh copy: the golden checks would fail on a reused database).

**Tests to imitate:** `check_conformance_bake_diy` and `check_conformance_fails_on_wrong_server` in `lab/check.sh`
(a harness run, and the same harness against a broken fixture), `lab/check/diy-parser-test.php` (raw byte strings,
every cut position).

**Decisions that touch you:**

- D29: rule 5, every request reads its own data; nothing read for one request answers another.
- D32: the app opens `SQLITE_PATH`, never copies it; the lab gives each run a fresh copy; the bake-off keeps working.
- D42: one seed-copy function in `lib.sh`, `cp` inside the server container, then `fsync` (scope 3 adds eviction).
- D35: PHP 8.5, the DIY loop.
- D17/D18: ext-event for the loop, extensions loaded in the order `sockets`, `event`.

**Out of scope:** the realistic k6 mode (scope 2), idle connections and per-second telemetry (scope 3; don't add
telemetry yet), the profiler (scope 4), any measurement (scope 5), any optimization of a step (next phase), the
submission folder (`install.sh`, `build.sh`, `start.sh`: a later phase).

**Where to look:**

- `lab/servers/diy-connection.php`: the parser and the call into the handler; `lab/servers/bake-diy.php`: the loop and
  the socket settings to reuse.
- `lab/servers/handler.php`: pragmas and the post query (don't break it: the bake-off uses it).
- `lab/conformance.sh` and `lab/lib.sh` (`lab_start_server`, `lab_in_container_path`): how a harness starts a server.
- `reference/twelve-dollar-server-challenge/test/test.sh` and `test/run.sh`: what the tests need (fresh database, the
  `/health` wait, `JWT_SECRET`).
- `plan/runs/phase-3/state/developer.md`: "Raw learnings" on the DIY server and the harnesses.

**Come back to me if:** a decision is missing from this brief, the spec and `test.sh` disagree, or the Done-when
doesn't pass after 3 tries.
