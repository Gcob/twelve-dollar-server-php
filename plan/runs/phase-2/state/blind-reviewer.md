# Blind reviewer: phase 2 lab (main, a47aa5e..ec0f3fa)

**State:** pass 2 done, verdict OK (1 new minor item, 11). Reports: pass 1
`plan/reviews/BLIND-2026-11-21-1131.md` (NOT_OK), pass 2 `plan/reviews/BLIND-2026-11-21-1139.md` (OK).

## Verified

- The tables of `lab/results/2026-11-21-noop-swoole/README.md` match the 9 JSON files. **Proof:** pass 1, ran a copy of
  `summarize.sh` on `git show` copies in the scratchpad, `diff` with the README tables: identical.
- `server_throttled_usec` is 0 and `valid` is true in all 9 runs. **Proof:** `jq` on the 9 files.
- No email, `/Users/` path, other project or container name in `lab/`, `.gitignore`, `README.md` or the result JSONs.
  **Proof:** `git grep` at `f5c52e4` and again at `ec0f3fa`; every unique string of the JSON files (`jq '.. | strings'`).
- Item 1's fix covers a failure in any process. **Proof:** `git show 095e7e8`, `micro_summarize()` loops over every
  process; the fixture `failing-check-later.php` fails in process 2 for sure (`static` flag plus a marker file in
  `/tmp`), and `check_micro_skips_case_failing_in_later_process` greps for `(process 2`.
- The prediction commit `85978ab` comes before the first run. **Proof:** `git log` metadata, ancestor of `c3a487b`,
  09:24 local against a first run at 11:08 local. The file it names is under `plan/`: not opened.
- The D11 and D12 references in `.gitignore` point to `plan/decisions.md`, which is in the public repo: not an
  out-of-repo reference.

## Supposed

- The flag list that `install-php-src.sh:24-26` says `dpkg-buildflags` prints in the apt image (I didn't run it).

## Dead ends

Rien.

## Decisions along the way

- Pass 1: rated item 1 🟠, not 🟡. It broke a promise the README makes ("a fast wrong variant is discarded, not
  ranked"), and the likely trigger is a bench that writes to the database copy.

## My items

| # | Severity | Where | Status |
|---|---|---|---|
| 1 | 🟠 | `lab/micro/micro.php:326-345` | fixed (`095e7e8`), checked in pass 2 |
| 2 | 🟡 | `lab/images/install-php83-apt.sh`, `lab/servers/noop-swoole.php` | fixed (`ec0f3fa`) |
| 3 | 🟡 | `lab/lib.sh:52`, `lab/servers/noop-swoole.php:4`, `lab/README.md:186-188` | fixed (`ec0f3fa`) |
| 4 | 🟡 | `lab/lib.sh:29` | fixed (`ec0f3fa`) |
| 5 | 🟡 | `lab/README.md:106-107` | fixed (`ec0f3fa`) |
| 6 | 🟡 | `lab/macro/k6/fixed-rate.js:2-6` | fixed (`ec0f3fa`) |
| 7 | 🟡 | `lab/servers/noop-swoole.php:6-7`, `lab/results/2026-11-21-noop-swoole/README.md:89` | fixed (`ec0f3fa`) |
| 8 | 🟡 | `lab/images/install-php-src.sh:24` | fixed (`ec0f3fa`) |
| 9 | 🟡 | `lab/results/2026-11-21-noop-swoole/README.md:72,118` | fixed (`ec0f3fa`) |
| 10 | 🟡 | `lab/results/2026-11-21-noop-swoole/README.md:3-4` | fixed (`ec0f3fa`) |
| 11 | 🟡 | `lab/README.md:99` | open (new in pass 2) |

## Next steps

1. On another pass: read the status of item 11, review only the new commits since `ec0f3fa` on the same paths, and
   don't bring back an item left by choice.

## Questions for the project lead

Rien.

## Rétro

1. **What I missed:** the repo's layout (work on `main`, plan in `plan/`) was only in the launch message, not in my
   agent file; the message was enough.
2. **What I guessed:** item 8 (Ubuntu's build flags), marked plausible in pass 1. The fix's comment now gives the
   list, still not run by me.
3. **Where I lost time:** nothing notable. Regenerating the tables with `summarize.sh` from `git show` copies saved
   reading the raw JSON line by line.
4. **A useless or contradictory rule:** `rules.md` says "Écrire en français", and the launch message said English for
   this public repo. The message won.
5. **What could be deterministic:** `summarize.sh` could run in `lab/check.sh` against each committed results
   folder and diff with its README, so a table that drifts from its JSON fails the suite.
6. **What the plan should have decided:** whether code copied from other submissions (MIT) gets a credit line (item 2).
   It was fixed in pass 2.
7. **A blind spot:** comments that describe the flags or settings (`noop-swoole.php`, `fixed-rate.js`, the fixture
   list in `lab/README.md`, item 11) go stale when `lib.sh` or the fixtures change. Nothing ties them together.
