# Phase 8's levers on x86 (AWS `c5.2xlarge`)

The step-lab series of phase 8 on one AWS `c5.2xlarge` (Intel Xeon, x86-64) in the lab's realistic mode at the bench's
shape (`s = 0.02`, 60,000 idle connections, 7,500 req/s, the server on one vCPU with its hyperthread sibling idle), booted
on the bench's kernel (6.8): the reference's A/A floor, the feed micro on both SQLites, the tuned SQLite's pair if the micro
calls for it, our io_uring ring's pair, and the winners together. The reference is phase 7's submission as it is. This
series decides: every step runs whatever the Mac series finds. This file is written in two steps: the predictions first
(before the launch), then the runs and the reading.

## Predictions

Written by the project manager on 2026-11-26 at 15:10, revised at 15:26, before any phase 8 run (the lines of this
session; the others belong to other folders).

> x86 numbers on AWS `c5.2xlarge` (the lab session), PHP 8.5, the reference phase 7's submission.
>
> 5. **The reference's A/A floor on x86** at 7,500 req/s: 1.0 to 3.0 µs/req; the reference at 54 to 60 µs/req (5b's
>    S1-b read 57.75 on the same box type, with telemetry on; the submission has none).
> 7. **The ring:** **−6 to −12 µs/req** against the reference (−11 to −22 %), beyond the floor in 3 pairs: S1-b's
>    second process gone (+7.44 on the Xeon in 5b) and 1 to 4 µs of syscalls; chosen.
> 9. **The tuned SQLite:** the feed micro 8 to 18 % under Ubuntu's 3.45.1; the pair −1 to −5 µs/req; beyond the floor
>    with about 50 % confidence.
> 13. **Cost and time:** the lab session 2 to 3 h, under 2 USD.

Written now (2026-11-26 21:30, before the launch): the box boots kernel 6.8, the bench's; the predictions above were written
for the session whatever its kernel.
