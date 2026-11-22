# Brief: scope 3/6, the bench's connections and time

**Read first:** [common.md](common.md), then `plan/state/developer.md` (scopes 1 and 2's handovers).
**Worktree:** `.claude/worktrees/twelve-dollar-server-php/phase-4-claude` under the home folder (your prompt gives the
full path) · **Your handover:** `plan/state/developer.md` in the main checkout.
**Planned commit:** `feat(lab): idle connections and per-second series in the realistic mode`

**Summary:** add to the realistic mode what the bench has and scope 2 doesn't: tens of thousands of idle keep-alive
connections held the whole run, and time (a per-second view of latency, CPU, memory, the WAL, page faults and the
server's own telemetry); plus a cold start and the same per-second latency for `macro.sh`, so a later measurement can
tell where a latency stall comes from.

**Today:** scope 2's `lab/realistic.sh` runs the bench's journey (`lab/macro/k6/realistic.js`) against the skeleton
in one k6 `ramping-vus` scenario, with k6 bound to its own source addresses, a live aggregator keeping per-second
latency histograms per endpoint, a lag and memory gate, and per-step results (see its handover for the exact names).
`lab_start_app` (scope 1) gives the app a fresh seed copy. Phase 3's idle-connection client `lab/conns/client.php`
opens connections one at a time from rotating 127.x source addresses, each with `GET /noop` and an exact body check;
`lab/conns.sh` uses it. `lab/macro.sh` loads a server at a fixed rate with no per-second view and can't start the app.

**Expected:**

- **`--idle <n>` in `realistic.sh`:** phase 3's client in a hold mode opens `<n>` keep-alive connections one at a time
  (one request each, answer read), rotating source addresses as in phase 3, **before** the warm-up, and holds them to
  the end; at the end it sweeps them, and a connection the server closed fails the run with that reason. The hold mode
  takes a path and a body pattern (`GET /health` and its `{"status":"ok",...}` body here; `/noop` and its exact body
  stay the default), and `conns.sh`'s phase 3 checks stay green. The count held at the start and at the end goes in the
  table and the JSON, and the client's memory too (scope 2's VU cap took 1 GiB for it until measured: record the real
  value). With 60,000 held, k6's VUs come on top: all sockets must stay under the server's 65,535 fds. If k6's own
  source addresses (scope 2) don't keep k6 from running out of ports with 60,000 held, the fallback is the idle client
  setting `IP_BIND_ADDRESS_NO_PORT` (ext-sockets); tell me if you need it.
- **Server telemetry, `APP_TELEMETRY=1`:** the app prints one line per second on stdout: requests per endpoint, the
  longest single callback of the event loop in ms (one `hrtime` around each callback is fine), `gc_status()` runs and
  collected, the WAL's size, and the process's minor and major faults (`/proc/self/stat`). Off by default. Keep it
  cheap: a later measurement compares on against off.
- **Per-second series**, one row per second of the run (a table in the output and an array in the JSON): per endpoint
  the request count, p50, p99 and max latency (from scope 2's live histograms); the server's CPU (`usage_usec` delta);
  `Pss_Anon`; `memory.current`; the WAL as its file size **and** its frames in use (`mxFrame`, a 32-bit big-endian
  integer at offset 16 of the `-shm` file: SQLite reuses the WAL from its start after a checkpoint without truncating
  the file, so only the frames show the checkpoints); the server's minor and major page faults
  (`/proc/<pid>/stat`); and the server's telemetry line for that second. The readings come from **one sampler loop
  inside the probe container** (CPUs `0-1`), never one `docker exec` per second (runc and dockerd work isn't pinned
  off the server's CPU). The telemetry lines come from the server container's log.
- **SQLite's page cache:** `pdo_sqlite` doesn't expose `sqlite3_db_status`; the page faults stand for it (the database
  is mapped). If you find a cheap way to read SQLite's own cache hit and miss counters from the server's connection,
  add them; otherwise say so in the README.
- **`--cold`:** after the copy and its `sync` (a dirty page isn't evicted), evict the copy's pages from the page cache
  before the server opens it (`posix_fadvise(DONTNEED)` on the copy only, for example `dd if=<copy> iflag=nocache
  count=0`); never a VM-wide `drop_caches`. `fincore` (util-linux) on the copy, just before the server opens it,
  records the resident pages: near 0 with `--cold`, the whole file without it. It goes into `lab_start_app` so every
  harness gets it.
- **`macro.sh` on the app:** behind a named switch `--fresh-db`, `macro.sh` starts its server with `lab_start_app`
  (fresh copy, `SQLITE_PATH`, `JWT_SECRET`) and takes `--cold`; `--per-second` gives the same per-second latency series
  (and the server-side columns) for a fixed-rate run. The bake-off servers keep copying their own seed and run as
  before without the switch. Q10's later runs use `macro.sh --fresh-db --per-second` with the bake-off's `posts.js`
  against the app (the app answers `/posts/:id` like the bake-off's handler).
- **`lab/check.sh`:** a small idle run (a few thousand held, start equals end); a fixture that closes an idle
  connection fails the run with the reason; the per-second rows cover the run with no gap; `--cold` against warm
  `fincore` readings; a `macro.sh --fresh-db --cold --per-second` smoke on the app; `conns.sh`'s checks unchanged.
- **`lab/README.md`:** the idle connections, the per-second columns, telemetry, cold, and `macro.sh --fresh-db`.

**Key interfaces:** `--idle`, `--cold` in `realistic.sh`; `--fresh-db`, `--cold`, `--per-second` in `macro.sh`; the
hold mode of `lab/conns/client.php`; `APP_TELEMETRY`; the per-second JSON keys.

**Done when:** `lab/realistic.sh --idle 60000` with a staircase up to the VU cap reports 60,000 idle connections held
at the start and at the end, and k6 had no connection error; its per-second table has one row per second with latency
per endpoint (count, p50, p99, max), server CPU, `Pss_Anon`, `memory.current`, the WAL's frames (`mxFrame`) and file
bytes, minor and major faults and the server's telemetry (longest callback, GC runs); `--cold` shows the copy's
resident pages near 0 before the first request (`fincore`), against the whole file without it;
`lab/macro.sh --fresh-db --cold --per-second` runs the app with `posts.js` and prints the same latency series;
`bash lab/check.sh` is all `ok`.

**About the 60,000 run while other projects' containers are running:** it's a smoke run, not a measurement. Check
`docker stats --no-stream` (or the VM's free memory) before it: if the VM can't fit the server's 2 GiB, the idle
client and k6 at its cap beside the other containers, run it with fewer VUs (keep the 60,000 idle, which is the point),
say so, and tell me the numbers. Never stop another project's container.

**Seams and cases to test:** the cases of the `lab/check.sh` bullet; the client's hold mode against a server that
closes one connection (fixture); `mxFrame` read against a known WAL (write some rows, read it, checkpoint, read again).

**Tests to imitate:** `check_conns_holds_steps`, `check_conns_back_to_back` (the client), `check_macro_*` (macro
runs), and scope 2's realistic checks.

**Decisions that touch you:** sockets under 65,535 fds; k6 on its own source addresses (fallback
`IP_BIND_ADDRESS_NO_PORT` in the client); one sampler loop in the probe container; WAL frames from the `-shm` header;
cold by `fsync`/`sync` then `DONTNEED` on the copy only; one seed-copy function for every harness, `macro.sh` behind
`--fresh-db`; telemetry on in every later run, its cost measured once (so keep it cheap).

**Out of scope:** the profiler (next scope); any measurement that counts (smoke runs only); any optimization of the
app; changing the bake-off servers' behavior.

**Where to look:** `lab/conns/client.php` and `lab/conns.sh` (phase 3's client and its checks),
`lab/macro.sh` and `lab/macro/probe.sh` (the probe container, cgroup and `/proc` reads), `lab/realistic.sh` and its
aggregator (scope 2), `lab_start_app` in `lab/lib.sh`, `plan/runs/phase-3/state/developer.md` (the client's
`TIME_WAIT` and source-address lessons).

**Come back to me if:** k6 still runs out of ports with 60,000 idle, the VM can't hold the 60,000 run at all, a
decision is missing, or the Done-when doesn't pass after 3 tries.
