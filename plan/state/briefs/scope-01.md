# Brief: scope 1/7, lint the lab's bash with a pinned shellcheck

**Worktree:** `phase-3-claude` (absolute path in your prompt) · **Run folder:** `plan/` of the main checkout
**Planned commit:** `chore(lab): lint the lab's bash with a pinned shellcheck`

**Read first:** [common.md](common.md) (how this run differs from your agent file), then `plan/state/developer.md`.

**Summary:** `lab/check.sh` runs shellcheck on every lab bash script, from a pinned Docker image.

**Today:** the lab has about 600 lines of bash (`lab/*.sh`, `lab/macro/probe.sh`, `lab/results/*/summarize.sh`,
`lab/images/*.sh`, `lab/images/php-info` if it is bash) and no linter. Nothing can be installed on the Mac.

**Expected:**

- `LAB_SHELLCHECK_IMAGE` in `lab/lib.sh`: `koalaman/shellcheck` (the stable release tag, not `latest`) pinned by tag
  **and** multi-arch index digest, with a one-line comment on how to move it, like `LAB_K6_IMAGE`.
- `check_shellcheck` in `lab/check.sh`: runs the image on every bash script under `lab/` (found by extension and by
  shebang), severity `warning` and up, the repo mounted read-only. One line `ok` or `FAIL: <file:line SCxxxx ...>`.
- Fix what it flags in the existing scripts **without changing their behavior** (quoting, `read -r`, `local` split
  from assignment, ...). A false positive gets `# shellcheck disable=SCxxxx` on the line before, with a one-line why.
- A fixture `lab/check/fixtures/lint-warning.sh` with one known warning (an unquoted variable in a command, SC2086),
  excluded from the normal scan, plus a check `check_shellcheck_catches_warning` that scans it alone and passes only
  when shellcheck **fails** on it. It proves the lint check can fail.

**Interfaces:** `LAB_SHELLCHECK_IMAGE` (lib.sh), two new entries in `CHECKS`.

**Done when:** `bash lab/check.sh` prints `ok` for `shellcheck` and for `shellcheck_catches_warning`, the image is
pinned by tag and digest in `lib.sh`, and the whole suite stays green (report `N/N ok`).

**Seams and cases to test:**

- Seam: `bash lab/check.sh` (the two new lines).
- A clean tree passes; the fixture fails shellcheck (so its check passes); the fixture isn't part of the normal scan.
- Every existing check still passes after the lint fixes (the fixes changed no behavior).

**Tests to imitate:** the existing `check_*` functions in `lab/check.sh` (`check_macro_marks_invalid_run` for a check
that expects a failure).

**Decisions that touch you:** nothing installed on the Mac; tools run in Docker with pinned images (tag and digest);
the repo is public.

**Out of scope:** any behavior change of a script; new features.

**Where to look:** `lab/lib.sh` → `LAB_K6_IMAGE` (the pinning pattern) `@b14068f`; `lab/check.sh` → `CHECKS` `@b14068f`.

**Come back to me if:** a fix would change a script's behavior, or the "Done when" doesn't pass after 3 tries.
