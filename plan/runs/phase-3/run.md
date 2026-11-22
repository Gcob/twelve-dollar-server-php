# Run: phase 3, runtime bake-off

**Pace:** 🟢 full · 5-hour 16 % · weekly 22 % at 22:21 · 5-hour resets 23:30 · away

**Status:** 🏁 Delivered, your review
**Progress:** delivered at 22:36: 7/7 scopes, both final reviews OK, `lab/check.sh` 32/32, branch `phase-3-claude`
pushed (`01e1ad5`), not merged · started 2026-11-21 16:24
**Since your last read:** the bake-off is measured on a quiet VM. Per request at 7,000 req/s (posts): DIY 29.14 µs,
Swoole 32.83, Workerman nocache 33.32; at 9,500 Workerman nocache (29.40) passes Swoole (31.01) on posts, so second
place is a tie within the noise. All three stop at the fd limit (about 65,520), none on memory. See
[Livraison](#livraison).
**👉 Your turn:** review and merge (commands in [Livraison](#livraison)); Q7 and Q10 open in [plan.md](../../plan.md), not
blocking.

## Steps

| #   | Step              | State       | Start | End | Detail |
|-----|-------------------|-------------|-------|-----|--------|
| 0   | Plan review       | done        | 16:29 | 16:48 | full: NOT_OK (1 🔴, 3 🟠), settled as D21 to D24 at 16:44; delta: OK at 16:48, 4 🟡 folded in |
| 1   | Scopes            | done        | 16:31 | 22:11 | 7/7; scope 7 measured on a quiet VM, first try redone under D25 |
| 2   | Questions         | done        | 22:16 | 22:21 | Q10 opened (the posts stalls' cause, for phase 4, not blocking); Q7 stays open |
| 3   | Lab suite         | done        | 18:17 | 22:30 | `lab/check.sh` 32/32 on `3e74d76`; 31/32 on `e062f0b` (shellcheck on `summarize.sh`), fixed `793d503`; 32/32 on `793d503` and `b216364` (`01e1ad5` is README only) |
| 4   | `pr-reviewer`     | done        | 18:17 | 22:17 | pass 1 OK on scopes 1 to 6 (6 🟡); delta on scope 7 NOT_OK (1 🟠, 5 🟡), all fixed; delta 2 OK |
| 5   | `blind-reviewer`  | done        | 18:31 | 22:29 | pass 1 NOT_OK (1 🟠), fixed; pass 2 OK; delta on scope 7 NOT_OK (1 🟠, 5 🟡), all fixed; delta 2 OK (3 🟡, fixed in `01e1ad5`) |
| 6   | Delivery          | done        | 22:31 | 22:36 | branch pushed, not merged |

## Scopes

| #   | State | Start | End | Lines | Checks | SHA | Fixes |
|-----|-------|-------|-----|-------|--------|-----|-------|
| 1   | done | 16:31 | 16:33 | +55 -3 | shellcheck ok, check.sh 18/18 (PM rerun) | `a0477ba` |       |
| 2   | done | 16:45 | 16:55 | +837 -37 | conformance 8/8, VALID at 7k on both routes, check.sh 21/21 (PM rerun) | `0d74fda` | delta 🟡 1-3 (relaunch 16:47) |
| 3   | done | 16:59 | 17:12 | +821 -3 | 10k held, nofile 2048 ceiling 2,035 (timeout), check.sh 24/24 (PM rerun) | `deeb8d1` |       |
| 4   | done | 17:15 | 17:50 | +636 -16 | php-info 8.5/8.6 event 3.2.0 + Workerman, caches 5/5, boots on both trees, check.sh 26/26 (PM rerun) | `8c8f7cc` |       |
| 5   | done | 17:53 | 18:01 | +136 -50 | conformance 8/8 on both trees, 4 macro runs VALID, check.sh 28/28 (PM rerun) | `ad52342` |       |
| 6   | done | 18:03 | 18:14 | +862 -8 | conformance 8/8, parser 30/30, partial write 4/4, VALID at 7k, check.sh 32/32 (PM rerun) | `3e74d76` | R1 R2 R4 (`e1cf918`) |
| 7   | done | 21:13 | 22:31 | +41141 (results) | summarize.sh regenerates the README tables (PM diff at each commit), predictions verbatim, every counted run VALID with other_containers 0 | `e062f0b` | `793d503` (check.sh), `d0bf2bc` (R13-R18), `2b54788` `b216364` (R19-R24), `01e1ad5` (R25-R27); first try stopped 21:28, D25 |

## Reviews

### `plan-reviewer`, full · 16:30 to 16:42 · NOT_OK

**Report:** [PLAN-2026-11-21-1635.md](../../reviews/PLAN-2026-11-21-1635.md). 5 questions, each settled with the reviewer's
own pick (D21 to D24, and scope 4's Done-when now boots a Workerman); the 10 🟡 folded into `details/phase-3.md`.

- **🔴 Workerman can't start: no `pcntl` in the images.** Settled: D21, `pcntl`, `sockets`, `event` as shared
  extensions in scope 4, whose Done-when now starts a `Worker`.
- **🟠 Listen backlog unset (DIY would get PHP's 32).** Settled: D22, 4,096 and `TCP_NODELAY` everywhere; the client
  opens connections one at a time.
- **🟠 Max connections and stop reasons could be wrong** (no "refused" on Linux, the accept queue counted as
  established, `TIME_WAIT` between runs). Settled: D23, counted by the client, client errors fail the run.
- **🟠 The partial-write case never forces a partial write.** Settled: D24, a socket-pair test in scope 6.
- **🟡** D19 miscounted Workerman's headers (3, no `Server`); the spec's 404/400 messages; the caches are static
  locals; Workerman's `start` argv and pid files; Pss instead of VmRSS; predictions 7 and 8 against the prior art
  (revised at 16:44, still before any measurement); `micro.sh` dropped from the quiet-VM rule; the VM had 7, then
  23, other containers running (action in `plan.md`).

### `pr-reviewer`, pass 1 · 18:17 to 18:23 · OK

**Report:** [PR-2026-11-21-1820.md](../../reviews/PR-2026-11-21-1820.md). Scopes 1 to 6 match `details/phase-3.md`; the lab
is ready for scope 7 to measure fairly (same handler, same socket settings, CPU and Pss over every process of the
cgroup, the connection harness's max and slopes as planned). It reran the DIY parser and partial-write tests and the
caches script.

#### R1 🟡 A dead `wait` mode in the conformance client

**Scopes:** 2 · **Status:** fixed (`e1cf918`)

#### R2 🟡 A comment says Workerman adds a `Server` header

**Scopes:** 5 · **Status:** fixed (`e1cf918`). It contradicted D19 and what scope 5 found.

#### R3 🟡 Helpers and the other-containers block duplicated in `macro.sh` and `conns.sh`

**Scopes:** 2, 3 · **Status:** left (no failure; a refactor for phase 4 if a third harness needs them)

#### R4 🟡 "The loop is Event" is only checked by hand

**Scopes:** 5 · **Status:** fixed (`e1cf918`): `conformance.sh` prints the `loop:` line; the checks assert Event for Workerman, epoll for DIY.

#### R5 🟡 No check that `conns.sh` removes its containers after a failure

**Scopes:** 3 · **Status:** left (the trap exists; scope 3's developer checked it by hand with a `docker kill`)

#### R6 🟡 The backlog is the value asked for, not read back

**Scopes:** 5, 6 · **Status:** left: no socket option returns it and the images have no `ss`; `somaxconn` is 4,096
on the VM, so no clamp. Said in the README.

### `blind-reviewer`, pass 1 · 18:31 to 18:38 · NOT_OK

**Report:** [BLIND-2026-11-21-1831.md](../../reviews/BLIND-2026-11-21-1831.md). No 🔴; it found no broken path in the DIY
parser, the back-pressure or the connection test. Mental load 🔴 high (3,278 lines, 28 files).

#### R7 🟠 "Memory under load, Pss" counts SQLite's mapped database pages

**Scopes:** 2, 3 · **Status:** fixed (`9aadddc`): `Pss_Anon` summed everywhere, the README compares runtimes on it. Smoke: Swoole posts Pss 139 MiB, Pss_Anon 12.5 MiB; on `/noop` 31 and 12.5.

The handler maps the database (`mmap_size`), and Pss counts every mapped page touched, up to about 105 MiB. How much
depends on how many rows a run touched (warm-up included), not on the runtime, so two runtimes measured at different
rates or run lengths would differ by tens of MiB for nothing.

#### R8 🟡 DIY stops on a handler exception, and has no 500

**Scopes:** 6 · **Status:** fixed (`9aadddc`)

#### R9 🟡 DIY accepts a header with a space before the colon

**Scopes:** 6 · **Status:** fixed (`9aadddc`)

#### R10 🟡 Five doc inaccuracies

**Scopes:** 2, 4, 5, 6 · **Status:** fixed (`9aadddc`; Workerman doesn't close after 60 s: it ignores `Connection: close` and keeps the connection; README and comments: the quiet-VM sentence, three pipelined requests,
Workerman's 60 s keep-alive claim, the libevent version, "allocates nothing").

#### R11 🟡 Three leftovers

**Scopes:** 4, 6 · **Status:** left: a comment that assumes phase 2 context, `workerman-caches.php` living next to
the servers, and the warm-up replaying the measured run's ids (the same for every runtime, so it doesn't bias a
comparison).

### `blind-reviewer`, pass 2 · 18:48 to 18:49 · OK

**Report:** [BLIND-2026-11-21-1848.md](../../reviews/BLIND-2026-11-21-1848.md). R7 to R10 fixed; R11 left and not raised
again.

#### R12 🟡 `memory.current` holds the 250 MB database copy in page cache

**Scopes:** 2 · **Status:** left in the code; scope 7's results README says it (compare runtimes on differences).

### `plan-reviewer`, delta · 16:46 to 16:48 · OK

**Report:** [PLAN-2026-11-21-1650-delta.md](../../reviews/PLAN-2026-11-21-1650-delta.md). D21 to D24 settle the full
review's 🔴 and 🟠. 4 🟡, all folded in: each server prints its backlog and `TCP_NODELAY` at boot for the JSON; peak
Pss sampled during the run; `other_containers` counts every container that isn't the run's own; DIY loads `sockets`
before `event`. The first three went to scope 2's developer as a relaunch.

### `pr-reviewer`, delta on scope 7 · 22:12 to 22:15 · NOT_OK

**Report:** [PR-2026-11-21-1820.md](../../reviews/PR-2026-11-21-1820.md), section "Delta : scope 7". The 9 prediction
judgments are right by their own rules (recomputed from the JSON); nothing counted that shouldn't be; the flip rule
read right.

#### R13 🟠 The README gave "host stalls" as the cause of the invalid runs

**Scopes:** 7 · **Status:** fixed (`d0bf2bc`): cause not separated, in four places and in D25; Q10 for phase 4.
All invalid runs are posts runs and most cost more CPU than their pair, which points away from the host alone.

#### R14 to R18 🟡 Five overreadings

**Scopes:** 7 · **Status:** fixed (`d0bf2bc`): "Last step held" column; Swoole's ceiling fits both `nofile` and its
`max_connection`; Swoole's slope is two regimes; the 9,500 `/noop` drop is not explained; differences under about 5 %
sit inside the repeats.

### `pr-reviewer`, delta 2 · 22:16 to 22:17 · OK

**Report:** same file, section "Delta 2". R13 to R18 landed, no verdict changed.

### `blind-reviewer`, delta on scope 7 · 22:13 to 22:20 · NOT_OK

**Report:** [BLIND-2026-11-21-2217.md](../../reviews/BLIND-2026-11-21-2217.md). The tables regenerate, the counted runs
are right, no private data in 134 files.

#### R19 🟠 The second finalist was picked on a gap the README calls noise

**Scopes:** 7 · **Status:** fixed (`2b54788`): Swoole 32.83 against Workerman nocache 33.32 on posts (1.5 %, ranges
overlap). Workerman nocache ran the 9,500 series too (6 runs, not interleaved, said): 29.40 on posts, ahead of
Swoole's 31.01. Second place is a tie within the spread.

#### R20 to R24 🟡 An unproven argument and four smaller items

**Scopes:** 7 · **Status:** fixed (`2b54788`, `b216364`): the "paused vCPU adds no CPU" argument dropped (steal reads
0 in the VM: nothing stolen or not reported); prediction 4's repeat range; the spread figure; `summarize.sh` no
longer hangs on stdin; the `runtimes.md` path.

### `blind-reviewer`, delta 2 · 22:27 to 22:29 · OK

**Report:** [BLIND-2026-11-21-2229.md](../../reviews/BLIND-2026-11-21-2229.md). R19 to R24 landed; the new runs follow the
same counting.

#### R25 to R27 🟡 Three stale wordings

**Scopes:** 7 · **Status:** fixed (`01e1ad5`): the stall range (140 to 511 ms, at 700, 1,400 and 1,900 VUs); "not
separable on posts" instead of a measured order; "the brief's rule" now points to the README's own plan section.

## Retro

Sorted from the retros of 7 developer scopes, 3 `pr-reviewer` passes, 4 `blind-reviewer` passes and mine. A remark
that came from more than one agent says so.

**For the project** (a question in 👉 of [plan.md](../../plan.md)):

- **A check that each results folder regenerates its tables** (`blind-reviewer` delta, and I diffed it by hand at 5
  commits): `lab/check.sh` runs every `lab/results/*/summarize.sh` and checks each printed line is in the README.

**For `~/.claude`** (entries in the inbox, nothing changed during the run):

- **A delta review message lists the commits since the reviewer's last pass and what the project manager already
  checked** (`pr-reviewer`, pass 1 and delta: it found two commits by hand).
- **A measuring scope starts with a one-minute run per route at the planned load** (scope 7's developer and me: the
  first try lost 14 minutes on a VU count the posts route couldn't hold).
- **zsh traps in agents' shells** (scopes 2 and 5, `pr-reviewer`: unmatched globs, `set -- $var` loops): write any
  loop as a bash file.
- **How a late scope's delta counts against `max_relaunches`** (the `blind-reviewer` ran 4 passes for a limit of 1
  relaunch: one per review scope, scopes 1 to 6 then scope 7).

**For you, the planning:**

- **The finalist rule had no noise band.** "The two lowest medians" picked Swoole on a 1.5 % gap the README itself
  calls noise; at 9,500 the order flipped. Next time: inside the spread, both go on.
- **D15 quiets Docker's VM, not the Mac.** The Mac ran PhpStorm, Chrome and a 7.7 GB helper process during the
  series; 8 of 37 posts runs stalled. Q10 asks phase 4 to find the cause.
- **A memory comparison needs a fixed connection count** (`pr-reviewer`): D25 doubled k6's VUs, and Swoole's memory
  under load moved with it (102 MiB `Pss_Anon` against 12 and 9).
- **Which memory figure compares runtimes** (`blind-reviewer` pass 1, impression) was left to the code; it picked
  `Pss_Anon` after a review. The plan could have named it.
- **The predictions that missed** leaned on prior art (Workerman's cost, the 9,500 trend, p99 on posts); the memory
  slopes' near misses (prediction 8) are Swoole's two regimes, not noise.

**For the PR:** "Ce qu'on a appris" in the description below.

**Dismissed (4):** a lint code's severity (scope 1), the brief's port range against the VM (scope 3), `fread`'s 8 KiB
limit (a PR learning instead), Workerman's keep-alive probe (scope 4, became a learning).

## Livraison

**Since the snapshot:** decisions D17 to D25 were added by this phase (D12 to D16 came before it, from phase 2 and
the planning session):

- D17: the bake-off on PHP 8.5. D18: Workerman and DIY on ext-event. D19: each runtime its own headers. D20: two
  routes, `/noop` and `/posts/:id`.
- D21 to D24 (the plan review): `pcntl`, `sockets`, `event` as shared extensions; backlog 4,096 and `TCP_NODELAY`
  everywhere; max connections counted by the client; DIY's partial write on a socket pair.
- D25: twice the k6 VUs on every run, after stalls dropped iterations at rate / 10; cause not separated.

Open `run` questions:

- **Q7** (8.6): the plan wanted 8.6 measured like the others; the branch runs Swoole on 8.5 and gives 8.6 one
  information run per route for Workerman nocache and DIY.
- **Q10** (the posts stalls): the plan had nothing; the branch's extra VUs keep stalls out of the validity rule, and
  the real bench would see them in its p99.

**3 places to look:**

1. `lab/results/2026-11-21-bake-off/README.md:386`: "Did the predictions hold?" and the finalists: where phase 4's
   runtime gets picked, and where the tie sits.
2. `lab/servers/diy-connection.php:118`: `parse()`, our own HTTP parser, the densest code of the branch and the base
   if DIY goes on.
3. `plan/decisions.md` D25: the VU count changed for every run; any memory comparison depends on it (Q10).

**Expected answers:** none: no `FIXME(pending)` in the branch.

**What was done:**

- A lab for comparing runtimes: one handler, three servers (Swoole, Workerman with and without its caches, our own on
  ext-event), an HTTP conformance test, an idle-connection harness.
- The bake-off: 42 counted runs at 7,000 and 9,500 req/s, 3 connection runs, 4 information runs on 8.6, with
  `summarize.sh` regenerating every table.
- Each of the 9 predictions judged: 4 held (2 narrowly), 1 in part, 4 not (8 held only for DIY's slope).

**Final reviews:** `pr-reviewer` OK ([report](../../reviews/PR-2026-11-21-1820.md), delta 2) · `blind-reviewer` OK
([report](../../reviews/BLIND-2026-11-21-2229.md)).

**PR description** (ready to paste):

```markdown
**Résumé**

Le labo de la phase 3 et sa première comparaison de runtimes : un handler commun, trois serveurs (Swoole, Workerman avec ses 5 caches de requêtes retirés ou non, et un serveur maison sur ext-event), un test de conformité HTTP, un test de connexions inactives, et les résultats mesurés avec leur lecture. Avec le même handler, sur arm64 (Docker Desktop, M3 Pro), le serveur maison coûte le moins par requête. Swoole et Workerman patché sont à égalité dans le bruit des répétitions.

**Décisions**

- **PHP 8.5, ext-event pour Workerman et le serveur maison :** `stream_select` plafonne à 1,024 descripteurs, ce qui fausserait le test de connexions. Même boucle pour les deux, donc seule la couche HTTP diffère.
- **Chaque runtime garde ses propres en-têtes de réponse :** moins d'octets d'en-tête fait partie de ce qu'un runtime peut gagner. Les résultats donnent les octets exacts.
- **Backlog 4,096 et `TCP_NODELAY` pour les trois :** le défaut de PHP (32) classerait le harnais, pas le runtime.
- **Le max de connexions est compté par le client :** les connexions qui ont eu leur réponse et sont encore ouvertes. Une erreur côté client fait échouer le run au lieu de passer pour un plafond.
- **L'écriture partielle du serveur maison est testée sur une paire de sockets :** sur loopback, les tampons grossissent jusqu'à des mégaoctets, donc un test de bout en bout peut passer sans jamais écrire en partie.
- **Les VUs de k6 sont à taux / 5 pour toute la série :** à taux / 10, des arrêts de 100 à 300 ms ont fait perdre des itérations sur `posts.js`. Le premier essai est gardé dans `first-try-700-vus/` et n'est compté nulle part. La cause des arrêts n'est pas séparée (l'hôte ou les lectures de la base).
- **Seuls les runs valides sans autre conteneur comptent :** un run invalide est refait une fois en fin de tour, et les deux restent visibles dans le README.

**Changements**

- Handler commun et trois serveurs de bake-off, avec la ligne `socket:` (backlog, `TCP_NODELAY`) et la boucle copiées dans le JSON des mesures.
- `conformance.sh` : 8 cas. `conns.sh` : paliers jusqu'à 66k connexions, rotation des adresses source, pentes de Pss et de `memory.current`, cause d'arrêt nommée.
- Images : `pcntl`, `sockets`, `event` 3.2.0 et Workerman 5.2.4 en deux arbres, tout épinglé par sha256.
- `macro.sh` : `--ext`, `--env`, `--label`, `Pss_Anon` sous charge. `posts.js` pour `GET /posts/:id`.
- `lab/results/2026-11-21-bake-off/` : 42 runs comptés, 4 runs PHP 8.6 (information), 3 runs de connexions, et `summarize.sh` qui regénère les tableaux.

**Preuves**

Médianes de 3 répétitions entrelacées, 7,000 req/s, PHP 8.5, 1 CPU, VM sans autre conteneur (µs de CPU par requête) :

| Runtime | `/noop` | `GET /posts/:id` |
|---|---|---|
| Swoole | 25.47 | 32.83 |
| Workerman (caches retirés) | 26.24 | 33.32 |
| Workerman (caches en place) | 23.39 | 34.05 |
| Serveur maison | 21.88 | 29.14 |

- À 9,500 req/s : serveur maison 17.37 et 27.66, Swoole 18.53 et 31.01, Workerman (caches retirés) 21.65 et 29.40. Sur posts, Workerman passe devant Swoole : la deuxième place est une égalité dans le bruit (les écarts sous environ 5 % sont dans l'étendue des répétitions).
- Connexions inactives, un processus : les trois tiennent 65,000 puis s'arrêtent à 65,522 ou 65,523, la limite de descripteurs. Swoole n'a pas été tué par la mémoire (1,659 MiB sur 2 GiB). Pente de `Pss_Anon` par connexion : Swoole 14.3 KiB (69 KiB sous 10,000 connexions, 5 KiB au-delà de 20,000), Workerman 2.4, serveur maison 1.5.
- Règle de bascule : Workerman patché est à 3.0 % de Swoole sur `/noop`, donc elle ne bascule pas.
- Des 9 prédictions écrites avant la mesure, 4 ont tenu (1, 2, 4 et 5, les deux dernières de justesse), une en partie (7) et 4 n'ont pas tenu (3, 6, 8 et 9). Le détail, avec les chiffres, est dans le README du dossier de résultats.
- Ce sont des chiffres arm64 : seuls les écarts entre runtimes comptent, les valeurs absolues ne comptent que sur x86.
- `bash lab/check.sh` : 32/32.

**Ce qu'on a appris**

- Workerman ignore `Connection: close`, dans la requête comme dans la réponse, et garde la connexion ouverte : seul `$connection->close($response)` la ferme.
- Les caches de Workerman font gagner 11 % sur `/noop` (la même requête revient sans cesse) et rien sur posts, où chaque id revient rarement.
- `fread` sur un socket PHP rend au plus 8,192 octets, quelle que soit la longueur demandée.
- La plage de ports éphémères de la VM est 55000-65535 (10,536 ports) : 66k connexions demandent 7 adresses source.
- La mémoire de Swoole n'est pas linéaire en connexions (69 KiB chacune sous 10,000, 5 KiB au-delà de 20,000) : une pente unique la cache.
- Seule la route posts a des arrêts de 140 à 511 ms, et ces runs coûtent plus de CPU : la cause reste à séparer (l'hôte ou les lectures de la base).
```

**The commits:**

```bash
git log --oneline main..phase-3-claude
```

**Review** (in PhpStorm: right-click the branch > *Compare with Current*, or on the command line):

```bash
git diff main...phase-3-claude
```

**Minor items left:** R3 (helpers duplicated in `macro.sh` and `conns.sh`), R5 (no check that `conns.sh` cleans up
after a failure), R6 (the backlog is the value asked for), R11 (three leftovers: a phase 2 comment,
`workerman-caches.php`'s place, the warm-up replays the measured ids), R12 (`memory.current` holds the database's page
cache).

**Merge and close**, from the main checkout on `main` (`main` has plan commits the branch doesn't, so no
fast-forward; the branch touches only `lab/`):

```bash
git merge --no-edit phase-3-claude && git push && git worktree remove ~/.claude/worktrees/twelve-dollar-server-php/phase-3-claude && git branch -d phase-3-claude
```

Variants:

```bash
git cherry-pick <sha>          # take one commit
git worktree remove --force ~/.claude/worktrees/twelve-dollar-server-php/phase-3-claude   # throw it all away
git branch -D phase-3-claude
```

Or the PR loop: ask for the branch's PR (skill `pr-loop`) instead of the merge.
