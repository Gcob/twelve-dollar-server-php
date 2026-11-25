# Phase 7: the score on x86

**Done when:** in our own run, `submissions/php-Gcob/` holds more than 71,000 users for 5 minutes under the
challenge's **unmodified** `bench/load.js` (p95 < 500 ms, p99 < 1 s, errors < 1 %, k6's own thresholds), or a clear,
measured reason why not (which wall: the server's CPU, its fds, its memory, the network, or k6). Every probe records
the server's CPU, RSS and connections per second. The score is written with what differs from the bench next to it
(AWS's Xeon against the bench box's, a Synteq VPS with a Xeon Platinum 8260; one core with no sibling; the RTT
measured; the kernel; the disk; EC2's connection tracking): **it's our
estimate, not Arjay's number.** The predictions below were written before any run (D5). Then the run stops (D12).

**Plan review:** [PLAN-2026-11-24-2325.md](../reviews/PLAN-2026-11-24-2325.md), NOT_OK (1 🔴, 9 🟠, 18 🟡). Settled by the
project manager with the reviewer's picks where the choice was the run's: D92 (`TOKENS`), D93 (the load box's type
from scope 1's measure, both ways), D95 (the service's share, others, fd by `stat`), D96 (the bench box named, the
estimate apart from the pass mark), D97 (k6 as the wall: a 🔴 for one bigger relaunch), D98 (the session's order),
D99 (no conntrack on the load box), D100 (EC2's tracking measured, port 80 opened only with Jacob's yes: Q22), D101
(the guard learns AWS's traces); the 🟡 folded in below.

**Where (D14):** code on branch `phase-7-claude`, in its worktree (from `main` at `5a28a69`). `plan/` stays on
`main`. The factory holds the private side: the AWS scripts and policy (`aws/`), the run log with ids and
addresses, the raw diagnostics (`lab/`).

**Why this shape:** phases 2 to 6 measured µs of CPU per request with a shortened think time (`s = 0.02`), a few
thousand k6 VUs and 60,000 idle connections standing in for the bench's users. The bench does none of that: one k6 VU
per user, real think time (about 20.5 s a loop), so 70,000 to 140,000 VUs, each with its own keep-alive connection,
the app installed by its own scripts and started by systemd as `deploy`. Phase 7 has three risks, one per slice: **the
search** (a driver that runs Arjay's procedure the same way every time and reads pass or fail as k6 does), **the
boxes** (a server shaped like the droplet, set up the bench's way, and a load box that is never the wall), and **the
reading** (which wall stopped us, measured, and how far our AWS number is from the bench's).

## Decisions of this phase

In [decisions.md](../decisions.md):

- **D89, the machines (Jacob):** two AWS boxes in one cluster placement group, `ca-central-1`: a server box shaped
  like the droplet (a `c5.large`, Ubuntu 24.04 x86-64, one vCPU, 2 GB for the whole box, no swap; `install.sh` as root,
  `build.sh` and the service as `deploy`, started by systemd with `LimitNOFILE=65535` and `CAP_NET_BIND_SERVICE`, direct
  on port 80, a fresh seed copy per probe, no kernel tuning beyond what the droplet has) and a load box running k6 with
  the unmodified `bench/load.js`.
- **D90, the search (Jacob):** Arjay's warm-up (1,000 users, 2 minutes), a 2-minute probe at 71,000, steps of 5 % up
  until a probe fails, then 5-minute holds stepping down 5 % until one passes. Pass as the bench says. The app restarts
  on a fresh database before every probe.
- **D91, how the server box is shaped (project manager):** one vCPU through EC2's CPU options at launch
  (`CoreCount=1, ThreadsPerCore=1`): the OS sees one CPU from boot (`nproc` 1), and the core's other hyperthread is
  disabled for the instance, so the server runs on one core with no sibling, the layout of 5a's x86 calibration
  (server on one vCPU, its sibling idle), whose Xeon-to-bench factor (1.57) then applies as measured. A CPU taken
  offline after boot would give the same core but leave a second CPU in the boot logs and in `lscpu`. 2 GB: `mem=2G`
  on the kernel's boot line (a `grub.d` drop-in, one reboot), so the whole box, OS included, sees 2 GB as on the
  droplet (rule 8); a cgroup cap on the service would leave the OS outside the 2 GB. No swap (the AMI has none,
  checked). Nothing else is changed on the server box: no `sysctl`, no service disabled, no package beyond what
  `install.sh` installs and the sampler's needs (none: it reads `/proc` and `/sys`). If `mem=` doesn't hold (MemTotal
  over 2,048 MiB after the reboot), the run stops: no improvised other way.
- **D92, where things run (project manager):** the search driver runs **on the load box**, detached (`nohup`), and
  drives the server box over SSH on the private network with a key made on the load box (no AWS key leaves the Mac).
  The Mac launches the boxes, sets them up, starts the driver and copies the results back; a dropped home connection
  never stops a probe. Each probe: stop the service, a fresh copy of the seed (`cp`, `chown deploy`, `sync`, the old
  `-wal` and `-shm` removed), start, `/health` within 60 s, the server sampler on, k6, the sampler off. k6 runs in the
  lab's pinned image (`grafana/k6:1.8.3@sha256:2cd9…`, the one the lab's memory per VU was measured with) on the host
  network with `nofile` 1,048,576, on the challenge's `bench/load.js` checked by its git blob hash against the
  reference commit (`162699a`); the script gets only `-e BASE_URL -e VUS -e DURATION -e TOKENS` (the warm-up and the probes;
  the bench's 60 s ramp and 30 s ramp-down stay as the script sets them; `TOKENS` because `lab/seed.sh` writes
  `tokens.json` to `lab/data/`, not where the script's default looks), and k6 gets three command-line flags that don't
  touch the script: `--local-ips` (D94), `--summary-export`, `--address 127.0.0.1:6565`. The driver polls k6's REST API
  once a second (`/v1/metrics/vus`, `/v1/metrics/http_reqs`, `/v1/metrics/http_req_failed`): that gives the plateau's
  exact window and its request count, so µs/req is the service's CPU over the plateau divided by the plateau's
  requests. Pass or fail is k6's exit code: 0 passes, 99 (thresholds crossed) fails, anything else is a harness error
  that stops the search.
- **D93, the load box sized from k6's memory a VU (project manager, Q20):** memory. The lab measured k6 at
  0.343 MiB a VU; on AWS the server's core is about 1.57 times faster per request than the bench's (5a), so its CPU
  wall sits near 1.57 times the bench forecast: about 83,000 to 88,000 on the bench is 125,000 to 140,000 on AWS. A
  `c5.4xlarge` (32 GiB) holds about 85,000 VUs and would be the wall before the server. The `m5.4xlarge` has the same 16
  vCPUs (as the bench's 16-core generators) and 64 GiB, about 170,000 VUs. Scope 1 measures k6's MiB a VU with the real
  `load.js` and its real think time before the policy is attached, and the type follows (160,000 VUs under 90 % of the
  box's memory): up to 0.16 MiB the `c5.4xlarge`, up to 0.33 the `m5.4xlarge`, above an `r5.4xlarge` (128 GiB). The
  policy names only the type chosen.
- **D94, the load box's source addresses (project manager):** 3 secondary private addresses at launch (4 in all) and
  the load box's ephemeral range widened to 1,024 to 65,535: 4 × 64,512 connections, about 258,000, over the search's
  top. One address would cap k6 at 28,232 connections to the server's one `address:80` (Ubuntu's default range). The
  load box isn't the box under test: rule 11 binds the server box, which keeps Ubuntu's defaults.
- **D95, what a probe records and how a wall is named (project manager):** the server sampler, once a second, reads
  only cheap counters (no `ss`, no fd listing on the 1 s path): the box's CPU (`/proc/stat`: busy, user, system,
  softirq, iowait, steal), the service's cgroup (`cpu.stat` `usage_usec`, `memory.current`, `memory.peak`), the
  processes' RSS (`VmRSS` of each), `MemAvailable`, `/proc/net/sockstat` (TCP in use, TIME_WAIT, the TCP memory pages),
  `/proc/net/snmp` (`PassiveOpens`, the accepted connections: their difference a second is **connections per
  second**; `RetransSegs`) and `/proc/net/netstat` (`ListenOverflows`, `ListenDrops`); every 10 s each process's open
  fds; at the start and end of a probe the ENA driver's allowance counters (`ethtool -S`: `bw_in`, `bw_out`, `pps`,
  `conntrack_allowance_exceeded`, `linklocal`) and the kernel log's OOM lines. The load box samples its own CPU and the
  k6 container's memory. The wall of the first failing probe is named by the first rule that holds: **k6** (the load
  box over 85 % CPU or 90 % of its memory in the plateau: the probe is void, not a fail), **memory** (an OOM kill, the
  service gone, or `MemAvailable` under 100 MiB), **network** (an ENA allowance counter grew), **fds** (`ListenDrops`
  grew, or k6 dial errors with a process within 100 fds of 65,535), **CPU** (the service's own share of the core, from its cgroup, over 88 % on the plateau's median second), else
  **latency below saturation** (then the iowait and the longest stall are looked at, and the
  reason is written as found or as not found). The sampler also records "others" (the box busy minus the service
  minus the sampler): a plateau with others over 5 % of the core is run again once. The fd count is the size of
  `/proc/<pid>/fd` (one `stat`), not a listing.
- **D96, our score against the bench (project manager):** the score is "AWS, our run" and is what "Done when" reads;
  the bench estimate is written apart, never as the pass mark: when the wall is the CPU, AWS users / 1.57 (1.50 to
  1.63, estimated from the two Swoole entries; users scale as 1 / µs at a CPU wall), "beats 71,000 or not". The factor
  holds as measured only on the calibration's Xeon Platinum 8275CL; another model is said. The bench machine named is
  the leaderboard's: a Synteq 1 vCPU / 2 GB VPS (Xeon Platinum 8260 at 2.4 GHz, kernel 6.8, 1,967 MB); rule 8's droplet
  only as the shape. The differences written next to it, measured where they can be: the CPU model, one core with no
  sibling against a shared vCPU, the RTT (`ping`, 100 packets), the kernel (AWS's against 6.8), the disk's `fsync`
  (EBS gp3), EC2's connection tracking (D100).
- **D97, the search's arithmetic and its guards (project manager):** the next probe is 5 % up, rounded to the nearest
  1,000 (71,000, 75,000, 79,000, 83,000, 87,000, 91,000, 96,000, 101,000, 106,000, 111,000, 117,000, 123,000, 129,000,
  135,000, 142,000, 149,000…). The holds start at the highest passing probe; if 71,000 fails, at 67,000 (5 % under,
  rounded). Each next hold is 5 % under the last, rounded. At most 6 holds: past them the search stops, and the reason
  is the deliverable. A void probe (k6 the wall) stops the search: "at least N, bound by k6", and a 🔴 offers Jacob one
  relaunch of the load box on a bigger type (D89 allows it; the policy holds one load type). 60 s between two k6 runs (the load box's TIME_WAIT). The two boxes shut down on
  their own after 4 hours (`shutdown -h +240`, `--instance-initiated-shutdown-behavior terminate`). The server box re-arms its cap after the `mem=` reboot (a reboot clears a pending
  `shutdown`). No placement-group capacity: one retry 2 minutes later, then the box that failed goes alone in the same
  subnet, outside the group, with the RTT measured and said. `--round` sets the rounding (1,000; smaller in the smoke).
- **D98, the session's order (project manager):** launch; `k6-setup.sh` (Docker, k6, the clone, `lab/seed.sh` with
  its content hash, an SSH key); the Mac installs that key on the server box; `server-setup.sh --shape`; the load box
  pushes the seed over the private network; `server-setup.sh` (cloud-init done and the dpkg lock free first). The 42
  checks run from the load box against the server's private address (`test.sh` needs `jq` and `curl`, kept off the
  server box).
- **D99, no connection tracking on the load box (project manager):** Docker with `"iptables": false` (k6 on the host
  network needs no NAT); `nf_conntrack` checked not loaded; if loaded anyway, `nf_conntrack_max` 1,048,576 and its
  count sampled, "table full" a void reason.
- **D100, EC2's connection tracking (project manager, Q22):** both boxes' `conntrack_allowance_available` read after
  launch, the load box's ENA counters sampled too; under 220,000 on the server, port 80 opens to `0.0.0.0/0` (an
  untracked flow) for the session only (Jacob, Q22 = A, 2026-11-25 07:34); else tracked, and named if it binds.
- **D101, the guard learns AWS's traces (project manager):** IPv4 addresses (except loopback, `0.0.0.0` and the
  documentation ranges), `ip-N-N-N-N` host names, AWS ids and 12-digit account ids, in `tools/public-guard.sh`, each
  with a fixture.

## Scopes

| #   | Commit                                                           | Done when |
|-----|------------------------------------------------------------------|-----------|
| 1   | `feat(lab): the score search, driven from the load box`          | `bash lab/score/smoke.sh` on the Mac runs the warm-up and the search at a small size (200 users, `RAMP_UP=10s`, `DURATION=20s`, `--round 10`) against the submission in a lab container, with one probe made to fail by the smoke's own controller: it prints one row per k6 run (kind, users, pass, p95, p99, errors, plateau req/s, server CPU, µs/req, accepts/s) and each step's decision, ends on a passing hold, and exits 0; each run's JSON has the fields listed in "Scope 1"; `bash lab/check.sh check_score` passes and each of its fixtures makes it fail once; a copy of `load.js` with one byte changed is refused before k6 starts; the hand-back gives k6's MiB per VU at 2,000 and 5,000 VUs with the real `load.js` and real think time; `lab/check.sh` all `ok` |
| 2   | `feat(lab): the two boxes, set up the bench's way`               | `shellcheck` (the lab's pinned one) passes on every script under `lab/score/`; the unit file passes `systemd-analyze verify` in a clean `ubuntu:24.04` container; `server-ctl.sh restart` exits 1 when `/health` doesn't answer within 60 s; `tools/public-guard.sh` refuses each of
D101's fixtures (an address, a host name, an AWS id, an account id) and passes on the tree; `server-setup.sh --check` and `k6-setup.sh --check` print one line per check and exit non-zero when one fails (fixtures); the factory's `aws/phase-7/launch.sh --print` makes no AWS call and prints every call it would make (`--dry-run`, AWS's own `DryRun`, waits for the policy), and `teardown.sh --verify` lists placement groups too; the guard passes; `lab/check.sh` all `ok` |
| 3   | `docs(lab): the score on x86, Arjay's search`                    | `lab/results/<date>-x86-score/README.md`: the predictions copied unchanged and committed before the launch; the machine table (CPU model, kernel, `nproc` 1, MemTotal, no swap, RTT, `fsync`); the setup proofs (install time, `build.sh` ok, 42/42 on the service, healthy seconds, `deploy`, `Max open files 65535`, `CapAmb` with only `cap_net_bind_service`); every k6 run's row and the search's decisions; the score (the highest passing hold) or the measured reason why none passes 71,000, with the wall named by D95's rule; what differs from the bench (D96); `summarize.sh` regenerates the tables; the guard passes; `teardown.sh --verify` ends on `TEARDOWN CLEAN` (its output in the factory's run log) |
| 4   | `docs(submission): our own run on AWS, labelled` (D103)        | the README's "Results" has one paragraph: our own run on AWS, the users held 5 minutes, the boxes, "not the bench's score", the AWS core about 1.5 times faster per request than the bench's, a link to scope 3's folder; `check_submission` resolves the link; the guard passes |

Vertical slices: scope 1 is the search end to end on the Mac (the driver, k6, the controller, the probe's JSON,
the reading), with a local controller in place of the server box; scope 2 is the bench's way in on real boxes (the
shape, the install, systemd, the samplers, launch and teardown), checked locally as far as a laptop allows; scope 3 is
the one measurement; scope 4 the claim. Scope 2's scripts first run for real on AWS in scope 3: a failure there is
fixed by a `fix(lab)` commit while the boxes wait (about 1 USD an hour).

**AWS (D89):** nothing is created before Jacob's go. The policy waits in the factory
(`aws/phase-7-score-policy.json`); a 🔴 in 👉 asks Jacob to attach it and say go. Then `launch.sh --dry-run` (AWS's
own `DryRun`, which checks the policy without creating anything), then the run. The policy is the fence: a refused
call means the run strayed, it stops and reports.

## Shared rules for every scope

- **The bench's script stays the bench's:** `load.js` is read from the challenge's clone at `162699a` and checked by
  its git blob hash before every k6 run. No copy under `lab/` is run in this phase (the lab's `realistic.js` is a
  modified copy, for the step lab).
- **The submission is not touched by scopes 1 to 3.** A bug found on the boxes is a question for the project manager.
- **Public and private:** `lab/score/` and the results hold no address, instance id, account, key or host name
  (`tools/public-guard.sh`, which learns them in scope 2, D101). Ids, addresses, the key and the raw diagnostics go to the factory (`aws/run-log.md`,
  `lab/`). A public result records counts and the CPU model, not names.
- **No `gh` command, nothing on the challenge's repo.** Jacob's Docker containers are stopped until tomorrow: never
  start or stop them; the lab's own containers are fine.

## Scope 1: the search, driven from the load box

- **Seams:** new `lab/score/search.sh` (the driver), `lab/score/probe.sh` (one k6 run: the controller's restart, the
  samplers, k6, the REST poll, the JSON), `lab/score/next-step.jq` or a small function the developer names (the
  search's arithmetic, pure, so `check.sh` can feed it fixtures), `lab/score/smoke.sh`, `lab/score/ctl-local.sh` (the
  smoke's controller), `lab/score/server-sample.sh` (the server's sampler, D95: every probe needs it, so it is built
  and smoked here and reused on the server box by scope 2), `lab/check.sh` (`check_score`).
- **The controller interface:** the driver never knows where the server is; it calls `<ctl> restart` (fresh seed, start,
  healthy, prints the healthy seconds), `<ctl> sample-start <run>`, `<ctl> sample-stop <run>` (copies the server's CSV
  next to the run's JSON), `<ctl> facts` (one JSON object: CPU model, `nproc`, MemTotal, kernel, swap). On AWS it is
  `server-ctl.sh` over SSH (scope 2); in the smoke, `ctl-local.sh` runs the submission in the lab's image with the lab's
  seed-copy function (D42) and can be told to fail one probe (it stops the server for that probe: k6 then fails on
  errors, exit 99).
- **The driver:** `search.sh --base-url <url> --ctl <cmd> --out <dir> [--start 71000] [--step 5] [--probe 2m]
  [--hold 5m] [--warmup 1000,2m] [--max-holds 6] [--round 1000] [--tokens <file>] [--local-ips <list>]
  [--ramp-up <d>]` (the last for the smoke only:
  the bench's 60 s otherwise). It writes `search.json` (every run in order, every decision with its reason) and one
  folder per k6 run. It refuses to start if `load.js`'s blob hash is not the reference's, if the controller's `facts`
  fails, or if `--out` exists.
- **One k6 run's JSON:** kind (`warmup`, `probe`, `hold`), users, duration, k6's exit code, pass, p95, p99, the error
  rate, `http_reqs` (whole run and plateau), the plateau's start, end and seconds (from the REST poll: the seconds where
  `vus` equals the target), the plateau's req/s; from the server's CSV over the plateau: CPU busy (median and max
  second), µs/req (Δ `usage_usec` / Δ plateau requests), accepts a second (median and max, and the ramp's max),
  `memory.current` and RSS peaks, `MemAvailable` minimum, TCP in use peak, TCP memory pages peak, TIME_WAIT peak, the
  differences of `ListenOverflows`, `ListenDrops`, `RetransSegs`, the ENA counters and the OOM lines; from the load box:
  CPU max second, the k6 container's memory peak; the healthy seconds; the wall per D95 when it failed.
- **k6's memory a VU (D93):** the smoke also runs `load.js` once at 2,000 and once at 5,000 VUs (real think time, 2
  minutes each, against the local server) and prints the k6 container's peak memory over VUs, with and without its
  baseline. It decides the load box's type before the policy is attached.
- **The server's CSV header** (in order): `epoch_ms, cpu_user, cpu_nice, cpu_system, cpu_idle, cpu_iowait, cpu_irq,
  cpu_softirq, cpu_steal, cg_usage_usec, cg_memory_current, cg_memory_peak, rss_kib, mem_available_kib, tcp_inuse,
  tcp_tw, tcp_mem_pages, passive_opens, active_opens, curr_estab, retrans_segs, listen_overflows, listen_drops,
  fds_per_process` (the last every 10th row, `pid:count` joined by `;`). Every row of the REST poll and of both samplers
  carries an epoch in milliseconds; the plateau is matched by time (both AWS boxes on Amazon Time Sync).
- **Cases (`check_score`):** the next-step rule (71,000 → 75,000 → 79,000; a pass then a fail starts the holds at the
  highest pass; a first fail at 71,000 starts them at 67,000; 6 failing holds stop); k6 exit 0, 99 and 1 (harness
  error stops the search); a void probe (k6 over its limits) stops with "bound by k6"; a modified `load.js` refused; the
  plateau window from a fixture of REST samples (the ramp, the plateau, the ramp-down); µs/req from a fixture CSV;
  one fixture per wall and two for their order (an OOM with 95 % busy names memory; an ENA counter grown with 90 % busy
  names network); a failing warm-up is a harness error.
- **`server-sample.sh`:** D95's counters, one row a second, cheap reads only (bash builtins on `/proc` and the
  cgroup's files, no fork on the 1 s path where avoidable); the fds every 10 s; the ENA counters and the OOM lines at
  start and stop; its own CPU at the end (it must stay under 1 % of the core). The load box's CPU and the k6
  container's memory are sampled by the driver itself.
- **Not here:** SSH, AWS, systemd (scope 2).

## Scope 2: the two boxes, set up the bench's way

- **Seams:** new `lab/score/server-setup.sh` (root, once, on the server box), `lab/score/php-gcob.service` (the unit),
  `lab/score/server-ctl.sh` (the controller on the server box: `restart`, `sample-start`, `sample-stop`, `facts`,
  which runs scope 1's `server-sample.sh`), `lab/score/k6-setup.sh` (root, once, on the load box), `tools/public-guard.sh` (D101) and its fixtures; in the
  factory, `aws/phase-7/launch.sh`, `aws/phase-7/README.md` and `aws/teardown.sh`
  (placement groups added to the teardown and to `--verify`), committed in the factory.
- **`server-setup.sh`** (`set -euo pipefail`): checks the shape first (`nproc` 1, MemTotal ≤ 2,048 MiB, no swap; else
  it prints which and exits 1, before any install); `useradd -m deploy`; the submission at `/srv/php-Gcob` owned by
  `deploy` (copied in, not a git checkout); `install.sh` as root, timed; `build.sh` as `deploy`; the seed at
  `/srv/seed/feed.db` (read-only, root), the live copy at `/srv/data/feed.db` (`/srv/data` owned by `deploy`: WAL
  writes beside the file); the unit installed and enabled, not started; then one start on a fresh copy, the healthy
  seconds, the challenge's `test/test.sh http://127.0.0.1:80` → `passed=42 failed=0`; each server process's user,
  `Max open files` and `CapAmb` (decoded) printed; `nf_conntrack` not loaded (printed). `--check` reruns only the
  checks.
- **The unit:** `User=deploy`, `Group=deploy`, `WorkingDirectory=/srv/php-Gcob`, `Environment=` the four SPEC.md
  variables (`SQLITE_PATH=/srv/data/feed.db`, `JWT_SECRET=twelve-dollar-challenge`, `HOST=0.0.0.0`, `PORT=80`),
  `ExecStart=/usr/bin/bash /srv/php-Gcob/start.sh`, `LimitNOFILE=65535`, `AmbientCapabilities=CAP_NET_BIND_SERVICE`,
  `Restart=no` (a crash shows; the probe then fails as the bench's would). Nothing else: what the bench's unit adds
  beyond the two named settings is unknown, and the README says so.
- **`server-ctl.sh restart`:** `systemctl stop`, the live copy and its `-wal`/`-shm` removed, `cp` from the seed,
  `chown deploy`, `sync`, `systemctl start`, `/health` polled every 0.1 s up to 60 s (exit 1 past it), prints the
  seconds. No page-cache drop (the bench's isn't known; the copy leaves the file in the cache, as a `cp` on the droplet
  would). `sample-start` starts `server-sample.sh` detached, `sample-stop` stops it and prints its CSV path.
- **`k6-setup.sh`:** Docker CE from Docker's apt (the factory's `bootstrap.sh` lines) with `"iptables": false` in
  `daemon.json` before its first start (D99), the pinned k6 image pulled, the
  secondary addresses read from the instance metadata and added to the interface if the OS hasn't, the ephemeral range
  set (D94), the challenge's clone at `162699a` (plain `git clone`, no `gh`), `lab/seed.sh` run there (its content hash
  checked), the seed copied to the server box over the private network, an SSH key made and its public half printed for
  the server box, the RTT measured (`ping -c 100`, min/avg/max). `--check` reruns the checks (k6's version, `nofile`,
  the addresses, the range, `load.js`'s hash, SSH to the server box).
- **`launch.sh`** (factory, private): one placement group (`strategy cluster`), one security group (22 from the Mac's
  address `/32`, all TCP from the group itself), one subnet (the default VPC's in `ca-central-1a`, both boxes; the
  secondary addresses need `--network-interfaces` with `SubnetId`, `Groups`, `AssociatePublicIpAddress=true`,
  `SecondaryPrivateIpAddressCount=3`, not the top-level `--security-group-ids`), the load box first then the server box (CPU options `CoreCount=1,
  ThreadsPerCore=1`; `mem=2G` set by `server-setup.sh`'s first step `--shape`, which reboots), both with
  `--instance-initiated-shutdown-behavior terminate`, a 40 GiB gp3 root deleted on termination, tagged
  `project=twelve-dollar-server` on the instance, the volume, the network interface, the group, the key pair and the
  placement group; writes `run-state.env`; `--print` makes no AWS call and prints the calls; `--dry-run` creates the placement group and the security group for real (free, tagged, removed by
  `teardown.sh`: a `RunInstances` dry run can't match the group's tag otherwise), then sends the two `RunInstances`
  and the key pair with AWS's `--dry-run` (AWS answers `DryRunOperation` when the policy allows it, `UnauthorizedOperation` when it doesn't),
  with stand-ins where a call needs an id that doesn't exist yet (the VPC's default group, no key), and creates nothing.
- **Cases:** the shape check refuses 2 CPUs, 4 GiB and a swap (fixtures through env overrides of the paths it reads);
  `restart` past 60 s exits 1; the sampler's columns on a lab container; `k6-setup.sh --check` refuses a changed
  `load.js`.

## Scope 3: the score on x86, Arjay's search

- **Before the launch:** the predictions below copied unchanged into `lab/results/<date>-x86-score/README.md` and
  committed; Jacob's go (🔴); `launch.sh --dry-run` clean.
- **The session, in order:** launch (the run log gets the ids, the time and the hard cap); then D98's order: `k6-setup.sh`, the
  key on the server box, `server-setup.sh --shape` (reboot, the cap re-armed), the seed pushed, `server-setup.sh` (the
  proofs, the 42 checks from the load box); both boxes' `conntrack_allowance_available` (D100); the facts and the RTT; then `search.sh` started
  detached on the load box with `--ctl` the SSH form of `server-ctl.sh`; the developer follows `search.json` and stops
  the session at the end of the search or at 3 h 30 of the boxes' life; the results copied back (`rsync` of the out
  folder, raw CSVs kept in the factory's `lab/`, the summaries in the public folder); `teardown.sh`, then `--verify`.
- **The README:** the predictions, the plan of the runs, the machine, the setup proofs, what differed from the plan,
  the results (`summarize.sh`: every run's row, the decisions, the plateau's server CPU, µs/req, RSS, accepts a second,
  the ENA counters, the load box's peaks), the score and its wall, what differs from the bench and the bench estimate
  (D96), the predictions judged. Counts only: no address, no id.
- **A stop:** a refused AWS call, a harness error, `mem=` not holding, or 42/42 not passing on the box: the session
  is torn down, `teardown.sh --verify` clean, and the run stops and reports.

## Scope 4: the submission's README, labelled

- **Seams:** `submissions/php-Gcob/README.md` ("Results"), nothing else.
- **What it says:** one paragraph: "Our own run, not the bench's score": the boxes (an AWS `c5.large` with one core
  and 2 GB, k6 on a separate box, the challenge's `load.js` unchanged), the users held 5 minutes, the wall, that the
  AWS core costs about 1.5 times less per request than the bench box (estimated from two entries; the bench
  box named as `LEADERBOARD.md` names it), so the bench should read lower, the
  link to scope 3's folder. No bench estimate as a claim (phase 6's rule): the factor is stated, the division isn't.

## Predictions (D5)

Written by the project manager on 2026-11-24 at 23:45, before any phase 7 run, and revised at 00:05 after the plan
review, still before any run: prediction 13 counts 15 to 19 k6 runs (a highest pass at 135,000 means 15 probes), and
prediction 8 reads the service's share of the core (D95). AWS `ca-central-1`, the server box as
D91 shapes it, the load box an `m5.4xlarge`, the submission at `main` `5a28a69`, unless a line says otherwise.

1. **k6's memory a VU** with the real `load.js` and real think time (scope 1, the Mac): 0.25 to 0.45 MiB (the lab's
   0.343 at shortened think time), so the `m5.4xlarge` stays.
2. **`install.sh` on the server box's one vCPU:** 280 to 450 s (232 to 237 s on one M3 core; the Xeon costs about 1.6
   times the M3 per request).
3. **The box:** `nproc` 1; MemTotal 1,900 to 2,048 MiB; the OS at idle uses 250 to 450 MiB (MemTotal minus
   MemAvailable); no swap.
4. **42/42** on the systemd service at the first try; healthy under 1 s after `systemctl start`.
5. **RTT** between the boxes in the cluster group: 0.04 to 0.15 ms (the bench: 0.25).
6. **The first probe, 71,000 users** (about 7,500 req/s): passes; the server 38 to 50 % busy; µs/req on the plateau
   52 to 62 (S1-b cost 57.75 at 7,500 req/s on the c5.2xlarge with the lab's telemetry on; the copy has none); p99
   under 100 ms; 0 errors.
7. **Accepts a second:** at most 1,000 to 2,500 during the 60 s ramp of a probe near 100,000 users (users over the
   ramp, spread by the script's first sleep of 0 to 5 s), under 10 a second on the plateau below 128,000 users (2 × the
   soft limit: no `Connection: close` there).
8. **The wall is the CPU:** the first failing probe has the service at 88 % of the core or more on its plateau's
   median second, with no ENA counter grown, no `ListenDrops`, no OOM and the load box under 50 % CPU.
9. **The highest passing probe: 111,000 to 135,000 users**, and the 5-minute hold passes there or one step under.
10. **The score on AWS: 105,000 to 135,000 users held 5 minutes.** The bench estimate (÷ 1.57): 67,000 to 86,000, so
    71,000 is beaten on the bench too with about 75 % confidence.
11. **Memory at the top:** the service's `memory.current` under 1.2 GiB, `MemAvailable` never under 250 MiB, no OOM.
12. **The load box at 130,000 VUs:** 35 to 55 GiB of k6, its CPU under 50 %: never the wall.
13. **The session:** 15 to 19 k6 runs (VU initialization measured per run), launch to teardown 2 h 30 to 3 h 30, under 5 USD.

## Out of scope

- **The ring, the PGO SQLite, the single-post plan:** phase 8 (D76, D84). The score here is the phase 6 submission's.
- **Tuning the submission for the box:** a change found useful goes to phase 8; phase 7 measures what ships.
- **The bench's full search from 2,500** (doubling, then bisecting): Jacob chose the short search (D90).
- **The bench's own box** (a Synteq VPS; rule 8 still says a DigitalOcean droplet, about twice as slow): Jacob chose
  AWS (D89); the difference is written next to the score (D96).
- **The challenge's repo and its fork, any `gh` command:** phase 9, with Jacob.
- **A bigger load box mid-run without Jacob:** the policy holds one load type; k6 as the wall ends the search and a 🔴
  offers one relaunch (D97).
