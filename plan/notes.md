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
