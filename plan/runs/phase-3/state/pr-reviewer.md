# PR reviewer: phase 3, runtime bake-off

**State:** Delta 2 done (`793d503`, `d0bf2bc`): items 7 to 12 all landed, verdict OK. Before that: pass 1 done (scopes 1 to 6, `3e74d76`, verdict OK). Delta on scope 7 (`e062f0b`) done: verdict NOT_OK, one 🟠 (item 7, README attributes the invalid runs to host stalls as a fact), five 🟡 (8 to 12). Report: `reviews/PR-2026-11-21-1820.md`, section "Delta : scope 7".

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

## Delta, scope 7 (e062f0b)

- Pass-1 items 1, 2 and 4 were fixed by `e1cf918` (dead mode, stale comment, loop line in conformance); `9aadddc` changed the harness (Pss_Anon, DIY 500) after my pass 1: I did not re-review those two commits, I only read that the README names `9aadddc` as the harness.
- Verified: `bash summarize.sh` exits 0 here; the 9 predictions recomputed from the README tables and JSON, all judged correctly by their rules; 24 + 12 valid counted runs, 3 invalid excluded, 3 reruns counted; two identical-looking 31.01 values (`run-2/3-swoole-posts-9500`) are different runs (31.00711 and 31.00673).
- 7. 🟠 `README.md` (first try, environment, prediction 9) and D25: "host stalls" stated as the cause; own data says not separated, all 7 invalid runs are posts, 6 of 7 cost more µs/req. Open.
- 8. 🟡 `summarize.sh` series C header "Stopped at step" shows the last held step. Open.
- 9. 🟡 README prediction 7: Swoole's fd limit vs its own `max_connection`. Open.
- 10. 🟡 README prediction 8: Swoole slope is two regimes. Open.
- 11. 🟡 README "Surprising" (9,500 noop explanation untested; spreads; prediction 5 spread). Open.
- 12. 🟡 README arm64 line: differences under about 5 % are inside the repeats. Open.
- ⚠️ D25 and Swoole's memory under load (a k6 VU is a connection): question for Jacob.

## Delta 2 (793d503, d0bf2bc)

- Items 7 to 12: all corrected (README wording in 4 places, D25, `summarize.sh` header, Swoole ceiling, slope regimes, 9,500 explanation, 5 % limit). Checked by reading the diff and recomputing the quoted numbers (9.9 %, 16.3 %, 27/21/10 %).
- `summarize.sh` after `793d503`: exit 0, every printed line is in the README, shellcheck (pinned image) exit 0.
- ⚠️ D25 and Swoole's memory: now Q10 / D25, phase 4, not blocking.

## Rétro

1. **Ce qui m'a manqué:** nothing blocking. The developer's `Verified` section answered most of what I would have rerun. Impression: a short list of "what the project manager already checked by hand" in my brief would save a pass of re-reading.
2. **Ce que j'ai deviné:** that the `ss -ltn` Send-Q column gives a listener's backlog on the Docker VM's kernel. No `ss` in the lab image, so not verified (item 5 says "to check").
3. **Où j'ai perdu du temps:** zsh aborted a `grep --include=*.sh` on an unmatched glob (the same trap the developer logged in scope 5); I reran it under bash. Cost: one call.
4. **Une consigne inutile ou contradictoire:** Rien.
5. **Ce qui aurait pu être déterministe:** a dead function mode (item 1) and a stale comment (item 2) are the kind of thing a "no unused CLI mode" check cannot catch cheaply; not worth wiring. The duplicated helpers (item 3) would show in a duplicate-code scan, but the repo has no PHP/bash linter beyond shellcheck, so a review rule is the right place.
6. **Ce que le plan aurait dû trancher:** whether D22 means "asked" or "observed" for the backlog; the code chose "asked" (item 5).
7. **Un angle mort:** the measurement fairness of scope 7 rests on the harness code and on the VM being quiet; nothing in the pipeline checks the VM's state between two repeats of the 24-run series (a container started by another project during run 11 would be caught by `other_containers`, but only after the run).

### Delta, scope 7

1. **Ce qui m'a manqué:** the harness commits `e1cf918` and `9aadddc` landed between my passes and were not in my delta brief; I found them with `git log`. A "commits since your last pass" line in the delta message would save that step.
2. **Ce que j'ai deviné:** that a vCPU descheduled by the host does not add CPU time to the server cgroup (item 7's argument). Reasoned, not tested. Impression.
3. **Où j'ai perdu du temps:** nothing notable; recomputing the medians from the JSON was quick because `summarize.sh` runs in seconds.
4. **Une consigne inutile ou contradictoire:** Rien.
5. **Ce qui aurait pu être déterministe:** a README that says "host stalls" while another line says "not separated" is a contradiction a script could not catch; no wiring proposed.
6. **Ce que le plan aurait dû trancher:** whether the k6 VU count (hence the connection count) is a fixed parameter of a memory comparison; D25 changed it for the whole bake-off without saying so for memory.
7. **Un angle mort:** nobody separates "the Mac stalls" from "the server stalls" on posts runs; a `/noop` run under the same VUs and a posts run with a preloaded database would tell them apart.

### Delta 2

Rien de nouveau : même rétro que le delta. Une chose concrète : le chargé a corrigé les six items en deux commits que j'ai pu vérifier en un `git show`, parce qu'il avait cité les items par numéro.
