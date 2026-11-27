# The score on x86, phase 7's server and phase 8's side by side

Phase 7's session again, with two server boxes: the challenge's own `bench/load.js`, unmodified, run from one k6 box against two server boxes
shaped like the droplet (one vCPU, 2 GiB, no swap, the generic 6.8 kernel), in one cluster placement group in `ca-central-1`. `server-a` runs
phase 7's submission as it was (`submissions/php-Gcob/` before the tuned SQLite and the ring), `server-b` runs phase 8's (the ring on three rings
and the tuned SQLite). Both boxes get the same tree for `lab/`; only `submissions/php-Gcob/` differs. This file is written in two steps: the
predictions and the plan of the runs first (before any AWS call, committed that way), then the machines, the runs and the reading.

## Predictions

Copied unchanged from the phase's plan. They are the plan's predictions 10 to 13 (the earlier ones were judged in the folders of the Mac's and the
first x86 sessions). The `(D125)` in 13 is the plan's own name for the choice of one load box and two server boxes.

> Written by the project manager on 2026-11-26 at 15:10, before any phase 8 run; 13 said 4 boxes before D125.

10. Phase 7's server: at 101,000 users 52 to 56 µs/req (phase 7: 53.6); its ceiling with a load that doesn't bind
    138,000 to 145,000 held, its wall the CPU (service median second over 88 %) or the kernel's TCP memory.
11. Phase 8's server (the ring): at 101,000 users 42 to 49 µs/req; its ceiling 142,000 to 160,000 held, its wall the
    kernel's TCP memory or the packets-a-second allowance before its CPU (the 2 GiB box logged `TCP: out of memory`
    at 142,000 in phase 7, with either server).
12. The bench estimates (5.12 million / µs): phase 7's about 86,000 (unchanged), phase 8's 100,000 to 120,000.
13. Cost and time: the score session 3 to 4 h with 3 boxes (D125), under 10 USD.

## Plan of the runs

Written before the launch. The boxes are an `m5.8xlarge` (the load box: two k6 containers, each on its own 16 vCPUs and 2 of the 4 source
addresses) and two `c5.large` limited to one vCPU at launch (`server-a` and `server-b`), all Ubuntu 24.04, all with a hard shutdown cap of 240
minutes armed at the first ssh. `launch.sh` and `teardown.sh` are the session's AWS scripts: they are private (they hold account details), and so
is the run log. `teardown.sh --verify` ends `TEARDOWN CLEAN` when nothing tagged is left.

1. `teardown.sh --verify` clean, `launch.sh --dry-run` (a refusal of any call stops the session, the policy is never edited), the teardown of what
   the dry run made and `--verify` clean, then the real launch. The cap (`shutdown -h +240`) on every box at its first ssh.
2. Each server box: `server-setup.sh --shape --kernel generic` (one reboot: `mem=2G` and the generic 6.8), in parallel on both boxes and with the
   load box's setup. After the reboot `--check` must say `kernel-flavour: generic chosen, generic running`, `uname -r` a `6.8.*-generic` and MemTotal
   at most 2,048 MiB: anything else is a stop. Then the install (`--launch-epoch`), the cap re-armed.
3. The challenge's 42 checks on each server box, and each box's `loop:` line: `server-a` must say `epoll`, `server-b` `ring, 3 rings, legacy buffers`
   (anything else is a stop). The box's CPU model and the CPU-only micro (`lab/score/cpu-micro.php`) are read on each: two different CPU models mean
   no reading across the two boxes, and this file says so.
4. The smokes and a warm-up on each server, then the fixed-load probes at 101,000 users, A B B A across the two servers (A is `server-a`, B is
   `server-b`; two k6 halves).
5. The ring-only pair, on `server-b` alone, at the same fixed load, probe length and warm-up as step 4, in the order A1, B1, B2, A2: A is the ring
   off (`kernel.io_uring_disabled=2` and a restart: the `loop:` line must say the epoll fallback), B is the ring on (`kernel.io_uring_disabled=0`
   and a restart: `ring, 3 rings, legacy buffers`). The setting goes back to 0 afterwards and the searches run with it at its default. This toggle
   is a test switch, not a tuning of the score. If it does not produce the fallback's `loop:` line the pair is skipped and said so.
6. Phase 8's search first (`server-b`: its number is the one at risk in the time box), then phase 7's (`server-a`): probes from 135,000 users in 5 %
   steps until one fails, one probe halfway back, then 5-minute holds stepping down 2.5 % from the highest pass (`search.sh --finer`, two k6
   halves). A void run stops the search itself and the session is reported before the teardown.
7. The results copied back (once in the middle too if the session passes 90 minutes), the teardown, `--verify`, the key and its `known_hosts`
   lines deleted.

**Time limits.** The boxes' life stops at 3 h 30 from the launch whatever is left; no new run starts after 3 h 10. If the time is tight, phase 7's
search is cut first, and the ring-only pair stays before it.

**What goes where.** This folder keeps the per-run JSON files, the searches' `search.json` and the tables, which `summarize.sh` regenerates. The
raw files (the CSVs, k6's logs, the boxes' facts, anything that names a machine) are in the private factory repository.
