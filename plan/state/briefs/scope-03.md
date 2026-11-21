# Brief: scope 3/6, PHP 8.3 to 8.6 from source with Swoole

**Repo (no worktree, work on `main`):** the repo root, `www-perso/twelve-dollar-server-challenge/` under the home
folder. **Run folder:** `plan/` in that repo.
**Planned commit:** `feat(lab): PHP 8.3 to 8.6 from source with Swoole`

## How this run differs from your agent file

- **Write in English** everywhere: `plan/state/developer.md`, your answer, code, comments, commits.
- **No worktree:** you work in the repo's own checkout, on `main`. Every git command is `git -C <absolute repo path>
  ...`, alone in its Bash call, path written in full (no `~`, no variable).
- **Commit, don't push:** one commit, `git add` each file by name (never `git add .`), no co-authored-by line. The
  project manager pushes after checking your commit.
- **Another session may edit `plan/notes.md` and the project manager edits other files in `plan/`:** never stage
  them, never stash, reset or switch branches.
- **The repo is public:** no absolute `/Users/...` path, email or account id in any committed file.
- **`reference/` is read-only.**

## The scope

**Summary:** four more lab images, `php-lab:8.3`, `8.4`, `8.5` and `8.6`, each PHP compiled from the php.net tarball
with the same configure flags, each with Swoole 6.2.6 when it builds.

**Today:** scope 2 made `lab/lib.sh`, `lab/build.sh`, `lab/run.sh`, the `8.3-apt` image, `php-info` and the limits
check. Read the handovers in `plan/state/developer.md`.

**Expected:**

- **One Dockerfile for the source builds**, with build args `PHP_VERSION`, `PHP_SHA256` and `WITH_SWOOLE` (1 or 0).
  `ubuntu:24.04` with the same pinned digest as scope 2.
- **Tarballs from php.net**, the latest patch release of each branch (8.3, 8.4, 8.5, 8.6) as of today, 2026-11-21.
  The sha256 comes from php.net's own published checksums (the releases page or
  `https://www.php.net/releases/?json&version=8.4`, for example), pinned in the repo, and checked during the build.
  Say in your handover where each checksum came from.
- **Same configure flags for every version:** CLI only (no FPM, no CGI), `pdo_sqlite` against the system
  `libsqlite3` (record its version: it should match what `8.3-apt` reports, or say why not), `mbstring`, `sodium`,
  `ffi`, `ctype`, `iconv`, OPcache with its JIT (`--enable-opcache` where it's still a flag; it's always built from
  8.5), `CFLAGS=-O2` like the distro builds. A one-line why per flag, in the Dockerfile or the build script. The build
  prints the flags it used, and `lab/check.sh` checks every source image was built with the same ones.
- **Swoole 6.2.6**, same tarball and sha256 as scope 2, same `./configure --disable-brotli --disable-zstd`, loaded
  with `-d extension=swoole` like the apt image.
- **PHP 8.6.0 was released on 2026-11-19 and no Swoole release mentions it yet.** If Swoole 6.2.6 doesn't build on
  8.6:
  - save the relevant part of the build error and the versions in `lab/results/swoole-on-php-8.6.md`;
  - build the 8.6 image with `WITH_SWOOLE=0` so the micro harness (scope 4) still runs on 8.6, and make `php-info`
    print `Swoole: not built` there;
  - try **Swoole 6.3.0-rc2** once on 8.6 (its sha256 pinned the same way), **for information only**: write the
    outcome in the same file. Don't adopt it in the images: a release candidate would mix Swoole versions across
    PHP versions.
  - Don't patch Swoole to make it build. If the fix looks trivial, describe it in the results file instead.
- **`lab/build.sh`** knows the new variants (`8.3`, `8.4`, `8.5`, `8.6`) and keeps recording build times in
  `lab/results/build-times.md`. A `lab/build.sh all` is welcome. Builds can run in parallel (they're not measured),
  but record each one's time honestly (say if they ran in parallel).
- **`lab/check.sh`:** each source image reports its PHP version and Swoole 6.2.6 (or the documented absence on 8.6),
  and the flags check above.
- **`lab/README.md`:** the variants table (variant, PHP, Swoole, how it's built).

**Done when (from the plan, word for word):** `lab/build.sh <v>` builds `php-lab:<v>` for 8.3, 8.4, 8.5 and 8.6 from
sha256-pinned php.net tarballs; `lab/run.sh <v> php-info` prints each version with Swoole 6.2.6, or the build failure
is documented and the image builds without Swoole.

**Cases to check:** a wrong PHP sha256 fails the build; `php-info` passes on the 4 source images; `lab/check.sh`
passes in full (scope 1 and 2 checks included).

**Environment:** Docker Desktop on an Apple M3 Pro (linux/arm64), 12 vCPUs in Docker's VM. A PHP build takes a few
minutes with `make -j`.

**Decisions that touch you:**

- D8: the PHP version is a measured variant: 8.3, 8.4, 8.5 and 8.6.
- D13: 8.3 is also built from source with the same flags as 8.4 to 8.6, as a control against Ubuntu's build flags.
- D11: public repo.

**Out of scope:** the micro harness (scope 4), any server or k6 (scope 5), choosing a version (phase 4).

**Where to look:** scope 2's files (`lab/lib.sh`, `lab/build.sh`, the 8.3-apt Dockerfile and install script).

**Read first:** `plan/state/developer.md`.

**Come back to me if:** a decision is missing from this brief, or the "Done when" doesn't pass after 3 tries.
