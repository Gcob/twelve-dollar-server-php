# Developer: phase 4, the realistic baseline

**State:** scope 1 done (`64af809`). Challenge suite `passed=42 failed=0` twice in a row, the broken fixture fails on its one golden, app's own cases 57/57, full `bash lab/check.sh` 35/35 ok (2 min), shellcheck clean.

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

1. Scope 2 (the realistic k6 mode) and scope 3 (idle connections, eviction option in `lab_start_app`) build on `lab_start_app`.

## Questions for the project manager

- Rien.

## Retro

### Scope 1

- **Missing:** nothing about the app; the one gap was the tools for `test.sh` (the brief guessed an image with bash, curl, jq, openssl exists locally: none does; `jq` is in no php-lab image). Found by running `command -v` in every local image.
- **Guessed:** that building `php-lab-tools:1` from the pinned Ubuntu with apt is acceptable once the pull of a published image was refused (no confirmation; it is in the README and in "Dead ends").
- **Lost time:** about 10 minutes waiting on `lab/check.sh` with a `pgrep -f lab/check.sh` loop that matched its own shell (the loop never ended); the suite itself took 2 minutes. A harness-level `until [ -f done ]` file would not have that trap.
- **Useless or contradictory instruction:** the brief says "see it fail first" for every case; for the app, the challenge's suite is the failing test and the app does not exist before it, so the app's own 57 cases came after the code (stated in "Verified", checked by mutation instead).
- **Deterministic:** the extra-agent-side guards that bit me were already there (shellcheck on every script, `check.sh`'s counts). One thing: a test count hard-coded in `check.sh` (`[ "$ok" = 40 ]`) forces an edit of the check with each new case; `check_diy_parser` would be steadier counting `FAIL`-free output plus a floor. Impression.
- **Plan should have decided:** where the 4th handler argument goes (I chose a 4th positional argument that the bake-off handler ignores; the alternative, an array or a request object, would have touched every adapter).
- **Blind spot:** nothing watches that the app and the bake-off handler keep the same pragmas: they are copies of each other (`app_boot` and `handler_open_db`). Impression.
