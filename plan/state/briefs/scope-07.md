# Brief: scope 7/7, the runtime bake-off

**Worktree:** `phase-3-claude` (absolute path in your prompt) · **Run folder:** `plan/` of the main checkout
**Planned commit:** `docs(lab): the runtime bake-off`

**Read first:** [common.md](common.md), then `plan/state/developer.md` (scopes 1 to 6), then
`lab/results/2026-11-21-noop-swoole/README.md` and its `summarize.sh` (the model for this scope's results folder).

**Summary:** measure the three runtimes with the same handler and write one table: µs CPU/req at 7,000 req/s on both
routes, the two finalists at 9,500, max connections and memory per connection, then judge each prediction.

**Today:** three bake-off servers on the shared handler, all passing conformance: `lab/servers/bake-swoole.php`
(`--ext swoole`, the default), `lab/servers/bake-workerman.php` (`--ext pcntl --ext sockets --ext event`, `--env
WORKERMAN_TREE=nocache|stock`), `lab/servers/bake-diy.php` (`--ext sockets --ext event`). `lab/macro.sh` (fixed rate,
`--path /noop` or `--script lab/macro/k6/posts.js`), `lab/conns.sh` (idle connections). Both record
`other_containers`.

**Expected:**

- **The quiet VM, first and before every series:** `docker ps`. If any container that isn't the lab's own is running,
  **don't measure**: stop and report to me with the list. Never stop or remove other projects' containers. A run whose
  JSON has `other_containers` above 0 is not counted: rerun it on a quiet VM, or report.
- **No image build, no other benchmark, no `lab/check.sh`** during the series (they share the VM's CPUs).
- **Before any run:** create `lab/results/<date>-bake-off/README.md` with the Predictions section copied **unchanged**
  from the text at the end of this brief (it's the plan's, written before any measurement), and the plan of the runs.
  Then measure.
- **Image:** `8.5` for everything except the 8.6 information runs.
- **Series A, µs/req at 7,000 req/s:** 4 servers (Swoole; Workerman nocache; Workerman stock; DIY) × 2 routes (`/noop`;
  `posts.js`), 30 s measured after 10 s warm-up (`macro.sh` defaults otherwise: VUs = rate / 10), **3 repeats
  interleaved**: round 1 runs all 8 (server, route) pairs, then round 2, then round 3, in the same order each round. 24
  runs, about 20 minutes. `--label` names the server and tree; `--out` into the results folder
  (`run-<round>-<server>-<route>-7000.json`, and the printed output next to it as `.txt`).
- **The finalists:** the two of Swoole, Workerman nocache and DIY with the lowest **median posts µs/req** at 7,000
  (Workerman stock isn't a candidate). Say which and the numbers.
- **Series B, the finalists at 9,500 req/s:** both routes, 3 interleaved repeats: 12 runs.
- **Series C, connections:** `lab/conns.sh` once per server (Swoole, Workerman nocache, DIY), default steps up to 66k,
  `--out` into the folder. Let `TIME_WAIT` clear between them (the client skips busy addresses; check it did).
- **Series D, 8.6 information:** Workerman nocache and DIY once each on both routes at 7,000 on image `8.6`, marked
  "information, one run".
- **An invalid run** (dropped iterations or errors): keep its files, rerun it once at the end of its round, and report
  both. Two invalid runs of the same pair: stop the series and report to me.
- **`summarize.sh`** in the folder builds the tables from the JSON (like phase 2's): per runtime and route at 7,000
  the median µs/req and min..max, p99 (median of 3), peak `Pss_Anon` and `memory.current` under load (the full Pss
  counts SQLite's mapped database pages, so it isn't a runtime comparison: show it, don't rank on it; `memory.current`
  also holds the 250 MB database copy in page cache, so it only compares as a difference between runtimes); the finalists at 9,500; per runtime the max
  connections, why it stopped, the Pss slope, the `Pss_Anon` slope and the `memory.current` slope (least squares over every held step, as
  `conns.sh` prints), the average per connection at the max ((Pss at the max − baseline) / held), the baseline; the
  backlog and `TCP_NODELAY` line; the response bytes of `/noop` per runtime (from conformance, run once per server
  after the series, `--out` not needed: paste the bytes); every run in the order it ran, with its time and validity.
- **README after the runs:** what was measured, the tables (generated), "Did the predictions hold?" one line per
  prediction judged by its own rule (held / didn't hold, with the numbers), runtimes.md's flip rule (is Workerman
  nocache within 30 % of Swoole on `/noop`?), the environment (Docker Desktop, kernel, image ids), the exact commands,
  and what surprised you. Arm64 numbers on an M3 Pro: say that absolute numbers only count on x86.
- **Commit:** the README, `summarize.sh`, every JSON and `.txt`. No change to the lab's scripts in this commit; if a
  script has a bug that blocks the series, stop and report.

**Done when:** `lab/results/<date>-bake-off/README.md` holds the predictions (unchanged), then the generated tables
(µs/req median and spread of 3 interleaved repeats per runtime and route at 7,000, the finalists at 9,500, max
connections and memory per connection per runtime), each prediction marked held or not by its rule; every counted run
is VALID with `other_containers: 0`; the raw JSON is next to it; `bash lab/results/<date>-bake-off/summarize.sh`
regenerates the tables.

**Seams and cases:** `summarize.sh` regenerates exactly the tables in the README (diff them); a run with
`other_containers` above 0 or `valid: false` is shown and not counted.

**Decisions that touch you:**

- PHP 8.5 for the bake-off; 8.6 runs are information only.
- Compare at 7,000 req/s; the finalists also at 9,500.
- Workerman runs with its caches out; the stock run only shows what they buy.
- Each runtime keeps its own headers; backlog 4,096 and `TCP_NODELAY` everywhere.
- Max connections counted by the client; memory as summed Pss and `memory.current`.
- Measure only on a quiet VM; numbers from a busy VM don't compare.

**Out of scope:** changing any server or harness; µs/req with many connections held; x86.

**Come back to me if:** the VM isn't quiet, a pair is invalid twice, a script blocks the series, or a number looks
impossible (for example µs/req below 5 or a runtime holding more than 65,535 connections).

## Predictions (copy this section unchanged into the README)

### Predictions (D5)

Written by the project manager on 2026-11-21 at 16:29, before any phase 3 measurement (commit `4e3a8a5`), and
revised at 16:44 after the plan review, still before any measurement: 7 and 8 now follow the prior art's 18 to
42 KiB per connection, and each prediction says how it's judged. Arm64, Docker Desktop on an M3 Pro, quiet VM, PHP
8.5, 1 CPU.

**What we start from:** the no-op Swoole server cost 50.2, 30.2 and 21.7 µs/req at 1k, 3k and 6k req/s on 8.3-apt,
on a **busy** VM. On the quiet VM the micro sample landed every swinging row on its slow level (D15), so quiet-VM
numbers may come out higher than busy-VM ones. tzimpel saw 2 Swoole workers cost 27 % more per request, 184 MB RSS at
10k connections with stock Swoole (about 18 KiB each) and the worker die at about 38k; mattsplat saw 840 MB at 20k
(about 42 KiB each); HolyPHP measured fewer header bytes as part of a 9 % round.

**How they're judged:** a µs/req number is the median of the 3 interleaved repeats; a percentage is relative to the
number named in the prediction; a range holds if the measured value is inside it.

1. **Swoole `/noop` at 7,000 req/s: 18 to 35 µs/req.** The busy-VM trend gives about 20 at 7k; the quiet VM may add up
   to 1.5x.
2. **`/posts/:id` costs 5 to 15 µs/req more than `/noop` on every runtime**, and the gap (posts minus noop) differs by
   at most 3 µs between the three: the handler is the same code, so the runtimes should differ by the same amount on
   both routes.
3. **Workerman with its caches out costs 30 to 70 % more than Swoole on `/noop`.** Its HTTP parsing, `Request` and
   `Response` objects and its connection object run in PHP. So runtimes.md's flip rule (within 30 % of Swoole) **fails**.
4. **Workerman with its caches on is 10 to 25 % cheaper than with them out on `/noop`** (every request has the same
   bytes, so `baseRead()`'s cache returns the decoded request every time) **and under 5 % cheaper on posts.js** (each
   id comes back rarely, so the cache rarely hits). Only 2 of the 5 caches can move these numbers: the handler never
   calls `header()`, `get()` or `post()`.
5. **DIY lands within 15 % of Swoole on `/noop`, either side.** It runs more PHP than Swoole per request but builds no
   objects and sends 2 headers instead of 5. So the finalists are **Swoole and DIY**.
6. **At 9,500 req/s, µs/req is 5 to 15 % lower than at 7,000** for both finalists: the trend of phase 2 (fixed costs
   spread over more requests per wake-up).
7. **Max connections:** Swoole stops on **memory (OOM kill), between 35,000 and 60,000**: about 30 KiB of process
   memory per connection plus the kernel's socket buffers reach 2 GiB before 65,535 fds. Workerman and DIY stop on the
   **fd limit, between 65,000 and 65,535**.
8. **Memory per connection (Pss slope):** Swoole **15 to 45 KiB** (prior art's 18 to 42), Workerman **3 to 10 KiB**,
   DIY **1 to 4 KiB**. The `memory.current` slope is higher than the Pss slope on all three, by the kernel's socket
   memory.
9. **p99 at 7,000:** under 3 ms on all three on both routes, with Workerman the highest.
