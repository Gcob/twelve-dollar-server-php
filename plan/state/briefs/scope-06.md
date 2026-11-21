# Brief: scope 6/6, the first number: the no-op Swoole server

**Repo (no worktree, work on `main`):** the repo root, `www-perso/twelve-dollar-server-challenge/` under the home
folder. **Run folder:** `plan/` in that repo.
**Planned commit:** `docs(lab): first number, the no-op Swoole server`

## How this run differs from your agent file

- **Write in English** everywhere: `plan/state/developer.md`, your answer, the results, commits.
- **No worktree:** you work in the repo's own checkout, on `main`. Every git command is `git -C <absolute repo path>
  ...`, alone in its Bash call, path written in full (no `~`, no variable).
- **Commit, don't push:** one commit, `git add` each file by name (never `git add .`), no co-authored-by line. The
  project manager pushes after checking your commit.
- **Another session may edit `plan/notes.md` and the project manager edits other files in `plan/`:** never stage
  them, never stash, reset or switch branches.
- **The repo is public:** no absolute `/Users/...` path, email or account id in any committed file (check the raw
  JSON outputs too: if the harness writes an absolute path, strip it or make it relative before committing).

## The scope

**Summary:** measure the no-op Swoole server with the macro harness, with repeats, and record it next to the
prediction written before the run.

**Today:** scope 5 made `lab/macro.sh` and `lab/servers/noop-swoole.php`. Read the handovers in
`plan/state/developer.md`, scope 5's above all (how `cpu.stat` is read, what "invalid" means).

**Expected:**

1. **The prediction first.** Create `lab/results/2026-11-21-noop-swoole/README.md` and write the "Prediction"
   section **before any measured run**, from the text below (keep its numbers and reasoning; you may tighten the
   wording). Commit order doesn't matter, but the file's own text must say it was written before the runs.

   > **mattsplat:** about 18 µs/req, closed loop, 64 connections, no think time, 1 Apple Silicon core, with the
   > whole API (mostly SQLite reads). A no-op does no SQLite and no JSON of rows, so it should cost less than
   > 18 µs/req. **tzimpel:** 50 to 60 µs/req at a fixed rate on the real mix on Apple Silicon. A fixed rate costs
   > more per request than a closed loop (fewer requests per `epoll_wait`, more wake-ups), so the no-op at a fixed
   > rate could land above mattsplat's closed-loop number. **Our prediction:** 8 to 20 µs/req at 3,000 req/s, and
   > higher per request at 1,000 req/s than at 6,000 (fixed costs per wake-up spread over fewer requests). Peak
   > RSS under 50 MB with a few hundred connections.

2. **The runs:** image `8.3-apt`, the no-op server, rates **1,000, 3,000 and 6,000 req/s**, **30 s** measured after a
   **10 s** warm-up, **3 repeats interleaved** (1k, 3k, 6k, 1k, 3k, 6k, 1k, 3k, 6k), because the host drifts.
   Nothing else heavy running on the Mac during the runs (no image builds); say if something was.
3. **If a run is invalid** (errors or dropped iterations): find out why (k6 VUs, k6 CPU, the server), fix the
   harness parameters, not the server, and rerun the whole interleaved series. A harness bug found here: fix it in
   the harness, in this same commit, and say so in your handover.
4. **The record**, in the same README:
   - a table per rate: median µs CPU/req and its spread (min, max) over the 3 repeats, achieved req/s, p95, p99,
     peak RSS (`memory.peak` and `VmHWM`), VUs, k6 CPU;
   - the environment: Mac model (Apple M3 Pro), Docker Desktop version, VM kernel, image digest, PHP, Swoole and k6
     versions, the CPU layout, the exact commands;
   - **"Did the prediction hold?"**: one short paragraph per claim of the prediction (the range at 3k, the trend
     across rates, the RSS), held or not, with the numbers;
   - anything surprising, as facts with numbers. No guesses presented as findings: a hypothesis is labelled as one.
   - the raw JSON outputs of the 9 runs, next to the README.

**Done when (from the plan, word for word):** `lab/results/<date>-noop-swoole/README.md` holds the prediction
(written before the run), then the median µs/req and spread per rate, 3 interleaved repeats each, raw outputs next to
it.

**Cases to check:** all 9 runs valid; `lab/check.sh` still passes.

**Decisions that touch you:**

- D5: we re-measure everything; a prior-art number is a prediction to check, written before the run, then our number
  and whether it held. A prediction that fails is the interesting result.
- D7: relative results count on the Mac; absolute numbers only count on x86. Say so in the README: this number is
  arm64 in Docker Desktop, not the bench VM.
- Measuring method: fixed rate, CPU µs per request from the server cgroup's `cpu.stat`, p95/p99, peak RSS.

**Out of scope:** other PHP versions or runtimes (phase 3), changing the server, the connection ceiling.

**Where to look:** `lab/macro.sh`, `lab/README.md` ("Macro benchmarks"), scope 5's handover.

**Read first:** `plan/state/developer.md`.

**Come back to me if:** a decision is missing from this brief, the numbers make no sense after a rerun (for example
µs/req changes by more than 2x between repeats of the same rate), or the "Done when" doesn't pass after 3 tries.
