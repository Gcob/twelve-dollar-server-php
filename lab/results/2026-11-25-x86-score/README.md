# The score on x86, Arjay's search

Phase 7's session: the challenge's own `bench/load.js`, unmodified, run from a k6 box against a server box shaped like the droplet (one vCPU,
2 GiB, no swap), on two AWS boxes in one cluster placement group in `ca-central-1`, with Arjay's search (a warm-up, 2-minute probes stepping up
5 %, then 5-minute holds stepping down 5 %). The submission is `submissions/php-Gcob/` as it stands at `main` `5a28a69`. This file is written in two
steps: the predictions and the plan of the runs first (before any AWS call), then the machines, the runs and the reading.

## Predictions

Copied unchanged from the phase's plan. Prediction 1 was judged earlier, on the Mac (0.286 to 0.298 MiB a VU at 2,000 and 5,000 VUs, inside 0.25 to 0.45).

> Written by the project manager on 2026-11-24 at 23:45, before any phase 7 run, and revised at 00:05 after the plan review, still before any run.

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

## Plan of the runs

Written before the launch. The boxes are an `m5.4xlarge` (the load box: k6 at 71,000 users and more needs 19 GiB and over) and a `c5.large` limited to
one vCPU at launch (the server box), both Ubuntu 24.04, both with a hard shutdown cap of 240 minutes armed at the first ssh.

The order of the session, each step with its time written in the private run log:

1. `launch.sh --dry-run`: a refusal of any call stops the session (the policy is never edited). Then the teardown of what the dry run made and `--verify`
   clean, then the real launch.
2. The cap on both boxes at the first ssh; the tree sent to both with `git archive` of the commit that holds the scripts.
3. The load box: `k6-setup.sh` (Docker without iptables rules, k6 pinned, the challenge at its commit with `load.js`'s hash checked, the seed built, an ssh key).
   The key goes to the server box's `authorized_keys` from the Mac.
4. The server box: `server-setup.sh --shape` (`mem=2G` on the boot line, reboot). MemTotal over 2,048 MiB after the reboot is a stop.
5. The seed pushed from the load box; then `server-setup.sh --launch-epoch` (install, `build.sh`, the unit; the cap re-armed).
6. The load box: `k6-setup.sh --check`, `--check-42` (42 of 42 or a stop), `--rtt` (100 pings), `--allowance`; the server box's allowance counters
   from its sampler's start facts; then `--smoke` (one minute at 100 users on the real boxes). A failing smoke is a stop.
7. The search, detached on the load box, log in its out folder:
   `search.sh --start 71000 --step 5 --round 1000 --probe 2m --hold 5m --warmup 1000,2m --max-holds 6` with the tokens, the four local addresses
   and the controller that reaches the server box over ssh. Followed with long waits, never a poll. The out folder is copied back to the Mac at
   the end, and once in the middle if the search runs past 90 minutes.
8. The teardown, then `--verify` ending `TEARDOWN CLEAN`; the key file deleted.

How the search reads a run: k6's exit code decides (0 pass, 99 threshold crossed, anything else a harness error and a stop). A run is void when the
load box was over 85 % CPU on a plateau second or k6 held over 90 % of that box's memory: the search then ends at "at least the highest pass, bound
by k6". The wall of a failing run is named in this order: k6 (void), memory (an OOM line, or `MemAvailable` under 100 MiB), died (the service stopped
with neither), network (an ENA allowance counter grew), fds (`ListenDrops` grew, or k6 had dial errors while a process held 65,435 descriptors or more), cpu (the service over 88 %
of the core on its plateau's median second), latency below saturation.

**Connection tracking stays on:** the server box's security group tracks connections (port 80 is not opened to everyone to untrack it), so the
session runs tracked whatever the allowance number says. If `conntrack_allowance_exceeded` grows in a run, the wall is named `network` and it is EC2's
connection-tracking table, which the bench's own box does not have.

**Others:** a plateau where the processes other than the service and the sampler use over 5 % of the core is run again once. The driver does not do
this itself; the rerun is made by hand with `run-k6.sh` after the search, in a folder of its own, and said so here.

**The stops** (the boxes are torn down and `--verify` is clean, then the session is reported before going on): a refused AWS call; a harness error
the driver reports; MemTotal over 2,048 MiB after the reboot; the 42 checks not passing; the smoke failing; the boxes' life past 3 h 30. A void run is
the exception: the search stops itself and the session is reported **before** the teardown, because one bigger load box may be allowed.

**What goes where:** this folder keeps the per-run JSON files and `search.json` (the guard checked), and the tables below, which `summarize.sh`
regenerates. The raw files (the CSVs, k6's logs, the boxes' facts, anything that names a machine) are in the private factory repository.
