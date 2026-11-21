# PR reviewer: phase 3, runtime bake-off

**State:** pass 1 done on `phase-3-claude` (6 commits, scopes 1 to 6, `3e74d76`). Verdict OK, 5 minor items, no 🔴 or 🟠. Scope 7 has not run: not reviewed.

## Verified

- Read every file of the diff against `details/phase-3.md` (scopes 1 to 6), the briefs' intent, and `developer.md`. **Proof:** report `reviews/PR-2026-11-21-1820.md`.
- Ran by hand in the worktree: `lab/run.sh 8.5 php /lab/check/diy-parser-test.php` (30 ok), `diy-partial-write-test.php` (4 ok), `workerman-caches.php` (5 filled on stock, 5 empty on nocache, exit 0). **Proof:** command output.
- No `D\d+`, `Q\d+` or `scope N` reference, no `/Users/` path and no email in the added lines. **Proof:** grep on the diff.

## Assumed

- `check.sh` 32/32 on `3e74d76` (the project manager's word, not rerun: about 2 minutes, starts containers).
- A listening socket's backlog cannot be read back from `/proc/net/tcp` (the developer's finding); `ss -ltn` may show it (Send-Q). Not checked: no `ss` in the lab image.

## Remarques et suites

1. `lab/conformance/client.php:242`: dead `wait` mode, replaced by `poll` (the header comment at line 4 also omits `poll`). Open.
2. `lab/servers/bake-workerman.php:57`: comment says Workerman adds a `Server` header; it does not (D19, developer's scope 5 finding). Open.
3. `lab/macro.sh:128-135,211` and `lab/conns.sh:130-137,238`: same helpers and the same other-containers block written twice. Open.
4. `lab/check.sh:233` (conns checks), `lab/conformance.sh`: two plan cases verified by hand only (conns.sh removes its containers after a failure; Workerman's loop is Event). Open.
5. `lab/servers/bake-workerman.php:30`, `bake-diy.php:149`: D22's "same backlog" is what was asked, not what the kernel holds, for all three runtimes. Open.

## Rétro

1. **Ce qui m'a manqué:** nothing blocking. The developer's `Verified` section answered most of what I would have rerun. Impression: a short list of "what the project manager already checked by hand" in my brief would save a pass of re-reading.
2. **Ce que j'ai deviné:** that the `ss -ltn` Send-Q column gives a listener's backlog on the Docker VM's kernel. No `ss` in the lab image, so not verified (item 5 says "to check").
3. **Où j'ai perdu du temps:** zsh aborted a `grep --include=*.sh` on an unmatched glob (the same trap the developer logged in scope 5); I reran it under bash. Cost: one call.
4. **Une consigne inutile ou contradictoire:** Rien.
5. **Ce qui aurait pu être déterministe:** a dead function mode (item 1) and a stale comment (item 2) are the kind of thing a "no unused CLI mode" check cannot catch cheaply; not worth wiring. The duplicated helpers (item 3) would show in a duplicate-code scan, but the repo has no PHP/bash linter beyond shellcheck, so a review rule is the right place.
6. **Ce que le plan aurait dû trancher:** whether D22 means "asked" or "observed" for the backlog; the code chose "asked" (item 5).
7. **Un angle mort:** the measurement fairness of scope 7 rests on the harness code and on the VM being quiet; nothing in the pipeline checks the VM's state between two repeats of the 24-run series (a container started by another project during run 11 would be caught by `other_containers`, but only after the run).
