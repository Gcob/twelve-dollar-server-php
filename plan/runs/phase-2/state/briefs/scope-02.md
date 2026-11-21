# Brief: scope 2/6, the PHP 8.3 lab image with Swoole 6.2.6

**Repo (no worktree, work on `main`):** the repo root, `www-perso/twelve-dollar-server-challenge/` under the home
folder. **Run folder:** `plan/` in that repo.
**Planned commit:** `feat(lab): PHP 8.3 lab image with Swoole 6.2.6`

## How this run differs from your agent file

- **Write in English** everywhere: `plan/state/developer.md`, your answer, code, comments, commits.
- **No worktree:** you work in the repo's own checkout, on `main`. Every git command is `git -C <absolute repo path>
  ...`, alone in its Bash call, path written in full (no `~`, no variable).
- **Commit, don't push:** one commit, `git add` each file by name (never `git add .`), no co-authored-by line. The
  push is refused right now (no write access); the project manager handles pushing.
- **Another session may edit `plan/notes.md` and the project manager edits other files in `plan/`:** never stage
  them, never stash, reset or switch branches.
- **The repo is public:** no absolute `/Users/...` path, email or account id in any committed file.
- **`reference/` is read-only** (git-ignored clones). Copy out of it, never write into it.

## The scope

**Summary:** a Docker image `php-lab:8.3-apt` (Ubuntu 24.04, apt PHP 8.3, Swoole 6.2.6 from source) and the two
scripts every later scope uses to build and run lab images.

**Today:** scope 1 made `lab/seed.sh`, `lab/check.sh`, `lab/README.md`, `lab/data/` (ignored). Read its handover in
`plan/state/developer.md`.

**Expected:**

- **Install script** (for example `lab/images/install-php83-apt.sh`), run by the Dockerfile, written so phase 5 can
  reuse it as a submission's `install.sh` on a bare Ubuntu 24.04: apt `php8.3-cli php8.3-dev php8.3-sqlite3
  php8.3-mbstring php8.3-opcache` plus the build tools, then Swoole **6.2.6** from
  `https://github.com/swoole/swoole-src/archive/refs/tags/v6.2.6.tar.gz`, sha256 pinned in the script (compute it
  once; say in your handover how you got it), `phpize`, `./configure --disable-brotli --disable-zstd`, `make
  -j"$(nproc)"`, `make install`. Model: `reference/twelve-dollar-server-challenge/submissions/php-swoole-mattsplat/install.sh`.
  Swoole is **not** enabled globally: the server loads it with `-d extension=swoole`, like the entries.
- **Dockerfile:** `ubuntu:24.04` pinned by tag **and** digest. Runs the install script. Adds a `php-info` command
  (a small script on the `PATH`).
- **`php-info`** prints one line each: PHP version, Swoole version (loaded with `-d extension=swoole`), SQLite
  version (through PDO), OPcache loaded, JIT available, and the presence of `pdo_sqlite`, `mbstring`, `sodium`,
  `ffi`, `ctype`, `iconv`. A missing extension is printed as missing, not fatal: later steps decide if they need it.
- **`lab/lib.sh`:** the one place for shared settings: the CPU layout of the Docker VM (server and micro benches on
  CPU 2, k6 on CPUs 4 to 11, CPUs 0 and 1 left to the VM), the resource flags, the image name (`php-lab`), the
  known variants. Every lab script sources it.
- **`lab/build.sh <variant>`:** builds `php-lab:<variant>`. Variants known now: `8.3-apt`. Unknown variant: exit
  non-zero with the list. Records the build time in `lab/results/build-times.md` (a table: date, variant, seconds,
  Docker Desktop version), appending a row.
- **`lab/run.sh <variant> <command…>`:** `docker run --rm` with `--cpus=1 --memory=2g --memory-swap=2g --ulimit
  nofile=65535:65535 --network host --cpuset-cpus <server CPU>`, the repo's `lab/` mounted (read-only is fine except
  `lab/results/` and `lab/data/`, your call), then the command.
- **`lab/check.sh`:** add a check that `php-lab:8.3-apt` exists and `php-info` reports PHP 8.3 and Swoole 6.2.6, and
  a limits check through `lab/run.sh`: `cat /sys/fs/cgroup/cpu.max` is `100000 100000`, `memory.max` is
  `2147483648`, `memory.swap.max` is `0`, `ulimit -n` is `65535`.
- **`lab/README.md`:** a short "Images" section.

**Key interfaces:** `lab/lib.sh`, `lab/build.sh <variant>`, `lab/run.sh <variant> <cmd…>`, image `php-lab:<variant>`,
`php-info` in the image. Scope 3 adds source-built variants (`8.3`, `8.4`, `8.5`, `8.6`) to the same scripts, scope 4
runs the micro harness through `lab/run.sh`, scope 5 runs the server and k6.

**Done when (from the plan, word for word):** `lab/build.sh 8.3-apt` builds `php-lab:8.3-apt`; `lab/run.sh 8.3-apt
php-info` prints PHP 8.3, Swoole 6.2.6, SQLite and OPcache; the limits check prints 1 CPU, 2 GiB, no swap, 65535 fds.

**Cases to check:** a wrong sha256 fails the build (try it once with a corrupted value, then restore); an unknown
variant fails `lab/build.sh` with the list of known ones; `lab/check.sh` passes.

**Environment:** Docker Desktop 29 on an Apple M3 Pro, so the image is **linux/arm64**; 12 vCPUs and cgroup v2 in
Docker's VM. The bench VM of the challenge is x86_64: don't force `--platform`, arm64 is expected here (relative
results are what the lab is for).

**Tests to imitate:** no test suite in the repo; the checks are `lab/check.sh` and the commands above. Bash with
`set -euo pipefail`, `shellcheck` if installed.

**Decisions that touch you:** D1 (no Nginx, no FPM: CLI only); D7 (Docker on the Mac, host network, pinned CPUs);
D8 (PHP version is a variant: scope 3 adds 8.3 to 8.6 from source, so keep the scripts open to more variants); D11
(public repo).

**Out of scope:** PHP from source (scope 3), the micro harness (scope 4), k6 and any server (scope 5).

**Where to look:** `reference/twelve-dollar-server-challenge/submissions/php-swoole-mattsplat/install.sh` (the
build to copy) and `start.sh` (the PHP flags the entries run with).

**Read first:** `plan/state/developer.md`.

**Come back to me if:** a decision is missing from this brief, or the "Done when" doesn't pass after 3 tries.
