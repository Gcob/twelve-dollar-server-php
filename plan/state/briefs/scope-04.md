# Brief: scope 4/6, the micro benchmark harness, JIT on and off

**Repo (no worktree, work on `main`):** the repo root, `www-perso/twelve-dollar-server-challenge/` under the home
folder. **Run folder:** `plan/` in that repo.
**Planned commit:** `feat(lab): micro benchmark harness, JIT on and off`

## How this run differs from your agent file

- **Write in English** everywhere: `plan/state/developer.md`, your answer, code, comments, commits.
- **No worktree:** you work in the repo's own checkout, on `main`. Every git command is `git -C <absolute repo path>
  ...`, alone in its Bash call, path written in full (no `~`, no variable).
- **Commit, don't push:** one commit, `git add` each file by name (never `git add .`), no co-authored-by line. The
  project manager pushes after checking your commit.
- **Another session may edit `plan/notes.md` and the project manager edits other files in `plan/`:** never stage
  them, never stash, reset or switch branches.
- **The repo is public:** no absolute `/Users/...` path, email or account id in any committed file.

## The scope

**Summary:** a PHP harness that times one step's variants in isolation, run inside every lab image, JIT on and off.

**Today:** scopes 1 to 3 made the seed, `lab/lib.sh`, `lab/build.sh`, `lab/run.sh`, `lab/check.sh` and the images
(`8.3-apt`, `8.3`, `8.4`, `8.5`, `8.6`). Read the handovers in `plan/state/developer.md`: which images have Swoole
doesn't matter here (the harness doesn't use it).

**Expected:**

- **A bench file** is a PHP file that declares named cases. Each case has:
  - a `check`: run once before timing, verifies the case gives the right result (the plan's rule: a fast wrong
    variant is discarded). A failure stops that case with its message, and the run goes on with the other cases;
  - a `run`: the code timed. It must not be optimized away (use its result somehow; your call how).
  - optionally a `setup` (data built once, outside the timing).
  The format is yours to design: a returned array of closures, or a small class. Keep it the simplest thing that
  later steps (routing, JWT, SQLite queries, JSON) can use without ceremony. A SQLite case will need a setup that
  opens a copy of `lab/data/feed.db`: make sure the bench can reach `lab/data/` inside the container.
- **Timing:** warm-up first (at least 1 s, or a fraction of the iterations, your call, said in the README), then
  `hrtime(true)` around N iterations, repeated 10 times. Report the **median ns/op** and the **spread** (min and max
  of the 10 repeats, or the interquartile range; say which). N is calibrated so one repeat lasts long enough to be
  measurable (around 100 ms is a good target).
- **The loop's own cost:** an empty case is measured and shown in the output, **not** silently subtracted.
- **OPcache on for the CLI** (`opcache.enable_cli=1`). **JIT on:** `opcache.jit=tracing` with a buffer (for
  example 64M). **JIT off:** `opcache.jit=disable` where the version accepts it, or what 8.3 needs (check: on 8.3,
  `opcache.jit=disable` may not exist; `opcache.jit_buffer_size=0` turns the JIT off). The harness reads
  `opcache_get_status()['jit']` (or the equivalent) and **exits non-zero** if the JIT state isn't the one requested.
  Check that OPcache really caches the bench file in the CLI (file cache vs shared memory: say what you found).
- **`lab/micro.sh <bench-file> [--images a,b,…] [--jit on|off|both] [--out <path>]`:** runs the bench through
  `lab/run.sh` (so pinned to the server CPU, 1 CPU, 2 GiB), **one image at a time**, never two benches at once.
  Defaults: every image, JIT both. Unknown image: exit non-zero.
- **Output:** a table on stdout (image, PHP version, JIT, case, median ns/op, spread, iterations) and a JSON file with
  the same numbers plus the date, the image digest, the PHP ini values that matter, and the exact command. Default
  path under `lab/results/` (your naming, dated); `--out` overrides.
- **`lab/micro/benches/sample.php`:** two cheap cases with a real check each, for example `json_encode` of a small
  fixed array (check: the exact string) and `ctype_digit` on `"12345"` (check: `true`) and on `"12a"` (check:
  `false`). It proves the harness, it's not a step result.
- **`lab/check.sh`:** a quick micro run (1 image, short timing, a "quick" mode is welcome) that passes.
- **`lab/README.md`:** a "Micro benchmarks" section: the bench file format with a tiny example, the command, how to
  read the output.

**Done when (from the plan, word for word):** `lab/micro.sh lab/micro/benches/sample.php` prints, for every image
and JIT on and off, the median ns/op and its spread, and fails if the JIT state isn't the one requested.

**Cases to check:** a case whose `check` fails is reported and skipped, the others run; asking JIT on with a config
that leaves it off exits non-zero (force it once, for example with a zero buffer); an unknown image exits non-zero;
the full `lab/micro.sh lab/micro/benches/sample.php` run on all 5 images, both JIT states, passes. Keep its JSON
output and commit it in `lab/results/` as the harness's first run.

**Decisions that touch you:**

- D5: every prior-art number is a prediction we re-measure; the harness's output must say where it ran (image,
  version, date, command) so a result can be compared later.
- D8: the PHP version is a measured variant.
- Measuring method (from the plan): warm-up, `hrtime(true)`, 10 repeats, median and spread in ns per call, same
  container and PHP build as the server, OPcache on for the CLI, JIT on and off; each variant checked for correctness
  first.

**Out of scope:** any real step's bench (phase 4), the macro harness (scope 5).

**Where to look:** `lab/lib.sh` (CPU layout), `lab/run.sh`. Scope 1 found that any `sqlite3` open of the WAL-mode
`lab/data/feed.db` leaves `-wal`/`-shm` files next to it: a SQLite bench works on a per-run copy, never on
`feed.db` itself (`lab/check.sh` uses `file:…?immutable=1` for its read-only check).

**Read first:** `plan/state/developer.md`.

**Come back to me if:** a decision is missing from this brief, or the "Done when" doesn't pass after 3 tries.

## Relaunches

- **2026-11-21 10:25:** "Done when" passes, but the spread lies: 4 runs of `--images 8.4 --jit on` gave
  `ctype_digit "12345"` medians 27.8, 13.5, 28.0, 27.3 ns, while each run's min..max stays within about 10 %. Asked
  for K processes per case (default 5, interleaved), the median of process medians, the spread across processes, an
  "unstable" flag above 1.3x, a README paragraph on the finding, one quick experiment (ASLR off) at most, and a new
  sample run. New commit `fix(lab): micro harness repeats each case across processes`.
