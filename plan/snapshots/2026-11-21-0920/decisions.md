# $12 server challenge in PHP: decisions

## Active

- **D1:** no Nginx and no PHP-FPM. PHP runs the fastest way we can find: a long-running process that serves HTTP itself,
  in direct mode on port 80 (Jacob, 2026-11-21).
- **D2:** every score comparison uses `docs/leaderboard-par-langage.md` (snapshot of 2026-11-21). The real-PHP record to
  beat is 71,000 users (Swoole, #24 and #28) (Jacob, 2026-11-21).
- **D3:** we plan before we code: use cases, then a UML sequence per use case, then, for every step, the ways to
  implement it and a measurement of each (Jacob, 2026-11-21).
- **D4:** the project is a git repo in `www-perso/twelve-dollar-server-challenge/`. What we clone to read or compare
  (the challenge repo, other submissions) goes in `reference/`, ignored by git (Jacob, 2026-11-21).
- **D5:** we re-measure everything ourselves. A prior-art number is a prediction to check, never an answer
  ([Q1](questions/2026-11-21-0856.ronde-1.md)).
- **D6:** the bake-off runs Swoole, Workerman and our own loop and parser. RoadRunner, FrankenPHP and OpenSwoole are
  out. Workerman only once it's clear of rule 5 ([Q2](questions/2026-11-21-0856.ronde-1.md)).
- **D7:** we measure in a Docker container on the Mac, and move to x86 machines in the cloud (AWS EC2) when a result
  needs it ([Q3](questions/2026-11-21-0856.ronde-1.md)).
- **D8:** the PHP version is a measured variant: 8.3, 8.4, 8.5 and 8.6 ([Q4](questions/2026-11-21-0856.ronde-1.md),
  other exit).
- **D9:** the UML diagrams stay in Mermaid, in the Markdown ([Q5](questions/2026-11-21-0856.ronde-1.md)).
- **D10:** Workerman runs in the bake-off with its 5 request caches patched out in `build.sh`; one extra run with the
  caches on shows what they buy ([Q6](questions/2026-11-21-0914.ronde-1.md)).
- **D11:** the whole plan (plan, decisions, details, questions, notes) lives in this repo under `plan/` and is
  committed in public, for transparency. Anything about other people's private exchanges (`communications/`) stays
  out, ignored by git (Jacob, 2026-11-21).

## History

Nothing yet.
