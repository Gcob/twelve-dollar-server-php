# Phase 8's levers on the Mac

The step lab's pairs on the Mac's quiet Docker VM (arm64): phase 7's submission (the reference) against the two levers phase 8 still has open, the
tuned SQLite (`8.5-sqlite`) and our own io_uring loop (`APP_RING=1 APP_RINGS=3`), with the Mac's own A/A floor. Arm64 numbers: they close nothing
on their own and start no change to the submission; the same series runs later on AWS x86. This file is written in two steps: the predictions
first (below, before any run of the series), then the plan of the runs, the machine, the tables and the reading.

## Predictions

Written by the project manager on 2026-11-26 at 21:21, before any run of the series.

> Mac's Docker VM (arm64, kernel 6.12), 7,500 req/s, `s = 0.02`, 60,000 idle, 60 s runs, no seccomp filter, the
> reference phase 7's submission.
>
> 14. **The Mac's A/A floor:** 0.5 to 2.0 µs/req; the reference at 31 to 35 µs/req (scope 5's smokes read about 32.5).
> 15. **The tuned SQLite's feed micro on the Mac:** 15 to 28 % under Ubuntu's 3.45.1 (scope 2's smoke read 23 %),
>     enough to call for its pair; the pair −1.5 to −4 µs/req, beyond the floor with about 60 % confidence.
> 16. **The ring on the Mac:** −1.5 to +1.5 µs/req, within the floor (scope 5's three smokes: −1.0, +0.1, −0.3): not
>     chosen on the Mac, its verdict left to the x86 series.
> 17. **The winners together:** the tuned SQLite alone, if it wins; nothing to pair otherwise.
> 18. **Time:** 2 to 3 hours of runs.
