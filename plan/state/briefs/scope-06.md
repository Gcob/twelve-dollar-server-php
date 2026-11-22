# Brief: scope 6/6, every results folder regenerates its tables

**Read first:** [common.md](common.md), then `plan/state/developer.md`.
**Worktree:** `.claude/worktrees/twelve-dollar-server-php/phase-4-claude` under the home folder (your prompt gives the
full path) · **Your handover:** `plan/state/developer.md` in the main checkout.
**Planned commit:** `chore(lab): check that every results folder regenerates its tables`

**Summary:** a `lab/check.sh` check that every results folder with a `summarize.sh` still produces the tables its
README shows, so a README can't drift from its raw files.

**Today:** `lab/results/` holds folders written by earlier work: `2026-11-21-noop-swoole/` and `2026-11-21-bake-off/`
have a `summarize.sh` that reads only the files next to it and prints the README's tables; `2026-11-22-realistic-baseline/`
(scope 5) has one too; `2026-11-22-realistic-calibration/` has none (raw calibration JSON only). The project manager
checked by hand that each README holds its `summarize.sh` output.

**Expected:**

- **A check** in `lab/check.sh`: for each `lab/results/*/summarize.sh`, run it (from its folder, with the tools it
  needs: run it where `jq` is available, like the other checks), and check that **every non-empty line it prints is a
  line of that folder's `README.md`**, byte for byte. Print `ok` per folder, or the first missing line and the folder.
  A folder without `summarize.sh` is skipped and named in the output (not a failure).
- **The phase 2 folder** (`2026-11-21-noop-swoole`): if its README was written by hand from the script's output with
  edits, the check will show the difference: fix whichever side is wrong (most likely regenerate the README's tables
  from the script, keeping the prose around them), and say what you changed. Don't change any number by hand.
- **A fixture** under `lab/check/fixtures/` (a folder with a `summarize.sh` that prints two lines and a README holding
  only one) must make the check fail and name the missing line. The fixture folder is not under `lab/results/`, so the
  real check doesn't pick it up: the check takes the results root as a parameter, and the fixture case points it at
  the fixture.
- **`lab/README.md`:** one paragraph on the check.

**Done when:** `bash lab/check.sh` runs every `lab/results/*/summarize.sh` and prints `ok` for each folder whose README
holds every line it prints (the bake-off's and the baseline's included); a fixture folder whose README misses one line
fails and names the line; `bash lab/check.sh` is all `ok`.

**Tests to imitate:** `check_shellcheck_catches_warning` (a fixture that must make a check fail).

**Out of scope:** changing any measurement or result number; the summarize scripts' logic (only if one prints
something that isn't a table line, for example a timestamp: then make it print the same thing every time and say so).

**Come back to me if:** a README and its `summarize.sh` disagree on a number (not formatting), or the Done-when doesn't
pass after 3 tries.
