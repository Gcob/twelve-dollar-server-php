# Phase 5b: step lab, second run (the series driver, S1-b, JSON, the parser, the loop, the FFI SQLite driver)

**Done when:** the lab has a series driver and a host line in each run's JSON (D68); `steplab.sh` alternates the
order of a round and reads one floor rule (Q19, coded as A until answered); S1 has its x86 answer (a second reconnect
pair on the Xeon, S1-b's own cost, the S1 variant for the bench's sizes, D67, D69); S7, S2, the event loop, S6's
driver and the PHP version each have a chosen variant with its µs of CPU per request (median of its runs) against the
reference's (D49), or the micro bench that says why none was run; the chosen variants together have a new µs/req,
profile and held rate on the Mac, and on x86 if the AWS session runs. The predictions below were written before any
measurement (D5). Then the run stops (D12).

**Plan review:** [PLAN-2026-11-23-2335.md](../reviews/PLAN-2026-11-23-2335.md), NOT_OK (1 🔴, 5 🟠, 9 🟡). Its six
questions were settled by the project manager with the reviewer's own picks (D71 to D73), and its minor points are
folded in below. Delta: [PLAN-2026-11-23-2341-delta.md](../reviews/PLAN-2026-11-23-2341-delta.md), NOT_OK (1 🟠: 7a
would measure a worktree being edited), settled with the reviewer's pick (D74). Delta 2: [PLAN-2026-11-23-2342-delta.md](../reviews/PLAN-2026-11-23-2342-delta.md), OK (1 🟡: the commit goes into `stages.json`, folded into scope 1). Final full review: [PLAN-2026-11-23-2343-final.md](../reviews/PLAN-2026-11-23-2343-final.md), OK (2 🟡 for scope 1: the developer told, and the dirty flag reads tracked files only). Prediction 9 was revised at 23:37, still before any measurement. The reviewer ran SQLite's JSON
against the golden files: the feed and the three posts byte for byte; only U+2028 differs (SQLite raw), which the
spec allows.

**Where (D14):** code on branch `phase-5b-claude`, in its worktree. `plan/` stays on `main`. The factory's working
files (`run.md`, `state/`, `reviews/`) are private (D48).

**Why this shape:** 5a left the Mac's request at about 27 µs (25 with `mmap-off`, D66), the bench's at about 84
(x86 calibration), and S1-d's reconnect at 23.7 µs on the Xeon: +13.6 µs per request at 150,000 users, 25 % (D67).
Jacob's forecast (notes 19:25) puts 100,000 users at "about 15 % less CPU, or no reconnect cost". So 5b has two
targets: **the reconnect** (S1-b, priced on x86) and **the PHP work around SQLite** (the feed is half the requests;
its query is 38 % of the samples, its JSON and PDO's fetch most of the rest of S6 and S7). The steps under 2 % of the
profile (S4 1.7 %, S3 0.4 %, S5 0.1 %) are skipped (D60). The io_uring ring is not built in 5b: it comes back as a
question for Jacob only if S1-b costs too much (the planning session's brief).

## Decisions of this phase

In [decisions.md](../decisions.md):

- **D49, how a variant is judged:** µs of CPU per request (median of its runs) and its profile; the held rate only at
  the end, on the chosen variants together.
- **D60, fail fast:** each variant is screened with one pair and stops there unless it beats the floor; a micro bench
  that shows less than the floor stops a variant before its macro pair; a failed gate ends a spike.
- **D66:** `mmap-off` is S6's choice, so 5b's reference is `APP_PRAGMAS=mmap-off`, not the bare skeleton (D70).
- **D67, D69, S1:** a second reconnect pair on x86, then S1-b if S1-d adds more than 15 % at 150,000 users with the
  Xeon's price. S1-b is built before the AWS session (D69), so one session prices both.
- **D68, the series driver and the host line:** the first scope, before any measurement.
- **Q19 (open, coded as A):** `steplab.sh` alternates which side runs first; one floor rule for every pair, A/A
  included. Until Jacob answers, the code carries a `FIXME(pending)` (scope 2).

## Scopes

| #   | Commit                                                                  | Done when |
|-----|-------------------------------------------------------------------------|-----------|
| 1   | `feat(lab): a series driver and the host's state in each run`           | `bash lab/stages.sh --dry-run <fixture>` prints each series' command, its dated start and end and the gap; on a VM with a container that isn't the lab's it refuses to start a measured series (a check starts its own unlabelled container to prove it, then removes it); a short live series of 2 runs writes `stages.json`; each run's JSON has a `host` object (load 1 and 5, the VM's CPU busy %, steal %, the disk's fsync ms, `other_containers`) with numbers, and `steplab-summary.sh` prints them; `lab/check.sh` all `ok` |
| 2   | `feat(lab): alternate the order of a round, and one floor rule`          | `steplab.sh` runs round 1 with the reference last and round 2 with it first (B A, A B, ...), the order printed per round; `--floor-from <A/A folder>` reads the floor from an A/A summary with the rule below; the verdict's fixtures pass (identical, beyond, mixed signs, under the floor, 5a's A/A differences give 0.36, a run that fails the 97 % rule counts and is flagged, an invalid run has no pair as today); 5a's results folders print the same tables; a `FIXME(pending)` points at Q19; `lab/check.sh` all `ok` |
| 3   | `feat(app): several processes on SO_REUSEPORT`                          | with `APP_WORKERS=2`, `challenge-test.sh --env APP_WORKERS=2` prints `passed=42 failed=0`, a check counts both pids answering, a 2-minute realistic smoke at 12,000 req/s with 60,000 idle is valid; unset, the server is the one process it was; `lab/check.sh` all `ok` |
| 4   | `feat(app): JSON built by concatenation or by SQLite`                   | `APP_JSON=concat` and `APP_JSON=sqlite` each pass 42/42 (`challenge-test.sh --env`); `concat` gives the reference's bytes for the golden feed and post; `sqlite` gives JSON that decodes to the same values on the golden rows and on a check row with a quote, a backslash, a slash, a control character, U+2028 and an emoji; `lab/micro/benches/feed.php` prints ns per feed (query and JSON) for the three; `lab/check.sh` all `ok` |
| 5   | `feat(app): parser and event-loop variants`                             | a micro bench prints ns per parse of k6's real request heads, today's parser against the lean one; the lean one is wired as `APP_PARSE=lean` only if it saves at least 20 % of a parse, and then passes every DIY parser check (the smuggling cases) and 42/42; `APP_LOOP=<preset>` (at most 3 presets of libevent's base flags) each pass 42/42 with its `syscalls.sh` count beside the reference's (D73), and the bake-off's DIY checks stay green; `lab/check.sh` all `ok` |
| 6   | `feat(app): an FFI driver to libsqlite3`                                | the feed micro bench prints ns per feed for `pdo` and `ffi` with `APP_JSON=encode` and `sqlite`; if `ffi` with `sqlite` is not under `pdo` with `sqlite` there, the scope stops at the micro (committed, the reason in the hand-back); otherwise `APP_DRIVER=ffi` passes 42/42 alone and with `APP_JSON=sqlite`, and a write whose 201 was received is still there after `kill -9`; `lab/check.sh` all `ok` |
| 7   | `docs(lab): the CPU steps of 5b and S1-b, measured on the Mac`          | `lab/results/<date>-cpu-steps-5b/README.md`: predictions copied unchanged, the A/A floor at 24,000 in the new order, each variant's screen and confirmation, the Mac's reconnect pair at 7,500, S1-b against S1-a at 12,000, the micro numbers beside the macro ones, the profile of the chosen variants, each prediction marked, a choice per step; every counted run's host line; `summarize.sh` regenerates its tables |
| 8   | `docs(lab): the chosen variants together, 5b` (**skipped, D75:** no CPU variant chosen) | `lab/results/<date>-step-lab-together-5b/README.md`: a short staircase, then 3 holds of 5 minutes of 5b's configuration interleaved with 3 of 5a's, µs/req and held rate of each, the profile step by step against 5a's; `summarize.sh` regenerates its tables |
| 9   | `docs(lab): S1-b and the reconnect on x86`                              | only with Jacob's go: on one `c5.2xlarge` as in 5a, a second reconnect pair, S1-b against S1-a (3 pairs), and 5b's configuration against 5a's (3 pairs) at 7,500 req/s; the S1 choice by the rule below; the bench estimate; the instance terminated and nothing tagged left |

Vertical slices: scopes 1 and 2 are the instrument every measurement after them uses. Scopes 3 to 6 are the variants,
each behind a switch with its own checks. Scope 7 measures them on the Mac (quiet VM), scope 8 puts the winners
together, scope 9 is the only one that leaves the Mac.

**Quiet VM (D15):** scopes 7 and 8 measure. The VM is quiet from 2026-11-23 23:18 until Jacob's containers come back
in the morning (the planning session warns first): then the run in flight finishes and no new macro measurement
starts; coding and reviews go on. A developer runs `lab/check.sh` only when no measurement is running.

**AWS (scope 9):** needs Jacob's go each time; the policy is the factory's `aws/phase-5-x86-calibration-policy.json`
(or a 5b copy), profile and region as environment variables. A call the policy refuses means the run strayed: stop
and report. Without his go when scope 8 is done, the run stops there with a 🔴 item (⏸️), not a split. The AWS session
doesn't need the Mac's VM quiet: k6 runs on the instance.

**Its boundary (5c):** if the quiet night ends before scope 7's confirmations, the remaining pairs wait for the next
quiet VM; scope 8 and the delivery follow. Nothing is cut silently: what isn't measured is said in its README.

## Shared rules for every scope

5a's rules hold ([phase-5.md](phase-5.md), "Shared rules"): a variant is a switch and the default is the skeleton;
correctness before speed (42/42); the public guard; predictions copied unchanged; the DIY loop shared with the
bake-off's server; the TIME_WAIT gate. New for 5b:

- **The reference is `APP_PRAGMAS=mmap-off`** (D66, D70), PHP 8.5, telemetry off, at 24,000 req/s (`s = 0.02`, 60,000
  idle): the chosen configuration so far, minus S1-d, which never fires in this mode and costs nothing it can see.
- **Every measured series goes through `lab/stages.sh`** (D68), and every run's JSON has its host line.
- **The floor** is read with `--floor-from` from an A/A folder of the same rate and order rule, never typed by hand.

## Scope 1: the series driver and the host line (D68)

- **Seams:** `lab/stages.sh` (new), `lab/realistic.sh` (the host line), `lab/steplab-summary.sh`, `lab/macro/probe.sh`
  (if the probes live there), checks in `lab/check.sh`.
- **`stages.sh <series file> [--out <dir>] [--gap <s>] [--dry-run] [--allow-busy]`:** a series file is plain text,
  one series per line: a name, then the arguments of one `steplab.sh` call. For each series: the quiet check (the
  Docker VM's running containers that aren't the lab's: 0, or refuse; `--allow-busy` runs anyway and labels every
  JSON of the series `busy: true`, for smokes only), the dated start, the `steplab.sh` call with `--out <dir>/<name>`,
  the dated end, then the gap. It writes `stages.json` (the commit it measures and whether its tracked files are dirty; each series: name, command, start, end, exit code, quiet check)
  and prints a line per series. A series that fails stops the file (its exit code kept), unless `--keep-going`.
- **The host line:** `realistic.sh` adds to each run's JSON a `host` object read twice, before the warm-up and in the
  middle of the plateau: `load1`, `load5` (the VM's `/proc/loadavg`), `cpu_busy_pct` (the VM's `/proc/stat` over 5
  s, all CPUs), `steal_pct` (the same, steal; 0 on the Mac), `fsync_ms` (the median of 20 writes of 4 KiB each
  followed by `fdatasync`, on the volume of the server's seed copy, before the warm-up only), `other_containers`.
  Read from a small container (the lab's probe image), never from the Mac's host. Counts and timings only: no host
  name, no CPU serial (the guard).
- **Cases:** a dry run prints the commands without running anything; the quiet check refuses with an unlabelled
  container running (the check's own `sleep` container, removed after); a live series of 2 runs (short, small rate)
  writes `stages.json` with start before end; the host object has numeric fields, `fsync_ms` positive; a run's
  summary row shows `load1` and `fsync_ms`.

## Scope 2: the order of a round and one floor rule (Q19, coded as A)

- **Seams:** `lab/steplab.sh`, `lab/steplab-verdict.jq`, `lab/steplab-summary.sh`, the fixtures.
- **Order (D71):** rounds alternate, and round 1 runs the reference **last** (B A, then A B, ...; with 3 variants C B A,
  then A B C), counted from the folder's round number, so a one-pair screen has the order bias (the second run reads
  about 0.2 µs lower) against the variant. `--order fixed` keeps today's order. The run's JSON says its position.
- **The floor rule, one for every pair (A/A included, D71):** a run counts when the harness says it is valid, passing
  the 97 % rule or not (as today); a counted run that failed the rule is flagged `*`; a run the harness marked invalid
  stays out of the pairs (as today). The floor of an A/A folder is `|median of its paired differences| + their
  interquartile range`, quartiles by linear interpolation (inclusive), so one outlier run doesn't set it: 0.36 on 5a's
  A/A at 24,000 (2.57 by the largest difference). `--floor-from <folder>` computes it from that folder's run JSONs;
  `--floor <µs>` stays for fixtures and for Q19's B (the largest difference, typed).
- **5a's folders unchanged:** their `summarize.sh` keep printing the tables they were judged by (the new rule's text,
  flags and columns only for runs that carry the new fields); `lab/check.sh`'s results check stays green without
  touching their READMEs.
- **The verdict:** "beyond the noise" when every pair has the same sign and the median paired difference is at least
  the floor (unchanged).
- **`FIXME(pending)`:** one line in `steplab.sh` and one in `steplab-verdict.jq`, in English, pointing at Q19 of
  `plan/plan.md`: "Jacob must confirm the order and floor rule (Q19). Assumes A."
- **Cases:** order of rounds 1 to 4 with 2 and with 3 variants; 5a's A/A differences (-0.267, -0.260, -0.161, -0.063,
  +2.565) give 0.36 (inclusive quartiles), not 2.57 or 1.68; an even count; a run that fails the 97 % rule counts and
  shows `*`; an invalid run has no pair; the old fixtures still pass; `--floor` with `--floor-from` exits 2.

## Scope 3: S1-b, several processes (D67, D69)

5a's scope 3, unchanged ([phase-5.md](phase-5.md), "Scope 3"): `APP_WORKERS=<n>`, the parent forks `n` children
after reading the config, each opens its own `SO_REUSEPORT` listener, `EventBase` and SQLite connection (after the
fork), the parent exits non-zero if a child dies (no restart loop). Two additions:

- **With other switches:** `APP_LOCKING=exclusive` and `APP_CHECKPOINTER` are refused with `APP_WORKERS` above 1 (a
  second process can't open an exclusive database); `APP_SOFT_CONN_LIMIT` applies per process (each counts its own
  connections), said in the boot line.
- **The realistic mode:** the server's fd count and its telemetry sum over the children (pids in the line).
- **Extensions:** `pcntl` isn't in the lab's default list (`sockets event`), and one `--ext` replaces the list: S1-b's
  runs and checks pass `--ext sockets --ext event --ext pcntl`.
- **Cases:** 42/42 with 2 workers; both pids answer over 200 connections; a smoke at 12,000 req/s with 60,000 idle is
  valid; unset, the same boot lines and bytes as before.

## Scope 4: S7, the JSON (`APP_JSON`)

- **Seams:** `lab/app/app.php` (the boot reads the switch, the feed and post queries and JSON functions),
  `lab/micro/benches/feed.php`, checks.
- **Variants:**
  - `encode` (today): `json_encode` of the keyed rows;
  - `concat`: each post built by concatenation, `json_encode` only on the strings (body, created_at, author), the
    numbers cast, the posts joined with `implode`, from the keyed rows (5a's `FETCH_NUM` path was slower: positions
    aren't the point);
  - `sqlite`: SQLite builds the JSON. The feed's statement returns one row of one column, `json_group_array` of a
    `json_object` per post in the spec's key order, with the 20 newest kept in order (SQLite 3.45 takes `ORDER BY`
    inside an aggregate); PHP wraps it (`{"posts":` ... `}`). The post's statement returns its `json_object`. Writes
    stay as they are.
- **Byte rules:** `concat` gives the reference's bytes. `sqlite` may escape differently (SQLite's `json_quote` against
  PHP's flags: U+2028, control characters): it must decode to the same values, and the challenge's 42 checks decide.
  The README of scope 7 shows a byte difference if there is one.
- **Combinations:** `sqlite` and `concat` need `APP_FEED_SQL=reference` and `APP_FETCH=assoc`; every unsupported
  combination (here and in scope 6: with `num`, `join`, `two-step`, group commit where it doesn't compose) is refused
  at boot with a message, as the checkpointer is with `exclusive`.
- **The micro bench:** ns per feed, query and JSON together, for the three, on a fresh seed copy, the rows checked
  against the reference's (decoded).
- **Cases:** 42/42 each; the golden feed and post byte for byte for `concat`; decoded-equal for `sqlite`, also on a
  check post whose body holds a quote, a backslash, a slash, a tab, U+2028 and an emoji; an empty feed gives
  `{"posts":[]}` for all three.

## Scope 5: S2, the parser, and the event loop

- **Seams:** `lab/servers/diy-connection.php`, `lab/servers/diy-server.php`, `lab/app/server.php`, a new micro bench
  `lab/micro/benches/parse.php`, checks.
- **The parser, micro first:** `parse.php` times today's `parseHead` on the heads k6 sends (the feed's `GET` and the
  like's `POST` with its `Authorization`, copied from a real k6 request) against a lean parse that the developer
  proposes (one pass of `strpos`/`stripos` for the three headers that matter, with the same rejections). Wired as
  `APP_PARSE=lean` only if it saves at least 20 % of a parse's ns (D73); otherwise the micro numbers are the result.
  The lean parse must keep every rejection of today's (smuggling: two `Content-Length`, a space before the colon, an
  obsolete fold, `Transfer-Encoding`).
- **The loop:** `APP_LOOP=<preset>`, an `EventConfig` for the `EventBase`, at most 3 presets from libevent's base
  flags that ext-event exposes (for example no locking, epoll's change list, no cached time), the developer says why
  each could save CPU. Unset: `new EventBase()` as today. The bake-off's DIY server unchanged. **The gate (D73):**
  `syscalls.sh` under each preset against the reference; only a preset whose count shows something removed gets a
  macro pair in scope 7. 5a's count has 0 `epoll_ctl` per request.
- **Cases:** the parse bench's check (both parsers give the same method, target, length, authorization); with
  `APP_PARSE=lean` every existing DIY parser check passes; each `APP_LOOP` preset 42/42 and the server's boot line
  names its method and flags.

## Scope 6: S6, an FFI driver to `libsqlite3` (`APP_DRIVER`)

- **Seams:** `lab/app/app.php` (the driver behind the query functions), a new `lab/app/sqlite-ffi.php` with its C
  declarations, `lab/micro/benches/feed.php`, checks. FFI needs no ini change: the image's `ffi.enable=preload` allows it
  in the CLI (the plan review checked it); never `--php-ini`, which drops the lab's JIT and OPcache flags.
- **The driver:** the image's `libsqlite3.so.0` (3.45.1, the version `pdo_sqlite` uses: checked at boot, refused if
  they differ). The same pragmas, locking and `busy_timeout` as the PDO path. Statements prepared at boot
  (`sqlite3_prepare_v3` with `SQLITE_PREPARE_PERSISTENT`), bound, stepped, read, reset. Feed and post reads through
  `sqlite3_column_*`; with `APP_JSON=sqlite` the feed is one step and one `sqlite3_column_text`. Writes: the insert's
  `RETURNING` row, the like's `sqlite3_changes`. Errors as the PDO path answers them.
- **Micro first, with a stop:** the feed micro bench gets the driver dimension (`pdo`, `ffi`) × (`encode`, `sqlite`).
  If `ffi` with `sqlite` is not under `pdo` with `sqlite`, the scope stops there (the micro committed, the driver
  for reads only, the reason in the hand-back): an FFI call per column can't beat PDO's C loop, and with one column
  there is nothing left for FFI to save. Time box: about 2 hours.
- **Cases:** 42/42 with `ffi`, alone and with `APP_JSON=sqlite`; the boot refuses a version mismatch; `kill -9`
  after a 201, reopen: the row is there; the micro bench's rows decode to the reference's.

## Scope 7: the CPU steps of 5b and S1-b, measured on the Mac

- **Before any run:** the predictions below copied unchanged into `lab/results/<date>-cpu-steps-5b/README.md`; quiet
  VM; every series through `stages.sh` (D68).
- **When (D72):** in three parts. **7a**, as soon as scope 2 is in, while scopes 3 and 4 are coded (their developers
  run no Docker until the VM is free): the A/A at 24,000, the Mac reconnect pair at 7,500, the PHP 8.4 and 8.6
  screens. **7b**, after scope 3: S1-b's pairs. **7c**, after scopes 4 to 6: the variant screens, confirmations, the
  profile, the README. 7a and 7b run from a second worktree detached at the commit they measure (D74), so a file
  edited by the scope being coded never reaches a run; their folders are then copied into the phase's worktree.
- **The A/A at 24,000 req/s** (the reference against itself, 5 pairs, alternating order): the floor by D71's rule; its
  first pair is also the real-shape smoke of the new order and the host line (D57). **At 12,000 req/s** (for S1-b):
  5a's A/A JSONs at that rate (the bare skeleton, old order: 0.52 by D71's rule) re-read with `--floor-from`, said
  so; S1-b is predicted far above that floor, so no new A/A.
- **S1, on the Mac:** the reconnect pair at 7,500 req/s (D67: S1-a against S1-d with every request reconnecting, one
  pair, about 5 minutes); S1-b (`APP_WORKERS=2`) against S1-a at 12,000 req/s, 3 pairs (its cost decides scope 9's
  question, so it gets its pairs without a screen).
- **The CPU screens at 24,000 req/s against the reference (D60, one pair each, 2 more only if it beats the floor):**
  `APP_JSON=concat`, `APP_JSON=sqlite`, `APP_DRIVER=ffi` with `APP_JSON=sqlite` (if scope 6 passed its micro),
  `APP_PARSE=lean` (if wired), an `APP_LOOP` preset only if its syscall count passed D73's gate, PHP 8.6 and 8.4 (`--variant-args` with the image, the
  reference's switches). A variant whose micro already says under the floor gets its one pair only to show it costs
  nothing.
- **Then, if two or more variants beat the floor on different steps:** one pair of them together against the
  reference, as 5a's D64 did.
- **The profile:** one profiled 60 s run of the chosen combination, folded (on 8.5: 8.6 has no Excimer, so if 8.6 were
  chosen its profile is 8.5's, said so).
- **The choice:** per step, the chosen variant and why; a variant within the noise isn't chosen unless it is simpler.

## Scope 8: the chosen variants together, 5b

- **Before any run:** the predictions copied unchanged into `lab/results/<date>-step-lab-together-5b/README.md`.
- **Runs:** a short staircase of 5b's configuration (scope 7's choices with `mmap-off`, S1-d's limit set above the
  run's connections so it doesn't fire) from 22,000 req/s at `s = 0.02`; then, at the highest step both pass, 3 holds
  of 5 minutes of 5b's configuration interleaved with 3 of 5a's (S1-d and `mmap-off`), in alternating order: their
  µs/req (median of 3), the held rate, the profile.
- **The table:** each step, its µs in the profile for 5a's configuration and 5b's; the users each maps to on the Mac
  (arm64, not a score) and with the x86 factor (1.61 at the same rate), next to S1's cost at 100,000 and 150,000 users.

## Scope 9: S1-b and the reconnect on x86 (D67, D69)

- **Only with Jacob's go** (a 🔴 item in 👉, relayed by the planning session). 5a's scope 12 harness
  (`lab/lib.sh`'s 8-vCPU layout, the factory's `aws/` scripts), one `c5.2xlarge`, server on one vCPU with its sibling
  idle, `cgroupfs` for Docker's probe.
- **Runs at 7,500 req/s with 60,000 idle:** S1-a against S1-d with every request reconnecting, one pair (the second
  x86 reconnect pair); S1-b (`APP_WORKERS=2`) against S1-a, 3 pairs. (5b's configuration against 5a's: dropped, D75:
  they are the same.)
- **The S1 rule:** with the x86 reconnect price, S1-d's added µs at 100,000 and 150,000 users (5a's model: a share
  `1 - 64,000 / N` of the requests reconnect); S1-b's added µs is its measured cost (2 workers hold 131,000
  connections; at 150,000 users, 2 workers each with S1-d past 64,000, or 3 workers, projected from the 2-worker
  cost, said so). The S1 variant is the one that adds fewer µs at 150,000 users; S1-d stays if it adds 15 % or less
  (D67). The choice also says each variant's memory at 150,000 users (S1-b keeps about twice the open connections, at
  5a's 6.7 KiB each, plus a page cache per process, on a 2 GB box). If S1-b costs more than S1-d at both sizes, the io_uring ring becomes a question for Jacob, not a scope.
- **The bench estimate:** 5b's configuration's Xeon µs/req times 1.57 (5a's Xeon-to-bench factor).
- **The end:** the instance terminated, its volume deleted, the key pair and security group removed, checked with a
  `describe` that shows nothing tagged; the policy detached and deleted by Jacob.

## Predictions (D5)

Written by the project manager on 2026-11-23 at 23:24, before any phase 5b measurement. Arm64, Docker Desktop on an
M3 Pro, quiet VM, PHP 8.5, the reference `APP_PRAGMAS=mmap-off` (25.0 to 25.6 µs/req at 24,000 req/s in 5a's pairs),
unless a line says otherwise.

1. **The host line on a quiet VM** during a 24,000 req/s plateau: load average 3 to 7, the VM's CPU 35 to 60 % busy,
   steal 0, `fsync_ms` 0.05 to 2 ms.
2. **The A/A at 24,000 in alternating order:** the median paired difference within ±0.15 µs (the order bias of
   about -0.2 cancels), and the floor (`|median| + interquartile range`) 0.3 to 0.8 µs/req.
3. **The Mac's reconnect at 7,500 req/s:** 7 to 9.5 µs (6.62 at 12,000, plus the 19 % the Mac's request rises at
   7,500), so the Xeon over the Mac for a reconnect is 2.5 to 3.4, not 3.58.
4. **S1-b on the Mac at 12,000 req/s:** +1.5 to +5 µs per request over S1-a (+5 to +18 %), beyond the floor.
5. **`APP_JSON=concat`:** 3 to 12 % under `encode` in ns per feed (micro); -0.2 to -0.8 µs per request at the macro,
   under the floor, so judged on its micro.
6. **`APP_JSON=sqlite`:** 10 to 25 % under `encode` in ns per feed (PDO's hundred values per feed and the encoder
   replaced by one pass in C); -1.5 to -4 µs per request at the macro, beyond the floor, and chosen.
7. **The FFI driver:** with `encode`, slower than PDO by 8 to 30 µs per feed (one FFI call per column and per row,
   about 120 a feed); with `sqlite`, within ±1 µs of PDO with `sqlite` (a handful of calls a feed), so the micro's
   stop fires or its pair is within the noise: not chosen.
8. **The loop presets:** each within ±0.5 µs of the reference, none chosen.
9. **The lean parser:** saves under 20 % of a parse in the micro (under 0.4 µs a request), so it isn't wired.
   (Revised at 23:37 after the plan review, before any measurement: the first version straddled the bar.)
10. **PHP 8.6 against 8.5:** within ±3 % (not chosen unless beyond the floor); 8.4 0 to 5 % slower.
11. **Together on the Mac:** 5b's configuration 1.5 to 4 µs per request under 5a's (6 to 15 %), interleaved holds;
    the held rate at `s = 0.02` stays the harness's floor (22,000 to 24,000 req/s); S6 still the largest step.
12. **x86, S1:** the second reconnect pair within 10 % of 23.69 µs; S1-b's 2 workers cost +5 to +15 % per request on
    the Xeon, less than S1-d's +25 % at 150,000 users: S1-b chosen for the bench's sizes.
13. **x86, the configuration:** 5b's 6 to 15 % under 5a's on the Xeon; the bench estimate 71 to 80 µs/req.

## Out of scope

- **S4 (JWT, 1.7 %), S3 (route, 0.4 %), S5 (validation, 0.1 %):** under D60's 2 %; skipped, not measured.
- **The io_uring ring for the app:** not built in 5b; a question for Jacob only if S1-b costs too much (scope 9).
- **Group commit, the checkpointer, `exclusive`:** measured in 5a, not chosen; `exclusive` can't run with S1-b.
- **Our own C:** ❌ (D2, notes 2026-11-23 19:28). SQLite's own JSON functions are SQLite's code, like its query
  engine: allowed.
- **Read coalescing:** ❌ (rule 5, D29). `APP_JSON=sqlite` builds one request's own JSON from its own query.
- **The submission folder, the real score:** phases 6 and 7.
