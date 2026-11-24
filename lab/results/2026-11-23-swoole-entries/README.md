# The two Swoole entries in our realistic mode

What the leaderboard's two real-PHP entries (`php-swoole-mattsplat`, 94 µs per request on the bench, and `php-swoole-tzimpel`, 101 µs)
cost in our realistic mode on the Mac, unchanged, against the skeleton, and what that says about the Mac-to-bench factor. Docker
Desktop on an M3 Pro (arm64), 1 CPU, 2 GiB. These are arm64 numbers, not a score. This file is written in two steps: the predictions and
the plan of the runs first (below, committed before any run), then the results and the verdicts.

## Predictions (D5)

Added on 2026-11-22 at 22:08 with scope 13 (D61), before any of its runs:

14. **The Swoole entries at 12,000 req/s with 60,000 idle on the Mac:** mattsplat 35 to 55 µs/req, tzimpel 40 to 60
    (his own Mac reading was 50 to 60 at fewer connections); both above the skeleton's S1-a.
15. **The Mac-to-bench factors** (94 and 101 over their Mac µs): 1.7 to 2.7 each, within 25 % of each other.
16. **Memory:** both hold the 60,000 idle within 2 GiB; mattsplat's `memory.current` is 2 to 4 times tzimpel's (its
    64 KiB receive buffer stays after each idle connection's first request; tzimpel's patch frees it).
17. **The skeleton on the bench** (its Mac µs at 12,000 times the mean factor): 45 to 75 µs per request, so scope 12
    should read 1.7 to 2.7 times the Mac on the Xeon.

**How they're judged:** a µs/req is the median of a variant's runs; a range holds if the measured value is inside it. The skeleton's
S1-a at 12,000 req/s, 27.95 µs/req, and the A/A floor of that rate, 1.43 µs/req, come from the S1 series (`2026-11-23-s1-fd-wall`).

## Plan of the runs

Every series starts with `docker ps` showing no container: the VM is quiet. No image build and no `lab/check.sh` during a series.

1. **The entries as they are:** their `server.php` (and tzimpel's `php.ini`) copied byte for byte under `lab/servers/swoole-entries/`,
   run in the lab's container on `php-lab:8.3-apt` (PHP 8.3 from apt, Swoole 6.2.6; the entries used 6.2.3). Their `install.sh` and
   `build.sh` are never run. tzimpel's Swoole patch (the receive buffer freed after each request) is the one `perl -0pi` line of his
   `build.sh`, applied to our Swoole 6.2.6 source in its own image, `php-lab:8.3-apt-tzimpel`, with his check that it applied exactly twice;
   if it does not apply twice to 6.2.6, tzimpel's entry runs on stock Swoole and the README says so.
2. **Correctness first:** the challenge's own suite (`lab/challenge-test.sh`) on each entry, 42 of 42.
3. **One pair each against the skeleton:** `lab/steplab.sh` at 12,000 req/s (`s = 0.02`, 60,000 idle, 60 s plateau, the baseline's warm-up),
   the skeleton first in every round, the entry second, one round each. The skeleton is the S1 series' S1-a (PHP 8.5, telemetry on); the
   entry is on 8.3-apt with its own flags. The pair is read with the A/A floor of 12,000 req/s.
4. **Memory and descriptors:** one run of each entry with the per-second probes on (`lab/realistic.sh --hold` at the same rate and shape;
   the step lab's runs have the probes off so that they do not cost CPU): the server's `memory.current` peak, its anonymous memory and its
   descriptors. If an entry cannot hold the 60,000 idle connections within 2 GiB, that is the result, and it is rerun once at the most it held.
5. **The factors:** 94 over mattsplat's Mac µs per request, 101 over tzimpel's; if they agree (prediction 15), the skeleton's Mac µs at
   12,000 req/s times their mean is its bench estimate, the number the x86 calibration checks.
6. **Results and verdicts:** `summarize.sh` regenerates every table below from the JSON files next to it.

## What differed from the plan of the runs

- **Versions.** The entries run on PHP 8.3.6 (Ubuntu's package, `php-lab:8.3-apt`) with Swoole **6.2.6**; the leaderboard's runs used 6.2.3. The skeleton
  runs on PHP 8.5.13, as in every pair of the step lab. The two differences (the PHP version and the Swoole version) are not separated here.
- **tzimpel's patch applied.** `bash lab/build.sh 8.3-apt-tzimpel` built `php-lab:8.3-apt-tzimpel`: our Swoole 6.2.6 source with the `perl -0pi` line of his
  `build.sh` (copied byte for byte, checked against the challenge's file by `lab/check.sh`) and his check that it applied exactly twice, which passed
  (the build would have stopped otherwise). The patched extension is `/opt/swoole-tzimpel/swoole.so`, loaded by path, next to the stock one. His
  `install.sh` and `build.sh`, and mattsplat's `install.sh`, were not run; their PHP files ran only in the lab's containers.
- **Correctness first:** `lab/challenge-test.sh` passed 42 of 42 on each entry as run here (mattsplat on `8.3-apt`; tzimpel on `8.3-apt-tzimpel`
  with his `php.ini`).
- **The wrapper is the lab's, not a script:** mattsplat's `start.sh` flags are the lab's own flags (the four of his `start.sh` plus
  `opcache.file_update_protection=0` and `zend.assertions=-1`, which the lab sets for every server); tzimpel's are `-c <his php.ini> -d extension=<the
  patched .so>` and nothing else (`--php-ini` leaves the lab's flags out, so his 512 MiB `memory_limit` and his JIT buffer apply, not the lab's
  `memory_limit=-1`). Both are in the table of flags below, as the runs recorded them.
- **The memory comes from separate runs.** The step lab's runs have the per-second probes off (a probe that walks 60,000 sockets' page tables every second
  costs CPU), so they hold no memory. One run of each entry with the probes on gives the memory and the descriptors; its µs/req is shown too and is
  within 0.02 µs (mattsplat 29.22 against 29.20) and 0.7 µs (tzimpel 32.09 against 32.77) of the pair's, under the A/A floor (1.43).
- **The step lab's gate.** The two pairs ran with the gate as fixed for the idle client's addresses (a limit of 0 sockets on them, `--idle-time-wait-max`;
  each run waited 47 to 60 s for the last run's sockets). The D62 proof run before them, 2 rounds at 2,000 req/s with 60,000 idle, both started.
- **Scratch paths were scrubbed after the runs:** `<tmp>` replaces the runner's temporary folder in the `command` fields and the `.txt` files.
- **The leaderboard's numbers come from another shape.** 94 and 101 µs are the bench's at 71,000 users (about 7,500 req/s, 65,535 connections held), ours
  are at 12,000 req/s with 60,000 idle; the S1 series found the skeleton about as costly per request at 12,000 as at 24,000 (27.55 and 26.1 µs), so the rate
  does not move a request's cost much, but it is not the same load. The factors below are the ratio of two numbers measured in two shapes.

## Results

Every table is printed by `summarize.sh` from the files next to it and from the S1 series' (the skeleton's µs/req and the A/A floor at 12,000 req/s).
A run counts when its JSON says `valid: true` and `other_containers: 0`; every run of this folder does. `docker ps` showed no other container before
each series.

<!-- BEGIN summarize -->
### One pair each against the skeleton: 12,000 req/s, `s = 0.02`, 60,000 idle, 60 s plateau, the skeleton first in the round (PHP 8.5, telemetry on), the entry second (PHP 8.3 from apt)

**mattsplat-pair**

| Run | valid | other containers | idle held at the end | closed by the server | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|
| s1a-1 | true | 0 | 60000 | 0 | 11917.3 | 99.3 % | 27.94 | 1.88 | 5.75 | pass |
| php-swoole-mattsplat-1 | true | 0 | 60000 | 0 | 11912.7 | 99.2 % | 29.2 | 2 | 5.42 | pass |

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  result
    1  s1a            yes      11917.3      27.9     1.88     5.75         0  pass
    1  php-swoole-mattsplat yes      11912.7      29.2        2     5.42         0  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)

variants (us is the server's CPU per request over the plateau)
variant         valid median us        min to max   p99 ms  paired differences us     median  verdict
s1a               1/1      27.9      27.9 to 27.9     5.75  reference                      -  reference
php-swoole-mattsplat    1/1      29.2      29.2 to 29.2     5.42  +1.3                        +1.3  screen: not better in one pair

Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 1.4317068739785483 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

**tzimpel-pair**

| Run | valid | other containers | idle held at the end | closed by the server | achieved req/s | achieved / offered | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|
| s1a-1 | true | 0 | 60000 | 0 | 11906.3 | 99.2 % | 28.34 | 2.15 | 6.58 | pass |
| php-swoole-tzimpel-1 | true | 0 | 60000 | 0 | 11927.3 | 99.4 % | 32.77 | 1.01 | 4.47 | pass |

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  result
    1  s1a            yes      11906.3      28.3     2.15     6.58         0  pass
    1  php-swoole-tzimpel yes      11927.3      32.8     1.01     4.47         0  pass
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)

variants (us is the server's CPU per request over the plateau)
variant         valid median us        min to max   p99 ms  paired differences us     median  verdict
s1a               1/1      28.3      28.3 to 28.3     6.58  reference                      -  reference
php-swoole-tzimpel    1/1      32.8      32.8 to 32.8     4.47  +4.4                        +4.4  screen: not better in one pair

Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 1.4317068739785483 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```

The A/A floor at 12,000 req/s (S1 series): 1.432 µs/req. The skeleton's S1-a at 12,000 req/s there: median 27.95 µs/req over 5 runs.

### The entries' flags, as the runs recorded them

| Entry | image | PHP | server file | PHP flags |
|---|---|---|---|---|
| php-swoole-mattsplat | `php-lab:8.3-apt` | 8.3.6 | `servers/swoole-entries/php-swoole-mattsplat/server.php` | `-d extension=swoole -d memory_limit=-1 -d opcache.enable_cli=1 -d opcache.jit=tracing -d opcache.jit_buffer_size=32M -d opcache.file_update_protection=0 -d zend.assertions=-1` |
| php-swoole-tzimpel | `php-lab:8.3-apt-tzimpel` | 8.3.6 | `servers/swoole-entries/php-swoole-tzimpel/server.php` | `-c /lab/servers/swoole-entries/php-swoole-tzimpel/php.ini -d extension=/opt/swoole-tzimpel/swoole.so` |

### Memory and descriptors: one run of each entry with the per-second probes on (same rate and shape)

| Entry | valid | other containers | idle held at the end | closed by the server | file descriptors at the peak | `memory.current` peak MiB (limit 2,048) | anonymous memory (Pss_Anon) peak MiB | µs CPU/req (probes on) |
|---|---|---|---|---|---|---|---|---|
| mattsplat | true | 0 | 60000 | 0 | 62281 | 2048 | 1680.1 | 29.22 |
| tzimpel | true | 0 | 60000 | 0 | 62300 | 610.7 | 63 | 32.09 |

`memory.current` of mattsplat over tzimpel: 3.35 times (mattsplat is held at the cgroup limit, its anonymous memory plus the page cache the kernel keeps reclaiming, so it could not read higher: the ratio is a floor). Anonymous memory, mattsplat over tzimpel: 26.7 times.

### The Mac-to-bench factors and the skeleton's bench estimate

| Entry | bench µs/req (leaderboard) | Mac µs/req (the pair above) | factor (bench over Mac) |
|---|---|---|---|
| php-swoole-mattsplat | 94 | 29.2 | 3.22 |
| php-swoole-tzimpel | 101 | 32.77 | 3.08 |

Mean factor 3.15; the two differ by 4.3 % of the mean. The skeleton's S1-a at 12,000 req/s is 27.95 µs/req on the Mac, so its **bench estimate is 88 µs/req** (27.95 times 3.15; with each factor alone: 90 and 86.1).
<!-- END summarize -->

## The reading

- **Both entries cost about what the skeleton costs.** mattsplat is +1.3 µs/req over the skeleton's S1-a (29.20 against 27.94 in the same round), under the
  A/A floor of 1.43: not distinguishable from the skeleton. tzimpel is +4.4 µs (32.77 against 28.34), above the floor, from one pair, which is a
  screen and not a verdict. The skeleton's two runs here (27.94 and 28.34) agree with the S1 series' median (27.95).
- **Memory is where they differ.** mattsplat held the 60,000 idle connections in 2 GiB but only just: its anonymous memory is 1,680 MiB (about 28 KiB per
  idle connection) and its `memory.current` sits at the 2,048 MiB limit. tzimpel's is 63 MiB of anonymous memory and 611 MiB of `memory.current`. The
  likely cause is the receive buffer Swoole keeps for a connection's next request, which his patch frees once the request is done (not isolated here:
  no run of mattsplat with the patch).
- **The factors agree with each other and not with the prediction:** 3.22 and 3.08, 4.3 % apart, where 1.7 to 2.7 was expected. The skeleton's
  bench estimate is 88 µs/req (86.1 to 90 with each factor alone): the number scope 12's x86 run reads against.

## Did the predictions hold?

14. **Missed, below.** mattsplat 29.2 µs/req (predicted 35 to 55), tzimpel 32.8 (40 to 60). "Both above the skeleton's S1-a": tzimpel yes (+4.4, one
    pair), mattsplat by 1.3 µs, which is inside the floor.
15. **Half.** The factors, 3.22 (mattsplat) and 3.08 (tzimpel), are outside 1.7 to 2.7, both above it; they are within 25 % of each other (4.3 %).
16. **Held.** Both hold 60,000 idle within 2 GiB and close none. mattsplat's `memory.current` is 3.35 times tzimpel's (2 to 4; a floor, since mattsplat is at
    the limit), and its anonymous memory 26.7 times.
17. **Missed, above.** The skeleton on the bench: 88 µs/req (45 to 75 predicted), so scope 12 should read about 3.1 to 3.2 times the Mac on the Xeon, not 1.7
    to 2.7 (prediction 13's range, 1.8 to 3, sits under it). Written here before scope 12 runs.
