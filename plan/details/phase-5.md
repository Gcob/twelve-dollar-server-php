# Phase 5: step lab (5a: the fd wall, the io_uring spike, SQLite, the write, durability)

**Done when:** S1 has a chosen way past the fd wall, with its cost per request measured and a run that serves more
users than one process has fds; the io_uring spike has its answer (a no-op server on an FFI ring holding 60,000
connections with no fd of its own each, more than 65,535 on two rings if the stretch is reached, or the step where it
stopped and why, D56); S6, S8 and S9 each have a chosen variant with its µs of
CPU per request (median of its runs) against the skeleton's, and its profile (D49); the chosen variants together have
a new µs/req, profile and held rate. The predictions below were written before any measurement (D5). Then the run
stops (D12): phase 5b takes the rest of the steps (D50).

**Plan review:** [PLAN-2026-11-22-2110.md](../reviews/PLAN-2026-11-22-2110.md), NOT_OK (2 🔴, 4 🟠, 11 🟡). Its six
questions were settled by the project manager with the reviewer's own picks (D51 and D53 revised, D56 to D59), and
its minor points are folded in below. Predictions 5, 8 and 10 were revised at 21:12, still before any measurement.
Delta: [PLAN-2026-11-22-2116-delta.md](../reviews/PLAN-2026-11-22-2116-delta.md), NOT_OK (2 🟠: the floor's
definition, nothing resumes a paused connection), settled with the reviewer's picks (D51, D59 revised); its 3 🟡
folded in. Delta 2: [PLAN-2026-11-22-2120-delta.md](../reviews/PLAN-2026-11-22-2120-delta.md), OK (1 🟡, folded into
scope 10).

**Where (D14):** code on branch `phase-5-claude`, in its worktree. `plan/` stays on `main`. The factory's working files
(`run.md`, `state/`, `reviews/`) are private (D48).

**Why this shape:** the baseline (phase 4) puts 51.7 % of the CPU in SQLite, 20.2 % in the write, 9.7 % in JSON and
30 % in the kernel, at 27.15 µs per request. But one process holds about 65,500 connections, so the real bench caps
it near 71,000 users whatever the CPU: every CPU gain is worth zero users until S1 is solved. S1 comes first, with the
io_uring spike next to it (it is the only way past the wall without reconnects), then the profile's top: S6 (the feed
query is 38.8 % of all the samples), S8 and S9 (D30's two variants). The lower steps (S7, S2, the loop, S4, S3, S5)
and the PHP version are phase 5b.

## Decisions of this phase

From Jacob (D47 to D49) and the project manager (D50 to D59), in [decisions.md](../decisions.md):

- **D49, how a variant is judged:** µs of CPU per request (median of its runs) and its profile; the per-second p99
  beside it when a variant moves latency without moving CPU (S9). The held rate only at the end, on the chosen
  variants together.
- **D50, the split:** this run is 5a (S1, the spike, a syscall count, S6, S8, S9, the chosen variants together, the
  x86 calibration if Jacob says go). 5b: S7, S2, the event loop, S4, S3, S5, the PHP version, the FFI SQLite driver.
- **D51, the A/B method (revised after the plan review):** variants run interleaved as fresh 60 s realistic runs,
  60,000 idle connections, no per-second probes, telemetry off, at one offered rate per step. An A/A calibration first
  (the skeleton against itself) gives the noise and the smallest difference the method sees (its floor). A variant's
  number is the median of its runs; the verdict reads the paired differences (each run against the reference's run of
  the same round): "beyond the noise" when every pair has the same sign and the median difference passes the floor. A
  variant predicted under the floor is judged on its micro bench or its syscall count, the macro only checking that it
  costs nothing.
- **D52, the io_uring gate:** the bench starts a submission with systemd, not Docker, and scores io_uring entries;
  the lab runs io_uring servers with Docker's seccomp filter off.
- **D53, S1-d's shape (revised):** a soft limit on open connections, `Connection: close` on a response built while
  more than `n` are open, never an idle connection closed. Separately, at the hard limit accepts pause instead of
  spinning, in every server built on the DIY loop (a fix, not a variant). S1-d's runs set `n` to the idle count.
- **D54, the syscall count:** `strace -c` attached from a sidecar container to a fixed low-rate run: counts per
  request, never a time.
- **D56, the spike's target:** one ring, 60,000 connections held with the process's own fds under 100 (a ring's
  fixed-file table can't pass `RLIMIT_NOFILE`); a second ring past 65,535 is a stretch goal in the same time box
  (Q15).
- **D57, smokes at the real shape:** scope 1 smokes the runner at 60,000 idle and 24,000 req/s, scope 2 the churn at
  the fd wall's shape for 5 minutes, both with the TIME_WAITs counted before and after.
- **D58, group commit's turn:** with `APP_GROUP_COMMIT=1` the server drives the loop with `EventBase::loop(LOOP_ONCE)`
  and flushes after each call; unset, `dispatch()` as today.
- **D59, pipelining behind a queued write:** a connection with a write waiting for the flush stops parsing until its
  response is in `wbuf`; responses stay in request order.
- **D55, the x86 calibration:** one `c5.2xlarge` on Jacob's AWS account running the lab as the Mac does, only after
  his go; the policy waits in the factory.

## Scopes

| #   | Commit                                                                      | Done when |
|-----|-----------------------------------------------------------------------------|-----------|
| 1   | `feat(lab): the step lab's A/B runner and a syscall count`                  | `bash lab/steplab.sh` prints one row per run (interleaved order, valid, µs/req, p99), one per variant (median µs/req, min to max, median p99, paired differences) and a verdict per variant (D51); the verdict logic passes its fixture cases (identical, clearly beyond, mixed signs, under the floor) on recorded JSON files; one live pair at the real shape (60,000 idle, 24,000 req/s, 60 s) runs valid with the TIME_WAITs counted before each run; `bash lab/syscalls.sh` on the skeleton at 2,000 req/s prints syscalls per request by name and in total; `lab/check.sh` all `ok` |
| 2   | `feat(app): Connection: close past a soft connection limit`                 | with `APP_SOFT_CONN_LIMIT=2`, a check opens 3 keep-alive connections: the third's response carries `Connection: close` and the server closes it after the write, the first two stay open; `challenge-test.sh --env APP_SOFT_CONN_LIMIT=0` prints `passed=42 failed=0`; a server with 256 fds and a soft limit of 200 holds 200 idle and serves 2,000 new connections one after the other with no error; at the hard limit accepts pause and resume (a check: the pauses counted in telemetry, no CPU spin); a 5-minute realistic smoke at the fd wall's shape (64,000 idle, `APP_SOFT_CONN_LIMIT=64000`, 12,000 req/s, `s = 0.04`) holds the 64,000 to the end, 0 k6 errors, 0 accept pauses, the close count within 1 % of k6's requests, the TIME_WAITs before and after recorded; `lab/check.sh` all `ok` |
| 3   | `feat(app): several processes on SO_REUSEPORT`                              | with `APP_WORKERS=2`, `challenge-test.sh --env APP_WORKERS=2` prints `passed=42 failed=0`, a check shows both processes answered, and a realistic smoke is valid; with the variable unset the server is the one process of phase 4; `lab/check.sh` all `ok` |
| 4   | `feat(lab): FFI micro benches for an io_uring loop`                         | `bash lab/micro.sh lab/micro/benches/ffi.php --images 8.5 --jit both` prints ns per op for every case of the list below, each case checked; a first reading (busy VM allowed, labelled so) against the stop rule of step 2, written in the scope's hand-back |
| 5   | `feat(lab): a no-op server on an io_uring ring through FFI`                 | `conformance.sh` all `ok` on the ring server; the stress client sends 2 million requests with unique ids over 1,000 connections and finds 0 mismatches; `conns.sh` holds 60,000 connections on one ring with the server's own fds under 100 (stretch: 80,000 on 2 rings, D56); `macro.sh` gives its µs/req on `/noop` at 7,000 req/s; or, within the time box, a stop with the step that failed and why |
| 6   | `docs(lab): S1 and the io_uring spike, measured`                            | `lab/results/<date>-s1-fd-wall/README.md` holds the predictions (copied unchanged), the syscall counts, S1-a against S1-d (every request reconnecting) against S1-b at 12,000 req/s, the cost of one reconnect, the fd-wall run with and without S1-d, the FFI micro and the ring's no-op against DIY, each prediction marked, the chosen S1 variant; every counted run `other_containers: 0`; `summarize.sh` regenerates its tables |
| 7   | `feat(app): feed query, fetch and pragma variants`                          | each variant (`APP_FEED_SQL`, `APP_FETCH`, the pragmas) passes `challenge-test.sh` 42/42 (the golden feed byte for byte); `lab/micro/benches/feed.php` prints ns per feed for each on a fresh seed copy, with its `EXPLAIN QUERY PLAN` saved; `lab/check.sh` all `ok` |
| 8   | `feat(app): response write and syscall variants`                            | each variant (`APP_IO` and the others the count of scope 1 points to) passes 42/42 (`challenge-test.sh --env`), the DIY parser and partial-write checks, and `syscalls.sh` prints its count per request next to the reference's; `lab/check.sh` all `ok` |
| 9   | `feat(app): group commit per loop turn and a background checkpointer`       | with `APP_GROUP_COMMIT=1` and with `APP_CHECKPOINTER=<ms>`, 42/42; a check sends two writes in one loop turn and sees one commit and both responses after it; a pipelined like then feed on one connection come back in order, and two pipelined likes both get answered; a write whose response was sent is still there after `kill -9` and a reopen; a 2-minute realistic smoke at 24,000 req/s with the checkpointer at 1,000 ms keeps the WAL's `mxFrame` under 2 times the most frames written between two checkpoints, with the server's autocheckpoint off; `lab/check.sh` all `ok` |
| 10  | `docs(lab): S6, S8 and S9, measured`                                        | `lab/results/<date>-cpu-steps/README.md`: predictions copied unchanged, each variant against the reference at 24,000 req/s (D51), its µs/req median and spread, p99 (S9: per-second p99 and stalled seconds), the profile of each chosen variant, each prediction marked, the chosen variant per step; `summarize.sh` regenerates its tables |
| 11  | `docs(lab): the chosen variants together`                                   | `lab/results/<date>-step-lab-together/README.md`: the chosen variants as one configuration, its µs/req (median of 3 holds of 5 minutes), profile and held rate at `s = 0.02`, against the baseline, step by step; `summarize.sh` regenerates its tables |
| 12  | `docs(lab): the x86 calibration on EC2`                                     | only with Jacob's go (D55): a CPU layout for an 8-vCPU host in `lab/lib.sh`, the baseline's skeleton and the chosen configuration on a `c5.2xlarge`, server on one vCPU, 3 runs each at a fixed rate, µs/req and the x86 factor against the Mac; the instance terminated and the policy removed. Without his go by then: skipped, moved to phase 7 |

Vertical slices: scope 1 is the instrument every later scope uses. Scopes 2 to 5 are S1's three variants (S1-d, S1-b,
the ring), each behind a switch with its own checks; scope 6 measures them together on a quiet VM. Scopes 7 to 9 are
the CPU steps' variants, scope 10 measures them. Scope 11 puts the winners together and gives the phase's held rate
(D49). Scope 12 is the only one that leaves the Mac.

**Quiet VM (D15):** scopes 6, 10, 11 and 12 measure; the others don't need a quiet VM (code, checks, smoke runs, a
first micro reading labelled as such). The VM is quiet from 2026-11-22 20:55 until Jacob's containers come back the
next morning (the planning session warns first: the run in flight finishes, nothing new starts). If scope 6 is ready
while other containers run, the run goes on with scopes 7 to 9 and comes back to 6 and 10 when the VM is quiet; the
project manager asks the planning session (a 🔴 item in 👉).

**The lab's suite:** `lab/check.sh`. Each code scope adds its smoke checks; a long harness gets a smoke at its real
shape (15 to 20 minutes) in the scope that builds it, not in the measuring scope (phase 4's retro).

## Shared rules for every scope

Phases 2 to 4's rules hold ([phase-4.md](phase-4.md), "Shared rules"): limits, the CPU layout in `lab/lib.sh`,
pinned versions with sha256, `reference/` read-only, `other_containers` in every JSON, memory as `Pss`, `Pss_Anon` and
`memory.current`, rule 5 (every request does its own reads), every write committed before its response, no image
build during a measurement. New for phase 5:

- **A variant is a switch, the default is the skeleton:** every variant is an `APP_*` environment variable (or a
  server file, for the ring). Unset, the server behaves byte for byte as phase 4's, so the baseline stays
  reproducible and scope 11 is a set of switches.
- **Correctness before speed:** a variant that fails one of the 42 checks is out, whatever its µs.
- **The public guard (D48):** results record counts, never names; raw diagnostics about the machine (container lists,
  host details, `strace` output with paths) go to the factory's `lab/`, never to `lab/results/`. `lab/check.sh` runs
  the guard; a push it refuses is fixed, never bypassed.
- **Predictions are copied unchanged** into each results README before its first measured run (D5).
- **The DIY loop is shared** with the bake-off's server (`lab/servers/bake-diy.php`): a change to `DiyServer` or
  `DiyConnection` keeps the bake-off's checks green and its bytes unchanged when no switch is set.
- **TIME_WAITs:** every runner that churns connections counts the TIME_WAIT sockets on k6's source addresses before
  each run and waits for them to drain under a threshold, as phase 4's runner logged them. The VM's ephemeral port
  range is 55000 to 65535: about 10,500 ports per k6 source address.

## Scope 1: the A/B runner and the syscall count

- **Seams:** `lab/steplab.sh`, `lab/syscalls.sh`, checks in `lab/check.sh`.
- **`steplab.sh --image <v> --rate <req/s> --think-scale <s> --idle <n> --seconds <s> --pairs <n> --variant
  <name>=<K=V,...> [--variant ...] [--server-variant <name>=<file>] [--label] [--out <dir>]`:** the first variant is
  the reference. It runs `realistic.sh --hold` for each variant in turn, interleaved (A B C A B C ...), each a fresh
  run (seed copy, server, idle connections), `--no-series`, `APP_TELEMETRY=0` unless a variant sets it, a 60 s warm-up
  at a tenth of the rate like the baseline's (D51). Before each run it counts the TIME_WAITs on k6's addresses and
  waits for them to drain (D57). It writes each run's JSON and a summary JSON, and prints the table and the verdict
  (D51): per variant, its median µs/req, the paired differences against the reference's run of the same round, their
  median, and "beyond the noise" when every pair has the same sign and the median difference passes `--floor <µs>`
  (the A/A calibration's floor, given by the measuring scope; without it, the verdict prints "no floor: not judged").
  Invalid runs are shown, not counted; a round with an invalid run has no pair; a variant with fewer than 2 pairs has
  no verdict. The verdict is a function of the run JSONs, so a `summarize.sh` rebuilds it.
- **`syscalls.sh --image <v> --rate <req/s> [--env K=V]... [--seconds 20] [--server <file>]`:** a realistic hold at a
  low rate (2,000 req/s, no idle connections), and during its plateau a sidecar container (the server's pid
  namespace, `SYS_PTRACE`, the probe CPUs) runs `strace -c -f -p <pid>` for `--seconds`; the count by syscall divided
  by the requests the aggregator counted in the same window. The table: syscall, calls, calls per request, errors
  (EAGAIN shows there). The time column of `strace -c` is dropped: strace slows the server, so only counts are kept
  (D54). `strace` comes from a pinned image (or the lab image's apt, pinned by version); its raw output stays out of
  `lab/results/`. If `strace` can't attach under Docker Desktop, the script says so and exits non-zero; the
  developer reports it, and the project manager decides.
- **Cases:** the verdict on recorded run JSONs (fixtures, deterministic): identical variants give "within", a variant
  1 ms slower in every pair "beyond", mixed signs "within", a difference under the floor "within"; one live pair at the
  real shape (60,000 idle, 24,000 req/s, 60 s; D57), valid, with the TIME_WAITs logged; a short live run in
  `check.sh` checks only the table's shape; the count's total per request is positive and its write-family count per
  request is near 1 on the skeleton (one response per request); the containers are removed after a failure.
- **The A/A calibration** itself (5 pairs of the skeleton against itself) is a measurement: scope 6 runs it on the
  quiet VM, and its floor serves scopes 6 and 10.

## Scope 2: S1-d, `Connection: close` past a soft limit (D53)

- **Seams:** the DIY server (`lab/servers/diy-server.php`, `diy-connection.php`), `lab/app/server.php`, checks.
- **Behaviour:** `APP_SOFT_CONN_LIMIT=<n>` (unset: off). The server counts its open client connections. When a
  response is built while the count is over `n`, it carries `Connection: close`, and the server closes the
  connection once the response is written (half-close after the last byte, then close; no reset that could lose the
  response). A connection that sits idle is never closed by the server (S1-c scored 0, [prior-art.md](prior-art.md)).
  Under the limit nothing changes (keep-alive, phase 4's bytes). "Over `n`" is strict: with `n` connections open, the
  `n`-th keeps alive and the `n + 1`-th gets the close, so a run with `n` equal to its idle count keeps every idle
  connection and closes every k6 connection after its response (D53; a check pins it). `n = 0` closes after every
  response (the challenge's tests run that way).
- **The hard limit:** when `accept` fails for lack of fds (`EMFILE`, `ENFILE`), the listening event is paused (no
  busy loop) and resumed when a connection closes; the clients wait in the backlog. Printed once on stderr. This one
  applies with or without the soft limit, to every server on the DIY loop (D53): a fix of today's busy loop.
- **The realistic mode with S1-d:** D39's VU cap counts the server's free fds; with a soft limit set, the cap comes
  from k6's memory and its local ports instead (k6 reconnects after every response past the limit: 4 local addresses
  give it about 4 × 10,500 ports, the VM's range being 55000 to 65535). The counts that tell S1-d worked come from the
  server's telemetry line (`APP_TELEMETRY=1`): `Connection: close` responses, accept pauses, the most client
  connections open at once; `realistic.sh` sums them into the JSON (the server is removed with `docker rm -f`, so
  nothing printed at exit would be read). The fd peak needs the sampler (series on), so the fd-wall runs keep the
  probes.
- **Seams added by the review:** `lab/challenge-test.sh --env K=V` (repeatable, passed to the server; later scopes use
  it), and `lab/realistic.sh` (the VU cap with a soft limit, the telemetry sums, the TIME_WAIT count).
- **Cases:** soft limit 2 with 3 connections (above); `n` equal to the idle count keeps every idle connection (a
  small version: 50 idle, `n = 50`, then 20 new connections each closed after its response, the 50 still open);
  `n = 0` passes the 42 checks; 256 fds, soft 200: 200 idle held
  and 2,000 sequential new connections served, no error; hard limit: with 64 fds and no soft limit, 80 clients
  connect, 64 minus the server's own are served, the rest wait and are served as the first close; the 5-minute
  realistic smoke of the table above at the fd wall's shape (D57), with the TIME_WAITs before and after.

## Scope 3: S1-b, several processes

- **Seams:** `lab/app/server.php`, the DIY server, checks.
- **Behaviour:** `APP_WORKERS=<n>` (unset or 1: one process, as today). The parent opens nothing shared but the
  config: it forks `n` children (`pcntl_fork`); each child opens its own listener with `SO_REUSEPORT` on the same
  port, its own `EventBase` and its own SQLite connection (opened after the fork, never inherited), and serves. The
  parent waits; a child that dies makes the parent exit non-zero (no restart loop: the bench must see a crash).
  Telemetry, when on, prints one line per child per second with its pid. All the processes live in the server's
  cgroup (1 CPU), so its `usage_usec` counts them all.
- **SQLite:** each child is a WAL reader and writer on the same file, `busy_timeout` as today. A write that waits for
  the other child's lock waits inside its own request (rule 6: still committed before its response).
- **Cases:** 42/42 with 2 workers; a check that counts distinct pids answering over 200 requests on 200 connections
  (both seen); a realistic smoke, valid; unset: the same boot lines as phase 4.

## Scope 4: the FFI micro benches (the spike's step 2)

- **Seam:** `lab/micro/benches/ffi.php`, run by `lab/micro.sh` (FFI on in the images; `ffi.enable` set by the bench's
  run if needed, recorded).
- **Cases, ns per op, each checked (the result compared with the expected value):** `syscall(SYS_getpid)` through FFI
  against `posix_getpid()`; one `CData` field write and read of a struct like an SQE; `FFI::memcpy` of 64 B, 200 B and
  5 KB from a PHP string into C memory; `FFI::string` of 16 B, 200 B and 5 KB; `pack()` of a 64-byte SQE and
  `unpack()` of a 16-byte CQE; a batch of 32 SQEs packed in one string and copied in one `memcpy`; and, as the cost
  it would save, one `fread` and one `fwrite` of 200 B on a non-blocking socket pair from PHP.
- **The stop rule (notes 18:25):** a request's FFI budget on the ring (its share of one `io_uring_enter` per turn,
  one SQE written, one or two CQEs read, the request bytes copied in and the response copied out) against the
  syscalls it removes (scope 1's count: the `read` and `write` per request, and its share of `epoll_wait`). If the
  budget costs more, the spike stops here, and that is its result.
- **Then:** the first reading goes in the developer's hand-back (busy VM, labelled); scope 6 measures it on a quiet
  VM for the record.

## Scope 5: a no-op server on an io_uring ring (the spike's step 3)

- **Starts only if** scope 4's first reading passes the stop rule; otherwise the project manager skips it, and scope
  6 records why.
- **Seams:** `lab/servers/uring-noop.php` (its FFI declarations in a header file next to it), a stress client
  (`lab/conformance/` or a new one), `conformance.sh`, `conns.sh`, `macro.sh` (each takes the server file), a
  `--seccomp-unconfined` option in `lab/lib.sh`'s server start, used only by this server (D52).
- **Requirements (notes 18:25, the memory ordering):** no `SQPOLL`; `IORING_SETUP_SINGLE_ISSUER` and
  `IORING_SETUP_DEFER_TASKRUN` (the kernel touches the queues only inside our own `io_uring_enter`, on our thread);
  `IORING_SETUP_SUBMIT_ALL`; multishot accept into direct descriptors (a sparse fixed-file table with
  `IORING_FILE_INDEX_ALLOC`, as large as `RLIMIT_NOFILE` allows: the kernel refuses a larger one with `EMFILE`), so
  connections take no fd of the process; receive into a provided buffer ring (multishot
  receive) or per-connection buffers, the developer's choice with its memory per connection recorded; send of the
  fixed `/noop` response; close of a direct descriptor. One `io_uring_enter` per turn of the loop, submitting what the
  turn built and waiting for at least one completion; SQEs packed with `pack()` and copied with one `FFI::memcpy` per
  turn; CQEs read with one `FFI::string` and `unpack()` per turn (notes 18:25). The tails and heads are read and
  written only around `io_uring_enter`, the way the design rules the race out.
- **The stress test:** each request carries a unique id (`GET /noop?id=<n>` or a header) and the server echoes it in
  its body; 2 million requests over 1,000 connections, pipelined and not; 0 mismatches, 0 lost. The server stays
  pinned to its one CPU like the bench's (which has one vCPU): the test covers the loop's bookkeeping (`user_data`,
  buffer ids, connection slots), not cross-core reordering, which the design rules out (no SQPOLL, DEFER_TASKRUN).
  The `/noop` echo is the only change to the response; `conformance.sh`'s cases stay as they are.
- **Direct descriptors (D56):** `conns.sh` with the ring server, nofile 65,535, holds 60,000 idle connections on one
  ring, each answered, while the server's own fds (`/proc/<pid>/fd`) stay under 100: the connections take no fd of the
  process. **Stretch, same time box:** a second ring with its own table, 80,000 connections over the two; the loop
  blocks on one ring with a timed wait and enters the other when its `IORING_SQ_TASKRUN` flag shows pending work (both
  rings set up with `IORING_SETUP_TASKRUN_FLAG`; the reference's `c-iouring-PROGABBOMALA`, `src/net.h`, does this;
  without the flag and the timeout, ring B can stall). Reached or not, the hand-back says which.
- **Time box:** the developer stops at the first of: the Done-when met, three failed tries at the same step, or about
  3 hours of work. A stop commits what runs (the smoke and the step reached) with the reason in the server's header
  comment and the hand-back; scope 6 records it as the spike's result.

## Scope 6: S1 and the spike, measured

- **Before any run:** copy the Predictions section below into `lab/results/<date>-s1-fd-wall/README.md`, unchanged,
  commit nothing else first; `docker ps` shows only the lab's containers.
- **The syscall count:** `syscalls.sh` on the skeleton (keep-alive) and with `APP_SOFT_CONN_LIMIT=0`, at 2,000
  req/s: per request, by name. Only the load-independent counts (reads, writes, EAGAIN, accepts, closes) carry over to
  other rates; `epoll_wait` per request falls with the load.
- **The A/A calibration (D51):** 5 pairs of the skeleton against itself at 24,000 req/s (telemetry off, like the CPU
  steps' runs), then 5 at 12,000 with telemetry on (like the S1 runs it judges): the noise per run, the paired
  differences, and the floor for each rate: the largest absolute paired difference of its 5 A/A pairs.
- **S1 at 12,000 req/s** (`s = 0.02`, 60,000 idle, D51; 12,000 rather than the baseline's 24,000 so that every
  request reconnecting still fits in the CPU): the skeleton (S1-a), `APP_SOFT_CONN_LIMIT=60000` (S1-d: the 60,000
  idle fill the limit, so every k6 request reconnects, D53), `APP_WORKERS=2` (S1-b), 5 runs each interleaved,
  telemetry on for all three (the close count is how S1-d proves it fired). The cost of one
  reconnect is S1-d's median minus S1-a's; S1-b's cost is its difference.
- **The fd wall:** two realistic holds of 5 minutes at 12,000 req/s with 64,000 idle connections and k6's VUs on top,
  at `s = 0.04` so that 12,000 req/s takes about 4,500 VUs (more users than fds: about 68,500), `--vu-cap` raised,
  probes on (the fd peak): the skeleton (fails: k6 connection errors, or accepts refused) and S1-d with a soft limit of
  64,000 (passes, the server's fds never above 65,535). The users it serves at once against its fds.
- **What it means for the bench:** the share of requests that reconnect at 100,000, 150,000 and 200,000 users with a
  soft limit near 64,000 (each user's connection rotates with its think time), times the measured cost of a
  reconnect: the µs/req S1-d adds at each size.
- **The spike:** the FFI micro on 8.5, JIT on and off; the ring's no-op against DIY's at 7,000 req/s on `/noop`
  (`macro.sh`, 3 runs each, interleaved), its connections held and RSS per connection; or the step where it stopped.
- **The choice:** the S1 variant scope 11 uses, and why, in the README's last section.

## Scope 7: S6, the feed query and its neighbours

- **Seams:** `lab/app/app.php` (its boot reads the switches), `lab/micro/benches/feed.php`.
- **Variants:**
  - `APP_FEED_SQL=reference` (today's correlated count per post), `join` (`LEFT JOIN likes ... GROUP BY p.id` over the
    20 newest), `two-step` (the 20 posts with their authors, then their counts with one `IN (...)` of that request's own
    20 ids, merged in PHP: a request's own two statements, allowed by rule 5, D29);
  - `APP_FETCH=assoc|num` (`FETCH_NUM` with the column order fixed) and `fetchAll()` against `fetch()` in a loop;
  - the pragmas: `cache_size` and `mmap_size` larger and smaller than today's, `APP_PRAGMAS=<name>` presets; the
    developer keeps the set small (3 presets at most) and says why;
  - the post query (`GET /posts/:id`) with the same SQL switch, where it applies.
- **The micro bench:** a fresh seed copy, the feed query of each variant run as a loop of N, ns per feed, the
  database warm; the newest posts with a realistic number of likes; `EXPLAIN QUERY PLAN` of each saved next to it.
- **Cases:** 42/42 for each variant (the golden feed byte for byte); the micro bench's check compares each variant's
  rows with the reference's.

## Scope 8: S8, the write and the syscalls

- **Seams:** the DIY connection and server, `lab/app/app.php`'s response, checks.
- **Variants** (the count of scope 1 picks which are worth it, read on its load-independent counts: reads, writes,
  EAGAIN; the brief carries its table):
  - `APP_IO=streams` (today: PHP streams, `fread`, `fwrite`) against `sockets` (ext-sockets `socket_recv` and
    `socket_send` on the socket the stream wraps, or a server built on `socket_*` from the accept: the developer's
    choice, the parser untouched);
  - the read that returns nothing (`EAGAIN`) after a request, if the count shows one per request: not issued.
  (The prebuilt header prefix per status is already the skeleton's: not a variant.)
- **Cases:** 42/42, the DIY parser test and the partial-write test (D24) for each `APP_IO`; `syscalls.sh` per
  variant.

## Scope 9: S9, group commit per loop turn and a background checkpointer (D30)

- **Seams:** `lab/app/app.php` (the writes), the DIY server (an end-of-turn hook), `lab/app/server.php` (the
  checkpointer's process), checks.
- **Group commit (`APP_GROUP_COMMIT=1`):** a write's request queues its statement and its response instead of
  running it; at the end of the loop turn, one `BEGIN IMMEDIATE`, each write in its own `SAVEPOINT` (a failing write rolls back
  alone and gets its error response), `COMMIT`, then every queued response is sent. No timer delay: at low load a
  batch is one write. Telemetry counts commits and the batch sizes.
- **The end of a turn (D58):** libevent runs a timer added during a callback only after the next turn's I/O
  callbacks, so a zero-timeout timer would flush a turn late. With the switch on, the server drives the loop itself:
  `while (...) { $base->loop(EventBase::LOOP_ONCE); flush(); }`; unset, `dispatch()` as today. The cost of one PHP
  call per turn is measured with the variant.
- **Order (D59):** a connection with a write waiting for the flush stops parsing until that write's response is in
  `wbuf` (its later bytes stay in `rbuf`, reading pauses), so responses stay in request order. Reads on other
  connections are not delayed. **The flush resumes the connections it paused:** after the commit it appends their
  responses, parses what waits in their `rbuf` (which may queue new writes), re-arms their events, and loops (another
  `BEGIN … COMMIT`) until nothing is queued; only then does the loop go back to `LOOP_ONCE`. `DiyConnection` and
  `DiyServer` are in this scope's seams.
- **Background checkpointer (`APP_CHECKPOINTER=<ms>`):** the server sets `wal_autocheckpoint = 0`; a second process
  (forked at boot, its own connection) runs `PRAGMA wal_checkpoint(PASSIVE)` every `<ms>`. It lives in the server's
  cgroup. It dies with the server.
- **Cases:** 42/42 each and both together; two writes in one turn (two connections, sent before the turn runs):
  one commit, both responses after it, both rows there; a pipelined `POST /posts/:id/like` then `GET /feed` in one
  write on one connection: the like's response first; two pipelined likes on one connection: both answered, in
  order, with no stall; a write that fails inside the batch (a like on a missing post
  never gets there, `post_exists` answers 404 first, so the check uses a test-only hook that makes one statement
  throw) rolls back alone, gets its 500, and the other commits; `kill -9` after a 201 is received, reopen: the row is there; with the checkpointer, a
  2-minute realistic smoke at 24,000 req/s with the checkpointer at 1,000 ms keeps `mxFrame` (the sampler) under 2
  times the most frames written between two checkpoints, with the autocheckpoint off.

## Scope 10: S6, S8 and S9, measured

- **Before any run:** the predictions copied unchanged into `lab/results/<date>-cpu-steps/README.md`; quiet VM.
- **Method (D51):** `steplab.sh` at 24,000 req/s (`s = 0.02`, 60,000 idle, the baseline's rate), 3 pairs per variant
  (5 for S9's), interleaved with the reference, judged with scope 6's floor for 24,000: "beyond" when every pair has
  the same sign and the median paired difference is at least the floor. The micro numbers of
  scope 7 beside the macro ones.
- **S6:** the feed SQL variants, then the best with `APP_FETCH=num`, then the pragma presets on the best so far.
- **S8:** `APP_IO` and the other variants of scope 8, each alone against the reference.
- **S9:** group commit, the checkpointer, both. These change latency more than CPU (D49): their runs keep the
  aggregator's per-second series (stalled seconds, per-second p99) and the server's longest callback (telemetry on for
  both sides of these pairs): their noise may be wider than the 24,000 floor, measured with telemetry off, so
  the README says so next to S9's verdict, and D49 judges S9 on its p99 first.
- **The profile:** one profiled 60 s run of each step's chosen variant (Excimer, `--profile`), folded.
- **The choice:** per step, the chosen variant and why; a variant within the noise is not chosen unless it is simpler.

## Scope 11: the chosen variants together

- **Before any run:** the predictions copied unchanged into `lab/results/<date>-step-lab-together/README.md`.
- **Runs:** the chosen switches together (S1's included, at a soft limit that leaves the realistic mode's 60,000 idle
  and k6's VUs under it, so it doesn't fire: the realistic mode can't show the bench's churn, scope 6 priced it):
  the baseline's shape (phase 4, scope 5): a staircase from 18,000 at `s = 0.02`, 3 holds of 5 minutes at the highest
  passing rate, the profile. The held rate is a harness floor at `s = 0.02` (D47): the result is the µs/req.
- **The table:** each step, its variant, µs per request in the profile before and after; the users it maps to with
  🤝's formula on the Mac (arm64, not a score), next to the µs S1-d adds at 100,000, 150,000 and 200,000 users (scope
  6), so the users aren't read without the reconnects' cost.

## Scope 12: the x86 calibration (D55)

- **Only with Jacob's go** (🔴 item in 👉). The IAM policy waits in the factory (`aws/`), least privilege, tagged
  resources, removed at the end.
- **The machine:** one `c5.2xlarge` (Xeon, AVX-512; `m5.2xlarge` if no capacity), Ubuntu 24.04, Docker, the lab
  cloned at the branch's commit, the images built there, the seed built there. `lab/lib.sh` gets a CPU layout for an
  8-vCPU host (today's `4-11` for k6 doesn't exist there), picked by an env variable. The server pinned to one vCPU whose
  hyperthread sibling stays idle, k6 on the others: the same harness as the Mac. SSH open to Jacob's IP only. The
  instance's CPU model is recorded (`/proc/cpuinfo` model name only).
- **Runs:** `steplab.sh` with two variants, the baseline's skeleton and scope 11's configuration, 3 runs each at a
  fixed rate the Xeon holds (found with a short staircase), plus the same pair on the Mac at the same rate. The x86
  factor: µs/req on the Xeon over the Mac's.
- **The end:** the instance terminated, its volume deleted, the key pair and security group removed, the policy
  detached and deleted (by Jacob), checked with a `describe` that shows nothing tagged left.

## Predictions (D5)

Written by the project manager on 2026-11-22 at 20:55, before any phase 5 measurement, and revised at 21:12 after
the plan review, still before any measurement: prediction 5 counts the fd wall's users at `s = 0.04` (about 68,500,
not 69,000), prediction 8 holds 60,000 connections on one ring (a ring's table can't pass 65,535) with 80,000 on two as
a stretch, prediction 10 drops the prebuilt header prefix (the skeleton already has it). Arm64, Docker Desktop on an M3
Pro, quiet VM, PHP 8.5, the skeleton on the DIY loop, 1 CPU, unless a line says otherwise.

**What we start from:** the baseline: 27.15 µs/req at 24,000 req/s (`s = 0.02`, 60,000 idle, probes on); about 28.7
µs at 12,000 (the `s = 0.0286` staircase, probes on). The profile: S6 51.7 % (the feed's query 38.8 %), S8 20.2 %, S7
9.7 %, S2 8.0 %, the loop 6.5 %, the kernel 30.3 % of the CPU. DIY's `/noop` at 7,000 req/s: 21.88 µs.

**How they're judged:** a µs/req is the median of a variant's runs; a range holds if the measured value is inside it;
a difference is "beyond the noise" when every pair has the same sign and the median paired difference is at least the
A/A floor of its rate (D51).

1. **Syscalls per keep-alive request: 2 to 4 in total**, one read with data and one write per request, `epoll_wait`
   shared by several requests (under 0.5 per request at 2,000 req/s), no `epoll_ctl` per request; writes add 1 to 3
   (the WAL's `pwrite`, no `fsync` with `synchronous = NORMAL`). The kernel's 30 % is the TCP stack's work, not
   syscall entries.
2. **S1-a at 12,000 req/s, probes off: 25 to 30 µs/req.**
3. **One reconnect costs 8 to 20 µs of the server's CPU** (an accept, a close, the handshake and the teardown in the
   kernel, an event added and freed): S1-d with every request reconnecting at 12,000 req/s is 35 to 50 µs/req.
4. **S1-b with 2 processes costs 5 to 20 % more per request than S1-a** at 12,000 req/s (context switches between
   two loops on one CPU; each has its own SQLite connection), less than tzimpel's 27 %.
5. **The fd wall:** with 64,000 idle and k6's VUs on top (about 68,500 users at `s = 0.04`), the skeleton fails (k6
   connection errors or accepts paused) and S1-d passes with 0 errors, 0 accept pauses and the server's fds under
   65,535.
6. **At the bench's sizes, S1-d adds 2 to 8 µs per request at 100,000 users and 5 to 15 at 150,000**, so S1-d is
   chosen over S1-b.
7. **FFI micro:** an FFI call to `syscall(getpid)` costs 150 to 500 ns more than `posix_getpid()`; a `CData` field
   write 20 to 80 ns; `FFI::memcpy` and `FFI::string` of 200 B 50 to 200 ns, of 5 KB 150 to 600 ns; `pack()` of a 64-byte
   SQE 100 to 300 ns; the JIT changes none of them by more than 20 %. A PHP `fread` or `fwrite` of 200 B on a socket
   costs 1 to 3 µs. **The stop rule passes:** a request's FFI budget (about 1 µs) is under the two syscalls it removes.
8. **The ring's no-op server** holds 60,000 connections on one ring with its own fds under 100, passes the stress test
   with 0 mismatches, and costs 15 to 25 µs/req on `/noop` at 7,000 req/s (DIY: 21.88). The second ring (80,000
   connections) is not reached inside the time box.
9. **S6, the feed:** `two-step` is the fastest SQL, 10 to 30 % under the reference's ns per feed in the micro bench;
   `join` is slower than the reference (it groups the newest posts' likes before the limit applies, unless SQLite
   pushes the limit down); `FETCH_NUM` saves under 5 % of a feed; no pragma preset moves µs/req beyond the noise (the
   hot set fits the cache already). The chosen S6 saves 1 to 4 µs per request (4 to 15 %).
10. **S8:** `APP_IO=sockets` saves 0.5 to 2 µs per request, under the A/A floor, so it is judged on its syscall count
    and its micro cost, and the macro shows it costs nothing.
11. **S9:** group commit changes µs/req by 0 to −3 % (writes are 8 % of requests; batches of 1 to 3 at 24,000 req/s)
    and the p99 within the noise; the background checkpointer changes µs/req within the noise and lowers the
    per-second maximum of the longest callback, but not the stalled seconds (they are outside the server, Q10).
12. **Together:** the chosen variants cost 21 to 25 µs/req at 24,000 req/s (8 to 22 % under 27.15), the held rate at
    `s = 0.02` stays the harness's floor (about 23,400 req/s, D47), and S6 is still the largest step of the profile.
13. **x86 (if run):** a request costs 1.8 to 3 times more on the `c5.2xlarge`'s Xeon than on the M3.

## Out of scope

- **5b (D50):** S7 (JSON), S2 (the parser), the event loop's own cost, S4 (JWT), S3 (route), S5 (validation), the PHP
  version (8.3 to 8.6, D8, D26), and the FFI driver to `libsqlite3` (S6): the spike's FFI numbers will say first what
  an FFI call costs. 5a touches their code only where its variants need it: scopes 2, 3 and 9 change `DiyServer`
  (the loop: the accept pause, the workers, the turn's flush), scopes 8 and 9 `DiyConnection` (the read path, the
  order behind a queued write); the parser itself stays as it is.
- **The app on the io_uring ring:** if the no-op wins, moving the app onto it is its own phase; this run stops at the
  no-op (the spike).
- **S1-c (closing idle connections):** ruled out by prior art.
- **Reading SQLite's B-trees directly:** the top entries do it, from C; out of reach from PHP without C (🤝 Out of
  scope).
- **The full-size run (100,000 users, several generators, x86):** phase 7.
- **The submission folder:** phase 6.
