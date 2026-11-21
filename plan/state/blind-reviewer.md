# Blind reviewer: phase-3-claude

**State:** first pass done on `phase-3-claude` at e1cf918 (base b14068f). Verdict NOT_OK (one 🟠). Report:
`plan/reviews/BLIND-2026-11-21-1831.md`.

## Verified

- The DIY parser's 30 cases match the count `check.sh` expects. **Proof:** `lab/check/diy-parser-test.php` read, cases counted.
- The seed's `posts` table has 500,000 rows, ids 1 to 500,000 (`posts.js` assumes so). **Proof:** `sqlite3` on `lab/data/feed.db`.
- Seed page counts: posts 21,077, likes_post_id_idx 5,913, users 639 (4 KiB pages). **Proof:** `dbstat` query.
- Workerman 5.2.4 (the reference clone) has no idle keep-alive timer. **Proof:** grep of `TcpConnection.php` and `Http.php`.

## Assumed

- Pss in `smaps_rollup` includes the SQLite mmap pages, so Pss under load grows with the DB pages touched (item 1). Not
  measured under k6.

## Dead ends

Nothing.

## Decisions along the way

- `mktemp -d` dirs left behind by the checks: dropped, it is the existing pattern of `check.sh`.
- `D15` at `lab/README.md:213`: predates the branch, not raised.

## My remarks

| # | Sev | `file:line` | Status |
|---|-----|-------------|--------|
| 1 | 🟠 | `lab/servers/handler.php:52`, `lab/macro/probe.sh:42-53`, `lab/README.md:274` | open |
| 2 | 🟡 | `lab/README.md:384` | open |
| 3 | 🟡 | `lab/conformance.sh:10` | open |
| 4 | 🟡 | `lab/README.md:103` | open |
| 5 | 🟡 | `lab/images/install-extras.sh:25` | open |
| 6 | 🟡 | `lab/servers/diy-connection.php:141-142` | open |
| 7 | 🟡 | `lab/servers/diy-connection.php:183-187` | open |
| 8 | 🟡 | `lab/servers/diy-connection.php:39` | open |
| 9 | 🟡 | `lab/check.sh:49` | open |
| 10 | 🟡 | `lab/servers/workerman-caches.php` | open |
| 11 | 💡 | `lab/macro/k6/posts.js:5-6` | open |

## Next steps

1. On a rerun: reread the final branch, check each remark against the status given, and don't bring back a remark left
   as a known choice.

## Questions for the project manager

Nothing.

## Rétro

1. **What I was missing:** the repo has no `CLAUDE.md` or project skills, so the only conventions were the lab README and
   the existing scripts. I judged against those (for example, the `mktemp -d` pattern in `check.sh`).
2. **What I guessed:** that Pss counts the mmap'd SQLite pages at the scale I estimated (item 1). Not measured: a `/noop`
   run against a `/posts` run would settle it.
3. **Where I lost time:** the diff is 3,278 lines in 28 files. Reading `lab/README.md` (257 added lines) mostly repeated
   the code. Proof: `git diff --stat`.
4. **A useless or contradictory instruction:** nothing.
5. **What could have been deterministic:** the doc/code count drift (item 3: "two pipelined" against three cases) and the
   README's "every measuring script" claim (item 2) are the kind of thing a check could hold. For example, a `check.sh`
   case that greps `micro.sh` for `lab_other_containers` once the README claims it.
6. **What the plan should have decided:** impression: which memory figure is the bake-off's comparison metric (full
   Pss, anonymous Pss or `memory.current`). The code picked one, and the README justifies it.
7. **A blind spot:** the `/posts` checks only assert that the memory numbers are above 0 (`check.sh`, `max_pss_mib > 0`),
   so nobody checks what the number is made of.
