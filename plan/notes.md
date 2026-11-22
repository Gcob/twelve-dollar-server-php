# Notes: ideas we challenged

Every idea we discuss lands here, with the challenge and its verdict, so we never have the same discussion twice. To
reopen one, say so: the verdict changes here, with the date, and the old reasoning stays.

**Verdicts:** ✅ kept (and where it lives in the plan) · ❌ rejected · 🔶 open.

### 2026-11-21 09:02 · 💡 Idea: Podman to cut the container overhead

**Jacob:** « Est-ce que Podman serait un overhead qui nous pénaliserait beaucoup? […] il me semble que Podman,
justement, enlève beaucoup d'overhead. »

**Challenge:**

- A container is a normal Linux process inside namespaces and cgroups: no CPU overhead for PHP itself.
- The cost is the network. Rootless Podman sends every packet through a userspace process (`pasta` or
  `slirp4netns`), and Docker's bridge adds NAT and a veth hop. Only `--network host` is native.
- Podman's real gain over Docker is no daemon (dockerd's RAM), not a faster network.
- None of the ~500 submissions runs its server in a container (two use Docker, for local dev or cross-compiling).

**Verdict:** ❌ for the submission: a container adds risk and nothing measurable. ✅ for the lab (D7), host network
only (see the 09:11 note).

### 2026-11-21 09:02 · 💡 Idea: several containers to get past the 65k connections

**Jacob:** « si PHP, il y a une limite avec Swoole de connexion, est-ce qu'on pourrait avoir plusieurs containers,
genre scalés horizontalement? Je sais qu'on a juste un vCPU. »

**Challenge:**

- The 65,535 limit is per process, so the container is only packaging: 2 Swoole processes with `SO_REUSEPORT` give the
  same 2 x 65k, without a container.
- 1 vCPU: a second process splits the same core. tzimpel measured +27 % CPU per request with 2 workers.
- Something must spread the connections: `SO_REUSEPORT` does it in the kernel, for free. Separate containers on
  different ports would need a load balancer in front.

**Verdict:** ✅ the idea stays as variant **S1-b** (N processes with `SO_REUSEPORT`), measured against **S1-d**
(one process, `Connection: close` near the limit) in [details/steps.md](details/steps.md). ❌ the containers.

### 2026-11-21 09:02 · 💡 Idea: ship a prebuilt image, or cached Docker layers

**Jacob:** « Est-ce qu'on pourrait fournir une image qui est déjà build, genre? Ou […] au moins les layers de cache
[…] pour que quand il fasse son build, ça aille plus vite? »

**Challenge:**

- Rule 10: build from source on the machine, pinned versions, no precompiled binaries. A prebuilt image or cached
  layers are precompiled binaries.
- The pressure was smaller than it sounded: the install timeout is **1 hour** (LEADERBOARD.md, the entries that hit
  it were V bootstrapping its own compiler). Compiling PHP fits well within that.
- The tight limit is another one: healthy within **60 s of `start.sh`**, easy for us.

**Verdict:** ❌ against rule 10, and not needed.

### 2026-11-21 09:11 · 💡 Idea: a PHP load balancer in front of PHP workers

**Jacob:** "I'm thinking about a PHP load balancer. Like there would be a PHP session, like that would relay to
another PHP the session. Ah, no, we're gonna hit the maximum limit with that, so it doesn't make any sense."

**Challenge (Jacob's own):** the balancer holds every client connection, so it hits the same 65,535 fds, and every
request pays a second hop on the same core.

**Verdict:** ❌ rejected by Jacob himself.

### 2026-11-21 09:11 · 💡 Idea: Traefik as the API gateway

**Jacob:** "I do like the API gateway of Traefik. I don't know if that would be good because Traefik has the auto
discovery and everything we need for all the traffic that comes in."

**Challenge:**

- Same fd wall: Traefik holds every client connection in one process, under the same `LimitNOFILE=65535`, plus its
  connections to the backends.
- CPU: a Go reverse proxy parses and re-serializes every request on our only core. Nginx alone cost 14 to 20 %, and
  Traefik is heavier per request than Nginx. D1 rules out Nginx for exactly that reason.
- Auto-discovery solves services that come and go. Here: one machine, 1 or 2 fixed processes, nothing to discover.
- The kernel already balances for free: `SO_REUSEPORT` spreads new connections across our processes.

**Verdict:** 🔶 Claude's take: no, for the reasons above. Open until you agree or bring a fact that changes it.

**2026-11-21 09:35:** Jacob: "We can let go Traefik." **Verdict:** ❌ rejected.

### 2026-11-21 09:11 · 👀 Observation: containers only with the host network

**Jacob:** "I would definitely use Docker or Podman with the host network. Never using the Docker network. That would
be just terrible."

**Challenge:** agreed, and it goes further on the Mac. Docker Desktop runs Linux in a VM: k6 on macOS reaching a
container goes through Docker Desktop's userspace port forwarding, even with `--network host`. That path would
pollute every macro measurement.

**Verdict:** ✅ in [details/measuring.md](details/measuring.md): k6 runs in its own container in the same Docker VM,
both on the host network, each pinned to its own cores.

### 2026-11-21 09:15 · 💡 Idea: keep the whole plan in this repo, and commit it in public

**Jacob:** "Could you keep the notes inside the $12 server challenge directory? I want to commit publicly all the
thoughts, all the process, everything like we are doing, just to keep track, to be transparent. Is that a good idea or
not?"

**Challenge:**

- **For:** the best thing we read in the prior art was HolyPHP's README, a public journal of every experiment with
  its numbers. Ours would be the same, plus the reasoning before each measurement. Nothing to hide either: once
  submitted, the code is MIT anyway.
- **Against:** half-baked ideas stay visible. That's the point of the log, not a flaw.
- **Care needed:** no employer names, personal paths, emails or account ids in `plan/`, and other people's private
  exchanges stay out. The plan tooling expects `~/.claude/plans/`, so a symlink points there.
- **The challenge PR is unaffected:** it only carries the submission folder, from a separate fork (D4).

**Verdict:** ✅ D11: the plan lives in `plan/`, committed in public, `plan/communications/` ignored by git.

### 2026-11-21 09:20 · 💡 Idea: a project-manager teammate does the work, and the team commits and pushes

**Jacob:** "Invoke a project manager with the autonomous-run skill if needed, so we can discuss and let the teammate do
the work. The team will be able to push and commit. This way, we can keep a good context window."

**Challenge:**

- **For:** the planning session stays light and stays the place where ideas get challenged; the project manager
  carries the run, and its developers carry the code.
- **The skill's worktree doesn't fit here:** it isolates a run from your working branch, but you don't code on this
  repo, and the plan now lives in the repo (D11). In a worktree, the run's questions would land in a copy of
  `plan.md` that the decision board can't see. So: `main`, this checkout, explicit `git add` of each file only.
- **One phase per run:** you want to see each step behave (D3, D5), so the project manager stops at the end of each
  phase instead of chaining all 7.
- **Two writers, one folder:** the planning session only writes `plan/notes.md`; the project manager owns the rest of
  `plan/`.

**Verdict:** ✅ D12. The `main`-without-worktree layout and the one-phase-per-run stop are Claude's choices: challenge
them anytime.

### 2026-11-21 09:35 · 💡 Idea: a heartbeat, and a git-ignored CLAUDE.local.md like lara-spec-first's

**Jacob:** "Could you have a heartbeat or something? Check lara-spec-first's CLAUDE.local.md, there is info about how it
runs the software factory. We could add a CLAUDE.local.md here too, gitignore it to take advantage of it." Also: never
Fable, "because I don't want to spend money other than my subscription".

**Challenge:**

- **Why a heartbeat is needed:** the weekly limit was at 96 %. A turn that fails on a usage limit isn't restarted by
  the app, and nothing wakes up by itself at the reset.
- **What it can and can't do:** `CronCreate` jobs live in the planning session only. They die if that session or the
  app closes, and a recurring job expires after 7 days. Good enough for a run of a few hours.
- **Pacing beats crashing:** a run that lands at 98 % (agents finish, state saved) resumes cleaner than one cut off at
  100 % in the middle of an agent.
- **Kept from the factory:** the pace modes, the heartbeat, the parent that relays without echoing, the reread after a
  compaction, "the project manager pushes, developers commit". **Left out:** the board, PR merges, parallel cards,
  digests: one phase, one branch, no PRs here.

**Verdict:** ✅ `CLAUDE.local.md` (git-ignored), an hourly heartbeat plus a one-shot check at 11:07, and no Fable ever.

### 2026-11-21 09:45 · ❓ Question: can the team work on separate branches?

**Jacob:** "Can the team work on separated branches? I do not understand the problem here?"

**Challenge:**

- **Yes, it can.** The only friction: `plan/` lives in the repo (D11). If the project manager writes its questions and
  `run.md` inside a worktree on another branch, they land in a copy that the decision board and
  `~/.claude/plans/...` (both pointing at this checkout) never see until the merge.
- **The fix is to split by folder, not by branch:** code goes on a branch per phase (`phase-N-claude`) in its own
  worktree; `plan/` stays on `main`, written from this checkout, so Jacob sees questions right away.
- **What a branch buys:** `main` only gets a phase once it's done and reviewed (the skill's second gate: Jacob, or a PR,
  merges); Jacob's own edits never meet a developer's; the diff of a whole phase is one comparison.
- **What it costs:** two places to keep straight for the project manager, and a merge at the end of each phase.
- **Timing:** scopes 1 and 2 of phase 2 are already on `main`, scope 3 is running. Switching mid-phase adds risk for
  little gain: from phase 3 is cleaner.

**Verdict:** 🔶 open: Claude's take is yes, from phase 3, code on a branch per phase and `plan/` on `main`. Replaces
the "no worktree" part of D12 if Jacob agrees.

**2026-11-21 09:50:** Jacob: "Yes, from phase 3". **Verdict:** ✅ D14 (recorded by the project manager in
`decisions.md`): from phase 3, code on a branch per phase in its own worktree, `plan/` stays on `main`.

### 2026-11-22 10:33 · 💡 Idea: compile the slowest PHP functions to native code

**Jacob** (to Gemini, after a LinkedIn post about fast-anything): « si je réussis à trouver les fonctions qui prennent
le plus de temps en PHP et que je les compile comme Fast Anything en Python, ça pourrait me sauver du temps, non ? »

**Challenge:**

- **It's HolyPHP's road.** HolyPHP compiles a PHP syntax to C and rewrote its runtime in C: 270,000 users, and the
  leaderboard notes file it as "not really PHP". Our goal is the real-PHP record (D2): every function moved to C or
  Rust moves us toward that line.
- **The genuine version already exists:** OPcache's tracing JIT compiles hot PHP to machine code, and the micro
  harness measures every step with the JIT on and off. FFI to `libsqlite3` (S6) calls an existing C library, like
  `pdo_sqlite` does.
- **The gain is unknown:** DIY's 29 µs on posts splits between our PHP code, SQLite's C and the kernel's syscalls,
  in proportions nobody has measured. Native code only shrinks the first part. The profiler (SPX or Excimer,
  [measuring.md](details/measuring.md)) tells how big it is.

**Verdict:** ❌ our own native code (D2). ✅ Gemini's own advice, "profile first": already in the plan.

### 2026-11-22 10:33 · 💡 Idea: Gemini's list of SQLite I/O techniques

**Jacob:** « c'est quoi les techniques connues ou peut-être moins connues, moins répandues, pour optimiser ça de façon
maximale ? »

**Challenge:** the premise first. Gemini says the bottleneck is SQLite's I/O. On our VM the 250 MB seed sits in RAM,
so a read is a memory copy, not a disk access; the only disk waits are the WAL writes and the checkpoint's `fsync`.
In the bake-off, a whole `/posts/:id` (SQLite read plus JSON) costs about 7 µs more than `/noop`'s 22: the network
side weighs more, at least on that route. `/feed` (20 posts, 20 like counts) isn't measured yet.

| Technique                                            | Verdict          | Why                                                                                         |
|------------------------------------------------------|------------------|---------------------------------------------------------------------------------------------|
| WAL + `synchronous=NORMAL`                           | ✅ already (S9)   | rule 6's minimum, our starting point                                                        |
| Prepared statements reused                           | ✅ already (S6)   | rule 5 allows it, S6 measures what it saves                                                 |
| `mmap_size`, `cache_size`                            | ✅ already (S6)   | a full mmap of the 250 MB seed fits in 2 GB; watch the cgroup's memory                      |
| `temp_store=MEMORY`                                  | ✅ already (S6)   | cheap to try; `EXPLAIN QUERY PLAN` tells if our queries use a temp table at all             |
| Checkpoint control (`wal_autocheckpoint`, `PASSIVE`) | ✅ already (S9)   | plus a background checkpointer, see the `Promise.all` note below                            |
| Group commit                                         | ✅ already (S9)   | rule 6 allows it, see the next note                                                         |
| `busy_timeout`, a single writer                      | free             | one process is already the only writer: no lock to fight over. Comes back only with S1-b    |
| Covering indexes                                     | ❌                | rule 3: no new index                                                                        |
| Avoid `OFFSET`                                       | n/a              | the feed is `LIMIT 20`, no paging                                                           |
| io_uring, reading the B-trees directly               | ❌ already        | out of scope in `plan.md`: not reachable from PHP without C                                 |

**Verdict:** ✅ the plan already holds this list (S6, S9), a good sign for [steps.md](details/steps.md); the only new
item is the background checkpointer. ❌ covering indexes (rule 3).

### 2026-11-22 10:33 · 💡 Idea: group the requests to the database

**Jacob:** "one of the idea of Gemini to group the request to the DB was already in my mind". Gemini's version: the
group commit, several writes in one transaction, each request answered once the `COMMIT` succeeds.

**Challenge:**

- **Writes, the group commit:** rule 6 allows it if every response waits for its commit, and S9 already lists it
  ("writes queued for a few ms"). **A better trigger than a timer:** one batch per turn of the event loop. Each turn
  gathers the writes that arrived together, runs one `BEGIN … COMMIT`, then answers them all. At low load a batch is
  one write, so no added latency; near saturation the batches grow by themselves, exactly when it matters. HolyPHP
  uses a group commit too.
- **What it can win:** writes are 7.8 % of the bench's requests (about 700 per second at 100,000 users). The gain is
  a commit's fixed cost (lock calls, WAL frame writes) shared by the batch, plus pages that several likes touch (the
  hot posts' index pages) written once. Measure one commit alone first: at 10 µs, the ceiling is about 1 % of the CPU.
- **Reads, a grey zone of rule 5:** grouping five `/posts/:id` into one `IN (...)` query keeps one row read per
  request, which looks allowed. Merging identical reads (two `/feed` in the same turn, or the same hot post) shares one
  query result between requests: rule 5's forbidden result cache. In the real bench `/posts/:id` only targets the
  newest 20 posts, so duplicates would be common.
- **Reads, the gain:** only a query's fixed cost (bind, execute, reset), and only when a turn holds several requests,
  which means near saturation.

**Verdict:** ✅ the group commit per loop turn, a new S9 variant for phase 4. 🔶 batched reads: only without merging
duplicates, and only if the profile shows a query's fixed cost is worth it. ❌ merging identical reads (rule 5).

**2026-11-22 10:41:** Jacob challenged the rule 5 part: "if 2 requests ask for the very same thing at the same time,
lookup seems to me to be fair, not cached". By the textbook he's right: a cache keeps a result to reuse it later, and
a read shared by requests already waiting keeps nothing. But the challenge's author ruled on exactly this on
2026-11-15 (`LEADERBOARD.md`, "Rule flags from code review"): **read coalescing is not allowed**, because "one query
result shared by several requests is a cache across requests". go-iouring-rkkautsar #260 (one feed query, or one
`IN (...)` for the post ids, per batch, "nothing outlives the batch") and go-nethttp #277 (one `/feed` read per write
generation, and concurrent `/posts/:id` batched into one `IN` query) went off the board for it; rust-iouring #322 came
back once each request did its own read. So the 🔶 above was wrong too: one `IN (...)` for different posts is the same
ruling. **Verdict:** ❌ every read shared by several requests, merged or batched (Arjay's ruling). ✅ the group commit
for writes stays: rule 6 allows it by name.

### 2026-11-22 10:33 · 💡 Idea: test the way Arjay tests

**Jacob:** "We must include its way to test!" The challenge's author, in his newsletter, shares his skill
[realistic-load-test](https://github.com/arjaythedev/realistic-load-test) (MIT, commit `8eb3343`). His point: a load
test that hammers one endpoint gives a requests-per-second number, not a number of users.

**His method** (read from the skill on 2026-11-22): profile how real users behave, turn the profile into virtual users
that sleep their think time (`ramping-vus`, a closed model), calibrate at 20 to 50 VUs, warm up at about 10 % of the
expected capacity, climb a linear staircase that stops at the first failing step (p95, p99, errors), then hold
5 minutes at the estimate, one step above and one below, 3 times each, and keep the median.

**Challenge:**

- **The challenge already is his method, applied to this app:** `bench/load.js` is the user profile (the feed, then a
  post taken from it, 15 % like, 2 % new post, 3 to 15 s of think time, one connection per user), and the scoring is
  a staircase (doubling from 2,500, bisection, 5-minute hold, fresh database for each probe). His first steps (profile
  the users, write the VU) are done for us.
- **Where our lab differs, on purpose:** it ranks variants by µs per request at a fixed rate
  (`constant-arrival-rate`), one route at a time, 30 s, about 1,900 connections. Good for ranking, blind to four
  things the bench does:
  1. **the mix:** `/feed` is 46 % of the requests and the heaviest, and isn't measured yet;
  2. **the connections:** 75,000 to 100,000 open, mostly idle;
  3. **time:** 5 minutes of writes, so the WAL grows and checkpoints run;
  4. **the hot set:** our `posts.js` walks all 500,000 posts in turn; the bench only reads posts it just got from the
     feed, the newest 20. Q10's stalls may be a lab artifact (cold pages of the 250 MB file) that the bench never
     meets.
- **The Mac can't play 100,000 users:** k6 needs 1 to 5 MB per VU and one instance tops out around 30,000 to 40,000
  VUs (k6's "Running large tests" guide); one source IP opens about 64,000 connections to one port. The scoring uses
  several 16-core generators.
- **A version that fits on the Mac:** `load.js`'s journey with shorter think times (a few thousand VUs make the
  bench's 9,300 req/s, with the same mix and the same hot posts), plus phase 3's connection harness holding about
  60,000 idle keep-alive connections, so the server also carries the bench's connection count. Arjay's run shape on
  top: warm-up, staircase, 5-minute holds 3 times, median, a fresh database each time. The full-size run stays for
  phase 6, on x86 with several generators.

**Verdict:** 🔶 Claude's take: yes, and early. Phase 4 starts with a walking skeleton (DIY, the 5 endpoints with the
reference SQL, the 42 tests) and the realistic mode above, then a profile under that load; the step lab follows, in
the order the profile gives. Open until Jacob picks.

**2026-11-22 10:41:** found in passing, for phase 6: java-micronaut-Clickin replaced k6 with a Rust implementation of
`load.js` (`rlt`), checked against k6 for the same request mix, think times, headers and server CPU per request, and
split its users over two 4-vCPU generators, because of k6's memory at tens of thousands of VUs and the ~64,500
connections one source IP can open to one port.

### 2026-11-22 10:33 · 💡 Idea: run a request's steps in parallel, like `Promise.all`

**Jacob:** async steps like JavaScript's `Promise.all`, where one failing part fails the request: "we do not wait to
validate the JWT before starting the rest of the process, so if the JWT validation fails, we stop the rest […] maybe
it is not worth because we waste CPU in this case, but maybe it is worth for a large scale".

**Challenge:**

- **Possible:** Fibers (built into PHP since 8.1), Swoole's coroutines, Amp or ReactPHP promises, or real threads with
  the `parallel` extension (it needs a thread-safe PHP build).
- **`Promise.all` wins by overlapping waits** (calls to other services, the disk). Inside one of our requests nothing
  waits: the JWT check is an HMAC, pure CPU, and the SQLite read is pure CPU too (the database sits in RAM, and
  `pdo_sqlite` has no async API). On one vCPU, two CPU tasks run one after the other however they're written.
- **The score counts CPU, not one request's latency:** users ≈ 9.2 million / µs per request. A microsecond less
  latency buys no user; starting a fiber or a coroutine costs CPU, which does cost users.
- **The failure case is rare, and so is the gain:** the bench always sends valid tokens.
- **Where the instinct is right, two places where something really waits:**
  - **across requests:** the event loop already does it. While one connection waits on the network, the others run:
    that's what the three runtimes of the bake-off do;
  - **the WAL checkpoint:** the one step that waits on the disk (`fsync`). In a one-process loop, a checkpoint inside
    a request freezes every connection while it runs. A separate process that runs `PRAGMA wal_checkpoint(PASSIVE)`
    on a timer, with the server's `wal_autocheckpoint` off, takes the wait off the loop: the CPU work stays, the
    waiting goes. HolyPHP runs its checkpoints in the background.

**Verdict:** ❌ parallel steps inside a request (one vCPU, steps that only use the CPU). ✅ its real form, a
background checkpointer: a new S9 variant for phase 4, next to the group commit per loop turn.
