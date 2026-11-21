# The $12 server challenge, in PHP

How many users can a $12/month server (1 vCPU, 2 GB) hold with a PHP API on SQLite? This repo is my attempt at
[arjaythedev's challenge](https://github.com/arjaythedev/twelve-dollar-server-challenge), done in the open: the
plan, every decision, every idea we rejected and every measurement are committed here.

**The target:** the real-PHP record is 71,000 users (two Swoole entries, both capped by the 65,535 file-descriptor
limit, not by the CPU). The goal is to beat it with genuine PHP, and to understand each step of a request by measuring
the ways to implement it.

## Where to look

- [`plan/plan.md`](plan/plan.md): the objective, the phases, what's open.
- [`plan/decisions.md`](plan/decisions.md): every decision, with a link to the question that settled it.
- [`plan/notes.md`](plan/notes.md): every idea we challenged, and its verdict.
- [`plan/details/`](plan/details/): use cases, UML sequences, the steps and their variants, the runtimes, prior art.
- [`lab/`](lab/README.md): the measuring lab: seed, PHP images, micro and macro benchmarks, and the first numbers.
- [`docs/`](docs/): the challenge rules and the leaderboard, as of 2026-11-21.

The work is planned and run with Claude (Anthropic): I make the calls, the reasoning is in the plan.

## License

MIT, like the challenge.
