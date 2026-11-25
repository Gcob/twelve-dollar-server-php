# The score on x86, Arjay's search

Phase 7's session: the challenge's own `bench/load.js`, unmodified, run from a k6 box against a server box shaped like the droplet (one vCPU,
2 GiB, no swap), on two AWS boxes in one cluster placement group in `ca-central-1`, with Arjay's search (a warm-up, 2-minute probes stepping up
5 %, then 5-minute holds stepping down 5 %). The submission is `submissions/php-Gcob/` as it stands at `main` `5a28a69`. This file is written in two
steps: the predictions and the plan of the runs first (before any AWS call, committed that way), then the machines, the runs and the reading.

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

The plan above is what was written before the launch. Four things in it changed during the session, each for a reason given in "What differed from the plan".

## Result

**The score is 135,000 users: the 5-minute hold at 135,000 passed** (k6 exit 0 of the challenge's own `bench/load.js`, unmodified), on the one-vCPU, 2 GiB server box, with the server box's port 80 open to everyone so that its connections were not tracked by EC2 (the hold started after the opening). The hold's numbers: 14,122 requests a second on the plateau, p95 171 ms, p99 328 ms, no error, the service at 83.3 % of the core, `memory.current` peak 881 MiB.

**It is a lower bound, and the wall above it is not cleanly named.** The probes below 135,000 all passed. The next step, 142,000 users, failed three times:
- the first time it ran **tracked** (the port was being opened during it): EC2's connection-tracking table was exceeded (`conntrack_allowance_exceeded` +65,810, 4,033 dial errors). That is a wall of EC2's table, which the bench's box does not have;
- the two others ran **untracked** (port open): `conntrack_allowance_exceeded` stayed 0, the service was at 84.6 and 86.2 % of the core (below the 88 % of the CPU wall), and the load box was over 85 % on 19 of about 109 plateau seconds (5 or 6 in a row), above the line that makes a failing run void. Both are therefore void (k6 may have caused them), not fails.

So the server's own wall lies between 135,000 and 142,000 or above, and it is not separated from k6's garbage-collection spikes on this load box. The session did not try 139,000, a step the search's 5 % ladder skips.

**The packets-a-second allowance, next to the score.** The `c5.large` has a packets-a-second allowance (`pps_allowance_exceeded`, a count of packets EC2 held back) that the bench's box does not have. In this session it grew in every probe from 87,000 users up, and in the passing hold, so the score above was reached with it partly exhausted. The counts per run are in the third table of each search below; the values: 0 up to 83,000 users, +74 at 87,000, +119 at 91,000, +434 at 96,000, +740 at 101,000, +813 at 106,000, +1,772 at 111,000, +1,176 at 117,000, +1,433 at 123,000, +3,892 at 129,000, +4,760 at 135,000, **+5,902 in the 135,000 hold**, and +3,864, +6,690, +4,560 in the three 142,000 runs. Whether it cost the score anything is not established: every run that grew it up to 135,000 still passed.

**The estimate for the bench, written apart (not measured, CPU-scaled):** the server box is an Intel Xeon Platinum 8275CL, the processor the factor 1.57 was measured on (the bench's box is a Synteq 1 vCPU / 2 GB VPS, Xeon Platinum 8260, kernel 6.8, as the challenge's leaderboard names it). 135,000 / 1.57 is about **86,000 users** on the bench's box (1.50 to 1.63 gives 83,000 to 90,000). The factor scales the CPU cost of a request, and the CPU was not the wall here (the service was at 83 % of the core in the hold), so the estimate is likely conservative: the bench's box has neither EC2's allowances nor this load box's garbage-collection spikes. It stays an estimate.

## The machines

| | Server box | Load box |
|---|---|---|
| Type | `c5.large`, CPU options 1 core 1 thread | `m5.4xlarge`, 3 secondary private addresses (4 source addresses) |
| CPU | Intel Xeon Platinum 8275CL @ 3.00 GHz, `nproc` 1 | Intel Xeon Platinum 8259CL @ 2.50 GHz, 16 vCPUs |
| Kernel, OS | 7.0.0-1018-aws, Ubuntu 24.04.5 | 7.0.0-1018-aws, Ubuntu 24.04 |
| Memory | MemTotal 1,899 MiB (1,944,868 kB, `mem=2G` on the boot line), no swap; 406 MiB used at idle before the install, 414 MiB with the service | MemTotal 62 GiB (65,113,488 kB) |
| Disk | `fsync`: a 4 KiB write with `oflag=dsync` takes 1.72 ms (500 in 0.86 s) | |
| `nf_conntrack` | module loaded (Ubuntu's image), 0 entries, no rule | module loaded, 0 entries (Docker still writes `ip6` tables with `{"iptables": false}`); its table raised to 1,048,576 by the setup |
| EC2 conntrack allowance, `conntrack_allowance_available` | 136,801 (read at 07:38, 136,750 at the start of the smoke) | 820,833 |
| Network | both boxes in one cluster placement group, one subnet | |

Round trip between the boxes (100 pings, 0.2 s apart): min 0.058 ms, avg 0.069 ms, max 0.098 ms, 0 % lost.

## The setup's proofs

- Load box: `k6-setup.sh` took about 85 s (packages, Docker without iptables rules, k6 1.8.3 pinned, the challenge at its commit with `load.js`'s git blob hash checked, the seed rebuilt with its content hash checked, 20,000 tokens); `nofile` 1,048,576 in a container; ephemeral ports 1024 to 65535; 4 addresses on the interface.
- Server box: the first-boot wait was 1 s; `install.sh` took **425 s**; `build.sh` ran as `deploy`; the service is healthy 1 s after the start (whole seconds: 0 or 1 in every run); 3 processes run as `deploy` with `Max open files 65535` and `CapAmb 0000000000000400` (`cap_net_bind_service`); `ethtool` was already on the image.
- The challenge's 42 checks: **42/42, on the second try** (32/42 on the first: see "What differed from the plan").
- The smoke (100 users, 1 minute, the real run through the controller): k6 exit 0, `summary.json` written, k6's cgroup read (layout `systemd`), the server box's samples came back with every column, VU initialization 2.0 s.

## What differed from the plan

- **Three bugs of the scripts, found by the real boxes** (each fixed in a `fix(lab)` commit with a check that failed first): the metadata service answers without a final newline, so the address check read 3 addresses instead of 4; the live copy of the read-only seed kept its mode, so the database was read-only for the service and 10 of the 42 checks failed (the setup's own check only polled `/health`); the analysis counted the gauge `conntrack_allowance_available` as a counter that grew.
- **The void rule changed twice.** First: any plateau second with the load box over 85 % made a run void. The first probe (71,000 users) was void that way and the search stopped: the load box's median was 11 % and 6 of 120 seconds were over 85 %, never more than 2 in a row, the pattern of k6's garbage collector on its 20 GiB heap. Second: a run is void when the load box is over 85 % on more than 10 % of the plateau's seconds or on 5 in a row, or when k6 holds over 90 % of its memory. The second search then stopped at the probe at 129,000 (13 of 117 seconds, 4 in a row at most, 11.1 %) although it had passed. Third, the rule now in the driver: this saturation voids **only a run that fails**, because k6's pauses can only make the measured latency worse, so a run that passes despite them is a valid pass. A failing run with the load box over the line is void: it is neither a pass nor a fail. The run JSON files in this folder were made by the first rule (the first search) or the second (all the others, so they say `void: true` for the passing runs at 129,000 and 135,000); the tables below read them by the third (the "reading" column).
- **Port 80 and connection tracking.** The plan kept port 80 closed (so EC2 tracked the connections, each taking one of the server box's 136,801 tracked-connection allowance: it fell by about the number of users in every run before the opening). A tracked search could not go past about 136,000 users. Jacob opened port 80 to everyone himself during the session: the checks of the session's rule list saw it first at 09:34, and the last read without it was at 09:32. Every run of the two searches and the probe at 135,000 started with it closed (tracked); run 16, the first 142,000 probe, started closed and the rule appeared during it (it logged `conntrack_allowance_exceeded` +65,810 and 4,033 dial errors: tracked flows from before the rule); the hold at 135,000 and the two later 142,000 probes started after it, with fresh untracked connections: `conntrack_allowance_exceeded` stayed 0 and `conntrack_allowance_available` went up instead of down (the gauge is a count of tracked connections). Internet scanners may add a few requests to the measurement while the port is open.
- **The by-hand runs.** After the second search ended, the runs from 135,000 users (runs 15 to 19) were made by hand with the driver's own `run-k6.sh` (same flags, a fresh database and 60 s pause between runs, no new warm-up) by a small script of the session, because the time left would not allow a new search from the warm-up. It followed the search's rules (probes 5 % up while they pass, then holds 5 % down from the highest passing probe), with the two rules above. The probe at 142,000 was run again twice (the first one was tracked, the second and third untracked, all void); the session stopped there and did not try 139,000.
- **Smaller:** the kernel is 7.0, not 6.x; `nf_conntrack` is loaded on both boxes (empty), not absent; `--shape` ran in parallel with the load box's setup (they do not depend on each other); the seed push was forgotten before the first `server-setup.sh` (it refused in 1 s, nothing installed); k6 held 20 GiB at 71,000 users and 44 to 45 GiB at 142,000 on the `m5.4xlarge` load box, as the Mac measurement of 0.29 MiB a user predicted.
- **Not measured, not planned:** no hold above 135,000 and no hold below it was run (the first hold passed); the soft-limit's accepts show from 129,000 up (the median accepts a second is 104 at 129,000 and 736 at 135,000).

## The runs

The tables are regenerated by `summarize.sh` from the per-run JSON files in the three folders (`search-1-void/`, `search-2/`, `search-3/`). `search-1-void/` is the first search (stopped at its first probe, see above), `search-2/` the second (warm-up and probes 71,000 to 129,000), `search-3/` the by-hand runs. "Hot seconds" are the plateau seconds with the load box over 85 % (the longest streak in brackets) out of the plateau's seconds: they go from 4 of 120 at 71,000 users to 13 of 117 at 129,000 (a burst of 1 to 4 s about every 37 s), then 14 of 118 at 135,000 and 33 of 294 in the 5-minute hold. The load box's median CPU stays near 20 %.

<!-- BEGIN summarize -->
### search-1-void

| Run | kind | users | k6 exit | pass | p95 ms | p99 ms | error rate | plateau req/s | service share of the core | µs CPU/req | others on the box | VU init s | healthy s | wall | reading | port 80 at the start |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01-warmup-1000 | warmup | 1000 | 0 | true | 0.38 | 0.71 | 0 % | 106 | 0.8 % | 73.8 | 0.8 % | 1.6 | 0 | - | valid pass | closed |
| 02-probe-71000 | probe | 71000 | 0 | true | 2.21 | 15.66 | 0 % | 7509 | 42.2 % | 56.2 | 3.5 % | 6.3 | 1 | - | valid pass | closed |

| Run | accepts/s median on the plateau | accepts/s max on the plateau | accepts/s max in the run | CPU busy median | k6 memory GiB | load box CPU max | load box seconds over 85 % (longest streak) / plateau seconds | service memory.current MiB | MemAvailable min MiB | ENA allowance counters grown | ListenDrops | TCP in use peak | dial errors |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01-warmup-1000 | 0 | 10 | 24 | 2 % | 0.3 | 3.3 % | - (-) / - | 20 | 1480 | none | 0 | 1006 | 0 |
| 02-probe-71000 | 0 | 651 | 1274 | 46.1 % | 21.9 | 98.9 % | - (-) / - | 495 | 1151 | none | 0 | 71006 | 0 |

| Run | users | pps_allowance_exceeded (packets over the packets-a-second allowance, over the run) | conntrack_allowance_exceeded | conntrack_allowance_available change | reading |
|---|---|---|---|---|---|
| 01-warmup-1000 | 1000 | 0 | 0 | -1000 | valid pass |
| 02-probe-71000 | 71000 | 0 | 0 | -71001 | valid pass |

| # | decision | reason |
|---|---|---|
| 1 | warm-up at 1000 users for 2m | not scored; a failing warm-up is a harness error |
| 2 | probe at 71000 users for 2m | the start |

End: **bound-by-k6**. at least 0, bound by k6: the load box's CPU reached 99 % on a plateau second at 02-probe-71000

### search-2

| Run | kind | users | k6 exit | pass | p95 ms | p99 ms | error rate | plateau req/s | service share of the core | µs CPU/req | others on the box | VU init s | healthy s | wall | reading | port 80 at the start |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01-warmup-1000 | warmup | 1000 | 0 | true | 0.39 | 0.66 | 0 % | 105 | 0.7 % | 69.3 | 1 % | 1.7 | 0 | - | valid pass | closed |
| 02-probe-71000 | probe | 71000 | 0 | true | 2.18 | 16.68 | 0 % | 7509 | 41.8 % | 55.7 | 3.6 % | 6.3 | 1 | - | valid pass | closed |
| 03-probe-75000 | probe | 75000 | 0 | true | 2.81 | 16.49 | 0 % | 7934 | 44.1 % | 55.6 | 3.3 % | 6.3 | 1 | - | valid pass | closed |
| 04-probe-79000 | probe | 79000 | 0 | true | 3 | 16.99 | 0 % | 8357 | 45.6 % | 54.5 | 3.4 % | 7.2 | 1 | - | valid pass | closed |
| 05-probe-83000 | probe | 83000 | 0 | true | 3.18 | 16.88 | 0 % | 8778 | 46.7 % | 53.2 | 3.4 % | 6.3 | 1 | - | valid pass | closed |
| 06-probe-87000 | probe | 87000 | 0 | true | 5.19 | 22.14 | 0 % | 9195 | 49.5 % | 53.8 | 3.4 % | 7.2 | 1 | - | valid pass | closed |
| 07-probe-91000 | probe | 91000 | 0 | true | 6.76 | 21.65 | 0 % | 9627 | 52.1 % | 54.1 | 3.7 % | 7.2 | 1 | - | valid pass | closed |
| 08-probe-96000 | probe | 96000 | 0 | true | 9.57 | 28.26 | 0 % | 10148 | 55 % | 54.2 | 3.3 % | 8.2 | 0 | - | valid pass | closed |
| 09-probe-101000 | probe | 101000 | 0 | true | 12.04 | 41.72 | 0 % | 10685 | 57.3 % | 53.6 | 3.1 % | 8.2 | 1 | - | valid pass | closed |
| 10-probe-106000 | probe | 106000 | 0 | true | 20.22 | 226.54 | 0 % | 11210 | 60.2 % | 53.7 | 3.2 % | 9.2 | 0 | - | valid pass | closed |
| 11-probe-111000 | probe | 111000 | 0 | true | 16.01 | 54.96 | 0 % | 11733 | 63.2 % | 53.9 | 3.3 % | 8.2 | 0 | - | valid pass | closed |
| 12-probe-117000 | probe | 117000 | 0 | true | 19.12 | 46.12 | 0 % | 12369 | 66.4 % | 53.7 | 3.5 % | 9.2 | 0 | - | valid pass | closed |
| 13-probe-123000 | probe | 123000 | 0 | true | 34.08 | 92.52 | 0 % | 12984 | 70.8 % | 54.5 | 3.2 % | 9.1 | 0 | - | valid pass | closed |
| 14-probe-129000 | probe | 129000 | 0 | true | 68.38 | 146.44 | 0 % | 13604 | 75.5 % | 55.5 | 2.8 % | 9.2 | 0 | - | valid pass | closed |

| Run | accepts/s median on the plateau | accepts/s max on the plateau | accepts/s max in the run | CPU busy median | k6 memory GiB | load box CPU max | load box seconds over 85 % (longest streak) / plateau seconds | service memory.current MiB | MemAvailable min MiB | ENA allowance counters grown | ListenDrops | TCP in use peak | dial errors |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01-warmup-1000 | 0 | 16 | 27 | 2 % | 0.4 | 2.8 % | 0 (0) / 121 | 20 | 1448 | none | 0 | 1007 | 0 |
| 02-probe-71000 | 0 | 794 | 1276 | 45.9 % | 20.4 | 98.9 % | 4 (1) / 120 | 437 | 1131 | none | 0 | 71006 | 0 |
| 03-probe-75000 | 0 | 1005 | 1325.7 | 47.5 % | 23.3 | 98.8 % | 7 (2) / 120 | 507 | 1089 | none | 0 | 75007 | 0 |
| 04-probe-79000 | 0 | 1003 | 1381 | 49.5 % | 22.8 | 98.8 % | 6 (2) / 121 | 594 | 1084 | none | 0 | 79007 | 0 |
| 05-probe-83000 | 0 | 1225.3 | 1460 | 50.5 % | 25.7 | 98.8 % | 6 (2) / 120 | 649 | 1079 | none | 0 | 83007 | 0 |
| 06-probe-87000 | 0 | 954 | 1531 | 53.4 % | 25.5 | 98.6 % | 8 (2) / 120 | 664 | 1033 | pps_allowance_exceeded +74 | 0 | 87007 | 0 |
| 07-probe-91000 | 0 | 1226 | 1608 | 56.5 % | 27.8 | 98.6 % | 5 (2) / 120 | 634 | 1026 | pps_allowance_exceeded +119 | 0 | 91008 | 0 |
| 08-probe-96000 | 0 | 1328 | 1696 | 58.8 % | 28.2 | 98.6 % | 8 (2) / 120 | 794 | 1022 | pps_allowance_exceeded +434 | 0 | 96007 | 0 |
| 09-probe-101000 | 0 | 946.1 | 1755 | 60.8 % | 30.6 | 99 % | 7 (3) / 120 | 796 | 986 | pps_allowance_exceeded +740 | 0 | 101007 | 0 |
| 10-probe-106000 | 0 | 1063.9 | 1999 | 64 % | 31.4 | 99.1 % | 10 (3) / 120 | 692 | 936 | pps_allowance_exceeded +813 | 0 | 106008 | 0 |
| 11-probe-111000 | 0 | 1226 | 1930.1 | 67.3 % | 33.1 | 100 % | 9 (3) / 120 | 746 | 950 | pps_allowance_exceeded +1772 | 0 | 111007 | 0 |
| 12-probe-117000 | 0 | 1827 | 2039 | 70.4 % | 35.4 | 100 % | 10 (4) / 120 | 789 | 823 | pps_allowance_exceeded +1176 | 0 | 117006 | 0 |
| 13-probe-123000 | 0 | 1695.3 | 2303 | 74.7 % | 37.4 | 100 % | 12 (4) / 120 | 812 | 901 | pps_allowance_exceeded +1433 | 0 | 123008 | 0 |
| 14-probe-129000 | 104.1 | 1753.5 | 2261.3 | 79.2 % | 39.8 | 100 % | 13 (4) / 117 | 826 | 785 | pps_allowance_exceeded +3892 | 0 | 128017 | 0 |

| Run | users | pps_allowance_exceeded (packets over the packets-a-second allowance, over the run) | conntrack_allowance_exceeded | conntrack_allowance_available change | reading |
|---|---|---|---|---|---|
| 01-warmup-1000 | 1000 | 0 | 0 | -1001 | valid pass |
| 02-probe-71000 | 71000 | 0 | 0 | -70995 | valid pass |
| 03-probe-75000 | 75000 | 0 | 0 | -75002 | valid pass |
| 04-probe-79000 | 79000 | 0 | 0 | -78997 | valid pass |
| 05-probe-83000 | 83000 | 0 | 0 | -82999 | valid pass |
| 06-probe-87000 | 87000 | 74 | 0 | -86994 | valid pass |
| 07-probe-91000 | 91000 | 119 | 0 | -91004 | valid pass |
| 08-probe-96000 | 96000 | 434 | 0 | -95997 | valid pass |
| 09-probe-101000 | 101000 | 740 | 0 | -100999 | valid pass |
| 10-probe-106000 | 106000 | 813 | 0 | -106000 | valid pass |
| 11-probe-111000 | 111000 | 1772 | 0 | -110996 | valid pass |
| 12-probe-117000 | 117000 | 1176 | 0 | -117000 | valid pass |
| 13-probe-123000 | 123000 | 1433 | 0 | -122998 | valid pass |
| 14-probe-129000 | 129000 | 3892 | 0 | -128704 | valid pass |

| # | decision | reason |
|---|---|---|
| 1 | warm-up at 1000 users for 2m | not scored; a failing warm-up is a harness error |
| 2 | probe at 71000 users for 2m | the start |
| 3 | probe at 75000 users for 2m | 5 % up from 71000, rounded to 1000 |
| 4 | probe at 79000 users for 2m | 5 % up from 75000, rounded to 1000 |
| 5 | probe at 83000 users for 2m | 5 % up from 79000, rounded to 1000 |
| 6 | probe at 87000 users for 2m | 5 % up from 83000, rounded to 1000 |
| 7 | probe at 91000 users for 2m | 5 % up from 87000, rounded to 1000 |
| 8 | probe at 96000 users for 2m | 5 % up from 91000, rounded to 1000 |
| 9 | probe at 101000 users for 2m | 5 % up from 96000, rounded to 1000 |
| 10 | probe at 106000 users for 2m | 5 % up from 101000, rounded to 1000 |
| 11 | probe at 111000 users for 2m | 5 % up from 106000, rounded to 1000 |
| 12 | probe at 117000 users for 2m | 5 % up from 111000, rounded to 1000 |
| 13 | probe at 123000 users for 2m | 5 % up from 117000, rounded to 1000 |
| 14 | probe at 129000 users for 2m | 5 % up from 123000, rounded to 1000 |

End: **bound-by-k6**. at least 123000, bound by k6: the load box's CPU was over 85 % on 13 of 117 plateau seconds (4 in a row at most, peak 100 %) at 14-probe-129000

### search-3

| Run | kind | users | k6 exit | pass | p95 ms | p99 ms | error rate | plateau req/s | service share of the core | µs CPU/req | others on the box | VU init s | healthy s | wall | reading | port 80 at the start |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 15-probe-135000 | probe | 135000 | 0 | true | 231.2 | 775.6 | 0 % | 14003 | 82.5 % | 58.9 | 2.4 % | 11 | 0 | - | valid pass | closed |
| 16-probe-142000 | probe | 142000 | 99 | false | 1353.33 | 3142.48 | 0.168 % | 13342 | 78.2 % | 58.6 | 1.9 % | 11.3 | 1 | k6 | void (k6 over the line) | opened during the run |
| 17-hold-135000 | hold | 135000 | 0 | true | 170.63 | 328.28 | 0 % | 14122 | 83.3 % | 59 | 2.1 % | 10.7 | 0 | - | valid pass | open |
| 18-probe-142000 | probe | 142000 | 99 | false | 728.41 | 1878.4 | 0 % | 14123 | 84.6 % | 59.9 | 1.5 % | 11.2 | 0 | k6 | void (k6 over the line) | open |
| 19-probe-142000 | probe | 142000 | 99 | false | 1109.39 | 3919.24 | 0 % | 14401 | 86.2 % | 59.9 | 1.4 % | 11.4 | 0 | k6 | void (k6 over the line) | open |

| Run | accepts/s median on the plateau | accepts/s max on the plateau | accepts/s max in the run | CPU busy median | k6 memory GiB | load box CPU max | load box seconds over 85 % (longest streak) / plateau seconds | service memory.current MiB | MemAvailable min MiB | ENA allowance counters grown | ListenDrops | TCP in use peak | dial errors |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 15-probe-135000 | 736.5 | 1715 | 2694 | 89 % | 42.2 | 100 % | 14 (5) / 118 | 876 | 814 | pps_allowance_exceeded +4760 | 0 | 128228 | 0 |
| 16-probe-142000 | 1319 | 5303 | 5303 | 89.8 % | 44.2 | 100 % | 26 (12) / 110 | 968 | 801 | pps_allowance_exceeded +3864, conntrack_allowance_exceeded +65810 | 0 | 129724 | 4033 |
| 17-hold-135000 | 734.5 | 2279 | 2620 | 86.7 % | 43 | 100 % | 33 (6) / 294 | 881 | 810 | pps_allowance_exceeded +5902 | 0 | 128349 | 0 |
| 18-probe-142000 | 1445 | 3544 | 3544 | 92.1 % | 44.6 | 100 % | 19 (6) / 109 | 1090 | 804 | pps_allowance_exceeded +6690 | 0 | 129059 | 0 |
| 19-probe-142000 | 1448 | 6093.9 | 6093.9 | 92.8 % | 45.1 | 100 % | 19 (5) / 109 | 972 | 797 | pps_allowance_exceeded +4560 | 0 | 129603 | 0 |

| Run | users | pps_allowance_exceeded (packets over the packets-a-second allowance, over the run) | conntrack_allowance_exceeded | conntrack_allowance_available change | reading |
|---|---|---|---|---|---|
| 15-probe-135000 | 135000 | 4760 | 0 | -131168 | valid pass |
| 16-probe-142000 | 142000 | 3864 | 65810 | -127354 | void (k6 over the line) |
| 17-hold-135000 | 135000 | 5902 | 0 | 13479 | valid pass |
| 18-probe-142000 | 142000 | 6690 | 0 | 7337 | void (k6 over the line) |
| 19-probe-142000 | 142000 | 4560 | 0 | 8320 | void (k6 over the line) |

The decisions, in the load box's clock (UTC), as the by-hand script logged them:

```text
14:27:01 decision: probe at 135000 (5 % up from the last pass)
14:27:01 start probe 135000 for 2m -> search-3/15-probe-135000
14:31:00 result probe 135000: k6_exit=0 pass=true void=true wall=- ena_exceeded_grown=1 p95=231.2 p99=775.6 req_s=14003 service=82.5 hot=14/118 streak 5 accmed=737
14:31:00 decision: probe at 142000 (5 % up from the last pass)
14:32:00 start probe 142000 for 2m -> search-3/16-probe-142000
14:36:00 result probe 142000: k6_exit=99 pass=false void=true wall=k6 ena_exceeded_grown=2 p95=1353.3 p99=3142.5 req_s=13342 service=78.2 hot=26/110 streak 12 accmed=1319
14:36:00 decision: probe 142000 did not pass (void=true wall=k6): stop stepping up, holds start at 135000
14:36:00 decision: hold at 135000 for 5m
14:37:00 start hold 135000 for 5m -> search-3/17-hold-135000
14:44:00 result hold 135000: k6_exit=0 pass=true void=true wall=- ena_exceeded_grown=1 p95=170.6 p99=328.3 req_s=14122 service=83.3 hot=33/294 streak 6 accmed=735
14:44:00 END: score 135000 (hold passed)
14:46:10 decision: probe at 142000 (5 % up from the last pass)
14:47:10 start probe 142000 for 2m -> search-3/18-probe-142000
14:51:10 result probe 142000: k6_exit=99 pass=false void=true wall=k6 ena_exceeded_grown=1 p95=728.4 p99=1878.4 req_s=14123 service=84.6 hot=19/109 streak 6 accmed=1445
14:51:10 decision: probe 142000 did not pass (void=true wall=k6): stop stepping up, holds start at 135000
14:51:10 END: no probe passed above 135,000: the score stays 135000 (hold passed at 17-hold-135000)
14:52:27 decision: probe at 142000 (5 % up from the last pass)
14:53:27 start probe 142000 for 2m -> search-3/19-probe-142000
14:57:26 result probe 142000: k6_exit=99 pass=false void=true wall=k6 ena_exceeded_grown=1 p95=1109.4 p99=3919.2 req_s=14401 service=86.2 hot=19/109 streak 5 accmed=1448
14:57:26 decision: probe 142000 did not pass (void=true wall=k6): stop stepping up, holds start at 135000
14:57:26 END: no probe passed above 135,000: the score stays 135000 (hold passed at 17-hold-135000)
```
<!-- END summarize -->

## What differs from the bench (the score is AWS's)

- **The score above is what the challenge's own script measured on AWS, not on the bench's box.** The bench's box (a Synteq VPS with one vCPU and 2 GiB, Xeon Platinum 8260, kernel 6.8) is slower per request than this server box (Xeon Platinum 8275CL @ 3.0 GHz); the plan's factor between the two is 1.57 (measured on a Xeon Platinum 8275CL, so it applies to this box and nothing else), giving the estimate of about 86,000 above. It is an estimate, not a measurement.
- **EC2 has tables and allowances the bench's box does not:** a connection-tracking allowance (136,801 on this box, avoided by Jacob's opening of port 80) and the packets-a-second allowance described next to the score, which grew from 87,000 users up.
- **The round trip is 0.069 ms** (the bench's is 0.25 ms) because both boxes sit in one cluster placement group; the load box is 16 vCPUs and 62 GiB (the bench's k6 box is smaller), and k6's own garbage collection on a 20 to 45 GiB heap is part of the measured latency here.
- **The search is the plan's short one** (a start at 71,000, steps of 5 %), not the bench's full search from 2,500; the result is the highest passing hold, 135,000.

## The predictions, judged

| # | Prediction | Result |
|---|---|---|
| 1 | k6's memory a VU 0.25 to 0.45 MiB | Inside: 0.286 to 0.298 MiB on the Mac; on AWS 20.4 GiB at 71,000 users (0.29 MiB a user), 39.8 GiB at 129,000 (0.32). |
| 2 | `install.sh` 280 to 450 s | Inside: 425 s. |
| 3 | `nproc` 1; MemTotal 1,900 to 2,048 MiB; OS 250 to 450 MiB; no swap | Almost: MemTotal 1,899 MiB (1,899.3, 1 MiB under the range), the rest inside (406 MiB, no swap). |
| 4 | 42/42 first try; healthy under 1 s | Missed: 32/42 first (a bug of ours, the read-only database), 42/42 on the second try. Healthy 1 s (whole seconds, 0 or 1). |
| 5 | RTT 0.04 to 0.15 ms | Inside: 0.058 / 0.069 / 0.098 ms. |
| 6 | First probe passes, server 38 to 50 % busy, 52 to 62 µs/req, p99 under 100 ms, 0 errors | Inside: 71,000 passed twice, service 41.8 to 42.2 % of the core (box busy 46 %), 55.7 to 56.2 µs/req, p99 15.7 to 16.7 ms, 0 errors. |
| 7 | Accepts a second: 1,000 to 2,500 at most during a probe's ramp near 100,000 users, under 10 a second on the plateau below 128,000 | Ramp: inside (1,755 at 101,000, 2,303 at 123,000). Plateau: the median is 0 (so, under 10) but the largest second is 794 to 1,827 below 128,000 . Half missed. |
| 8 | The wall is the CPU: the first failing probe has the service at 88 % or more, no ENA counter grown, no `ListenDrops`, no OOM, load box under 50 % | Missed: 142,000 failed with the service at 78 to 86 %, `pps_allowance_exceeded` grown, the load box over 85 % on 19 to 26 seconds, so no wall is named. No `ListenDrops`, no OOM. |
| 9 | Highest passing probe 111,000 to 135,000, the hold passes there or one step under | Inside, at the top: 135,000 passed as a probe and as a hold. |
| 10 | The score 105,000 to 135,000; the bench estimate 67,000 to 86,000 | Inside, at the top edge: 135,000, the bench estimate about 86,000 (a lower bound). 71,000 is beaten with room. |
| 11 | Memory: `memory.current` under 1.2 GiB, `MemAvailable` never under 250 MiB, no OOM | Inside: peak 881 MiB in the passing hold (1,090 MiB in the worst 142,000 run), `MemAvailable` minimum 785 MiB, no OOM. |
| 12 | The load box at 130,000 VUs: 35 to 55 GiB of k6, CPU under 50 %, never the wall | k6's memory inside (39.8 GiB at 129,000, 42 to 45 at 135,000 and 142,000); the median CPU is 20 %, but the load box was over 85 % on 12 to 33 plateau seconds from 123,000 up, and k6 cannot be ruled out as part of the 142,000 failures. Half missed. |
| 13 | 15 to 19 k6 runs, 2 h 30 to 3 h 30, under 5 USD | 21 runs on AWS (2 of the first search, 14 of the second, 5 by hand) plus the smoke: over. 2 h 29 launch to teardown: 1 min under the range. About 2 USD by the hourly prices (an estimate, not a bill): inside. |

## Where the files are

This folder keeps, for each search, the `search.json` of the two driver searches (its address list replaced) and every run's `run.json`, plus the by-hand script's `decisions.log`. The raw CSVs, k6's logs and summaries, the boxes' own output and anything that names a machine are in the project's private repository, under `lab/2026-11-25-x86-score/`. Nothing here names an address, an identifier or a host.
