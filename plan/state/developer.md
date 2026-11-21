# Developer: phase 3, runtime bake-off

**State:** scope 2 done (`0d74fda`), scope 1 done (`a0477ba`). Phase 2's handovers are in `plan/runs/phase-2/state/developer.md` (read its "Où regarder"
and "Impasses" if you touch `macro.sh`, `micro.sh`, `seed.sh` or the images).

## Verified

- Scope 1: `check_shellcheck` failed before the fixes (SC2034 on `lib.sh` variables and `sha` in check.sh, SC1007 on `pre_vus= max_vus=` in macro.sh, SC2148 on `lib.sh`), passed after. The fixture first exited 0 with SC2086 (info level, and a literal-valued variable), then exited 1 with SC2046. Full `bash lab/check.sh`: 18/18 ok (39 s).

- Scope 2, conformance (red first): `lab/conformance.sh --server lab/servers/bake-swoole.php` failed with "file not found" before the server existed; against the fixture `lab/check/fixtures/wrong-swoole.php` (text/plain "ok" to everything) 7 of 8 cases printed `FAIL  <case>: <why>` and exit 1, containers removed; then green on `bake-swoole.php` (8 cases ok, socket line `backlog=4096 open_tcp_nodelay=1`). Full `bash lab/check.sh`: 21/21 ok. Before the fix, `check_shellcheck` failed on SC2034 (`REPO`, `LAB_INI` unused in conformance.sh).
- Scope 2, one php process in the Swoole container (listed `/proc` of the running server: pid 1 only), so the PDO handle opened before `$server->start()` is the one that serves.
- Scope 2, Done-when runs, 8.5, 7000 req/s, 20 s, warm-up 10 s, quiet-VM warning on (23 other containers): `/noop` 21.05 us/req VALID (140,004 requests, 0 errors, 0 dropped, k6 at 99.6 % of one CPU); `posts.js` 31.22 us/req VALID (139,994 requests). Not measurements: other containers were running.

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

## Raw learnings

- macOS ships bash 3.2: no `mapfile`, no `${var,,}`. `lab/check.sh` runs under it, so use `while read` loops.
- A comment that starts with `# shellcheck ` followed by anything is parsed as a directive (`# shellcheck check ...` broke the scan with SC1073). Word comments so they do not start with `shellcheck `.

- Scope 2: BSD `sed -i`/`sed` on macOS refuses `sed '/x/d; s/..'` patterns that GNU accepts when chained with `&&` after a failure: use python3 for multi-line edits of scripts.
- Scope 2: zsh does not word-split `$args` in `for args in "a b"; do cmd $args`: the loop ran nothing silently. Run each Done-when command by hand.
- Scope 2: inside the macro/conformance containers, `docker exec <client> php client.php poll <port>` is the readiness check that also lets bash look at the server container between tries.

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

## Next steps

1. Scope 3.

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
