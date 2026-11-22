# Blind reviewer: phase 4

**State:** first review done on `phase-4-claude` at `ea30389` (base `0f7b594`): NOT_OK, 1 🔴, 2 🟠, 8 🟡. Report:
`plan/reviews/BLIND-2026-11-22-1809.md`.

## Verified

- Every server stack of the committed profile goes through `DiyServer::run`, so the fold's "unclassified" can't happen.
  **Proof:** `awk` over `lab/results/2026-11-22-realistic-baseline/profile.collapsed`: 57,666 of 57,666 samples.
- Only the two calibration JSONs list other projects' containers. **Proof:** `jq '.other_containers'` over every
  committed `lab/results/**/*.json`.
- The branch is pushed. **Proof:** `git branch -r` shows `origin/phase-4-claude` at `ea30389`.
- The median longest callback over the four holds' plateaus is 11.26 to 11.38 ms, every second over 5 ms; k6's mean
  latency is 2.21 to 2.67 ms. **Proof:** `jq` on `hold-*.json`.
- "17 runs at 24,000, 4 failed" adds up from the README's tables.

## Assumed

- That the sampler's and the poll's `smaps_rollup` reads cause the 11 ms callbacks (item 3): a hypothesis, not tested.
  I did not run anything in Docker (a measurement could be in progress on the VM).

## Dead ends

Nothing.

## Decisions along the way

- Report in English, item 1 without the container names (the report is committed in a public repo).
- D numbers: `plan/` is in the repo, so not the "out-of-repo reference" case; flagged as 🟡 for readability only.

## Next steps

1. On a relaunch: reread the branch, check each item below, never bring back an item marked "left".

## Questions for the project manager

Nothing.

## My remarks

| # | Sev. | `file:line` | Status |
|---|---|---|---|
| 1 | 🔴 | `lab/results/2026-11-22-realistic-calibration/*.json:8`, `lab/realistic.sh:506`, `lab/macro.sh:292` | open |
| 2 | 🟠 | `lab/profile/fold-lib.php:79` (and `lab/README.md:823`) | open |
| 3 | 🟠 | `lab/realistic.sh:414`, `:418`, baseline `README.md:411` | open |
| 4 | 🟡 | `lab/realistic.sh:482`, `lab/macro.sh:335` | open |
| 5 | 🟡 | `lab/realistic.sh:171` | open |
| 6 | 🟡 | `lab/check.sh:1032` | open |
| 7 | 🟡 | baseline `README.md:403`, `:399` | open |
| 8 | 🟡 | baseline `README.md:30`, `:11`, `:28` | open |
| 9 | 🟡 | `lab/servers/diy-connection.php:156` | open |
| 10 | 🟡 | `lab/check/app-test.php:86`, `:189` | open |
| 11 | 🟡 | `lab/app/app.php:237` | open |

## Retro

1. **What I was missing:** nothing in the brief. The project has no `CLAUDE.md` in the repo (only a git-ignored
   `CLAUDE.local.md`), so the public-repo rule I applied in item 1 comes from the local file, which a reviewer of the
   real PR on GitHub won't see.
2. **What I guessed:** the cause of the 11 ms callbacks (item 3). It stays a hypothesis without a run.
3. **Where I lost time:** `lab/README.md` is 82 KB, so a full read overflowed and I read the diff instead. The 6,700
   lines of code diff had to be read in about 12 chunks.
4. **A useless or contradictory instruction:** `rules.md` says "write in French", the global `CLAUDE.md` says reports
   are in English. I followed the global file.
5. **What could have been deterministic:** item 1. A check in `lab/check.sh` (or a pre-commit githook) that fails when
   a committed `lab/results/**/*.json` has `other_containers.count > 0` with names, or lists a name not starting with
   `lab-`, would have caught it before the push.
6. **What the plan should have decided:** whether the per-second probes are part of the baseline's conditions, or have
   to be switchable (item 3).
7. **A blind spot:** nobody looks at what the raw results contain beyond their numbers. The privacy rule is checked on
   code and prose, not on 449,000 lines of JSON.
