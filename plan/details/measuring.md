# How we measure

Two levels, always both: a micro result that doesn't hold up end to end doesn't count.

## Micro: one step, in isolation

- A small PHP harness per step: warm up, then `hrtime(true)` around N iterations, repeated 10 times, report the
  median and the spread in ns per call. No dependency needed.
- Run inside the same container and the same PHP build as the server, with OPcache on for the CLI, JIT on and off.
- Each variant is first checked for correctness on the test suite's inputs. A fast wrong variant is discarded.

## Macro: the whole server

- **Fixed rate, not max rate:** k6 with `constant-arrival-rate` at a set number of req/s. We read:
  - **µs CPU per request:** the cgroup's `cpu.stat` (`usage_usec`) before and after, divided by the requests. It's
    the leaderboard's metric, so our numbers compare with theirs;
  - **p95 and p99**, and the error rate;
  - **peak RSS** of the server's cgroup.
- **Connection ceiling:** many VUs with long sleeps and a no-op route, to find the max idle connections.
- **The real score:** `bench/load.js` with ramps, the way the leaderboard runs it, only at the end.

## Profiling

When a step is slower than its theory: a sampling profiler (SPX or Excimer) for a flame graph of the PHP side, and
`perf` for the C side (Swoole, SQLite), if the environment allows it.

## Prior art as predictions (D5)

Every step re-measures what the others measured. Before a run, write their number as the prediction next to the
variant; after, our number and whether it held. A prediction that fails is the interesting result.

## Environment (D7)

The Mac is an Apple M3 Pro (arm64); the bench VM is x86_64 with AVX-512. Relative results (variant A versus B) should
hold across both. Absolute numbers (users, µs/req) only count on x86.

- **Default:** Ubuntu 24.04 in Docker on the Mac, `--cpus=1 --memory=2g --memory-swap=2g`, `nofile` 65535.
- **Network path:** never the Docker bridge, and never k6 on macOS itself: Docker Desktop's port forwarding from
  macOS into its VM goes through a userspace proxy. k6 runs in its own container in the same Docker VM, both with
  `--network host`, the server pinned to one core (`--cpuset-cpus`) and k6 to others, so they don't share the server's
  CPU budget ([notes.md](../notes.md), 09:11).
- **Load generator memory:** mattsplat's k6 container died at about 22,000 VUs. For the connection tests (65k+), an
  idle-connection holder (a small Go or C program that opens N sockets and sends one request per socket now and then)
  may be cheaper than k6 VUs.

### x86 in the cloud, when we need it

Jacob asked whether AWS has a Xeon and whether two EC2 instances side by side would work. Yes to both:

- **The CPU:** the bench VM is a Xeon Platinum 8260 (Cascade Lake, AVX-512). EC2's `c5` family runs Cascade Lake or
  Skylake Xeons with AVX-512, the closest match. The exact model varies by host: check `/proc/cpuinfo` on each launch.
- **1 vCPU:** EC2 has no 1-vCPU `c5`, but the CPU options at launch (`CoreCount=1`, `ThreadsPerCore=1`) turn a
  `c5.large` into 1 vCPU. 2 GB: cap the server's cgroup (`MemoryMax=2G`, no swap), since a `c5.large` has 4 GB.
- **Avoid `t2`/`t3`:** burstable CPU credits would skew a 5-minute run.
- **Load generator:** a bigger instance (`c5.2xlarge` or larger) in the **same availability zone**, both in a
  **cluster placement group** for the lowest latency (the bench has 0.25 ms RTT).
- **Cost:** pay per hour, terminate after each session. To price when we get there.
- **Access:** a personal AWS account, read-only by default. Write rights through a temporary
  IAM policy in this plan's folder, deleted at the end. SSH open to your IP only.
