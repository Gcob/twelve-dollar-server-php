# How phase 3 differs from your agent file (every brief points here)

- **Write in English** everywhere: `plan/state/developer.md`, your answer, code, comments, commits.
- **Two places, never mix them:**
  - **Code:** the worktree `.claude/worktrees/twelve-dollar-server-php/phase-3-claude` under the home folder, branch
    `phase-3-claude`. Your prompt gives its full absolute path. Every git command is `git -C <that absolute path> ...`,
    alone in its Bash call, the path written in full (no `~`, no variable). You commit there.
  - **Your handover:** `plan/state/developer.md` in the **main checkout** (`www-perso/twelve-dollar-server-challenge/`
    under the home folder; your prompt gives the absolute path). Never write the worktree's copy of `plan/`, and
    never commit anything in the main checkout: the project manager commits `plan/`.
- **Commit, don't push:** one commit in the worktree, `git add` each file by name (never `git add .`), no co-authored-by
  line. The project manager pushes after checking your commit. Never merge, rebase, amend, reset, stash or switch
  branches.
- **The repo is public:** no absolute `/Users/...` path, email or account id in any committed file.
- **`reference/` is read-only.** In the worktree it is a relative symlink to the main checkout's clone (ignored
  locally): never `git add` it.
- **The seed is already built** in the worktree's `lab/data/` (ignored by git).
- **The `php-lab:*` Docker images are shared** with the main checkout (one Docker daemon). Never remove or retag them.
- **Other projects' containers on the Docker VM:** never stop or remove them. A smoke run with them running is fine;
  a measurement is not (scope 7 only).
- **No install on the Mac** (no `brew install`, no global npm): tools run in Docker.
- **No plan references in code, tests or docs** (no `D17`, no "scope 3"): write the reason itself.
- **The lab's suite** is `bash lab/check.sh` (from the worktree). Run it fully before you commit and report the count
  (`N/N ok`). It needs the images; it takes a few minutes.
