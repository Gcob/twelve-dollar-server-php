# Run: phase 3, runtime bake-off

**Pace:** 🟢 full · 5-hour 12 % · weekly 22 % at 22:11 · 5-hour resets 23:30 · away

**Status:** 🔄 Running: delta reviews on scope 7
**Progress:** 7/7 scopes, scope 7 pushed at 22:11 (`e062f0b`); delta pass of `pr-reviewer` running, then `blind-reviewer`, then delivery · started 2026-11-21 16:24
**Since your last read:** scopes 1 to 6 are committed and pushed; both final reviews are OK (`pr-reviewer` pass 1,
`blind-reviewer` pass 2 after one 🟠 fix). The bake-off (scope 7) can't measure: 23 containers of other projects run
in Docker's VM (D15). Smoke runs on the busy VM, not results: all three servers VALID at 7,000 req/s on both routes.
**👉 Your turn:** nothing blocking. Q7 still open, not blocking.

## Steps

| #   | Step              | State       | Start | End | Detail |
|-----|-------------------|-------------|-------|-----|--------|
| 0   | Plan review       | done        | 16:29 | 16:48 | full: NOT_OK (1 🔴, 3 🟠), settled as D21 to D24 at 16:44; delta: OK at 16:48, 4 🟡 folded in |
| 1   | Scopes            | done        | 16:31 | 22:11 | 7/7; scope 7 measured on a quiet VM, first try redone under D25 |
| 2   | Questions         | skipped     |       |     | no `run` question opened by this phase; Q7 stays open (not blocking) |
| 3   | Lab suite         | done        | 18:17 | 18:17 | `lab/check.sh` 32/32 on `3e74d76` |
| 4   | `pr-reviewer`     | done        | 18:17 | 18:23 | pass 1 OK on scopes 1 to 6 (6 🟡); a delta pass on scope 7 later |
| 5   | `blind-reviewer`  | done        | 18:31 | 18:49 | pass 1 NOT_OK (1 🟠), fixed in `9aadddc`; pass 2 OK (1 new 🟡, left); a delta pass on scope 7 later |
| 6   | Delivery          | to do       |       |     | branch pushed, not merged |

## Scopes

| #   | State | Start | End | Lines | Checks | SHA | Fixes |
|-----|-------|-------|-----|-------|--------|-----|-------|
| 1   | done | 16:31 | 16:33 | +55 -3 | shellcheck ok, check.sh 18/18 (PM rerun) | `a0477ba` |       |
| 2   | done | 16:45 | 16:55 | +837 -37 | conformance 8/8, VALID at 7k on both routes, check.sh 21/21 (PM rerun) | `0d74fda` | delta 🟡 1-3 (relaunch 16:47) |
| 3   | done | 16:59 | 17:12 | +821 -3 | 10k held, nofile 2048 ceiling 2,035 (timeout), check.sh 24/24 (PM rerun) | `deeb8d1` |       |
| 4   | done | 17:15 | 17:50 | +636 -16 | php-info 8.5/8.6 event 3.2.0 + Workerman, caches 5/5, boots on both trees, check.sh 26/26 (PM rerun) | `8c8f7cc` |       |
| 5   | done | 17:53 | 18:01 | +136 -50 | conformance 8/8 on both trees, 4 macro runs VALID, check.sh 28/28 (PM rerun) | `ad52342` |       |
| 6   | done | 18:03 | 18:14 | +862 -8 | conformance 8/8, parser 30/30, partial write 4/4, VALID at 7k, check.sh 32/32 (PM rerun) | `3e74d76` | R1 R2 R4 (`e1cf918`) |
| 7   | done | 21:13 | 22:09 | +37037 (results) | summarize.sh regenerates the README tables (PM diff), predictions verbatim, every counted run VALID with other_containers 0; finalists DIY 29.14 and Swoole 32.83 µs/req (posts at 7k) | `e062f0b` | first try stopped 21:28, D25 (VUs rate / 5) |

## Reviews

### `plan-reviewer`, full · 16:30 to 16:42 · NOT_OK

**Report:** [PLAN-2026-11-21-1635.md](reviews/PLAN-2026-11-21-1635.md). 5 questions, each settled with the reviewer's
own pick (D21 to D24, and scope 4's Done-when now boots a Workerman); the 10 🟡 folded into `details/phase-3.md`.

- **🔴 Workerman can't start: no `pcntl` in the images.** Settled: D21, `pcntl`, `sockets`, `event` as shared
  extensions in scope 4, whose Done-when now starts a `Worker`.
- **🟠 Listen backlog unset (DIY would get PHP's 32).** Settled: D22, 4,096 and `TCP_NODELAY` everywhere; the client
  opens connections one at a time.
- **🟠 Max connections and stop reasons could be wrong** (no "refused" on Linux, the accept queue counted as
  established, `TIME_WAIT` between runs). Settled: D23, counted by the client, client errors fail the run.
- **🟠 The partial-write case never forces a partial write.** Settled: D24, a socket-pair test in scope 6.
- **🟡** D19 miscounted Workerman's headers (3, no `Server`); the spec's 404/400 messages; the caches are static
  locals; Workerman's `start` argv and pid files; Pss instead of VmRSS; predictions 7 and 8 against the prior art
  (revised at 16:44, still before any measurement); `micro.sh` dropped from the quiet-VM rule; the VM had 7, then
  23, other containers running (action in `plan.md`).

### `pr-reviewer`, pass 1 · 18:17 to 18:23 · OK

**Report:** [PR-2026-11-21-1820.md](reviews/PR-2026-11-21-1820.md). Scopes 1 to 6 match `details/phase-3.md`; the lab
is ready for scope 7 to measure fairly (same handler, same socket settings, CPU and Pss over every process of the
cgroup, the connection harness's max and slopes as planned). It reran the DIY parser and partial-write tests and the
caches script.

#### R1 🟡 A dead `wait` mode in the conformance client

**Scopes:** 2 · **Status:** fixed (`e1cf918`)

#### R2 🟡 A comment says Workerman adds a `Server` header

**Scopes:** 5 · **Status:** fixed (`e1cf918`). It contradicted D19 and what scope 5 found.

#### R3 🟡 Helpers and the other-containers block duplicated in `macro.sh` and `conns.sh`

**Scopes:** 2, 3 · **Status:** left (no failure; a refactor for phase 4 if a third harness needs them)

#### R4 🟡 "The loop is Event" is only checked by hand

**Scopes:** 5 · **Status:** fixed (`e1cf918`): `conformance.sh` prints the `loop:` line; the checks assert Event for Workerman, epoll for DIY.

#### R5 🟡 No check that `conns.sh` removes its containers after a failure

**Scopes:** 3 · **Status:** left (the trap exists; scope 3's developer checked it by hand with a `docker kill`)

#### R6 🟡 The backlog is the value asked for, not read back

**Scopes:** 5, 6 · **Status:** left: no socket option returns it and the images have no `ss`; `somaxconn` is 4,096
on the VM, so no clamp. Said in the README.

### `blind-reviewer`, pass 1 · 18:31 to 18:38 · NOT_OK

**Report:** [BLIND-2026-11-21-1831.md](reviews/BLIND-2026-11-21-1831.md). No 🔴; it found no broken path in the DIY
parser, the back-pressure or the connection test. Mental load 🔴 high (3,278 lines, 28 files).

#### R7 🟠 "Memory under load, Pss" counts SQLite's mapped database pages

**Scopes:** 2, 3 · **Status:** fixed (`9aadddc`): `Pss_Anon` summed everywhere, the README compares runtimes on it. Smoke: Swoole posts Pss 139 MiB, Pss_Anon 12.5 MiB; on `/noop` 31 and 12.5.

The handler maps the database (`mmap_size`), and Pss counts every mapped page touched, up to about 105 MiB. How much
depends on how many rows a run touched (warm-up included), not on the runtime, so two runtimes measured at different
rates or run lengths would differ by tens of MiB for nothing.

#### R8 🟡 DIY stops on a handler exception, and has no 500

**Scopes:** 6 · **Status:** fixed (`9aadddc`)

#### R9 🟡 DIY accepts a header with a space before the colon

**Scopes:** 6 · **Status:** fixed (`9aadddc`)

#### R10 🟡 Five doc inaccuracies

**Scopes:** 2, 4, 5, 6 · **Status:** fixed (`9aadddc`; Workerman doesn't close after 60 s: it ignores `Connection: close` and keeps the connection; README and comments: the quiet-VM sentence, three pipelined requests,
Workerman's 60 s keep-alive claim, the libevent version, "allocates nothing").

#### R11 🟡 Three leftovers

**Scopes:** 4, 6 · **Status:** left: a comment that assumes phase 2 context, `workerman-caches.php` living next to
the servers, and the warm-up replaying the measured run's ids (the same for every runtime, so it doesn't bias a
comparison).

### `blind-reviewer`, pass 2 · 18:48 to 18:49 · OK

**Report:** [BLIND-2026-11-21-1848.md](reviews/BLIND-2026-11-21-1848.md). R7 to R10 fixed; R11 left and not raised
again.

#### R12 🟡 `memory.current` holds the 250 MB database copy in page cache

**Scopes:** 2 · **Status:** left in the code; scope 7's results README says it (compare runtimes on differences).

### `plan-reviewer`, delta · 16:46 to 16:48 · OK

**Report:** [PLAN-2026-11-21-1650-delta.md](reviews/PLAN-2026-11-21-1650-delta.md). D21 to D24 settle the full
review's 🔴 and 🟠. 4 🟡, all folded in: each server prints its backlog and `TCP_NODELAY` at boot for the JSON; peak
Pss sampled during the run; `other_containers` counts every container that isn't the run's own; DIY loads `sockets`
before `event`. The first three went to scope 2's developer as a relaunch.
