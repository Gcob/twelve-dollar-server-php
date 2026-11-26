# Phase 8: the ring

**Done when:** each of the four levers has its µs per request on x86 (on arm64, said so, if Q24 = B) against phase 7's submission, or the measured or
read reason it stopped earlier (fail fast, D60): (1) the single-post plan, (2) off-the-shelf io_uring (Swoole's
`uring_socket`, ext-mrloop), (3) our own io_uring loop in PHP through FFI, (4) a SQLite built from the amalgamation,
tuned and with PGO. If one or more win, `submissions/php-Gcob/` carries them and gets a new score; either way, one AWS
score session names the ceiling of phase 7's submission (D107) and, if it changed, of phase 8's, with a load that
doesn't bind. Every number is written with its bench estimate apart (D96, D106). The predictions below were written
before any run (D5). Then the run stops (D12).

**Plan review:** [PLAN-2026-11-26-1523.md](../reviews/PLAN-2026-11-26-1523.md), NOT_OK (0 🔴, 6 🟠, 14 🟡).
Settled by the project manager with the reviewer's picks where the choice was the run's: D116 (the ring's pair spans
2 rings, and D121 after the delta [PLAN-2026-11-26-1530-delta.md](../reviews/PLAN-2026-11-26-1530-delta.md): the loop
blocks on the last active ring), D117 (the `loop:` line is a gate), D118 (real-shape smokes on the Mac, D57), D119 (the submission's copy
proven like the lab's), D120 (the batching knob out: it can't ship to 6.8); the 🟡 folded in below. Two choices are
Jacob's because they shape the AWS sessions: the kernel of the boxes (Q27) and the score session's cross-box pair
(Q28).

**Where (D14):** code on branch `phase-8-claude`, in its worktree (from `main` at `1f6b163`). `plan/` stays on `main`.
The factory holds the private side: the AWS scripts and policies (`aws/`), the run logs with ids and addresses, the raw
diagnostics (`lab/`).

**Why this shape:** phase 7 found the AWS score bound by more than the CPU. At 135,000 users the service used 83 % of
its core at about 59 µs a request, and at 142,000 the kernel logged `TCP: out of memory` once, the `c5.large`'s
packets-a-second allowance grew in every run past 87,000, and k6's garbage collector spiked its load box. On the
bench's box the core costs about 1.57 times more per request, so its wall is the CPU, near 86,000 users (D106): there,
every µs saved counts, and the AWS score above about 140,000 says little about it. So phase 8 judges its levers by
their **µs per request on x86** (the step lab's pairs, D51, D60), and reads the bench estimate from them:
`users ≈ 0.85 × 9.45 × 10⁶ / (1.57 × µs on AWS) ≈ 5.12 million / µs` (phase 7: 5.12 million / 59 ≈ 86,800). The
score session then shows what the AWS box holds and names each server's wall.

Three risks, one per slice: **the ring** (an app on our own io_uring loop through FFI, correct under load, past the fd
wall in one process), **the instrument** (pairs on x86 that can see a few µs, where the lab's Mac kernel differs: S1-b
cost 8.6 % on the M3 and 14.8 % on the Xeon), and **the reading** (a score session whose load box is never the wall).

## Decisions of this phase

In [decisions.md](../decisions.md), settled by the project manager (Jacob's choices are Q24 to Q28 in
[plan.md](../plan.md)):

- **D108, the reference:** every lever is compared with phase 7's submission as it is on `main` (`1f6b163`), run by
  `lab/steplab.sh --server-variant` like D83's parity: S1-b's 2 processes, the soft limit at 64,000 each, `mmap` off.
  Not `lab/app`'s skeleton: the question is what beats what we ship.
- **D109, the order and the stops (D60):** cheapest first, each with its stop.
  1. **The single-post plan** is read, not timed: if Ubuntu's SQLite has no `ENABLE_STAT4` (checked: 3.45.1 has none),
     the statement's `SQLITE_STMTSTATUS_REPREPARE` stays 0 over 10,000 queries and `EXPLAIN QUERY PLAN` is the same for
     `p.id = ?` and `p.id = +?`, the lever closes with no run. Else it gets a micro bench, then one pair.
  2. **ext-mrloop** is audited, not run: a screen only if the audit finds a reason (a question to Jacob then).
  3. **Swoole's `uring_socket`** gets one pair against the reference; it stops there unless it beats the floor.
     (Closed earlier, on scope 3's real-shape smoke: D122.)
  4. **The tuned SQLite** gets the feed micro bench first; a pair only if the micro's saving, times the feed's share
     of a request's cost, reaches the floor: the micro must save at least (floor ÷ the reference's µs/req) ÷ the
     feed's share.
  5. **The ring** gets one pair, then 2 more if it beats the floor (3 in all), spread over 2 rings (D116). Its
     batching knob is out (D120).
  6. **The winners together:** one pair, only if two or more win.
- **D110, Swoole's screen:** our own `lab/app/app.php` handlers on `Swoole\Coroutine\Http\Server` (the server
  `uring_socket` moves; both Swoole entries use the reactor `Swoole\Http\Server`, which it doesn't), one process, in a
  lab image with liburing built from its pinned source (2.8 or later: Swoole 6.2 needs it, Ubuntu 24.04 ships 2.5) and
  Swoole 6.2.6 rebuilt with `--enable-uring_socket --with-liburing-dir`. Same app code, so the pair prices the server
  around it. Swoole still takes one fd per connection: it would need S1-b's processes past 65,535, so a win here must
  also beat the ring's fd story to ship.
- **D111, the tuned SQLite:** the amalgamation of the newest SQLite release, pinned by sha256, built with `-O2
  -march=native` and sqlite.org's recommended options for a single-threaded app (`THREADSAFE=0`,
  `DEFAULT_MEMSTATUS=0`, `DQS=0`, `LIKE_DOESNT_MATCH_BLOBS`, `MAX_EXPR_DEPTH=0`, `OMIT_DEPRECATED`,
  `OMIT_PROGRESS_CALLBACK`, `OMIT_SHARED_CACHE`, `USE_ALLOCA`), then PGO: built with `-fprofile-generate`, trained,
  rebuilt with `-fprofile-use`. The training runs the app's own statements (the five endpoints' SQL, in the bench's
  mix) on a database it **generates** with the challenge's schema and a seed-like size, never the seed: `install.sh`
  never sees the bench's data, and the build must not depend on it. PHP's `pdo_sqlite` links against that library
  (its own prefix, an rpath, so the system's `libsqlite3` is never replaced). `-march=native` is legal because
  `install.sh` compiles on the box that runs it (the bench's Xeon 8260 and our 8275CL are both Cascade Lake).
  `pdo_sqlite` is built into the `php` binary (`--with-pdo-sqlite`), so the proof is `ldd` of `php`, and the build
  prints what PHP's configure detected in the library (an omitted symbol must not drop a feature PDO uses). The
  version change alone is not separated from the flags unless the pair wins (then one more pair: the same version,
  stock flags).
- **D112, the ring's shape:** one process (no S1-b), built on 5a's spike (`lab/servers/uring-noop.php`: raw syscalls
  through FFI, no liburing, the memory-ordering design of [notes.md](../notes.md) 2026-11-22 18:25: no `SQPOLL`,
  `SINGLE_ISSUER` and `DEFER_TASKRUN`), unless Q25 says liburing-ffi. Connections are direct descriptors; a ring's
  table is capped by `RLIMIT_NOFILE` (65,535 on the bench), so 3 rings in one process hold 3 × 64,000 = 192,000, with
  `Connection: close` past that soft limit (as S1-d). The app's handlers are called as on the DIY loop; SQLite stays
  synchronous. At boot the server runs the ring's whole init (setup with its flags, the file table, the buffer
  ring): if any step is refused (a seccomp filter's `EPERM`, `ENOSYS`, `io_uring_disabled`, an older kernel's
  `EINVAL`), it prints why and runs the epoll loop instead, as S1-b does today. The bench's systemd service allows
  io_uring (30+ entries run on it). Every flag used exists on the bench's 6.8 (`DEFER_TASKRUN` 6.1, `NO_SQARRAY` 6.6).
- **D113, where the pairs run:** per Q24. Its option A: one AWS `c5.2xlarge` running the lab as 5b's x86 session did
  (`LAB_CPU_LAYOUT=x86-8`, the server on one vCPU with its sibling idle, k6 on the others), 7,500 req/s, `s = 0.02`,
  60,000 idle, 60 s runs, alternating order, a fresh A/A of the reference first (5 pairs: the 2-process reference has
  no x86 floor yet), then D109's pairs. The micro benches run on the same box. Every run of a pair, both sides, runs
  without Docker's seccomp filter (the bench has none, and the flag is per run). The kernel per Q27.
- **D114, the score session:** two server boxes shaped as D89 and D91 (`c5.large`, one core, `mem=2G`), one per
  submission, each installed the bench's way on a clean box, so neither install touches the other's `/opt/php-gcob`;
  the load per Q26, the kernel per Q27. Port 80 by D100's rule (opened to `0.0.0.0/0` when a box's
  `conntrack_allowance_available` is under 220,000, which the `c5.large` was, 136,801; only Jacob opens it, asked at
  the go). Both servers warm up, then a fixed-load probe at 101,000 users interleaved A B B A across the two (2-minute
  probes: the µs/req at the bench's shape, read per Q28), then each server's search, phase 8's first (the new number
  is the one at risk in the time box): probes from 135,000 in 5 % steps until one fails, one probe halfway back
  (2.5 %), then 5-minute holds stepping down 2.5 % from the highest pass. The phase 7 server's µs/req at 101,000 is
  compared with phase 7's session (53.6) and written. D95's walls, with two more: **network** only
  when a run fails with `pps_allowance_exceeded` grown (phase 7 passed with it grown), **TCP memory** when a failing
  run logged `TCP: out of memory`. If nothing wins at the x86 lab session, the session runs phase 7's server alone
  (D107).
- **D115, the submission:** the winning levers go into `submissions/php-Gcob/` as a clean copy (D79), with no switch:
  the ring (and its epoll fallback), and/or the tuned SQLite built by `install.sh`. No parity pair (D83): the score
  session measures the submission itself against phase 7's. Its proofs: `lab/submission-test.sh` 42/42 on a clean
  `ubuntu:24.04` with io_uring allowed (a new `--seccomp-unconfined`), and `--ci` 42/42 twice: with Docker's filter (the
  fallback) and without it (the real CI runs natively on `ubuntu-24.04`, so it likely runs the ring); D117's line
  says which loop each ran. `check_submission` refuses the word `FFI` today (`lab/check.sh`): it then allows it in the
  ring's file only, the SQLite FFI driver still refused, with a fixture each way. The README's rules audit covers
  io_uring and the PGO build.
- **D116, the ring's pair spans two rings:** at the lab's shape (60,000 idle and about 1,400 VUs) every connection
  fits in one ring's table, so the pair would price one ring against S1-b's two processes while the submission ships
  3 rings, 2 active at the bench's sizes. The ring's runs set the server's `nofile` to 32,768 (`LAB_SERVER_NOFILE`,
  `lab/lib.sh`), so 60,000 idle span 2 rings, with `APP_RINGS=3` as shipped; the `ring:` lines show each ring's open
  count. The table size is then not the bench's, said in the README. `lab/realistic.sh` gains `--server-nofile` for it
  (today only `lab/conns.sh` and `lab/check.sh` set `LAB_SERVER_NOFILE`).
- **D121, which ring the loop waits on:** the lab opens its idle connections before k6, so with D116's shape ring 0
  holds the idle ones and the traffic lands on ring 1. The spike's loop blocks on ring 0 (up to `URING_WAIT_US`, 500
  µs) and enters the others on their `IORING_SQ_TASKRUN` flag: it would batch ring 1's requests more than the bench
  would, and read the ring cheaper than it runs. The loop blocks on the ring that had completions in the last turn and
  enters each other ring when its `IORING_SQ_TASKRUN` flag is set or it has SQEs queued (only a ring's own
  `io_uring_enter` submits them: a send queued on a quiet ring would wait forever), as the spike does, so no ring's
  work waits on an idle one. Scope 5's smoke prints requests per turn for each
  ring, and D118's pair compares them with scope 4's one-ring smoke: a 2-ring turn batching over 1.5 times more is a
  question before scope 6.
- **D117, the loop line is a gate:** every server prints one `loop:` boot line (`ring, 3 rings`, `epoll (io_uring
  refused: <errno>)`, `swoole-co, uring` ...); `lab/realistic.sh` writes it into the run's JSON, `lab/steplab.sh`
  refuses a variant whose line isn't the one it expects (`--expect-loop <variant>=<text>`), `lab/submission-test.sh`
  prints it, and every "on io_uring" Done when reads it. A fallback can never stand in for the ring in a pair or a
  proof.
- **D118, real-shape smokes before AWS (D57):** scope 3 ends with one step-lab pair of `swoole-co.php` against the
  reference and scope 5 with one of the ring (D116's shape) against the reference, on the Mac at 60,000 idle and 7,500
  req/s, both runs valid. They are smokes of the harness, never verdicts, even with the Mac's VM quiet.
- **D119, the submission's copy proven like the lab's:** scope 7 also runs, on the submission's own server file,
  `lab/stress.sh` (0 mismatches, pipelines 1 and 16), `lab/conformance.sh` all `ok` and `lab/conns.sh` 150,000 held:
  42/42 and k6 never split or pipeline a request, so a port bug would ship unseen.
- **D120, the batching knob is out:** `URING_MIN_WAIT_US` uses `min_wait_usec`, kernel 6.12 and up; the bench runs 6.8,
  where the field is reserved and the call likely fails after setup succeeded, past the fallback. Predicted within
  the floor at 7,500 req/s anyway (D60): not built, not measured.

## Scopes

| #   | Commit                                                                  | Done when |
|-----|-------------------------------------------------------------------------|-----------|
| 1   | `feat(lab): the single-post plan, read`                                  | `bash lab/post-plan.sh` prints the SQLite version, whether `ENABLE_STAT4` is in its compile options, `SQLITE_STMTSTATUS_REPREPARE` after 10,000 single-post queries through the FFI driver (`lab/app/sqlite-ffi.php`) for `p.id = ?` and for `p.id = +?`, and both `EXPLAIN QUERY PLAN`s, and ends on one line: `closed` or `timing needed`; a fixture with a forced re-prepare makes it say `timing needed`; `lab/check.sh` all `ok` |
| 2   | `feat(lab): a SQLite built from the amalgamation, tuned, with PGO`       | `lab/images/install-sqlite-tuned.sh` builds D111's library (sha256 pinned) with its training on a generated database; a `php-lab:8.5-sqlite` image whose `pdo_sqlite` prints the new version and `THREADSAFE=0`; `lab/challenge-test.sh --image 8.5-sqlite` 42/42; `bash lab/micro.sh lab/micro/benches/feed.php --images 8.5,8.5-sqlite` prints ns per feed for both (a smoke, not a measurement); the build fails if the training ran no statement; `lab/check.sh` all `ok` |
| 3   | `feat(lab): off-the-shelf io_uring, Swoole built and ext-mrloop audited` | `php-lab:8.5-uring` (liburing pinned, Swoole 6.2.6 with `--enable-uring_socket`) prints Swoole's io_uring support in `--ri swoole`; `lab/servers/swoole-co.php` (D110) passes `lab/challenge-test.sh` 42/42 on it with `--seccomp-unconfined`, its `loop:` line says io_uring (D117), and `strace -c` on a short run shows `io_uring_enter` with under 0.1 `recvfrom`, `sendto` and `accept4` a request; one step-lab pair against the reference at 60,000 idle and 7,500 req/s, both runs valid (D118, a smoke); `lab/results/<date>-mrloop-audit/README.md` answers the audit's questions (below) with file and line, and ends on `screen` or `no screen`; `lab/check.sh` all `ok` |
| 4   | `feat(app): the app on an io_uring ring through FFI`                     | `APP_RING=1` runs `lab/app` on one ring (D112): `lab/challenge-test.sh --seccomp-unconfined` 42/42 twice; `lab/conformance.sh` all `ok` (partial reads, pipelining); `lab/stress.sh` on the app's `GET /posts/<id>` with 0 mismatches and 0 lost over 1,000,000 requests, pipelines 1 and 16; `lab/realistic.sh` and `lab/steplab.sh` take `--seccomp-unconfined` (both sides of a pair) and run it at a small size; the `loop:` line in the run's JSON and `--expect-loop` refusing a wrong one, with a fixture (D117); `APP_GROUP_COMMIT` refused with `APP_RING`; `lab/check.sh` all `ok` |
| 5   | `feat(app): three rings, a close past their capacity, the fallback`      | `APP_RING=1 APP_RINGS=3`: `lab/conns.sh --seccomp-unconfined` holds 150,000 connections in one process with its own fds under 100, each answered; the soft limit's `Connection: close` past it (a small limit in a check: closes counted, 0 errors); the loop blocks on the last active ring (D121); with Docker's default seccomp filter the server prints the fallback line and passes 42/42 on the epoll loop; one step-lab pair, ring (D116's shape: `nofile` 32,768, 2 rings open) against the reference, 60,000 idle, 7,500 req/s, both valid, `loop:` lines checked, each ring's requests per turn printed against scope 4's one-ring smoke (D118, D121, a smoke); `lab/check.sh` all `ok` |
| 6   | `docs(lab): phase 8's levers on x86, measured`                           | `lab/results/<date>-x86-levers/README.md`: the predictions copied unchanged and committed before the session; the machine; the reference's A/A floor; every pair D109 calls for, with its verdict; the feed micro bench on both SQLites; one line per lever: its µs/req against the reference, chosen or not and why; the bench estimate of each; `summarize.sh` regenerates the tables; the guard passes; `teardown.sh --verify` clean (factory) |
| 7   | `feat(submission): php-Gcob on the ring` (or the levers that won)        | the winning levers in the clean copy (D115): `bash lab/submission-test.sh --seccomp-unconfined` 42/42 with `loop: ring`, `--ci` 42/42 with and without the filter, each `loop:` line printed; on the submission's server file `lab/stress.sh` 0 mismatches, `lab/conformance.sh` all `ok`, `lab/conns.sh` 150,000 held (D119); `check_submission` green with its new `FFI` rule; the README's rules audit names io_uring and the build; **skipped** if scope 6 chose nothing |
| 8   | `feat(lab): the score search on two load generators and two servers`     | `lab/score/search.sh` drives Q26's load (two k6 halves, started in the same second, pass when both pass, void per half) and D114's fixed-load pair; `bash lab/score/smoke.sh` runs it small on the Mac (two k6 containers, the local controller); `check_score` gains fixtures for the halves (one fails, one void, the plateau's intersection) and the new walls; `launch.sh --print` (factory) shows two server boxes and the load; `lab/check.sh` all `ok` |
| 9   | `docs(lab): the score on x86, phase 7 against phase 8, and their ceilings` | `lab/results/<date>-x86-score-2/README.md`: the predictions committed before the launch; both boxes' proofs; the fixed-load pair; every run and decision; each server's highest hold and its wall by D114's rules; the bench estimates; what differs from the bench; `TEARDOWN CLEAN` (factory) |
| 10  | `docs(submission): the new score, labelled`                              | the README's "Results" paragraph (D103) updated with the session's numbers and link; `check_submission` resolves it; the guard passes |

Vertical slices: scopes 1 to 3 close the cheap levers or make them measurable; 4 and 5 are the ring end to end in the
lab (one ring, then the fd wall and the fallback); 6 is the one measurement that decides; 7 ships what won; 8 to 10
are the score, as phase 7's scopes 1 to 4 were. Scopes 6 and 9 need Jacob's go for AWS (a 🔴 each), and 6 needs Q24.

**AWS:** nothing is created before Jacob's go. Each session's policy waits in the factory
(`aws/phase-8-levers-policy.json`, `aws/phase-8-score-policy.json`), least privilege, the types named; then
`launch.sh --dry-run`, then the session. The policy is the fence: a refused call means the run strayed, it stops and
reports.

## Shared rules for every scope

- **Measure only where D113 says:** the Mac's Docker VM is quiet since 15:20 (Jacob's containers stopped), but its
  verdicts wait for Q24: scopes 1 to 5 build and check,
  their numbers are smokes, never verdicts.
- **Public and private:** as phase 7 (D101): no address, id, account, key or host name in the public tree; the raw
  diagnostics go to the factory's `lab/`.
- **`lab/app` and the spike stay usable:** `APP_RING` unset is today's app on the DIY loop, byte for byte;
  `lab/servers/uring-noop.php` stays as 5a left it (its results cite it).
- **The submission is touched only by scopes 7 and 10.** Phase 7's copy is the reference until then.
- **No `gh` command, nothing on the challenge's repo.** Jacob's Docker containers: never start or stop them; the lab's
  own containers are fine.

## Scope 1: the single-post plan, read

- **Seams:** new `lab/post-plan.sh` (runs in the lab's image), a PHP script beside it using `lab/app/sqlite-ffi.php`
  (it already binds `libsqlite3` through FFI: `sqlite3_stmt_status` and `sqlite3_compileoption_used` are added to
  its declarations), `lab/check.sh` (`check_post_plan` with its fixture).
- **What it reads:** `APP_ONE_POST_SELECT` from `submissions/php-Gcob/app.php` (the reference, D108; the lab builds
  the same SQL in `app_post_sql()`), and the same with `+?`;
  10,000 queries over random existing ids on a copy of the seed; the re-prepare counter after them; the plans.
- **The fixture:** a statement that SQLite must re-prepare (a schema change between two steps, which expires the
  statement) shows the counter moving, so the check can fail.
- **Cases:** the counter read before and after (0 then 0 is `closed`); a moved counter is `timing needed`.

## Scope 2: a SQLite built from the amalgamation, tuned, with PGO

- **Seams:** new `lab/images/install-sqlite-tuned.sh` (the build, the training, the install under its own prefix),
  `lab/images/sqlite-train.php` or `.sql` (the generated database and the statements), `lab/images/Dockerfile.src` (a
  build arg that links PHP's `pdo_sqlite` against it: `PKG_CONFIG_PATH` or `SQLITE_CFLAGS`/`SQLITE_LIBS` and an
  rpath), `lab/build.sh` and `lab/run.sh` (the `8.5-sqlite` tag), `lab/check.sh`.
- **The training database:** the challenge's schema (from `reference/`), users, posts and likes at the seed's counts
  (`lab/seed.sh`'s numbers) but generated with a fixed random seed in the script, not copied; `ANALYZE` as the seed
  has `sqlite_stat1`. Statements: the feed, the single post, the post insert with `RETURNING`, the like insert, in
  the bench's mix (D40's weights), each run enough times that the profile has every path; the training's count is
  printed and the build fails at 0. The driver is PHP through PDO, the statements prepared once as the app does (a
  `.sql` file through the shell would re-parse each statement and weigh the parser in the profile): the instrumented
  library is built and installed first, PHP links against it once, the training runs, then the `-fprofile-use` build
  replaces the library under the same soname (PHP isn't rebuilt). Scope 7's `install.sh` follows the same order.
- **Not here:** the submission's `install.sh` (scope 7, if it wins), a pair (scope 6).
- **Cases:** `pragma compile_options` lists `THREADSAFE=0` and the options of D111; the version is the pinned one;
  the system's `libsqlite3` is still Ubuntu's; `ldd` of the `php` binary points to the new prefix (`pdo_sqlite` is
  built in); the build prints what PHP's configure detected.

## Scope 3: off-the-shelf io_uring

- **Seams:** new `lab/images/install-liburing.sh` (pinned tarball, sha256), a `WITH_SWOOLE_URING=1` build arg in
  `lab/images/install-php-src.sh` (the configure flags of D110), the `8.5-uring` tag; new
  `lab/servers/swoole-co.php` (the app's handlers in `Co\run`, one `Swoole\Coroutine\Http\Server`, the same headers as
  the DIY server where Swoole lets it); `lab/challenge-test.sh` gains `--seccomp-unconfined` (scope 4 needs it too).
- **The mrloop audit** (`lab/results/<date>-mrloop-audit/README.md`, from a clone at a pinned commit under
  `reference/` or a scratch folder, nothing built): does it use direct descriptors or one fd per connection; multishot
  accept and receive; one `io_uring_enter` per turn or per operation; who parses HTTP (picohttpparser) and how a PHP
  callback gets a request and returns a response; partial reads and writes, pipelining, keep-alive; how it frees
  memory, and what its tests cover; does it build against PHP 8.5; its license, last commit, open issues. The verdict
  `screen` needs a reason it could beat both the reference and our ring; else `no screen`.
- **Cases:** the image refuses to build if liburing's version is under 2.8; the server's 42/42.

## Scope 4: the app on an io_uring ring

- **Seams:** new `lab/servers/ring-server.php` (the ring loop, from the spike's `UringRing`, generalized to the app's
  connections), `lab/app/server.php` (`APP_RING=1` picks it), `lab/realistic.sh` and `lab/steplab.sh`
  (`--seccomp-unconfined`, passed to the server's container only), `lab/stress.sh` (a `--path` template so it can
  stress `GET /posts/{id}` and check each response's `"id"` against its request's), `lab/check.sh`.
- **What the loop does, as the spike's:** multishot accept into direct descriptors, multishot receive from a provided
  buffer ring, one send per response from a pooled slot (a response longer than a slot takes a slot sized for it),
  a short send resubmitted from where it stopped, a request split over several receives assembled before parsing,
  pipelined requests answered in order, `Connection: close` honoured, a closed peer freeing its slot, one
  `io_uring_enter` per turn. The handlers are the app's (`lab/app/app.php`), called as the DIY server calls them. The
  parser is copied into the ring's connection class, as the spike did, not shared: `DiyConnection` reads a PHP stream
  and its `parse()` is private, and `APP_RING` unset must stay byte for byte. `APP_GROUP_COMMIT` (a handler returning
  a `Closure`) is refused with `APP_RING`.
- **Telemetry:** with `APP_TELEMETRY=1` the `ring:` line a second (turns, requests, requests per turn, sends short,
  slots in use), as the spike printed.
- **Cases:** a request split at every byte boundary of its first 64 bytes; 16 pipelined requests in one packet; a
  response of the feed's largest size; a peer that closes mid-response; a full send pool (the loop waits, never
  drops); a receive buffer pool that runs dry (the kernel's `ENOBUFS` on the multishot receive: re-armed after
  buffers return).

## Scope 5: three rings, the close past capacity, the fallback

- **Seams:** `lab/servers/ring-server.php` (`APP_RINGS=<n>`, default 1; `APP_SOFT_CONN_LIMIT` counted over all rings;
  the boot-time probe and the fallback to `lab/servers/diy-server.php`), `lab/realistic.sh` and `lab/steplab.sh`
  (`--server-nofile`, D116), `lab/check.sh`.
- **Several rings:** each with its own table sized by `RLIMIT_NOFILE`, all accepting from one listening socket; the
  loop blocks on the ring that had completions in the last turn and enters the others when their `IORING_SQ_TASKRUN`
  flag shows work or they have SQEs queued (D121); a turn's cost with 3 rings and each ring's requests per turn are read in the smoke (`ring:`
  lines) so scope 6 knows what a ring costs.
- **The fallback:** any step of the ring's init refused (setup, the file table, the buffer ring; `EPERM` under
  Docker's default filter, `ENOSYS`, `io_uring_disabled`, `EINVAL` on an older kernel): one boot line (`loop: epoll
  (io_uring refused: <step> <errno>)`), then the DIY loop with S1-b's two processes as today. Never a silent switch
  mid-run.
- **Cases:** 150,000 held across 3 rings; a soft limit of 100 in a check: the 101st response closes; the fallback's
  boot line and its 42/42.

## Scope 6: phase 8's levers on x86

- **Before the launch:** the predictions below copied unchanged into the folder and committed; Q24 and Q27 answered;
  the policy written; Jacob's go (🔴); `launch.sh --dry-run` clean. If Q27 = A, the factory's `aws/bootstrap.sh`
  installs the 6.8 GA kernel and sets `GRUB_DEFAULT` to it (GRUB boots the newest otherwise), and the box's proofs
  print `uname -r`.
- **The session (Q24 = A), in order:** launch; the lab set up as 5b's (`aws/bootstrap.sh`, the images built on the
  box: `8.5`, `8.5-sqlite` with its PGO training on that CPU, `8.5-uring`); the reference's A/A (5 pairs); then D109's
  steps in D109's order, each with its stop: Swoole's pair, the feed micro on both SQLites and the tuned SQLite's
  pair if the micro calls for it, the ring's pair (D116's shape; 2 more if it beats the floor), the winners together; every run
  without the seccomp filter, its `loop:` line checked (D117);
  results copied back (raw files to the factory's `lab/`); `teardown.sh`, then `--verify`.
- **If Q24 = B:** the same series on the Mac's quiet VM, `--floor-from` its own A/A; arm64 numbers, said so. The
  score boxes are 1-vCPU `c5.large`s, where the step lab can't run, so the x86 reading is then the score session's
  per-box µs/req only.
- **The README:** the predictions, the plan of the runs, the machine, what differed, the tables (`summarize.sh`), the
  choice per lever with its bench estimate, the predictions judged. The bench estimate of a lever scales phase 7's
  by the pair: `86,800 × the reference's µs/req ÷ the lever's` (the `5.12 million / µs` rule reads the score box's µs
  at the bench's shape, not the lab's at 7,500 req/s).

## Scope 7: the submission

- **Seams:** `submissions/php-Gcob/` only (`loop.php` or a new `ring.php`, `server.php`, `workers.php`, `install.sh`
  if the tuned SQLite won, `README.md`), `lab/check.sh` (`check_submission`).
- **What ships:** what scope 6 chose, no switch. The ring's copy follows `lab/servers/ring-server.php` at the commit
  scope 6 measured; the README says which.
- **Skipped** when scope 6 chose nothing: the run goes to scope 8 with phase 7's submission alone.

## Scope 8: the search on two load generators

- **Seams:** `lab/score/search.sh`, `lab/score/run-k6.sh`, `lab/score/analyze.jq`, `lab/score/smoke.sh`,
  `lab/score/ctl-local.sh`, `lab/check.sh` (`check_score`); the factory's `aws/phase-8/launch.sh` (from phase 7's).
- **Two halves:** each k6 runs the unchanged `load.js` with `VUS` set to half the users (the odd one to the first),
  its own source addresses (2 each), the same `DURATION`; both start in the same second (the driver starts them
  together); the plateau is the seconds both report their target; a run passes when both exit 0; a half over D104's
  line voids the run only if the run fails (D105). µs/req is the service's CPU over the plateau divided by both
  halves' plateau requests.
- **The fixed-load pair and the finer steps** of D114, and the two new walls.
- **The kernel (Q27):** if A, `lab/score/server-setup.sh --shape` installs the 6.8 GA kernel and sets `GRUB_DEFAULT`
  beside its `mem=2G` drop-in (one reboot for both); `--check` and the box's facts print `uname -r` either way.

## Scope 9: the score session

- **Before the launch:** the predictions copied and committed; Jacob's go and port 80 (🔴); `--dry-run` clean.
- **The session:** D98's order for each server box, both set up in parallel; the 42 checks on each, the `loop:` line
  read; both boxes' CPU model (and Q28's check); both warm-ups, the fixed-load probes A B B A across the two servers,
  then phase 8's search, then phase 7's (D114); results copied back; teardown and `--verify`. Stop at 3 h 30 of the
  boxes' life.
- **The README:** as phase 7's, both servers side by side, each wall named or the reason it isn't.

## Scope 10: the README's results

- **Seams:** `submissions/php-Gcob/README.md` ("Results") only. The paragraph of D103 with the new number, the boxes,
  "not the bench's score", the link; the old number kept one line, as history.

## Predictions (D5)

Written by the project manager on 2026-11-26 at 15:10, before any phase 8 run, and revised at 15:26 after the plan
review, still before any run: prediction 5's range (5b's 57.75), prediction 8 (the knob is out). x86 numbers on AWS `c5.2xlarge` (the
lab session, Q24 = A) or `c5.large` (the score), PHP 8.5, the reference phase 7's submission, unless a line says
otherwise.

1. **The single-post plan:** no `ENABLE_STAT4`, `REPREPARE` 0 for both forms, the same plan (the primary key's
   search): `closed`, no timing.
2. **The tuned SQLite's build:** the training runs 20,000 to 100,000 statements in under 2 minutes; the image builds in
   under 10 minutes on one Mac core.
3. **ext-mrloop's audit:** `no screen`: one fd per connection (so the fd wall stays), one maintainer, no PHP 8.5 in
   its CI.
4. **The ring on the Mac (smokes):** 42/42, stress 0 mismatches, 150,000 connections on 3 rings with under 100 fds.
5. **The reference's A/A floor on x86** at 7,500 req/s: 1.0 to 3.0 µs/req; the reference at 54 to 60 µs/req (5b's
   S1-b read 57.75 on the same box type, with telemetry on; the submission has none).
6. **Swoole's `uring_socket`:** one pair, **+5 to +20 µs/req over the reference** (the Swoole entries cost 10 to 17 %
   more than our server on the Mac; io_uring under 5 % of that back): stops there.
7. **The ring:** **−6 to −12 µs/req** against the reference (−11 to −22 %), beyond the floor in 3 pairs: S1-b's
   second process gone (+7.44 on the Xeon in 5b) and 1 to 4 µs of syscalls; chosen.
8. **The batching knob:** out (D120), no prediction.
9. **The tuned SQLite:** the feed micro 8 to 18 % under Ubuntu's 3.45.1; the pair −1 to −5 µs/req; beyond the floor
   with about 50 % confidence.
10. **The score session, phase 7's server:** at 101,000 users 52 to 56 µs/req (phase 7: 53.6); its ceiling with a
    load that doesn't bind **138,000 to 145,000 held**, its wall the CPU (service median second over 88 %) or the
    kernel's TCP memory.
11. **Phase 8's server (the ring):** at 101,000 users 42 to 49 µs/req; its ceiling **142,000 to 160,000 held**, its
    wall the kernel's TCP memory or the packets-a-second allowance before its CPU (the 2 GiB box logged `TCP: out of
    memory` at 142,000 in phase 7, with either server).
12. **The bench estimates** (5.12 million / µs): phase 7's about 86,000 (unchanged), phase 8's **100,000 to 120,000**.
13. **Cost and time:** the lab session 2 to 3 h, under 2 USD; the score session 3 to 4 h with 4 boxes, under 10 USD.

## Out of scope

- **Our own C** (a glue, the B-tree read, a C ring): D2, D76. The hybrid entry is decided after this phase.
- **OpenSwoole's POLL_ADD reactor and php-uring:** D84, unless the mrloop audit finds a reason.
- **A third worker process:** the ring holds the connections in one process (notes.md 2026-11-25 10:05).
- **Kernel tuning on the server box** (`tcp_mem`, the backlog): rule 11; the TCP memory wall is named, not moved.
- **The bench's own box, DigitalOcean:** D89; the estimate stays CPU-scaled (D96, D106).
- **The PR to the challenge, any `gh` command:** phase 9, with Jacob.
