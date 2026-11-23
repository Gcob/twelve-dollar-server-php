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
