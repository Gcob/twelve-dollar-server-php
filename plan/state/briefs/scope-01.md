# Brief: scope 1/6, build the seed database outside git

**Repo (no worktree, work on `main`):** the repo root, `www-perso/twelve-dollar-server-challenge/` under the home
folder. **Run folder:** `plan/` in that repo.
**Planned commit:** `chore(seed): build the seed database outside git`

## How this run differs from your agent file

- **Write in English** everywhere: `plan/state/developer.md`, your answer, code, comments, commits.
- **No worktree:** you work in the repo's own checkout, on `main`. Every git command is `git -C <absolute repo path>
  ...`, alone in its Bash call, path written in full (no `~`, no variable).
- **Commit, don't push:** one commit, `git add` each file by name (never `git add .`), no co-authored-by line. The
  push is refused right now (no write access); the project manager handles pushing.
- **Another session may edit `plan/notes.md` and the project manager edits other files in `plan/`:** never stage
  them, never stash, reset or switch branches.
- **The repo is public:** no absolute `/Users/...` path, email or account id in any committed file. Paths in scripts
  are relative to the script or the repo root.
- **`reference/` is read-only** (git-ignored clones). Copy out of it, never write into it.

## The scope

**Summary:** a `lab/seed.sh` that builds the challenge's seed database into `lab/data/`, kept out of git.

**Today:** nothing in the repo builds the seed. The challenge repo is cloned in
`reference/twelve-dollar-server-challenge/`; its `seed/make-seed.sh` writes `feed.db` and `tokens.json` next to
itself (so into `reference/`) and reads `../schema.sql`.

**Expected:** `lab/seed.sh`:

- copies `seed/generate.mjs`, `seed/make-seed.sh` and `schema.sql` from `reference/twelve-dollar-server-challenge/`
  into a temporary build folder under `lab/data/` keeping their relative layout, runs `make-seed.sh` there, moves
  `feed.db` and `tokens.json` to `lab/data/`, removes the build folder (also on failure: trap);
- passes through `make-seed.sh`'s final line (`OK: … content sha256 matches`) and its exit code;
- fails with a clear message when `reference/twelve-dollar-server-challenge/` is missing, saying how to get it
  (`git clone https://github.com/arjaythedev/twelve-dollar-server-challenge reference/twelve-dollar-server-challenge`);
- leaves no `-wal` / `-shm` files next to `feed.db` (the script already checkpoints with `TRUNCATE`; check it).

Also create:

- `.gitignore`: add `/lab/data/` (keep the existing lines and comments, add a comment line saying why);
- `lab/check.sh`: the lab's smoke suite, which later scopes extend. For now, one check: `lab/data/feed.db` and
  `lab/data/tokens.json` exist and `feed.db` opens with `sqlite3` and has rows in `posts`. Output: one line per check,
  `ok` or `FAIL` with the reason, exit non-zero if any fails. Make it easy to add checks (a small function per check);
- `lab/README.md`: what `lab/` is (the measuring lab of phases 2 to 4), and a "Seed" section with the command. Later
  scopes add their sections. Short.

**Key interfaces:** `lab/seed.sh` (no arguments), `lab/check.sh` (no arguments), `lab/data/feed.db`,
`lab/data/tokens.json`.

**Done when (from the plan, word for word):** `lab/seed.sh` prints `OK: … content sha256 matches`, `lab/data/feed.db`
and `lab/data/tokens.json` exist, and `git status --porcelain` lists neither.

**Cases to check:** a second run rebuilds and still prints OK; the script fails loudly when `reference/` is missing
(test it by pointing it at a missing path with an env var override, for example `REFERENCE_DIR`, rather than moving
the real folder); `lab/data/` is ignored by git.

**Tests to imitate:** there's no test suite in this repo yet. The "tests" here are the commands above and
`lab/check.sh`. Bash: `set -euo pipefail`, quote everything, `shellcheck` if it's installed (say if it isn't).

**Tools on the Mac:** node 24, sqlite3 3.54. The build takes about a minute and the database is about 250 MB.

**Decisions that touch you:** D4 (`reference/` is ignored, not ours); D11 (the repo is public).

**Out of scope:** Docker images (scope 2), any use of the seed by a server (phase 3).

**Where to look:** `reference/twelve-dollar-server-challenge/seed/make-seed.sh` (reads `$HERE/../schema.sql`, writes
`$HERE/feed.db`).

**Read first:** `plan/state/developer.md` if it exists (it doesn't yet: you create it, with the skeleton of
`~/.claude/skills/autonomous-run/state.md`, in English).

**Come back to me if:** a decision is missing from this brief, or the "Done when" doesn't pass after 3 tries.
