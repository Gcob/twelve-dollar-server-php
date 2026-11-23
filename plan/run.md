# Run: phase 4, realistic baseline

**Pace:** 🟢 full · 5-hour 10 % · weekly 29 % at 17:35 · 5-hour resets 20:20 · away

**Status:** 🏁 Delivered, your review
**Progress:** delivered at 19:05 · started 2026-11-22 10:50 · 8 h 15
**Since your last read:** phase 4 is delivered on `phase-4-claude` (pushed, clean). Both final reviews are OK.
The baseline: at least 23,386 req/s (221,002 users, CPU-equivalent), 27.15 µs of CPU per request, p99 28 ms. The
history is cleaned of the container names; only the force push of `main` is left for you. See "Delivery" below.
**👉 Your turn:** W3, force-push the cleaned `main` (command in "Delivery"), then review and merge. Q11, not blocking.

## Steps

| #   | Step              | State   | Start | End | Detail |
|-----|-------------------|---------|-------|-----|--------|
| 0   | Plan review       | done    | 10:59 | 11:17 |     | full NOT_OK at 11:10 (1 🔴, 5 🟠), settled as D38 to D43; delta NOT_OK at 11:14 (1 🟠), settled as D44; delta 2 and final full OK at 11:17 |
| 1   | Scopes            | done    | 11:19 | 17:46 | 6/6    |
| 2   | Questions         | done    | 17:40 | 17:40 | none open: scope 5's two settled as D47 |
| 3   | Lab suite         | done    | 17:50 | 17:55 | 59/59 ok on `7d6281a`, no flake (other containers back at 17:54 during it) |
| 4   | `pr-reviewer`     | done    | 17:55 | 18:04 | OK at pass 1: no 🔴 or 🟠, 9 🟡 (7 being fixed), 1 plan question (Q11) |
| 5   | `blind-reviewer`  | done    | 18:09 | 19:02 | NOT_OK at pass 1 (1 🔴, 2 🟠), fixed 18:47; history cleaned; OK at pass 2 |
| 6   | Delivery          | done    | 19:02 | 19:05 | branch pushed; `main` force push left to Jacob (W3) |

## Scopes

| #   | State | Start | End | Lines | Checks | SHA | Fixes |
|-----|-------|-------|-----|-------|--------|-----|-------|
| 1   | done | 11:19 | 11:37 | +1060 -156 | 42/42 twice, broken fixture fails, check.sh 35/35 (PM rerun) | `f840725` |       |
| 2   | done | 11:40 | 12:28 | +8059 -3 | staircase 3/3 pass, slow fixture stops on the 97 % rule, cap 5,400 VUs, s = 0.0286, replay at 480k rows/s, check.sh 44/44 (PM rerun) | `07808e7` |       |
| 3   | done | 12:33 | 13:12 | +1632 -80 | 60,000 idle held start to end with 5,377 VUs (19,565 req/s, smoke), cold `fincore` 0 % vs 100 %, macro `--fresh-db --cold --per-second`, check.sh 53/53 (PM rerun) | `81d9216` |       |
| 4   | done | 13:22 | 13:53 | +1232 -38 | excimer 1.2.6 (not 8.6), fold 0 % unclassified, calibration 0.1 / 0.4 points off (JIT on / off), check.sh 56/57 (PM rerun: `check_realistic_idle_run` flaky, passes alone 3/3) | `6621654` | scope 3's flaky checks fixed: `0cbefb1`, `90a54c7` (10/10 alone each, check.sh 57/57) |
| 5   | done | 14:52 | 17:30 | +443864 -5 (raw JSON) | 3 holds pass, 26 counted runs `other_containers: 0`, `summarize.sh` = README (PM check), predictions copied unchanged | `8fe2ab8`, `60116f0` | harness: `0e7f604`, `52e9792` |
| 6   | done | 17:40 | 17:46 | +87 -0 | 4 folders: 3 `ok`, calibration skipped (no script); drift fixture fails and names the line; check.sh 59/59 (developer) | `be42b8b` | fd-wall note in the baseline README (planning session): `7d6281a`, results check `ok` |

## Reviews

### `plan-reviewer`, full · 10:59 to 11:10 · NOT_OK

**Report:** [PLAN-2026-11-22-1110.md](reviews/PLAN-2026-11-22-1110.md). 6 questions, each settled with the reviewer's
own pick (D38 to D43), and the 12 🟡 folded into `details/phase-4.md`. Predictions 3 and 7 revised at 11:12, still
before any measurement.

- **🔴 With 60,000 idle connections, k6 gets about 500 ports.** The idle client `bind()`s each port, and bound ports
  are skipped by every unbound `connect()`. Settled: D38, k6 binds its own source addresses; scope 3's Done-when now
  runs 60,000 idle with k6 at its cap.
- **🟠 The VU budget doesn't close** (11,400 req/s at most against a predicted knee up to 18,000; 3,000 × 2 MiB plus
  2 GiB is over the VM). Settled: D39, the cap and the scale from calibration, a memory limit on k6.
- **🟠 10.8 users per req/s includes the leaderboard's ramps.** A steady load is 9.45. Settled: D40; D16's users and
  🤝's formula corrected (7,000 req/s is about 66,000 users; about 8.0 million / µs).
- **🟠 No way to get per-step and per-second numbers from k6** without GBs of raw samples on the measured VM. Settled:
  D41, live per-second histograms from a FIFO, nothing raw on disk, k6 stopped at the first failing step.
- **🟠 `macro.sh` can't run the skeleton for Q10.** Settled: D42, one seed-copy function with `--cold`, wired in scope 3.
- **🟠 Nothing proves where Excimer puts a C function's samples under the JIT.** Settled: D43, a calibration fixture
  in scope 4.
- **🟡** profile flushed on a timer and copied out; WAL frames from the `-shm` header; k6's own loop overhead in the
  97 % margin; one sampler loop, no `docker exec` per second; `fsync` before eviction; `cp` inside the server container;
  Excimer in its own layer with a switch; statuses 201, 401, 503; `/health`'s `db` and auth before id; where `test.sh`
  runs; the idle client's path and body; k6's exit 99.

### `plan-reviewer`, delta · 11:12 to 11:14 · NOT_OK

**Report:** [PLAN-2026-11-22-1116-delta.md](reviews/PLAN-2026-11-22-1116-delta.md). D38 to D43 hold; the 🟡 are folded
in correctly.

- **🟠 k6's live stream has no backpressure:** k6 buffers samples in memory when the reader falls behind, so a slow
  aggregator ends in k6 killed by its memory limit mid-staircase, and the plan watched the wrong sign. Settled: D44,
  calibrate with the stream on, a replay case at 40,000 req/s worth of rows, and a lag and memory gate on every
  measured run.
- **🟡** the VU cap also bounded by the server's free fds (about 5,400); one function per step in the skeleton (D43);
  `macro.sh --fresh-db` so the bake-off servers don't get a second copy; a slow fixture server for scope 2's
  above-capacity case; a missing period in D16.

### `plan-reviewer`, delta 2 and final full pass · 11:16 to 11:17 · OK

**Report:** [PLAN-2026-11-22-1120-final.md](reviews/PLAN-2026-11-22-1120-final.md). No 🔴 or 🟠; the scope order
holds. 4 🟡, all fixed in the plan at 11:18: two `{R}` placeholders in D43 and D44; D44's lag gate now the calibrated
lag plus 2 s with `K6_CSV_SAVE_INTERVAL` lowered (k6 flushes its CSV every second); `plan.md`'s "Since your last
read"; the aggregator in its own container, outside k6's memory budget.

### `pr-reviewer`, pass 1 · 17:55 to 18:04 · OK

**Report:** [PR-2026-11-22-1755.md](reviews/PR-2026-11-22-1755.md). No 🔴 or 🟠; it also wrote the PR description.

- **⚠️ Plan to review:** the held rate is the harness's floor (D47), so phase 5 can only tell variants apart by µs per
  request. **Status:** Q11 in plan.md, for Jacob, not blocking.
- **🟡 1 to 4, 6:** four README readings say more than the data (Pss_Anon's cause, "7 times a post", S1 is mostly the
  idle accepts, "at least" missing), and the 11 ms longest callback at 24,000 req/s isn't mentioned. **Status:**
  fixed in `ea30389` (scope 5's developer, 18:05 to 18:08).
- **🟡 5:** the default lag gate is 4 s, under the 5.5 s measured. **Status:** fixed in `ab3dd04` (6 s, D46; realistic checks ok alone).
- **🟡 7:** lab/README's calibration table is typed by hand. **Status:** fixed in `ea30389` (said so).
- **🟡 8, 9:** a duplicated `jq` block, a 3 % tolerance. **Status:** set aside (reasons in project-lead.md).

### `blind-reviewer`, pass 1 · 18:09 to 18:17 · NOT_OK

**Report:** [BLIND-2026-11-22-1809.md](reviews/BLIND-2026-11-22-1809.md).

- **🔴 1 Two calibration JSON files list your 23 other containers' names, on the public branch since `07808e7`.**
  Scope 2's calibration ran on the busy VM and the harness recorded the names. **Scopes:** 2. **Status:** fixed in
  `0706612` (count only, files scrubbed, a check scans every JSON); Q12 = A (18:25): history rewritten by the PM, then pushed again. `main` is clean.
- **🟠 2 The fold can never say "unclassified"**: an unnamed frame takes its named caller's step, so a renamed step
  function would move its cost without a warning. **Scopes:** 4. **Status:** fixed in `c2178cc` (classify by the leaf frame; the baseline stays at 0 % unclassified).
- **🟠 3 The per-second probes may cause part of the p99 and the stalls** (11 ms longest callback each second, only
  with 60,000 idle), and nothing can run without them. **Scopes:** 3, 5. **Status:** fixed in `5deb526`, `af8fe6a` (`--no-series`
  switch, README labels); the hold that separates them needs a quiet VM: phase 5.
- **🟡 6, 7, 9, 10:** fixed in `e7c2d16`. **🟡 4, 5, 8, 11:** set aside (reasons in project-lead.md).

### History cleanup · 18:31 to 19:00 · done

Jacob, 18:31, through the planning session: "please clean master and force push, and make sure the git history has
no leak at all." One-time exception to "never push --force".

- **Backup:** every ref in a bundle outside the repo, never pushed.
- **Audit of every commit and message** (`main`, `phase-4-claude`, `phase-3-claude`): container names in the 2
  calibration JSON files (13 commits, the branch only); 3 short nickname phrases in plan files (`main`); nothing
  else (no email inside a file, no `/Users` path, no key or token, no employer name, no private word in a message).
- **Rewrite:** `git filter-repo --replace-text` on all refs, the names lists dropped from the JSON and the phrases
  replaced by "(names left out)". Only those files changed; commit counts unchanged (`main` 90, branch 82); every
  pattern returns nothing on the 109 rewritten commits. `phase-3-claude` holds no leak and kept its SHA.
- **SHAs:** every SHA from the first leak on changed; the plan and the baseline README point to the new ones
  (`989f932` on the branch).
- **Checks:** `lab/check.sh` 61/61 ok on the rewritten branch.
- **Not rewritten:** the author email in commit metadata is your own git config (personal address), as asked.
- **GitHub** may keep old commits reachable by their SHA for a while; only GitHub Support can purge them: your call.

### `blind-reviewer`, pass 2 · 19:00 to 19:02 · OK

**Report:** [BLIND-2026-11-22-1905.md](reviews/BLIND-2026-11-22-1905.md). 🔴 1, 🟠 2 and 🟠 3 closed, nothing new. It
noted that GitHub's `main` still holds the old history until your force push (W3).

## Retro

Sorted from the developers' and reviewers' retros (`state/developer.md`, `state/blind-reviewer.md`) and mine.

- **🔴 The leak came from raw results nobody read.** Scope 2 calibrated on the busy VM, and the harness wrote the
  other containers' names into the JSON. The rule "no private details" was checked on code and prose, never on
  449,000 lines of JSON. **Now:** the harnesses write a count only, and `check_results_hold_no_container_names`
  scans every committed JSON. **Still open:** the `.txt` run outputs aren't scanned. **For phase 5's plan:** a lint
  over every committed file of `lab/results/` before a push, and a history-cleanup recipe that ends with
  `git ls-remote` and `git for-each-ref` (pass 2 found `origin/main` that way).
- **A long run was never smoke-tested before the measuring scope.** k6 keeps about 190 bytes a request, and a long
  run passes jq's argument limit: two 21-minute staircases were lost (about 45 minutes). **For phase 5's plan:** a
  15 to 20 minute smoke at the real shape in the scope that builds the harness.
- **The plan didn't say how far `s` may fall, or that the held rate then belongs to the rule, not the server.** D47
  settled it after the fact; Q11 asks what phase 5 judges on.
- **The per-second probes were never switchable or priced.** `--no-series` now exists; its first hold is phase 5's
  first measurement, on a quiet VM.
- **`lab/check.sh` and a manual `lab/run.sh` disturb each other** (a 97 % step at low rate), and waiters mistake an
  old log for a new one: a lock and a done marker would help (scopes 4 and 6). Not done.
- **What worked:** predictions before measuring (6 of 12 held, and the misses taught the most: the server is 2 to 3
  times cheaper than predicted); the results check (scope 6) kept every README equal to its script through two
  rounds of review fixes; the reviews caught four over-readings in the baseline README.

## Delivery

**Since the snapshot:** decisions D26 to D47 came from this phase.

- D26 to D30 (Jacob's answers): 8.6 micro only, realistic first, Q10 inside the realistic runs, rule 5 (no shared
  read, group commit allowed), the two S9 variants.
- D31 to D37 (the plan): the 97 % rule, the skeleton opens `SQLITE_PATH`, Excimer, telemetry, DIY on 8.5 arm64,
  sizes and holds, the results check (scope 6).
- D38 to D44 (the plan review): k6's own source addresses, cap and scale from calibration, 9.45 users per req/s, live
  aggregation, one seed-copy function, Excimer's calibration, the stream guard.
- D45 to D47 (during the run): the generator-bound line at 80 %, `s` lowered when the knee is above the cap and a 6 s
  lag gate, the held rate as a harness floor (µs per request carries the step lab).

Open `run` question: **Q11** (what the step lab judges on): the plan had "the highest load held"; the branch delivers
it as a floor ("at least 23,386 req/s at `s = 0.02`").

**3 places to look:**

1. `lab/results/2026-11-22-realistic-baseline/README.md:393`, "Reading the results", down to "The step lab's order"
   (`:476`): the baseline, its limits (probes on, a harness floor) and the order phase 5 starts from (the fd wall
   first).
2. `lab/macro/aggregate-lib.php:254`: the 97 % rule that judges every step, and with it every held rate of this phase.
3. `lab/profile/fold-lib.php:116`: the fold now classifies by the leaf frame; the step lab's ranking rests on it.

**Expected answers:** none: no `FIXME(pending)` in the branch.

**What was done:**

- The challenge app on the DIY loop (42/42 of the challenge's tests), and a realistic mode: the bench's own journey
  with scaled think time, 60,000 idle connections, live per-second histograms, cold starts, telemetry.
- Excimer profiles folded into the steps S1 to S9 per endpoint, calibrated (JIT on and off).
- The baseline: **at least 23,386 req/s held (221,002 users at 9.45, CPU-equivalent), 27.15 µs of CPU per request,
  p99 28 ms**, median of 3 five-minute holds on a quiet VM; SQLite 52 % of the CPU, the write 20 %, JSON 10 %; Q10
  answered; 6 of 12 predictions held. One process caps the real bench near 71,000 users whatever its CPU: S1's fd
  wall comes first in phase 5.

**Final reviews:** `pr-reviewer` OK ([report](reviews/PR-2026-11-22-1755.md)) · `blind-reviewer` OK at pass 2
([pass 1](reviews/BLIND-2026-11-22-1809.md), [pass 2](reviews/BLIND-2026-11-22-1905.md)).

**History cleanup:** done (section above). One step left for you: the force push of `main` (W3). Until then,
`origin/main` holds the old history, and the plan commits since 18:40 wait locally (a normal push would be refused). The lease makes it fail if anyone
pushed to `main` since:

```bash
git -C /Users/jacobproulx/www-perso/twelve-dollar-server-challenge push --force-with-lease=main:ebd2855a434432065f7ac9df7a74c68fab085019 origin main
```

**PR description** (ready to paste):

```markdown
**Résumé**

J'ajoute le squelette de l'app du défi (les 5 endpoints sur la boucle DIY), un mode de charge qui rejoue le parcours du banc avec 60 000 connexions inactives, un profil par étape, et le premier baseline mesuré sur le Mac (arm64, pas un score).

**Décisions**

- **Le baseline ne compte que sur le DIY, PHP 8.5, arm64 :** c'est le serveur le moins cher du bake-off, et le Mac n'est pas la machine du banc, donc les utilisateurs mappés ne sont pas un score.
- **Think time réduit (`s = 0,02`) et règle des 97 % :** quelques milliers de VUs doivent faire le débit de dizaines de milliers. La latence pèse alors 1/s fois plus dans la boucle d'un VU, et les seuils du banc laisseraient passer des charges bien au-delà de la saturation : un palier passe seulement s'il atteint aussi 97 % du débit offert.
- **Le débit tenu est un plancher du harnais :** à `s = 0,02`, le serveur tient au moins 23 386 req/s avec son CPU à 63 %, et la règle échoue sur le surcoût de k6. Le labo d'étapes se mesure en µs de CPU par requête (27,15), pas en débit.
- **9,45 utilisateurs par req/s en régime stable :** le 10,8 du classement inclut les montées et les descentes du banc.
- **Chaque requête fait ses lectures :** aucune lecture partagée entre requêtes (règle du défi). Le regroupement des écritures reste permis, pour plus tard.
- **Les sondes à la seconde restent actives par défaut :** le p99 et les stalls du baseline sont mesurés avec elles. `--no-series` les coupe, pour la prochaine mesure.

**Changements**

- `lab/app/` : `GET /health`, `GET /feed`, `GET /posts/:id`, `POST /posts`, `POST /posts/:id/like`, JWT HS256 écrit à la main, SQL de référence, `json_encode`. `lab/challenge-test.sh` passe la suite du défi telle quelle (42 sur 42).
- `lab/servers/diy-server.php` : la boucle DIY, sortie de `bake-diy.php` et partagée avec l'app. Les callbacks sont des méthodes nommées pour que le profil les nomme. `bake-diy.php` en dépend et sa conformité passe, mais ses anciens chiffres ne se reproduisent qu'à leur commit.
- `lab/realistic.sh` et `lab/macro/k6/realistic.js` : une copie de `bench/load.js` avec seulement deux changements (les `sleep` mis à l'échelle, les options lues de l'environnement). Une vérification compare le fichier au banc.
- `lab/macro/aggregate*.php` : le flux CSV de k6 dans un FIFO, des histogrammes par seconde et par endpoint, rien de brut sur disque, une garde sur le lag de l'agrégateur (6 s par défaut) et sur la mémoire de k6.
- `--idle` (60 000 connexions tenues, vérifiées au début et à la fin), `--cold` (copie évincée du cache de pages), séries à la seconde (CPU, `Pss_Anon`, `memory.current`, WAL, fautes de pages), télémétrie `APP_TELEMETRY=1`, `--no-series`.
- Excimer 1.2.6 dans l'image (une couche à part, sha256 épinglé ; il ne compile pas sur PHP 8.6) et `lab/profile/fold.php`, qui replie les piles en S1 à S9 par endpoint d'après la fonction feuille. Une feuille inconnue tombe dans « unclassified ».
- `lab/macro.sh --fresh-db --cold --per-second` : le même squelette et les mêmes séries pour le `posts.js` du bake-off.
- Les harnais n'écrivent plus que le nombre des autres conteneurs, jamais leurs noms, et `lab/check.sh` vérifie que chaque README de résultats contient le bloc exact de son `summarize.sh`.

**Preuves**

- `bash lab/challenge-test.sh --image 8.5` : `passed=42 failed=0`, deux fois de suite.
- `bash lab/check.sh` : 61 sur 61 `ok` sur `989f932`.
- Le baseline (médiane de 3 holds de 5 minutes, 60 000 connexions inactives, VM calme, `other_containers: 0`) : au moins 23 386 req/s à `s = 0,02` (221 002 utilisateurs à 9,45, en équivalent CPU : un seul processus tient environ 65 500 connexions, donc le vrai banc plafonne près de 71 000), 27,15 µs de CPU par requête, p99 de 28 ms.
- Le profil : SQLite 52 %, l'écriture 20 %, le JSON 10 %, la lecture et l'analyse 8 %. 6 prédictions sur 12 tenues.
- Q10 : sur les 53 secondes au-dessus de 100 ms des trois holds, aucune n'a un callback aussi long que le stall.
- Pour valider soi-même : `bash lab/results/2026-11-22-realistic-baseline/summarize.sh | diff - <(sed -n '/^<!-- BEGIN summarize -->$/,/^<!-- END summarize -->$/p' lab/results/2026-11-22-realistic-baseline/README.md | sed '1d;$d')` n'imprime rien.

**Ce qu'on a appris**

- Le serveur coûte 2 à 3 fois moins cher par requête que prévu : 27 µs au lieu de 50 à 90.
- Avec un seul processus, le mur des descripteurs de fichiers arrive avant le CPU : c'est la première étape du labo.
- Les résultats bruts doivent passer la même vérification de confidentialité que le code : c'est là que la fuite s'est cachée.

**Risque du merge**

- **Porte :** à double sens : du code de labo, rien d'écrit hors du dépôt.
- **Rayon d'impact :** faible. Le bake-off partage `diy-connection.php` et la boucle DIY avec le squelette : sa conformité et ses vérifications passent, mais ses chiffres ne se reproduisent qu'à leur commit d'origine.

**Notes de déploiement**

Reconstruire les images pour avoir Excimer : `bash lab/build.sh 8.5` (et `8.3`, `8.4` au besoin). L'image `php-lab-tools:1` se construit au premier `challenge-test.sh`. Aucune variable d'environnement ni migration.
```

**The commits:**

```bash
git -C /Users/jacobproulx/www-perso/twelve-dollar-server-challenge log --oneline main..phase-4-claude
```

**Review** (in PhpStorm: right-click the branch > *Compare with Current*, or on the command line):

```bash
git -C /Users/jacobproulx/www-perso/twelve-dollar-server-challenge diff main...phase-4-claude -- . ':!lab/results/*/*.json'
```

**Minor items left aside:**

- `pr-reviewer` 🟡 8: the `cold_json` jq block copied in two harnesses; 🟡 9: the 3 % + 0.02 ms tolerance of the
  aggregator against k6.
- `blind-reviewer` 🟡 4: a dead aggregator would block the FIFO's last write; 🟡 5: two staircase steps can round to
  the same VUs; 🟡 8: D numbers in the predictions (a verbatim copy); 🟡 11: `trim()` keeps a non-breaking space.

**Merge and close** (after W3; `main` has plan commits, so a merge commit, like phase 3):

```bash
git -C /Users/jacobproulx/www-perso/twelve-dollar-server-challenge merge --no-ff phase-4-claude && git -C /Users/jacobproulx/www-perso/twelve-dollar-server-challenge worktree remove /Users/jacobproulx/.claude/worktrees/twelve-dollar-server-php/phase-4-claude && git -C /Users/jacobproulx/www-perso/twelve-dollar-server-challenge branch -d phase-4-claude
```

Useful variants:

```bash
git cherry-pick <sha>          # take one commit
git worktree remove --force /Users/jacobproulx/.claude/worktrees/twelve-dollar-server-php/phase-4-claude   # throw it all away
git branch -D phase-4-claude
```

Or the PR loop: ask for the branch's PR (skill `pr-loop`) instead of the merge.
