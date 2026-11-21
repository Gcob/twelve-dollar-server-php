# Developer: phase 3, runtime bake-off

**State:** scope 1 done (`a0477ba`). Phase 2's handovers are in `plan/runs/phase-2/state/developer.md` (read its "Où regarder"
and "Impasses" if you touch `macro.sh`, `micro.sh`, `seed.sh` or the images).

## Verified

- Scope 1: `check_shellcheck` failed before the fixes (SC2034 on `lib.sh` variables and `sha` in check.sh, SC1007 on `pre_vus= max_vus=` in macro.sh, SC2148 on `lib.sh`), passed after. The fixture first exited 0 with SC2086 (info level, and a literal-valued variable), then exited 1 with SC2046. Full `bash lab/check.sh`: 18/18 ok (39 s).

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

## Raw learnings

- macOS ships bash 3.2: no `mapfile`, no `${var,,}`. `lab/check.sh` runs under it, so use `while read` loops.
- A comment that starts with `# shellcheck ` followed by anything is parsed as a directive (`# shellcheck check ...` broke the scan with SC1073). Word comments so they do not start with `shellcheck `.

## Where to look

- `lab/check.sh` → `lab_bash_scripts`, `shellcheck_run`, `check_shellcheck*`: what is scanned (every `*.sh` and every bash/sh shebang under `lab/`, minus `lab/data` and `lab/check/fixtures`). A new script is picked up on its own. `@a0477ba`
- `lab/lib.sh` → `LAB_SHELLCHECK_IMAGE`. `@a0477ba`
- `lab/macro.sh`: arguments, the three containers (server, k6, probe), the jq program that builds the JSON.
  `lab/macro/probe.sh`: what is read from outside the cgroups. `@b14068f`
- `lab/lib.sh` → `LAB_SERVER_PHP_FLAGS`, `LAB_CPUSET_*`, `LAB_RESOURCE_FLAGS`, `LAB_K6_IMAGE`. `@b14068f`
- `lab/check.sh` → `CHECKS`: where each scope adds its smoke check. `@b14068f`
- `lab/servers/noop-swoole.php`: the floor server, reads `PORT`. `@b14068f`

## Next steps

1. Scope 2.

## Questions for the project manager

Rien.

## Retro

(one subsection per scope, at the end of each)

### Scope 1

- **What went well:** the red/green loop was cheap: the check itself is the test, and it failed on real findings first.
- **What cost time:** the brief's SC2086 fixture does not fail at `warning` level (info rating), and shellcheck treats a comment starting with `shellcheck ` as a directive. Both found by running it.
- **Next time:** when a brief names a lint code, check its severity in the pinned version first.
