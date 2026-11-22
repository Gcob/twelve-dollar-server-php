# The runtime bake-off

Written in two steps. The **Predictions** and **Plan of the runs** sections below were written before any measured run
of this series (the first run started after this file existed). Everything after them was written once the runs were
done. This file is committed together with the results, so git alone does not show the order.

### Predictions (D5)

Written by the project manager on 2026-11-21 at 16:29, before any phase 3 measurement (commit `4e3a8a5`), and
revised at 16:44 after the plan review, still before any measurement: 7 and 8 now follow the prior art's 18 to
42 KiB per connection, and each prediction says how it's judged. Arm64, Docker Desktop on an M3 Pro, quiet VM, PHP
8.5, 1 CPU.

**What we start from:** the no-op Swoole server cost 50.2, 30.2 and 21.7 µs/req at 1k, 3k and 6k req/s on 8.3-apt,
on a **busy** VM. On the quiet VM the micro sample landed every swinging row on its slow level (D15), so quiet-VM
numbers may come out higher than busy-VM ones. tzimpel saw 2 Swoole workers cost 27 % more per request, 184 MB RSS at
10k connections with stock Swoole (about 18 KiB each) and the worker die at about 38k; mattsplat saw 840 MB at 20k
(about 42 KiB each); HolyPHP measured fewer header bytes as part of a 9 % round.

**How they're judged:** a µs/req number is the median of the 3 interleaved repeats; a percentage is relative to the
number named in the prediction; a range holds if the measured value is inside it.

1. **Swoole `/noop` at 7,000 req/s: 18 to 35 µs/req.** The busy-VM trend gives about 20 at 7k; the quiet VM may add up
   to 1.5x.
2. **`/posts/:id` costs 5 to 15 µs/req more than `/noop` on every runtime**, and the gap (posts minus noop) differs by
   at most 3 µs between the three: the handler is the same code, so the runtimes should differ by the same amount on
   both routes.
3. **Workerman with its caches out costs 30 to 70 % more than Swoole on `/noop`.** Its HTTP parsing, `Request` and
   `Response` objects and its connection object run in PHP. So runtimes.md's flip rule (within 30 % of Swoole) **fails**.
4. **Workerman with its caches on is 10 to 25 % cheaper than with them out on `/noop`** (every request has the same
   bytes, so `baseRead()`'s cache returns the decoded request every time) **and under 5 % cheaper on posts.js** (each
   id comes back rarely, so the cache rarely hits). Only 2 of the 5 caches can move these numbers: the handler never
   calls `header()`, `get()` or `post()`.
5. **DIY lands within 15 % of Swoole on `/noop`, either side.** It runs more PHP than Swoole per request but builds no
   objects and sends 2 headers instead of 5. So the finalists are **Swoole and DIY**.
6. **At 9,500 req/s, µs/req is 5 to 15 % lower than at 7,000** for both finalists: the trend of phase 2 (fixed costs
   spread over more requests per wake-up).
7. **Max connections:** Swoole stops on **memory (OOM kill), between 35,000 and 60,000**: about 30 KiB of process
   memory per connection plus the kernel's socket buffers reach 2 GiB before 65,535 fds. Workerman and DIY stop on the
   **fd limit, between 65,000 and 65,535**.
8. **Memory per connection (Pss slope):** Swoole **15 to 45 KiB** (prior art's 18 to 42), Workerman **3 to 10 KiB**,
   DIY **1 to 4 KiB**. The `memory.current` slope is higher than the Pss slope on all three, by the kernel's socket
   memory.
9. **p99 at 7,000:** under 3 ms on all three on both routes, with Workerman the highest.

The D numbers in this section are the decisions in `plan/decisions.md`.

## Plan of the runs

All on PHP 8.5 (`php-lab:8.5`), 1 CPU for the server, except series D (8.6, information). The handler is the same shared
file for the three runtimes. Before each series: `docker ps` must show no container; every JSON must say
`other_containers: 0`, otherwise the run is shown and not counted.

- **Series A, µs CPU/req at 7,000 req/s.** 4 servers (Swoole; Workerman nocache; Workerman stock; DIY) × 2 routes
  (`/noop`; `posts.js`), 30 s measured after a 10 s warm-up, VUs = rate / 10. 3 repeats interleaved: round 1 runs the
  8 (server, route) pairs, then round 2, then round 3, in the same order each round. 24 runs.
- **The finalists:** the two of Swoole, Workerman nocache and DIY with the lowest median posts µs/req at 7,000
  (Workerman stock is not a candidate).
- **Series B, the finalists at 9,500 req/s:** both routes, 3 interleaved repeats, 12 runs.
- **Series C, connections:** `lab/conns.sh` once per server (Swoole, Workerman nocache, DIY), default steps up to 66,000.
- **Series D, PHP 8.6, information, one run each:** Workerman nocache and DIY, both routes, at 7,000 req/s.
- **An invalid run** (dropped iterations or errors) keeps its files and is rerun once at the end of its round. Two invalid
  runs of the same pair stop the series.
- No image build, no other benchmark and no `lab/check.sh` while a series runs.

### Change made after a first try, before the series that counts

A first try of series A (rate / 10 VUs, so 700 at 7,000 req/s) ran 18 runs and was stopped after round 2: 4 of its
`posts.js` runs dropped iterations during stalls of 100 to 300 ms, and one pair was invalid twice. Its files are
kept in `first-try-700-vus/` and are **not counted** anywhere. The series that counts restarted from round 1 with
`--pre-vus` and `--max-vus` at rate / 5 on every run of series A, B and D, both routes and all runtimes: 1,400 VUs at
7,000 req/s and 1,900 at 9,500, so that posts minus noop compares the same client. The predictions above were not
touched.

## What was measured

Four servers, one shared handler (`lab/servers/handler.php`: `/noop` answers `{"status":"ok"}`, `/posts/<id>` reads one row
of the 250 MB SQLite seed), each in its own lab container (1 CPU, 2 GiB, host network), loaded by k6 at a fixed request
rate with `lab/macro.sh`, and by `lab/conns.sh` for the connection test. Image `php-lab:8.5` for everything except series
D.

- **Series A:** Swoole, Workerman with its caches out (`nocache`), Workerman stock, and DIY (our own loop and parser), on
  `/noop` and on `posts.js` (a different post every request), at 7,000 req/s: 30 s measured after a 10 s warm-up, 1,400
  VUs, 3 repeats interleaved (round 1 runs the 8 pairs, then round 2, then round 3, same order).
- **Series B:** the two finalists at 9,500 req/s (1,900 VUs), both routes, 3 interleaved repeats.
- **Series C:** `lab/conns.sh` once per runtime (Swoole, Workerman nocache, DIY), default steps up to 66,000.
- **Series D:** PHP 8.6, Workerman nocache and DIY, one run per route, information only.
- **µs CPU per request** is the server cgroup's `usage_usec` over the measured run divided by the requests k6 sent in
  it, read from outside the cgroup. The server's cgroup holds every process of the runtime (Workerman's master and
  worker both count).
- **A run counts** when its JSON says `valid: true` (no errors, no dropped iterations) and `other_containers: 0`. The
  VM had no other container before each series (`docker ps` empty) and in every JSON. **Invalid runs** keep their files
  and are rerun once at the end of their round; the rerun counts, the invalid one is shown and left out.
- **This is arm64, Docker Desktop on an Apple M3 Pro, not the bench VM.** Relative results (runtime against runtime)
  count here, with a limit: the Mac was not quiet, and differences under about 5 % are not distinguishable from the spread
  of the 3 repeats (for example Workerman nocache against Swoole on `/noop`: 3.0 %, with repeats of 25.06 to 26.56 against
  24.44 to 25.72). Absolute numbers only count on x86.

## Results

Generated by `bash lab/results/2026-11-21-bake-off/summarize.sh` from the `run-*.json`, `info-*.json`, `conns-*.json` and
`conformance-*.txt` files next to it (the `.txt` next to each JSON is what the script printed for that run). The tables
below, down to the first-try table, are its output, unedited.

### Series A: per runtime and route at 7,000 req/s on 8.5 (counted runs only; spread = min to max)

| Runtime | Route | Counted runs | µs CPU/req median | min .. max | p99 ms (median) | peak Pss_Anon MiB | peak memory.current MiB | peak Pss MiB (with the mapped database) |
|---|---|---|---|---|---|---|---|---|
| swoole | noop | 3 | 25.47 | 24.44 .. 25.72 | 1.69 | 102.4 | 357 | 121.2 |
| swoole | posts | 3 | 32.83 | 31.62 .. 33.58 | 5.38 | 102.4 | 357.7 | 229.3 |
| workerman-nocache | noop | 3 | 26.24 | 25.06 .. 26.56 | 2 | 12.4 | 268.4 | 29.6 |
| workerman-nocache | posts | 3 | 33.32 | 31.5 .. 34.36 | 7.18 | 12.4 | 268.9 | 137.8 |
| workerman-stock | noop | 3 | 23.39 | 23.1 .. 23.59 | 1.68 | 12.4 | 268.6 | 29.6 |
| workerman-stock | posts | 3 | 34.05 | 33.12 .. 35.38 | 4.05 | 12.4 | 268.7 | 137.8 |
| diy | noop | 3 | 21.88 | 21.52 .. 22.03 | 1.79 | 8.6 | 263.2 | 24.5 |
| diy | posts | 3 | 29.14 | 28.74 .. 29.89 | 3.03 | 8.7 | 263.5 | 132.8 |

### Derived from the medians at 7,000 req/s

| What | Value |
|---|---|
| Gap posts minus noop, Swoole / Workerman nocache / Workerman stock / DIY (µs/req) | 7.37 / 7.08 / 10.67 / 7.26 |
| Largest difference between the gaps of Swoole, Workerman nocache and DIY (µs/req) | 0.28 |
| Largest difference between the four gaps (µs/req) | 3.58 |
| Workerman nocache against Swoole on `/noop` | 3 % |
| Workerman nocache against Swoole on posts | 1.5 % |
| Workerman stock against nocache on `/noop` (negative: cheaper with the caches on) | -10.9 % |
| Workerman stock against nocache on posts | 2.2 % |
| DIY against Swoole on `/noop` | -14.1 % |
| DIY against Swoole on posts | -11.3 % |

### The finalists: the two lowest median posts µs/req among Swoole, Workerman nocache and DIY (stock is not a candidate)

Finalists: **diy** and **swoole** (posts medians: Swoole 32.83, Workerman nocache 33.32, DIY 29.14 µs/req).

### Series B: the finalists at 9,500 req/s on 8.5 (counted runs only), against their 7,000 medians

| Runtime | Route | Counted runs | µs CPU/req median | min .. max | p99 ms (median) | median at 7,000 | lower than at 7,000 by |
|---|---|---|---|---|---|---|---|
| diy | noop | 3 | 17.37 | 15.91 .. 19.76 | 2.14 | 21.88 | 20.6 % |
| diy | posts | 3 | 27.66 | 26.12 .. 29.08 | 7.37 | 29.14 | 5.1 % |
| swoole | noop | 3 | 18.53 | 17.83 .. 20.88 | 2.21 | 25.47 | 27.3 % |
| swoole | posts | 3 | 31.01 | 28.34 .. 31.01 | 7.14 | 32.83 | 5.6 % |

### Series D: PHP 8.6, information, one run each, at 7,000 req/s (not counted in any median)

| Runtime | Route | µs CPU/req on 8.6 | median on 8.5 | difference | valid | other containers |
|---|---|---|---|---|---|---|
| workerman-nocache | noop | 24.57 | 26.24 | -6.4 % | true | 0 |
| workerman-nocache | posts | 34.13 | 33.32 | 2.4 % | true | 0 |
| diy | noop | 20.68 | 21.88 | -5.5 % | true | 0 |
| diy | posts | 33.16 | 29.14 | 13.8 % | true | 0 |

### Series C: connections (one run per runtime, 8.5)

| Runtime | Max connections | Last step held | Why it stopped | Source addresses | Pss slope KiB/conn | Pss_Anon slope KiB/conn | memory.current slope KiB/conn | Pss_Anon per connection at the max KiB | memory.current per connection at the max KiB | Pss per connection at the max KiB (with the mapped database) | Baseline Pss / Pss_Anon / memory.current MiB | Held steps in the slope | Valid (other containers) |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| swoole | 65000 | 65000 | request timeout | 7 (127.0.0.2 .. 127.0.0.8) | 14.29 | 14.28 | 18.13 | 18.12 | 21.98 | 18.14 | 22.47 / 9.28 / 257.54 | 9 | true (0) |
| workerman-nocache | 65000 | 65000 | request timeout | 7 (127.0.0.2 .. 127.0.0.13) | 2.37 | 2.37 | 6.07 | 2.37 | 6.08 | 2.37 | 19.75 / 7.52 / 256.91 | 9 | true (0) |
| diy | 65000 | 65000 | request timeout | 7 (127.0.0.2 .. 127.0.0.8) | 1.48 | 1.48 | 5.19 | 1.45 | 5.16 | 1.46 | 16.47 / 6.3 / 254.51 | 9 | true (0) |

### Series C, every step

| Runtime | Target | Held | Pss_Anon MiB | memory.current MiB | Established (kernel) | Fresh request ms | Stopped because |
|---|---|---|---|---|---|---|---|
| swoole | 1000 | 1000 | 76.03 | 328.06 | 1000 | 0.4 |  |
| swoole | 5000 | 5000 | 344.96 | 612.07 | 5000 | 0.4 |  |
| swoole | 10000 | 10000 | 683.46 | 969.42 | 10000 | 0.6 |  |
| swoole | 20000 | 20000 | 932 | 1255.66 | 20000 | 8.1 |  |
| swoole | 30000 | 30000 | 982.45 | 1343.66 | 30000 | 0.3 |  |
| swoole | 40000 | 40000 | 1032.55 | 1431.59 | 40000 | 0.3 |  |
| swoole | 50000 | 50000 | 1087.39 | 1523.99 | 50000 | 0.3 |  |
| swoole | 60000 | 60000 | 1135.62 | 1609.77 | 60000 | 0.2 |  |
| swoole | 65000 | 65000 | 1159.73 | 1652.66 | 65000 | 0.3 |  |
| swoole | 66000 | 65522 | 1164.13 | 1659.01 | 65522 | 1011.2 | request timeout |
| workerman-nocache | 1000 | 1000 | 10.26 | 263.35 | 1000 | 0.5 |  |
| workerman-nocache | 5000 | 5000 | 21.04 | 288.64 | 5000 | 0.6 |  |
| workerman-nocache | 10000 | 10000 | 34.02 | 319.76 | 10000 | 0.3 |  |
| workerman-nocache | 20000 | 20000 | 57.9 | 379.9 | 20000 | 0.3 |  |
| workerman-nocache | 30000 | 30000 | 75.58 | 433.71 | 30000 | 0.3 |  |
| workerman-nocache | 40000 | 40000 | 103.59 | 498.12 | 40000 | 0.6 |  |
| workerman-nocache | 50000 | 50000 | 127.45 | 558.13 | 50000 | 0.3 |  |
| workerman-nocache | 60000 | 60000 | 148.34 | 615.15 | 60000 | 0.2 |  |
| workerman-nocache | 65000 | 65000 | 157.79 | 642.67 | 65000 | 0.3 |  |
| workerman-nocache | 66000 | 65523 | 159.94 | 646.71 | 65523 | 1011.2 | request timeout |
| diy | 1000 | 1000 | 6.52 | 258.4 | 1000 | 0.4 |  |
| diy | 5000 | 5000 | 13.3 | 279.7 | 5000 | 0.5 |  |
| diy | 10000 | 10000 | 20.29 | 304.79 | 10000 | 0.3 |  |
| diy | 20000 | 20000 | 36.17 | 356.92 | 20000 | 0.3 |  |
| diy | 30000 | 30000 | 47.84 | 404.71 | 30000 | 0.2 |  |
| diy | 40000 | 40000 | 63.85 | 457.1 | 40000 | 0.6 |  |
| diy | 50000 | 50000 | 81.63 | 511.01 | 50000 | 0.3 |  |
| diy | 60000 | 60000 | 91.61 | 557.09 | 60000 | 0.7 |  |
| diy | 65000 | 65000 | 98.61 | 582.16 | 65000 | 0.2 |  |
| diy | 66000 | 65523 | 98.71 | 584.15 | 65523 | 1009.1 | request timeout |

### Socket settings each server printed at boot (from the JSON of its first run)

| Runtime | backlog | TCP_NODELAY |
|---|---|---|
| swoole | 4096 | 1 |
| workerman-nocache | 4096 | 1 |
| workerman-stock | 4096 | 1 |
| diy | 4096 | 1 |

### Bytes of the `/noop` response, per runtime (the conformance run's printed bytes)

**swoole**

```text
    HTTP/1.1 200 OK\r\n
    Content-Type: application/json\r\n
    Server: swoole-http-server\r\n
    Date: Sun, 22 Nov 2026 03:07:45 GMT\r\n
    Connection: keep-alive\r\n
    Content-Length: 15\r\n
    \r\n
    {"status":"ok"}
```

**workerman-nocache**

```text
    HTTP/1.1 200 OK\r\n
    Content-Type: application/json\r\n
    Connection: keep-alive\r\n
    Content-Length: 15\r\n
    \r\n
    {"status":"ok"}
```

**workerman-stock**

```text
    HTTP/1.1 200 OK\r\n
    Content-Type: application/json\r\n
    Connection: keep-alive\r\n
    Content-Length: 15\r\n
    \r\n
    {"status":"ok"}
```

**diy**

```text
    HTTP/1.1 200 OK\r\n
    Content-Type: application/json\r\n
    Content-Length: 15\r\n
    \r\n
    {"status":"ok"}
```

### Every run, in the order it ran (the time is when the run ended and its JSON was written)

| Written (UTC) | Run | Image | VUs | µs CPU/req | achieved req/s | p99 ms | max ms | server CPU % of one CPU | errors | dropped | other containers | valid | counted |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 2026-11-22T02:31:16Z | run-1-swoole-noop-7000 | 8.5 | 1400 | 25.72 | 6999.26 | 1.99 | 26.4 | 17.77 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:32:02Z | run-1-swoole-posts-7000 | 8.5 | 1400 | 39.36 | 6939.49 | 85 | 430.01 | 26.83 | 0 | 1785 | 0 | false | no |
| 2026-11-22T02:32:49Z | run-1-workerman-nocache-noop-7000 | 8.5 | 1400 | 26.56 | 6998.36 | 2.34 | 41.57 | 18.34 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:33:36Z | run-1-workerman-nocache-posts-7000 | 8.5 | 1400 | 34.36 | 6999.05 | 7.18 | 57.46 | 23.67 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:34:22Z | run-1-workerman-stock-noop-7000 | 8.5 | 1400 | 23.1 | 6999.35 | 1.65 | 27.79 | 15.93 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:35:09Z | run-1-workerman-stock-posts-7000 | 8.5 | 1400 | 34.05 | 6999.33 | 16.16 | 167.58 | 23.48 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:35:56Z | run-1-diy-noop-7000 | 8.5 | 1400 | 21.88 | 6999.47 | 1.57 | 24.06 | 15.1 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:36:42Z | run-1-diy-posts-7000 | 8.5 | 1400 | 29.14 | 6998.6 | 2.88 | 33.3 | 20.08 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:37:28Z | run-1-swoole-posts-7000-rerun | 8.5 | 1400 | 31.62 | 6990.6 | 5.38 | 59.1 | 21.75 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:38:14Z | run-2-swoole-noop-7000 | 8.5 | 1400 | 24.44 | 6998.77 | 1.66 | 41.2 | 16.9 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:39:00Z | run-2-swoole-posts-7000 | 8.5 | 1400 | 33.58 | 6999.42 | 9.6 | 112.67 | 23.12 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:39:47Z | run-2-workerman-nocache-noop-7000 | 8.5 | 1400 | 26.24 | 6999 | 2 | 32.78 | 18.16 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:40:34Z | run-2-workerman-nocache-posts-7000 | 8.5 | 1400 | 33.32 | 6999.14 | 9.34 | 72.85 | 22.98 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:41:20Z | run-2-workerman-stock-noop-7000 | 8.5 | 1400 | 23.39 | 6999.07 | 1.71 | 28.98 | 16.17 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:42:06Z | run-2-workerman-stock-posts-7000 | 8.5 | 1400 | 35.38 | 6999.32 | 4.05 | 35.28 | 24.42 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:42:52Z | run-2-diy-noop-7000 | 8.5 | 1400 | 22.03 | 6999.28 | 1.79 | 34.77 | 15.18 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:43:39Z | run-2-diy-posts-7000 | 8.5 | 1400 | 28.74 | 6999.33 | 3.03 | 27.12 | 19.84 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:44:25Z | run-3-swoole-noop-7000 | 8.5 | 1400 | 25.47 | 6999.17 | 1.69 | 22.18 | 17.63 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:45:12Z | run-3-swoole-posts-7000 | 8.5 | 1400 | 32.83 | 6997.83 | 5.14 | 54.03 | 22.62 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:45:58Z | run-3-workerman-nocache-noop-7000 | 8.5 | 1400 | 25.06 | 6999.02 | 1.6 | 37.37 | 17.34 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:46:44Z | run-3-workerman-nocache-posts-7000 | 8.5 | 1400 | 31.5 | 6998.99 | 3.74 | 34.87 | 21.74 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:47:30Z | run-3-workerman-stock-noop-7000 | 8.5 | 1400 | 23.59 | 6999.12 | 1.68 | 16.54 | 16.32 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:48:16Z | run-3-workerman-stock-posts-7000 | 8.5 | 1400 | 33.12 | 6999.06 | 2.8 | 20.18 | 22.83 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:49:02Z | run-3-diy-noop-7000 | 8.5 | 1400 | 21.52 | 6999.45 | 1.9 | 34 | 14.89 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:49:48Z | run-3-diy-posts-7000 | 8.5 | 1400 | 29.89 | 6999.44 | 5.73 | 76.85 | 20.61 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:51:06Z | run-1-swoole-noop-9500 | 8.5 | 1900 | 17.83 | 9498.82 | 1.65 | 32.78 | 16.7 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:51:52Z | run-1-swoole-posts-9500 | 8.5 | 1900 | 29.1 | 9482.44 | 69.81 | 278.86 | 27.1 | 0 | 468 | 0 | false | no |
| 2026-11-22T02:52:42Z | run-1-diy-noop-9500 | 8.5 | 1900 | 15.91 | 9498.98 | 1.85 | 29.2 | 14.76 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:53:28Z | run-1-diy-posts-9500 | 8.5 | 1900 | 29.37 | 9398.53 | 108.23 | 450.7 | 26.83 | 0 | 2995 | 0 | false | no |
| 2026-11-22T02:54:15Z | run-1-swoole-posts-9500-rerun | 8.5 | 1900 | 28.34 | 9498.64 | 7.14 | 97.82 | 26.46 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:55:01Z | run-1-diy-posts-9500-rerun | 8.5 | 1900 | 26.12 | 9497.03 | 20.7 | 89.88 | 24.31 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:55:48Z | run-2-swoole-noop-9500 | 8.5 | 1900 | 18.53 | 9498.86 | 2.21 | 36.84 | 17.36 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:56:34Z | run-2-swoole-posts-9500 | 8.5 | 1900 | 31.01 | 9497.92 | 17.76 | 109.09 | 28.94 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:57:20Z | run-2-diy-noop-9500 | 8.5 | 1900 | 19.76 | 9498.3 | 26.59 | 194.91 | 18.46 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:58:07Z | run-2-diy-posts-9500 | 8.5 | 1900 | 27.66 | 9498.03 | 7.37 | 70.09 | 25.79 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:58:53Z | run-3-swoole-noop-9500 | 8.5 | 1900 | 20.88 | 9498.91 | 3.5 | 122.09 | 19.53 | 0 | 0 | 0 | true | yes |
| 2026-11-22T02:59:42Z | run-3-swoole-posts-9500 | 8.5 | 1900 | 31.01 | 9497.76 | 6.96 | 45.01 | 28.94 | 0 | 0 | 0 | true | yes |
| 2026-11-22T03:00:28Z | run-3-diy-noop-9500 | 8.5 | 1900 | 17.37 | 9499.02 | 2.14 | 28.58 | 16.25 | 0 | 0 | 0 | true | yes |
| 2026-11-22T03:01:14Z | run-3-diy-posts-9500 | 8.5 | 1900 | 29.08 | 9498.1 | 6.6 | 56.16 | 27 | 0 | 0 | 0 | true | yes |
| 2026-11-22T03:05:14Z | info-8.6-workerman-nocache-noop-7000 | 8.6 | 1400 | 24.57 | 6998.79 | 1.78 | 31.63 | 16.95 | 0 | 0 | 0 | true | information only |
| 2026-11-22T03:06:00Z | info-8.6-workerman-nocache-posts-7000 | 8.6 | 1400 | 34.13 | 6999.26 | 1.99 | 43.99 | 23.53 | 0 | 0 | 0 | true | information only |
| 2026-11-22T03:06:46Z | info-8.6-diy-noop-7000 | 8.6 | 1400 | 20.68 | 6999.14 | 2.33 | 58.35 | 14.25 | 0 | 0 | 0 | true | information only |
| 2026-11-22T03:07:33Z | info-8.6-diy-posts-7000 | 8.6 | 1400 | 33.16 | 6999.61 | 10.21 | 75.96 | 22.84 | 0 | 0 | 0 | true | information only |

### Connection runs, in the order they ran

| Written (UTC) | Run | Max connections | Why it stopped | Other containers |
|---|---|---|---|---|
| 2026-11-22T03:02:03Z | conns-swoole-8.5 | 65000 | request timeout | 0 |
| 2026-11-22T03:03:00Z | conns-workerman-nocache-8.5 | 65000 | request timeout | 0 |
| 2026-11-22T03:03:57Z | conns-diy-8.5 | 65000 | request timeout | 0 |

### The first try (rate / 10 VUs, stopped after round 2): kept, not counted anywhere

| Written (UTC) | Run | VUs | µs CPU/req | p99 ms | max ms | dropped | other containers | valid |
|---|---|---|---|---|---|---|---|---|
| 2026-11-22T02:15:16Z | run-1-swoole-noop-7000 | 700 | 22.94 | 2.68 | 49.15 | 0 | 0 | true |
| 2026-11-22T02:16:03Z | run-1-swoole-posts-7000 | 700 | 37.95 | 18.75 | 140.19 | 124 | 0 | false |
| 2026-11-22T02:16:50Z | run-1-workerman-nocache-noop-7000 | 700 | 24.21 | 3.67 | 35.63 | 0 | 0 | true |
| 2026-11-22T02:17:36Z | run-1-workerman-nocache-posts-7000 | 700 | 33.78 | 7.21 | 100.65 | 0 | 0 | true |
| 2026-11-22T02:18:23Z | run-1-workerman-stock-noop-7000 | 700 | 21.93 | 4.73 | 68.65 | 0 | 0 | true |
| 2026-11-22T02:19:10Z | run-1-workerman-stock-posts-7000 | 700 | 36.56 | 5.44 | 40.08 | 0 | 0 | true |
| 2026-11-22T02:19:56Z | run-1-diy-noop-7000 | 700 | 19.92 | 2.11 | 20.52 | 0 | 0 | true |
| 2026-11-22T02:20:42Z | run-1-diy-posts-7000 | 700 | 30.75 | 5.41 | 41.8 | 0 | 0 | true |
| 2026-11-22T02:21:28Z | run-1-swoole-posts-7000-rerun | 700 | 34.55 | 8.79 | 72.94 | 0 | 0 | true |
| 2026-11-22T02:22:15Z | run-2-swoole-noop-7000 | 700 | 22.92 | 2.02 | 45.42 | 0 | 0 | true |
| 2026-11-22T02:23:01Z | run-2-swoole-posts-7000 | 700 | 36.06 | 8.11 | 105.65 | 0 | 0 | true |
| 2026-11-22T02:23:47Z | run-2-workerman-nocache-noop-7000 | 700 | 23.68 | 2.51 | 51.7 | 0 | 0 | true |
| 2026-11-22T02:24:34Z | run-2-workerman-nocache-posts-7000 | 700 | 40.32 | 66.28 | 290.14 | 2244 | 0 | false |
| 2026-11-22T02:25:20Z | run-2-workerman-stock-noop-7000 | 700 | 21.11 | 3.3 | 57.96 | 0 | 0 | true |
| 2026-11-22T02:26:08Z | run-2-workerman-stock-posts-7000 | 700 | 41.64 | 22.93 | 149.89 | 494 | 0 | false |
| 2026-11-22T02:26:54Z | run-2-diy-noop-7000 | 700 | 19.7 | 2.54 | 28.34 | 0 | 0 | true |
| 2026-11-22T02:27:41Z | run-2-diy-posts-7000 | 700 | 27.35 | 2.51 | 30.71 | 0 | 0 | true |
| 2026-11-22T02:28:27Z | run-2-workerman-nocache-posts-7000-rerun | 700 | 32.93 | 34.26 | 310.66 | 1114 | 0 | false |

Reading the tables:

- **Pss** counts the SQLite database pages the process has touched through its mapping (the `posts.js` rows are about 108 MiB
  above the `/noop` ones for that reason), so it is shown and not ranked on. **Pss_Anon** leaves them out. **memory.current**
  also holds the 250 MB copy of the database in page cache (about 255 MiB at rest), so it only compares as a difference
  between runtimes. Under load, the three peaks are the largest of the three samples of each counted run.
- **Max connections** is what the client got an answer on and still holds at the last step it fully held. At the step
  that follows (66,000) every runtime ended with 65,522 or 65,523 held, which is the 65,535 `nofile` limit minus the
  handful of descriptors the server itself uses, and the client's request timed out (a server out of descriptors never
  accepts, so the harness reports `request timeout`).
- **Source addresses:** Workerman's run used 127.0.0.2, .3, then .9 to .13: the client skipped .4 to .8, the addresses
  Swoole's run had left in TIME_WAIT a minute earlier. DIY's run, a minute after that, got .2 to .8 back.
- **Every run in the order it ran** lists the max latency of each run. Three counted-series runs dropped iterations
  (`run-1-swoole-posts-7000`, `run-1-swoole-posts-9500`, `run-1-diy-posts-9500`: 1,785, 468 and 2,995 dropped, max
  latency 430, 279 and 451 ms) and were rerun once each, all three reruns valid. All three are `posts.js` runs of round 1.
  Why round 1 only is not known; one guess, not tested: the first reads of the seed copy of a fresh container.

### About the first try

The first try ran series A at rate / 10 VUs (700 at 7,000 req/s). It was stopped after round 2: 4 `posts.js` runs dropped
iterations during stalls of 100 to 300 ms, and `workerman-nocache` posts was invalid twice in round 2. The cause of the
stalls is not separated: the host (the Mac was under memory pressure, 35 GB used and 16 GB in the compressor, with a load
average of 6 to 7 on 12 CPUs) or the server's reads of its database. What points away from the host alone: all 7 invalid
runs of the first try and the counted series are `posts.js` runs, none of the 28 `/noop` runs is invalid, and 6 of the 7
cost more µs/req than the valid run of their pair, which a paused vCPU would not do (it adds no CPU time to the server's
cgroup). The extra VUs absorb a stall whatever its cause. Its 18
runs are in `first-try-700-vus/` with their `.txt`, and are not counted anywhere. The table at the end of the output above
lists them. Series A restarted from round 1 with twice the VUs, and every run of A, B and D used them. One thing the two
tries show side by side, without being a test (the VUs and the time of day both changed): on `/noop` every runtime cost
about 2 µs/req more at 1,400 VUs than at 700 (Swoole 22.9 and 22.9 in the first try, 25.5 in the counted series).

## Did the predictions hold?

Each one judged by its own rule: a µs/req number is the median of the 3 interleaved repeats, a percentage is relative to
the number the prediction names, a range holds if the value is inside it.

1. **Swoole `/noop` at 7,000 req/s: 18 to 35 µs/req: held.** The median is **25.47** (24.44 to 25.72).
2. **`/posts/:id` costs 5 to 15 µs/req more than `/noop` on every runtime, gaps within 3 µs of each other: held for the
   three runtimes it names, with a caveat.** The gaps are Swoole 7.37, Workerman nocache 7.08, DIY 7.26 (largest
   difference 0.28). Workerman stock's gap is 10.67 because its `/noop` is cheaper (prediction 4), still inside 5 to 15;
   with stock counted as a fourth runtime the largest difference is 3.58, outside the 3 µs.
3. **Workerman nocache costs 30 to 70 % more than Swoole on `/noop`: did not hold.** It costs **3.0 % more** (26.24
   against 25.47). On posts the difference is 1.5 %. So the flip rule's condition (more than 30 % behind) is not met: see
   the rule below.
4. **Workerman stock 10 to 25 % cheaper than nocache on `/noop`, under 5 % cheaper on posts: held, narrowly.** On `/noop`
   stock is **10.9 % cheaper** (23.39 against 26.24, relative to nocache), 0.9 points inside the range. On posts stock is
   2.2 % more expensive (34.05 against 33.32), so it is not 5 % cheaper.
5. **DIY within 15 % of Swoole on `/noop`, finalists Swoole and DIY: held, narrowly.** DIY is **14.1 % cheaper**
   (21.88 against 25.47); depending on which repeats are compared it goes from 9.9 % (DIY's worst, 22.03, against
   Swoole's best, 24.44) to 16.3 % (DIY's best, 21.52, against Swoole's worst, 25.72), so the 15 % line is crossed only by
   the best against the worst. On posts it is 11.3 % cheaper. The finalists by the posts medians are DIY (29.14) and Swoole
   (32.83); Workerman nocache is third (33.32).
6. **At 9,500 req/s µs/req is 5 to 15 % lower than at 7,000 for both finalists: did not hold.** On posts it held (DIY
   27.66 against 29.14, 5.1 % lower; Swoole 31.01 against 32.83, 5.6 % lower), both just above the bottom of the range.
   On `/noop` the drop is much larger (DIY 17.37 against 21.88, 20.6 % lower; Swoole 18.53 against 25.47, 27.3 % lower).
7. **Max connections: partly held.** Swoole did **not** stop on memory: it held 65,000 and 65,522 at the next step, with
   no OOM kill (`oom_kill` 0 at every step) and memory.current of 1,659 MiB, under the 2 GiB limit. It stopped at 65,522 held, which fits both the 65,535 `nofile` limit
   and Swoole's own `max_connection` of 65,535: the run cannot tell which. Workerman and DIY stopped on the fd limit between 65,000 and 65,535 (65,000 held, 65,523 at
   the next step): that part held.
8. **Memory per connection (Pss slope): did not hold for two of three, held for DIY.** Swoole **14.29 KiB** (predicted 15
   to 45), a slope that averages two regimes (about 69 KiB per connection below 10,000, about 5 KiB above 20,000: see
   "Surprising"), so 0.7 under the range is not a near miss; Workerman **2.37 KiB** (3 to 10: 0.6 under), DIY **1.48 KiB** (1 to 4: held). The `memory.current`
   slope is higher than the Pss slope on all three (18.13, 6.07, 5.19 against 14.29, 2.37, 1.48): that part held.
9. **p99 at 7,000 under 3 ms on all three, both routes, Workerman the highest: did not hold.** On `/noop`: Swoole 1.69
   ms, Workerman nocache 2.00, DIY 1.79: under 3, and Workerman the highest. On posts: Swoole 5.38, Workerman nocache
   7.18, DIY 3.03: over 3 for all three (DIY by 0.03), Workerman still the highest. The medians hide wide spreads: single posts
   runs at 7,000 had p99 from 2.8 to 16 ms, with the max latency of a run up to 167 ms (stalls of unseparated cause, see "About the first try").

### The flip rule

The plan's rule for the runtime choice: Workerman's loop with our own parser would replace the plain patched Workerman if the patched parser
could not come within 30 % of Swoole on a no-op route. **It comes within 3.0 %** (26.24 against 25.47 µs/req on `/noop`),
so the rule does not flip. For reference, DIY is 14.1 % cheaper than Swoole on the same route and 16.6 % cheaper than
Workerman nocache (21.88 against 26.24 µs/req).

## Environment

| What | Value |
|---|---|
| Machine | Apple M3 Pro (`Mac15,6`), arm64 |
| Docker | Docker Desktop 4.76.0 (228118), engine 29.5.2 |
| VM | kernel `6.12.76-linuxkit`, 12 CPUs, 8.3 GB of memory (`docker info`), `ip_local_port_range` 55000 to 65535 |
| CPU layout | server on CPU 2 (`--cpuset-cpus 2`, `--cpus=1`), k6 and the connection client on CPUs 4 to 11, probe on CPUs 0 and 1 |
| Server limits | `--cpus=1 --memory=2g --memory-swap=2g --ulimit nofile=65535:65535`, host network |
| Images | `php-lab:8.5` id `sha256:a26d560527d715e977560151d208365dcf0ab6b99ba9aa4bab89d1ff9ec388eb` (PHP 8.5.13), `php-lab:8.6` id `sha256:44fee953cac08063e6862e83329b6bb50673ca472fa4a2b38cd952db1580e294` (PHP 8.6.0); local builds, no registry digest |
| Runtimes | Swoole 6.2.6; Workerman 5.2.4 (stock tree, and the tree with its 5 caches patched out), event loop `Workerman\Events\Event` (PECL event 3.2.0); DIY on PECL event 3.2.0 (`epoll`) |
| PHP flags | `-d memory_limit=-1 -d opcache.enable_cli=1 -d opcache.jit=tracing -d opcache.jit_buffer_size=32M -d opcache.file_update_protection=0 -d zend.assertions=-1`, plus the `-d extension=...` of each server |
| k6 | v1.8.3, image `grafana/k6:1.8.3@sha256:2cd9cd09e4119340a122aaf06f30cf3009c19db23b87954909fba0d3eda58e08`, scripts `lab/macro/k6/fixed-rate.js` and `lab/macro/k6/posts.js` |
| VUs | pre-allocated = max = rate / 5 (1,400 at 7,000 req/s, 1,900 at 9,500) |
| Harness | the lab at commit `9aadddc` (no lab script changed by this commit) |
| Other load | The VM had **no other container** before each series and in every counted JSON. The Mac was not quiet: Chrome and other apps were running, the load average was 4.6 to 7.6 on 12 CPUs during the runs, and the Mac was under memory pressure (about 35 GB used, 16 GB in the compressor, at 21:28). Stalls of 100 to 450 ms happened (the dropped iterations of the invalid runs, and the max-latency column), all on `posts.js`; their cause is not separated (the host, or the server's database reads). I ran no build, no other benchmark and no `lab/check.sh` during a series (a `summarize.sh` run with no input, blocked on stdin, ran during the second and third runs of the restart; it used no CPU). |

The exact commands, from the repo root (the drivers were loops in a scratch folder, not committed; they are these calls in
this order; `<server>` is one of the four below, `<route>` one of the two below):

```bash
# server flags
#   swoole             --server lab/servers/bake-swoole.php
#   workerman-nocache  --server lab/servers/bake-workerman.php --ext pcntl --ext sockets --ext event --env WORKERMAN_TREE=nocache
#   workerman-stock    --server lab/servers/bake-workerman.php --ext pcntl --ext sockets --ext event --env WORKERMAN_TREE=stock
#   diy                --server lab/servers/bake-diy.php --ext sockets --ext event
# route flags
#   noop   --path /noop
#   posts  --path /posts/1 --script lab/macro/k6/posts.js
bash lab/macro.sh --image 8.5 <server flags> --label <server> <route flags> --rate 7000 --pre-vus 1400 --max-vus 1400 \
  --duration 30 --warmup 10 --out lab/results/2026-11-21-bake-off/run-<round>-<server>-<route>-7000.json
# series B: --rate 9500 --pre-vus 1900 --max-vus 1900, swoole and diy only, out run-<round>-<server>-<route>-9500.json
# series D: --image 8.6, workerman-nocache and diy, --rate 7000 --pre-vus 1400 --max-vus 1400, out info-8.6-<server>-<route>-7000.json
bash lab/conns.sh --image 8.5 <server flags> --label <server> --out lab/results/2026-11-21-bake-off/conns-<server>-8.5.json
bash lab/conformance.sh --image 8.5 <server flags>        # output kept as conformance-<server>.txt
```

## Surprising or worth knowing

- **Workerman with its caches out is only 3 % behind Swoole on `/noop`,** not 30 to 70 %. Its parsing, `Request` and
  `Response` objects run in PHP, and still cost about 0.8 µs/req more. Prediction 3 assumed a much heavier PHP path.
- **Swoole's memory is not linear in connections.** From 1,000 to 10,000 connections Pss_Anon grows by 607 MiB (about 69
  KiB per connection); from 20,000 to 65,000 by 228 MiB (about 5 KiB per connection). The slope over every held step
  (14.28 KiB) describes neither half. Under the macro load, the 1,400 connections of k6 already put Swoole's Pss_Anon at
  102 MiB, against 12 MiB for Workerman and 9 MiB for DIY, and memory.current at 357 MiB against 268 and 263.
- **`/noop` costs a lot less at 9,500 than at 7,000** (20 to 27 % less per request), much more than the 5 to 15 % predicted,
  while posts drops by about 5 %. **Not explained.** The repeats are wide: DIY's three `/noop` runs at 9,500 are 15.91, 17.37
  and 19.76 (27 %, 21 % and 10 % under the 7,000 median). A fixed cost per wake-up would be the same for both routes,
  but the saving is 7 µs on Swoole `/noop` (25.47 to 18.53) against 1.8 on posts, so that explanation does not fit
  and was not tested.
- **No runtime was killed for memory.** Swoole at 65,522 connections is at 1.62 GiB of the 2 GiB, 18 KiB of
  `Pss_Anon` per connection at the max on average.
- **The posts route stalls more than `/noop`:** all 7 invalid runs (4 in the first try, 3 in the counted series) were
  `posts.js` runs, with 100 to 450 ms of max latency, at 700 VUs and at 1,400; none of the 28 `/noop` runs was invalid. The
  cause is not separated: the host, or the server's database reads. 6 of the 7 cost more µs/req than the valid run of
  their pair.
- **DIY on 8.6** cost 33.16 on posts in its one information run, 13.8 % above its 8.5 median (the other three 8.6 numbers
  are within 6.4 % of the 8.5 medians). One run each: not a result.
- **DIY wins by a margin that is not large:** 14.1 % on `/noop` and 11.3 % on posts against Swoole, with a spread of
  4 to 9 % inside each runtime's 3 repeats.
