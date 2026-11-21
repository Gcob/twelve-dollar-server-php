# $12 server challenge in PHP

**Status:** ✅ Approved on 2026-11-21 · snapshot 2026-11-21-0920 · **Round:** 1
**Since your last read:** you approved the plan in the chat. A project-manager session runs phase 2 and commits and
pushes on `main` itself (D12); its progress is in `run.md`. Traefik is still 🔶 open in [notes.md](notes.md).
**Project:** this repo, `plan/` · **Submission:**
`submissions/php-<runtime>-Gcob/` · **Jira:** none

## 👉 Your turn

> **Answer freely:** a letter or `ok`, your own choice (`other: …`), `?` if it's unclear, or
> `badly framed: …` if an option is missing or the question doesn't hold.

Nothing for now.

## 🤝 Essentials

**Objective:** beat 71,000 users with real PHP (D2), and understand every step of a request by measuring the ways to
implement it (D3). Done when a submission holds more than 71,000 users for 5 minutes in our own runs, with every
step's choice backed by a measurement.

### What sets the score

- **First wall, connections:** one process is capped at 65,535 fds. The way past it: answer with
  `Connection: close` near the limit, so clients reconnect (HolyPHP did 110k to 145k like that). Closing idle sockets
  silently scored 0 for two entries.
- **Second wall, CPU:** about `users ≈ 9.2 million / µs per request` at 85 % CPU. The Swoole entries were at 94 to
  101 µs on the VM, so about 92,000 users once past the fd wall. Every 10 µs saved is worth 10,000 to 15,000 users.

### Phases

| # | Phase           | Delivers                                                    | Done when                                               |
|---|-----------------|-------------------------------------------------------------|---------------------------------------------------------|
| 1 | Understand      | Use cases, UML sequences, steps and variants                | You approve this plan                                   |
| 2 | Lab setup       | Seed, container, PHP 8.3 to 8.6 (D8), micro and macro harnesses | A no-op Swoole server gives a µs/req number             |
| 3 | Runtime bake-off | Swoole, Workerman, DIY (D6), same handler                  | One table: µs/req, max connections, RSS per connection  |
| 4 | Step lab        | Each step S1 to S9, its variants measured                   | Each step has a chosen variant and its numbers          |
| 5 | Submission      | The chosen variants together                                | `test/run.sh` passes 42/42                              |
| 6 | Score           | `bench/load.js` ramps, x86 calibration                      | More than 71,000 held for 5 minutes                     |
| 7 | Submit          | The PR to the challenge repo                                | CI green                                                |

**Decisions:** 12 active, in [decisions.md](decisions.md). D5 changes how to read the step lab: every prior-art number
is a prediction we re-measure, not an answer.

### Out of scope

- **io_uring and reading SQLite's B-trees directly:** not reachable from PHP without writing C. FFI to `libsqlite3`
  stays a variant of S6.

## 🤖 For Claude

You don't need to read this part: it's the index of the execution details, in `details/`.

- [Use cases](details/use-cases.md): UC0 to UC6, the traffic mix.
- [Sequences](details/sequences.md): one Mermaid sequence per use case, arrows tagged with their step.
- [Steps](details/steps.md): S1 to S9, the variants and how to measure each.
- [Measuring](details/measuring.md): micro and macro harnesses, profiling, environment.
- [Runtimes](details/runtimes.md): the PHP runtimes in theory, before the bake-off.
- [Prior art](details/prior-art.md): what mattsplat, tzimpel and HolyPHP already measured.
