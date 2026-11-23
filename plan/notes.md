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

### 2026-11-22 13:41 · ❓ Question: a remote VM, so the lab can push its tests further?

**Jacob:** "Will you need an AWS EC2, Digital Ocean or other distant VM to let the lab push its test into a better
incubator?"

**Context:** scope 3's smoke runs (a busy VM, not measurements) passed every step up to 17,816 req/s with 60,000 idle
connections, and k6 on the Mac tops out around 20,000 req/s (D45, D46). The knee may sit above what the Mac can push.

**Challenge:**

- **Not for phase 4 or the step lab.** They ask relative questions (where the CPU goes, which variant costs less),
  and the Mac answers those. Pushing the Mac past its knee buys little: its req/s isn't the bench's (arm64 against a
  2.4 GHz Xeon), and past about 65,000 connections the fd wall comes first anyway (S1), on any machine.
- **Needed later, for two numbers the Mac can't give:**
  1. **The x86 factor:** µs per request on a Xeon like the bench's. One server VM and the realistic mode with one
     generator are enough, for an hour or two.
  2. **The score check (phase 7):** more than 71,000 users held 5 minutes with `load.js` unscaled. That's 100,000 or
     more VUs: tens of GB of k6 memory, and at most about 64,000 connections per source IP, so 2 or 3 generators in
     the same datacenter, or `rlt` (the Rust `load.js` used by java-micronaut-Clickin), which is lighter.
- **Which machine:** the most faithful is the bench's own provider, a Synteq VPS (KVM, Xeon Platinum 8260, 1 vCPU,
  about 2 GB, kernel 6.8): the leaderboard's hardware. The hourly alternative is AWS `c5` or `m5` (the same Xeon
  Scalable families), limited to 1 vCPU like the lab. Not a `t3`: its CPU credits run out under a 5-minute hold.
  Not DigitalOcean: the challenge's first runs there were about 2 times slower in CPU and were all re-run.
- **The cost is Jacob's call** (D7): nothing is created without him.

**Verdict:** 🔶 Claude's take: no remote VM for phase 4; a short x86 calibration after its baseline (one server VM,
one generator), and the full-size check with several generators in phase 7. Open until Jacob decides.

### 2026-11-22 17:57 · ❓ Question: is there still room for improvement?

**Jacob:** "Do you think there is still place for improvement somewhere, or we should finish next steps before asking
that?"

**Context:** the realistic baseline (phase 4, Mac arm64): 27.15 µs of CPU per request, at least 23,386 req/s held
with 60,000 idle connections. The profile: SQLite 52 % (`GET /feed` alone 48 % of the CPU, about 28 µs per feed
against 4 per post), the response write 20 %, JSON 10 %, parsing 8 %, the kernel 30 % of the CPU throughout.

**Challenge:** yes, and the profile says where, but in an order set by the walls, not by the CPU shares:

1. **The fd wall first.** With one process the server holds about 65,500 connections, so the bench caps it near
   71,000 users whatever the CPU. Every CPU gain is worth zero users until S1-d (`Connection: close` near the limit)
   or S1-b (several processes) works. Its cost is the question: a reconnect per request past the limit (accept, close,
   a TCP handshake), against S1-b's context switches (tzimpel measured +27 % per request with 2 workers).
2. **The x86 factor, alongside:** it says which wall binds on the bench's hardware. If a request costs 2 to 4 times
   more there, the CPU work below decides the score; if not, the connections do.
3. **Then the CPU, in the profile's order:**
   - **The feed query:** halving the feed handler (28 to 14 µs) would take the average from about 27 to 21 µs, about
     30 % more requests. Variants already in S6: a `LEFT JOIN ... GROUP BY`, or two statements (the 20 posts, then the
     counts with `IN (...)`). Within one request that `IN` is fine: rule 5 forbids a read shared between requests, not
     a request's own two statements.
   - **Syscalls per request (new):** 30 % of the CPU is the kernel. Count the syscalls of one request (`strace -c`
     under load): an `epoll_ctl` per request to arm a write event, or a read that returns `EAGAIN`, is pure overhead
     the loop could skip.
   - **The write, JSON and parsing (S8, S7, S2):** together about 10 µs, each with its variants in steps.md.
   - **Not worth it:** the JWT, routing and validation are under 2 % together.

**Verdict:** 🔶 Claude's take: phase 5 starts with the fd wall, the x86 calibration runs beside it once Jacob picks a
VM, then the feed query and the syscall count. Open until Jacob plans phase 5.

### 2026-11-22 18:01 · ❓ Question: what is the fd wall, and could we build our own way around it?

**Jacob:** "What is FD? And one question that might sound stupid, could we build our own one to surpass this limit?
Because your option B would be to have several processes that will use 27% more computer power per request. That is
way too much."

**The wall:** a file descriptor (fd) is the number the kernel gives a process for each thing it opens: a file, a
pipe, a network connection. The server holds one per open connection. The bench starts it with `LimitNOFILE=65535`,
the most fds one process may hold, and it can't raise that: it isn't root, and rule 11 forbids tuning the box. Every
k6 user keeps its own connection, so one process serves about 65,500 users at once, and many entries stop near
71,000.

**Challenge:** not a stupid question: the entries past 71,000 all built their own way around it.

- **io_uring direct descriptors** (csharp-kestrel 260,000, rust-iouring-kensac 310,000, HolyPHP's io_uring path):
  accepted sockets live in a ring's own table instead of the process's fd table, and several rings give several
  tables. ❌ for us: no io_uring for sockets from PHP without writing C.
- **`Connection: close` near the limit (S1-d):** go-epoll-MegaPanchamZ, one process on raw epoll like our DIY loop,
  held **185,000 users** (51 µs per request, 99 % CPU on the bench). Above a soft limit its responses carry
  `Connection: close`, so the user reconnects on its next request, about 10 s later, and the seat is free meanwhile;
  only at a hard limit does it evict the longest-idle connection. HolyPHP's classic path sheds the same way at
  61,439 fds. A user's connection sits idle more than 99 % of the time: the fds are the scarce resource, not the CPU,
  so the seats rotate. The cost is a reconnect (accept, TCP handshake, close) per request for the users past the
  limit: about 57 % of the requests at 150,000 users. Unknown, to measure.
- **Several processes (S1-b):** the +27 % is one measurement (tzimpel, Swoole, 2 workers), blamed on context switches
  and SQLite's write lock shared by two processes. It's a prediction to re-measure (D5), not an answer, but it starts
  behind S1-d.

**Verdict:** ✅ S1-d first in phase 5, with its cost per reconnect measured; prior art shows one epoll process reaching
185,000 that way. 🔶 S1-b only if S1-d's reconnects cost more than a second process. ❌ io_uring direct descriptors
(needs C).

**2026-11-22 18:08:** the ❌ on io_uring is reopened by the next note: PHP's FFI may reach it without writing C.

### 2026-11-22 18:08 · 💡 Idea: try io_uring anyway, something nobody tried in PHP

**Jacob:** "do you think we could still even try it? […] to be at the top, we need to do some, let's say, gray hat
actions. We need to go out of the woods and try to do something new, something like spectacular or just that nobody
really tried to do usually."

**What io_uring is:** a Linux interface where the program and the kernel share two queues in memory. The program
writes its orders (accept, read, write) into the first, the kernel does them and posts the results in the second.
Two gains: many operations per syscall instead of one each (the kernel is 30 % of our CPU), and "direct
descriptors", sockets kept in a ring's own table instead of the process's fd table, so several rings carry several
times 65,535 connections in one process.

**Challenge:**

- **A way in without C: FFI.** Our PHP builds have FFI (core PHP). It can call libc's `syscall()` and `mmap()`, so a
  PHP loop could set up a ring with `io_uring_setup`, map its queues, write the orders through FFI pointers and call
  `io_uring_enter`. liburing's helpers are inline C functions FFI can't call, so the loop would do their work in PHP.
  No PHP entry of the challenge uses io_uring (tzimpel's build even turns Swoole's off): it would be a first.
- **Is it still real PHP?** Our own PHP code driving the kernel through a core extension, like the FFI to
  `libsqlite3` already in S6. Not HolyPHP's road (PHP syntax compiled to C). Jacob's call (D2).
- **The risks:** each FFI call and each access to C memory costs more than a native call, maybe enough to eat the
  syscalls it saves; the queues need memory ordering, which FFI can't express, so the loop must rely on
  `io_uring_enter`'s own ordering; Docker's default seccomp profile blocks io_uring, so the lab needs its own profile
  (the bench's systemd service allows it: the top entries run on it).
- **Bold, not gray hat:** io_uring is inside the rules (the top 6 use it). Bending a rule is what took two entries
  off the board for read coalescing: the score has to survive Arjay's review.

**Verdict:** 🔶 Claude's take: yes, as a time-boxed spike in phase 5 next to S1-d (the safe path): a no-op server on
an FFI io_uring loop with direct descriptors, holding more than 65,535 connections in one process, its µs per
request against DIY's 21.88. If FFI's overhead eats the gain, we learned it cheaply. Open until Jacob plans phase 5.

### 2026-11-22 18:08 · 💡 Idea: a proxy in front, several processes holding the connections

**Jacob:** "Can we have a proxy in between that could help? Like if we have multiple processes that have 65,000 of
connections and they perform an HTTP in between our PHP application with the connection close on every request."

**Challenge:**

- **It's S1-b plus a hop.** The proxy processes are the several processes (each holding up to 65,535 clients), so
  they pay S1-b's context switches, and every request is then read, parsed and written twice, and crosses a second
  socket on the same core. Nginx alone cost 14 to 20 % of the CPU in the challenge's video (the reason for D1).
- **`Connection: close` between the proxy and PHP** makes it worse: an accept, a handshake and a close for every
  request, the cost S1-d only pays for the users past the limit.
- Same as the PHP load balancer and Traefik of 2026-11-21 (above): whoever holds the client's socket holds its fd.

**Verdict:** ❌ more CPU than S1-b alone, for the same fd gain.

### 2026-11-22 18:15 · 💡 Idea: continue the lab on Jacob's desktop PC

**Jacob** (his answer to Q11): "should we continue the lab on my ryzen 9 pc tower? It has 64 go RAM DDR5 + RTX4700, we
could maybe try to create a VM or something. It is on Windows though"

**Challenge:**

- **What it would fix:** the Mac shares its CPUs between the server and k6, and k6 gave out before the server (D47).
  The desktop has many more cores and 64 GB: at about 0.3 MiB per VU, 100,000 or more VUs fit, so `load.js` could run
  **unscaled** (real think times, one connection per user) and test the fd wall past 65,535 for real, which the Mac
  can't.
- **It's x86:** closer to the bench than the M3, so a first x86 number. Not the bench's CPU (a Ryzen core is much
  faster than a 2.4 GHz Xeon), so it doesn't replace the calibration on the bench's hardware.
- **Layout:** everything on the desktop, like the Mac lab: the server pinned to one core, k6 on the others, all in
  Linux. Mac to desktop over the LAN would put the home network in every measurement (about 400 Mbit/s of responses at
  23,000 req/s, so wired gigabit at least). The Mac stays the place the sessions run, driving the desktop over SSH.
- **Windows:** WSL2 runs a real Linux kernel (io_uring included, for the spike) with Docker inside, so the lab's bash
  and images move as they are. Its noise (Windows Update, the antivirus, power saving) needs a quiet-machine rule
  like D15. Dual-booting Ubuntu would be cleaner, at more setup.
- **Cost:** none: Jacob's hardware, inside the no-paid-service rule. The setup (WSL2, Docker, SSH in) is Jacob's to do
  on his machine.
- **Q11 stays A:** a CPU-saving variant is still judged by its µs per request and the profile; the desktop adds the
  server's own knee and the real connection counts.

**Verdict:** 🔶 Claude's take: yes, as the lab's second host for the full-size realistic runs, the fd wall and the
io_uring spike, with the Mac still running the quick comparisons. Open until Jacob confirms.

### 2026-11-22 18:25 · ❓ Question: what does FFI cost, and can a fail-fast lab tell?

**Jacob:** "'FFI isn't free': please detail more, and can we do a fail fast lab to see that?"

**Challenge:**

- **Where FFI costs:** (1) each call crosses from PHP to C: arguments converted from PHP values to C types, the call
  made through libffi, the result converted back; (2) each read or write of a C struct field through an `FFI\CData`
  is a PHP object operation with type checks, much costlier than an array access; (3) bytes move between C memory and
  PHP strings by copy (`FFI::string`, `FFI::memcpy`). How much each costs on PHP 8.5 nobody here has measured.
- **Designing around it:** work per turn of the loop, not per request. Build every submission of a turn in one PHP
  string with `pack()` and copy it in one `FFI::memcpy`; read every completion of the turn with one `FFI::string` and
  `unpack()`; one `io_uring_enter` per turn. A request is then left with two copies (its bytes in, its response out)
  plus its share of the turn's few calls.
- **What it can win:** the kernel is 30 % of the CPU and the event loop 6.5 % (phase 4's profile); io_uring saves the
  syscalls' entries and exits and epoll's bookkeeping, not the TCP stack's work. And, above all, the fd wall without
  reconnects.
- **The fail-fast lab, cheapest first, each step with its stop rule:**
  1. **Smoke (done, 18:25):** in a lab container with Docker's seccomp filter lifted, PHP's FFI called
     `io_uring_setup` and got a ring back (kernel 6.12.76, `io_uring_disabled` 0). With the default filter: `EPERM`.
  2. **Micro, about an hour on the micro harness:** ns per FFI call (`syscall(getpid)` through FFI against
     `posix_getpid()`), per `CData` field write, per `FFI::memcpy` and `FFI::string` of 200 bytes and 5 KB, per
     `pack()` of a 64-byte submission. Stop if a request's FFI budget (two copies and its share of a turn) costs more
     than the syscalls it saves.
  3. **A no-op server on an FFI ring** (multishot accept, receive, send, direct descriptors): its µs per request at
     7,000 req/s against DIY's 21.88, and more than 65,535 connections held. Stop if it costs more than DIY plus
     S1-d's reconnects.

**Verdict:** ✅ the fail-fast lab, as the io_uring spike's first steps in phase 5. Step 1 is done.

### 2026-11-22 18:25 · ❓ Question: the queues' memory ordering: what's the risk, can it be fully controlled?

**Jacob:** "I want more details. What is the risk, and can we determine if the risk can be 100% controlled?"

**The protocol:** the program writes a submission, then moves the submission queue's tail; the kernel reads the tail,
then the submission. The kernel writes a completion, then moves the completion queue's tail; the program reads the
tail, then the completion, then moves the head to free the slot. Each "then" matters: in C, liburing uses atomic
loads and stores with acquire and release ordering. FFI has no such operations.

**The risk:** a CPU core may see another core's writes out of order (x86 keeps them in order, arm64 doesn't). If the
kernel saw a new tail before the submission's bytes, it would run a half-written order (a wrong socket, buffer or
length); if the program saw a new completion tail before the completion's bytes, it would take a stale result. The
worst case is one user's response sent to another user: a correctness bug and a privacy bug.

**How to control it, by design rather than luck:**

- **No `SQPOLL`:** the kernel then reads submissions only inside our own `io_uring_enter` call, on our thread, so on
  the same core, where program order holds on any CPU.
- **`IORING_SETUP_DEFER_TASKRUN` with `IORING_SETUP_SINGLE_ISSUER`** (kernel 6.1 and up; the bench runs 6.8, the lab
  6.12): the kernel posts completions only when our thread calls `io_uring_enter` with `GETEVENTS`, in our thread's
  context. Both queues are then touched by the kernel only inside our own calls: no other core is involved.
- **The bench has one vCPU:** there is no other core to see things out of order.
- **A stress test checks the implementation:** every request carries a unique id that its response echoes, millions
  of requests on the multi-core lab VM (where a reordering could show), zero mismatches, plus the challenge's 42 tests.

**"100 %":** the design rules the race out (both queues only touched by the kernel inside our own calls, on our
thread); a test can't prove an absence, it catches mistakes in following the design. That's as controlled as a C
program using liburing.

**Verdict:** ✅ the risk is controlled by those settings; they are requirements of the spike, and the stress test
is part of its "done when".

### 2026-11-22 18:25 · 💡 Idea: move the lab to a VM

**Jacob:** "'Docker blocks io_uring by default' I think it is time to use a VM, what do you think?"

**Challenge:**

- **Not needed for io_uring:** Docker Desktop's VM runs kernel 6.12.76 with io_uring on. Docker only blocks it through
  its default seccomp profile, and a lab container can allow the io_uring syscalls (tested at 18:25, see above).
- **Useful for other reasons:** a VM with Ubuntu 24.04 runs the bench's kernel (6.8) and distribution, and is
  isolated from Jacob's other projects: Docker's VM rebooted on its own today and brought 23 containers back, which
  blocked measuring twice (D15).
- **Where:** Jacob's desktop (x86, many cores, 64 GB) in a Hyper-V VM with Ubuntu 24.04 is the closest thing to the
  bench we own: the bench is itself an x86 KVM virtual machine on kernel 6.8. It merges with the desktop idea above.
  The Mac's Docker stays for quick comparisons.

**Verdict:** 🔶 Claude's take: yes, an Ubuntu 24.04 VM on the desktop as the lab's main host for phase 5's
full-size runs and the io_uring spike; not required to start the spike. Open until Jacob confirms the desktop.

### 2026-11-22 18:25 · 💡 Idea: keep the software factory private, publish only the decisions

**Context:** a lab harness recorded the names of Jacob's other Docker containers in two results files of phase 4's
branch, pushed and public for about 6 hours before the blind reviewer caught it. The branch was deleted from GitHub
at 18:25 and is being rewritten without them. Fewer names had also reached a phase 3 plan update on `main` (since
removed from the files, still in the history).

**Jacob:** "I think the SF should not be public to avoid that in the future. Maybe only the decisions, what do you
think?"

**Challenge:**

- **This leak came from `lab/results/`, not from `plan/`:** a harness wrote what it observed. Hiding the factory
  wouldn't have stopped it, and the results have to stay public (they're the point of the repo).
- **The real guard is before every push:** a git-ignored denylist of private words (it can't be committed, it holds
  them), plus patterns (emails, account ids, `/Users/` paths), checked by `lab/check.sh` and a pre-push hook that
  refuses the push. And harnesses record counts, never names.
- **The factory's working files are where agents log what they see:** `run.md`, `state/`, `reviews/`, `runs/`,
  briefs, snapshots. They're also the noisiest to read. Keeping public `plan.md`, `decisions.md`, `notes.md`,
  `details/` and the lab, and making the working files private, loses little transparency and removes most of the
  exposure. Private means git-ignored here and backed up in a private repo, so nothing is lost.

**Verdict:** 🔶 Claude's take: the push guard first (it covers the whole repo), and the factory's working files
private, the decisions, notes, details and results public. A change to D11: Jacob decides.

**Jacob, 18:31:** "Yes, both: guard and a half private factory. What do you think about putting a new git private
repo besides the project for the factory? This way, we could commit everything. We ask the lab to start writing in
this private factory too." **18:35:** "go, name it twelve-dollar-server-factory, and you can commit and push."

**Verdict (20:29):** ✅ done.

- **The private repo:** `Gcob/twelve-dollar-server-factory`, cloned next to this one. It holds `run.md`, `run.yml`,
  `state/`, `reviews/`, `runs/`, `snapshots/` (git-ignored here, reached through symlinks under `plan/`, so paths and
  the decision board don't change), a `lab/` folder for raw environment diagnostics, and the guard's denylist. Raw
  exchanges go in neither repo. Their past versions stay in this repo's history: the rule applies from here on.
- **The guard:** `tools/public-guard.sh` refuses e-mail addresses, home paths and the private denylist's words. It
  runs before every push (`.githooks/pre-push`, chained by the personal hook through `perso.chainHooksPath`) on the
  lines a push adds and its commit messages, and in `lab/check.sh` on every tracked file. Without the denylist the
  push is refused. Its first run found the home paths in `run.md` that the history audit had missed.
- **D11 changes:** the project manager records it at the next phase.

### 2026-11-22 18:31 · 👀 Observation: the history cleanup of `main`

**Context:** after the leak above, `main` also held 3 short nickname phrases in plan files. Jacob: "please clean
master and force push, and make sure the git history has no leak at all. Ask the PM to do it."

**What happened:** the project manager rewrote every branch with `git filter-repo --replace-text` (the names lists
dropped, the phrases replaced by "(names left out)"), and pushed `phase-4-claude` clean. Its own `push --force` on
`main` was refused by its permission check, so Jacob ran it (20:22, `ebd2855` → `32a030f`).

**Verdict:** ✅ verified at 20:23: the 23 container names return nothing on `origin/main`, `origin/phase-4-claude`
and `origin/phase-3-claude`, apart from 2 generic service words in the audit note. GitHub may keep the old commits
reachable by SHA until its support purges them: Jacob's call.
