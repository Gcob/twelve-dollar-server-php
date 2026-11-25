# The submission against the lab: three pairs at 24,000 req/s

Phase 6's one measurement, on a quiet Docker VM (Docker Desktop on an M3 Pro, arm64, 1 CPU for the server, 2 GiB, PHP 8.5): does the
submission's clean copy (`submissions/php-Gcob/server.php`, the lab's image, its extensions loaded with `--ext`) cost what the lab's server costs with the
same configuration (`APP_WORKERS=2`, `APP_SOFT_CONN_LIMIT=64000`, `APP_PRAGMAS=mmap-off`)? One pair first, then two more, read two-sided against the A/A floor of phase 5b.
This is an arm64 number, not a score. This file is written in two steps: the predictions first (below, before any run), then the plan, the runs and the reading.

## Predictions (D5)

Copied unchanged from the phase's plan, section "Predictions (D5)" (all five). This folder judges 4; 1 to 3 were judged by the clean-container tests of the
submission's install (`lab/submission-test.sh`), and 5 by the smoke pair run when the copy was first added.

Written by the project manager on 2026-11-24 at 13:50, before any phase 6 run. Arm64, Docker Desktop on an M3 Pro,
PHP 8.5.13, unless a line says otherwise.

1. **`install.sh` on one CPU** (`nproc` 1, the M3 core): 8 to 20 minutes, PHP's `make` most of it; the droplet's
   slower Xeon core would take 1.5 to 3 times that.
2. **Healthy:** `/health` answers under 2 s after `start.sh` (opening the database and forking 2 processes; no warm-up).
3. **`test/run.sh` in the clean container:** 42/42 on the first try after scope 1's 42/42 in the lab's image; if it
   fails, the cause is the install (a missing extension or library), not the code.
4. **Parity at 24,000 req/s:** both sides 26 to 29 µs/req (the reference `mmap-off` was 25.0 to 25.6 in one process;
   S1-b added 2.14 at 12,000 on the Mac); the submission minus the lab between -0.6 and +0.2 µs/req (the copy drops
   the variant branches, the request counter and the telemetry's null checks: a few function calls a request), so
   within the floor: parity.
5. **The smoke pair of scope 1** (busy VM): both runs valid; no number read.

## Plan of the runs

Every series started with the quiet check of `lab/stages.sh` (no running container but the lab's, never `--allow-busy`); no image build and no `lab/check.sh` ran during a series.
Both ran from the phase's branch at commit `51ce9f8`, which holds the submission with the fix that steps a new post's insert to its end before the 201;
`stages.json` and `stages-more.json` record it, with no tracked file changed.

One series name, `parity-24000`: `--image 8.5 --think-scale 0.02 --idle 60000 --seconds 60 --rate 24000`, the warm-up of a tenth of the rate for 60 s, the alternating
order (round 1 runs the reference last), `--floor-from` the A/A of `lab/results/2026-11-24-cpu-steps-5b/aa-24000`.

- `lab` (the reference, runs last in round 1): `lab/app/server.php` with `APP_WORKERS=2,APP_SOFT_CONN_LIMIT=64000,APP_PRAGMAS=mmap-off`, telemetry off.
- `sub`: `submissions/php-Gcob/server.php` (`--server-variant`), with `APP_SOFT_CONN_LIMIT=64000`. The copy reads no such variable (its limit is a constant
  of `server.php`): the hint is for the harness only, so that k6's virtual-user cap and the JSON read the limit the way they do on the lab's side.

1. **Round 1, `series.txt`:** `bash lab/stages.sh lab/results/2026-11-24-submission-parity/series.txt --out lab/results/2026-11-24-submission-parity` (`--pairs 1`), recorded in `stages.json`.
2. **Rounds 2 and 3, `series-more.txt`:** the same flags with `--pairs 2 --first-round 2`, into the same folder
   (`bash lab/stages.sh lab/results/2026-11-24-submission-parity/series-more.txt --out lab/results/2026-11-24-submission-parity`), recorded in `stages-more.json`
   (the driver wrote it as `stages.json` and it was renamed, so that round 1's record stays). Started 90 s after round 1, with the quiet check again.

The reading is two-sided (the step lab's one-pair screen only says "not better"): the paired differences `sub - lab` against the floor, 0.864 µs/req. The step lab's rule
for pairs: outside the floor when every paired difference has the same sign and the median is at least the floor in absolute value; otherwise within it, parity.

## What differed from the plan of the runs

The plan was one pair. Round 1 read 4.254 µs/req outside the floor, so the run stopped before any reading, and two more pairs were run with the same flags and
the same harness (no change of method between rounds, so the three pairs compare). Nothing else changed: the quiet check passed both times, with 0 other containers.

## Results

<!-- BEGIN summarize -->
### The series, as the driver recorded it (`stages.json`)

The lab's commit when the file started: `51ce9f8`, tracked files changed since: false. `--allow-busy`: false.

| Series | start (UTC) | end (UTC) | exit code | other containers at the quiet check | busy | refused |
|---|---|---|---|---|---|---|
| parity-24000 | 2026-11-25T01:42:50Z | 2026-11-25T01:48:22Z | 0 | 0 | false | false |

### The series, as the driver recorded it (`stages-more.json`)

The lab's commit when the file started: `51ce9f8`, tracked files changed since: false. `--allow-busy`: false.

| Series | start (UTC) | end (UTC) | exit code | other containers at the quiet check | busy | refused |
|---|---|---|---|---|---|---|
| parity-24000 | 2026-11-25T01:49:51Z | 2026-11-25T02:00:53Z | 0 | 0 | false | false |

### The pair at 24,000 req/s (`lab`: the lab's server with the submission's configuration; `sub`: the submission's copy; `s = 0.02`, 60,000 idle, telemetry off, three pairs)

| Run | position in its round | valid | other containers | idle held at the end | closed by the server | achieved req/s | achieved / offered | at or over 97 % | µs CPU/req | p95 ms | p99 ms | result |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| sub-1 | 1 | true | 0 | 60000 | 0 | 22876.5 | 95.3 % | no | 29.94 | 24.74 | 52.87 | FAIL: achieved below 97 % of offered |
| lab-1 | 2 | true | 0 | 60000 | 0 | 21705.2 | 90.4 % | no | 34.2 | 70.15 | 204.93 | FAIL: achieved below 97 % of offered |
| lab-2 | 1 | true | 0 | 60000 | 0 | 23197.2 | 96.6 % | no | 27.9 | 15.6 | 37.54 | FAIL: achieved below 97 % of offered |
| sub-2 | 2 | true | 0 | 60000 | 0 | 23103.7 | 96.3 % | no | 29.05 | 17.57 | 41.66 | FAIL: achieved below 97 % of offered |
| sub-3 | 1 | true | 0 | 60000 | 0 | 22649.7 | 94.4 % | no | 31.79 | 31.87 | 68.1 | FAIL: achieved below 97 % of offered |
| lab-3 | 2 | true | 0 | 60000 | 0 | 23032.9 | 96 % | no | 29.74 | 20.69 | 49.81 | FAIL: achieved below 97 % of offered |

| Run | load1 before | load1 on the plateau | CPU busy on the plateau | steal on the plateau | fsync ms | TIME_WAIT on the busiest address before | waited s |
|---|---|---|---|---|---|---|---|
| sub-1 | 0.60 | 3.99 | 33.01 % | 0.00 % | 0.436 | 0 | 0 |
| lab-1 | 4.51 | 5.44 | 36.82 % | 0.00 % | 0.507 | 10036 | 0 |
| lab-2 | 1.53 | 4.00 | 27.65 % | 0.00 % | 0.452 | 0 | 0 |
| sub-2 | 4.21 | 4.35 | 29.42 % | 0.00 % | 0.460 | 10036 | 0 |
| sub-3 | 5.53 | 5.29 | 33.47 % | 0.00 % | 0.504 | 7043 | 0 |
| lab-3 | 6.16 | 4.73 | 29.36 % | 0.00 % | 0.445 | 7155 | 0 |

What each JSON says about the harness's side of the soft limit (`sub` was given `APP_SOFT_CONN_LIMIT=64000` as a hint only: the copy reads no environment variable):

| Run | environment given to the server | soft limit in the JSON | VU cap | VU cap bound by | server file |
|---|---|---|---|---|---|
| sub-1 | APP_SOFT_CONN_LIMIT=64000 APP_TELEMETRY=0 | 64000 | 12685 | k6 memory | /submissions/php-Gcob/server.php |
| lab-1 | APP_WORKERS=2 APP_SOFT_CONN_LIMIT=64000 APP_PRAGMAS=mmap-off APP_TELEMETRY=0 | 64000 | 12685 | k6 memory | app/server.php |
| lab-2 | APP_WORKERS=2 APP_SOFT_CONN_LIMIT=64000 APP_PRAGMAS=mmap-off APP_TELEMETRY=0 | 64000 | 12685 | k6 memory | app/server.php |
| sub-2 | APP_SOFT_CONN_LIMIT=64000 APP_TELEMETRY=0 | 64000 | 12685 | k6 memory | /submissions/php-Gcob/server.php |
| sub-3 | APP_SOFT_CONN_LIMIT=64000 APP_TELEMETRY=0 | 64000 | 12685 | k6 memory | /submissions/php-Gcob/server.php |
| lab-3 | APP_WORKERS=2 APP_SOFT_CONN_LIMIT=64000 APP_PRAGMAS=mmap-off APP_TELEMETRY=0 | 64000 | 12685 | k6 memory | app/server.php |

The pairs, in the order they ran (the order alternates: round 1 runs the reference last, so `sub` ran first; round 2 runs it first; round 3 like round 1):

| Round | order | lab µs/req | sub µs/req | sub minus lab µs | absolute value µs |
|---|---|---|---|---|---|
| 1 | sub then lab | 34.2 | 29.94 | -4.254 | 4.254 |
| 2 | lab then sub | 27.9 | 29.05 | +1.147 | 1.147 |
| 3 | sub then lab | 29.74 | 31.79 | +2.042 | 2.042 |

Medians over 6 valid runs: lab 29.74 µs/req, sub 29.94 µs/req. Paired differences (sub minus lab) -4.254, +1.147, +2.042; **median +1.147 µs/req, absolute value 1.147 against the floor 0.864**. The 3 signs differ. **Within the floor: the signs differ, parity by the step lab's rule.** Achieved over offered: 90.4 % to 96.6 %; runs under the 97 % rule: 6 of 6. Largest spread between two paired differences: 6.3 µs.

```text
runs, in the order they ran (one round runs every variant once, the first variant is the reference; the order alternates: odd rounds run it last, even rounds first)
round  variant        valid      req/s    us/req   p95 ms   p99 ms   tw/addr  load1 fsync ms  result
    1  sub            yes      22876.5     29.9*    24.74    52.87         0   3.99     0.44  FAIL: achieved below 97 % of offered
    1  lab            yes      21705.2     34.2*    70.15   204.93     10036   5.44     0.51  FAIL: achieved below 97 % of offered
    2  lab            yes      23197.2     27.9*     15.6    37.54         0      4     0.45  FAIL: achieved below 97 % of offered
    2  sub            yes      23103.7       29*    17.57    41.66     10036   4.35     0.46  FAIL: achieved below 97 % of offered
    3  sub            yes      22649.7     31.8*    31.87     68.1      7043   5.29      0.5  FAIL: achieved below 97 % of offered
    3  lab            yes      23032.9     29.7*    20.69    49.81      7155   4.73     0.45  FAIL: achieved below 97 % of offered
tw/addr: the most TIME_WAIT sockets on any one address, k6's or the idle client's, when the run started (- when the runner did not count)
*: the run counts in the pairs but its step failed (see result): that us/req rests on a run that did not pass
load1: the VM's 1-minute load average in the middle of the plateau; fsync ms: the median fdatasync of a 4 KiB write before the warm-up (- when a run has no host reading)

variants (us is the server's CPU per request over the plateau)
variant         valid failed median us        min to max   p99 ms  paired differences us     median  verdict
lab               3/3      3      29.7      27.9 to 34.2    49.81  reference                      -  reference
sub               3/3      3      29.9        29 to 31.8    52.87  -4.3 +1.1 +2                +1.1  within the noise

Floor: 0.864 us, from lab/results/2026-11-24-cpu-steps-5b/aa-24000: |median 0.083| + interquartile range 0.78 of 5 paired differences (quartiles by linear interpolation, inclusive)
Rule: a variant is beyond the noise when it has at least 2 pairs, every paired difference (its µs CPU/req minus the reference's in the same round) has the same sign and the median paired difference is at least 0.864 µs in absolute value; otherwise it is within the noise. A round where either run is invalid has no pair. One pair with a floor: a screen (beats the floor when lower by at least the floor, else not better), never a verdict. No pair: no verdict. No floor: not judged (the floor comes from an A/A calibration).
```
<!-- END summarize -->

## The reading

**The verdict: parity by the step lab's rule.** Three pairs, all runs valid (0 other containers, 60,000 idle connections held to the end), the paired
differences `sub - lab` are -4.254, +1.147 and +2.042 µs/req. The signs differ, so the rule reads them as within the noise whatever the median: no difference
the step lab can see between the submission's copy and the lab's server with the same configuration at 24,000 req/s. The median pair difference is +1.147 µs/req
(1.147 in absolute value, over the floor's 0.864: it is the signs that put it inside), and the medians of each side are close: `lab` 29.74 µs/req, `sub` 29.94.

**The instrument was noisier than the floor assumed.** All six runs are under the 97 % rule (90.4 to 96.6 % of the offered rate; 5b's A/A ran at 97.8 to 98.2 %), and the three
paired differences span 6.3 µs/req (-4.254 to +2.042), against about 1 µs for the A/A's five (-0.405 to +0.636). The floor of 0.864 was measured on one process; this pair
runs two processes on one CPU, and at 24,000 req/s they sit close to saturation on the Mac (the S1-b pairs of 5b ran at 12,000). That is a likely reason and was not
measured here. No new A/A was run for two processes (the plan's caveat). So "within the noise" says the step lab cannot tell the copy from the lab at this rate with
these runs; it does not say the difference is under 0.864 µs.

**The order.** Round 1 runs the reference last, so `sub` ran first in rounds 1 and 3 (and last in round 2), which adds about 0.2 to 0.3 µs to its number in the
alternating method. That is small beside the pairs' spread and was not corrected for.

**The outlier: `lab-1`.** It read 34.20 µs/req, 90.4 % of offered, p99 204.93 ms: the slowest, the lowest rate and the worst tail of the six. It ran second in round 1, right after
`sub-1` in the same call, with a load average of 4.51 and 10,036 `TIME_WAIT` sockets on the busiest address at its start (`sub-1` started at 0.60 and 0). Without it round 1
would not read -4.254. The gap hypothesis (a run that starts on the previous run's load and sockets reads slower) is not settled by these six runs: `sub-2` started at
4.21 and 10,036 and read 29.05, `lab-3` at 6.16 and 7,155 and read 29.74, and `sub-3` read 31.79 after starting at 5.53 and 7,043, while `lab-2` (1.53 and 0) read the lowest, 27.90.
Three runs started the same way as `lab-1` and none read like it.

**What comes from the harness in `sub`'s JSON.** `soft_limit` 64000 and the VU cap 12,685 (bound by k6 memory) are read from the `APP_SOFT_CONN_LIMIT=64000` hint, identical in
the six JSONs; the copy itself reads no environment variable.

**The measured code.** Commit `51ce9f8` includes the fix that steps a new post's insert to its end before the 201, so the copy measured is the one that commits before it answers.

## Did the predictions hold?

The one this folder judges is 4. 1 to 3 were judged by the clean-container tests of the install (`lab/submission-test.sh`), and 5 by the smoke pair run when the copy was added.

4. **Parity at 24,000 req/s: missed on its numbers, held on its conclusion.** Both sides were predicted at 26 to 29 µs/req: the medians are 29.74 (`lab`) and 29.94 (`sub`), just over, and the runs
   range from 27.90 to 34.20. The difference was predicted between -0.6 and +0.2 µs/req: the pairs are -4.254, +1.147 and +2.042 (median +1.147), outside that range on every pair. The conclusion,
   parity within the floor, held by the step lab's rule (the signs differ), with the caveat above: the floor came from one process and the runs were noisier than it.
