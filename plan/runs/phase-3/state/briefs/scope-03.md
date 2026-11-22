# Brief: scope 3/7, idle-connection harness, max connections and RSS

**Worktree:** `phase-3-claude` (absolute path in your prompt) · **Run folder:** `plan/` of the main checkout
**Planned commit:** `feat(lab): idle-connection harness, max connections and RSS`

**Read first:** [common.md](common.md), then `plan/state/developer.md` (scope 2's handover: the handler, the Swoole
bake-off server, `--ext`/`--env`/`--label`, `other_containers`, the Pss sampling in `macro.sh`).

**Summary:** `lab/conns.sh` measures how many idle keep-alive connections one server process holds, and what each
one costs in memory.

**Today:** after scope 2, `lab/servers/bake-swoole.php` serves `GET /noop` and `GET /posts/:id`; `macro.sh` and
`conformance.sh` start a server in a lab container (1 CPU, 2 GiB, no swap, `nofile` 65535, CPU 2, host network) and
read its cgroup from a probe container (`--pid host --cgroupns host`, CPUs 0-1), including summed `Pss` from
`/proc/<pid>/smaps_rollup`. Nothing opens tens of thousands of connections yet.

**Expected:**

- **`lab/conns.sh --image <v> --server <file> [--ext <e>]... [--env K=V]... [--label <text>] [--steps a,b,...]
  [--max N] [--server-nofile N] [--port N] [--out <path>]`.** Default steps: 1000, 5000, 10000, 20000, 30000, 40000,
  50000, 60000, 65000, 66000. Starts the server like `macro.sh` (reuse the shared start logic), the probe, and a
  client container.
- **The client** (a PHP CLI script in a php-lab container: `--network host`, CPUs `4-11` from `lib.sh`, `--ulimit
  nofile` well above 66k, for example 200000, no memory or CPU limit of the server's): for each step, opens
  connections **one at a time** until the step's total is reached: blocking connect, write `GET /noop HTTP/1.1` with
  `Host`, read the whole answer (status 200, body `{"status":"ok"}`), keep the socket open. One at a time means the
  accept queue never fills. **Source addresses rotate over a block of 127.x addresses starting at `127.0.0.2`**
  (`stream_context` `socket.bindto` `127.0.0.N:0`), switching address before its ephemeral ports run out (28,232 per
  source address on this VM: `ip_local_port_range` 32768-60999; read it from `/proc/sys/net/ipv4/ip_local_port_range`
  rather than hard-coding). `127.0.0.1` stays for the probe's fresh request. **No `sysctl` change anywhere**: the
  Docker VM is shared with other projects.
- **Between steps,** the client tells the orchestrator (stdout lines, or a small file in a mounted dir: your call) and
  waits; the orchestrator reads from the probe: summed `Pss` of the server's processes, the cgroup's
  `memory.current`, `memory.events` (`oom_kill`), the established connections to the server port in `/proc/net/tcp`
  (and `/proc/net/tcp6` if the server listens on v6), and a fresh connection from `127.0.0.1` that must get an answer
  within 1 s. The client also sweeps its held sockets with non-blocking reads: an EOF means the server closed one.
- **Before starting,** the client waits until no `TIME_WAIT` socket remains on its source addresses (read
  `/proc/net/tcp`), up to 70 s, printing that it waits; or, if you prefer, each run takes the next free block of
  addresses. A second run right after a first one must not fail on `bind`.
- **Max connections:** the connections the client got an answer on and still holds, at the last fully held step, and
  the exact count when it stopped. **The ceiling** is the first step where a connect or a request times out (2 s), a
  connection is reset, a held connection closed (EOF), the fresh request fails, or the server was OOM-killed or died.
  The output names which. Linux doesn't refuse a SYN because of a full accept queue or a server out of fds (it
  completes the handshake, then times out or resets), so don't expect "refused". **A client-side error** (`bind`
  failing, `EMFILE` in the client, no free port) exits non-zero as a harness failure, never as a ceiling.
- **Memory per connection:** least-squares slope of summed `Pss` against connections held, over the held steps from
  the first one up, in KiB per connection; the same slope for `memory.current`; the baseline (both, before any
  connection, after one `GET /noop` on a single connection so the first-request allocations are in the baseline).
- **Output:** a table, one row per step (target, held, Pss MiB, memory.current MiB, `/proc/net/tcp` count, fresh
  request ms, ok or the failure), then max connections, the reason it stopped, both slopes, the baseline, the server's
  socket line (backlog, `TCP_NODELAY`, printed by the server at boot), `other_containers`, the image and versions. A
  JSON file (`lab/results/conns-<server>[-<label>]-<image>-<UTC stamp>.json`) with every raw reading and the exact
  command, like `macro.sh`'s.
- **Exit codes:** 0 when it found a ceiling or reached `--max` (both are results); 1 when the harness failed (client
  error, server never answered, probe failure); 2 usage. Every container removed whatever happens (trap), with fixed
  names and the refusal to start when one exists, like `macro.sh`.
- **`--server-nofile N`** sets the server container's `nofile` (default the lab's 65535): a test hook, recorded in the
  JSON.
- **`lab/check.sh`:** a small run (`--steps 200,500 --max 500`) on `bake-swoole.php` that must exit 0 with 500 held,
  and a ceiling run (`--server-nofile 256 --steps 100,300`) that must exit 0 with a ceiling under 256 and a named
  reason. Keep them short.
- **`lab/README.md`:** a "Connection test" section: what it measures, the one-at-a-time client, the source-address
  rotation, how max and the slopes are computed, the reasons, the `TIME_WAIT` wait, the traps you met.

**Done when:** `bash lab/conns.sh --image 8.5 --server lab/servers/bake-swoole.php --max 10000` prints one row per
step, the max and the memory per connection (both slopes), and exits 0; `bash lab/conns.sh --image 8.5 --server
lab/servers/bake-swoole.php --server-nofile 2048 --steps 1000,3000` reports a ceiling under 2,048 with a named reason
and exits 0; running the first command twice in a row, both pass (no `bind` failure); `lab/check.sh` passes (report
`N/N ok`).

**Seams and cases to test:**

- Seam: `lab/conns.sh` (its table, JSON and exit code).
- Held run under `--max`: every step held, max = the last step, slopes positive.
- Ceiling by fds: `--server-nofile` low gives a ceiling under it, reason named (timeout or reset), exit 0.
- Back to back: the second run doesn't fail on `bind` (the `TIME_WAIT` wait or the next block).
- A step above `--max` isn't run.
- The containers are removed after a failure (kill the server mid-run once by hand to see the "server died" reason,
  and report it; no need for a check).

**Tests to imitate:** `lab/check.sh` → `check_macro_noop_is_valid`, `check_macro_cleans_up_after_failure`.

**Decisions that touch you:**

- Max connections is counted by the client (answered and still open); `/proc/net/tcp` is a cross-check; a client-side
  error fails the run.
- Every server: backlog 4,096 and `TCP_NODELAY` on, printed at boot; the harness copies that line.
- Memory: summed Pss (shared pages counted once across a master and its worker) and `memory.current` (holds the
  kernel's socket buffers, what reaches the 2 GiB limit), both reported.
- Quiet VM: record `other_containers` (every running container that isn't this run's own), warn above 0, still run.
- The real measurement is scope 7's; your runs here only prove the harness. Don't commit result files from these runs
  (the JSON default path is under `lab/results/`: use `--out` to a temp path for your own runs, and `check.sh` too).

**Out of scope:** CPU per request with connections held (a later phase); Workerman and DIY (scopes 4 to 6); any result
README.

**Where to look:** `lab/macro.sh` and whatever scope 2 factored out of it for starting servers; `lab/macro/probe.sh`
(cgroup and `/proc` reads); `lab/lib.sh` (CPU layout, limits). SHAs in `plan/state/developer.md`.

**Come back to me if:** the client can't reach 66k connections for a reason in the client or the VM (not the server),
a decision is missing, or the "Done when" doesn't pass after 3 tries.
