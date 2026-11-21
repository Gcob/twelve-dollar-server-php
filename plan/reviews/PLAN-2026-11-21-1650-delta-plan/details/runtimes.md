# PHP runtimes: the theory before the bake-off

Every claim here is a hypothesis. Phase 3 measures them with the same minimal handler on each runtime.

**In the bake-off (D6):** Swoole, Workerman and DIY. RoadRunner, FrankenPHP and OpenSwoole stay here as theory only.

Rule already set: no Nginx, no PHP-FPM (D1). Every candidate is a long-running process that keeps PHP, OPcache and
the prepared statements in memory between requests.

## The candidates

| Runtime                    | Who parses HTTP                        | Path of a request (theory)                                             | Who holds the connections                            |
|----------------------------|----------------------------------------|------------------------------------------------------------------------|------------------------------------------------------|
| **Swoole 6**               | C++ extension (llhttp)                 | epoll in C, then a PHP callback, in the same process                   | `SWOOLE_PROCESS`: the master. `SWOOLE_BASE`: each worker |
| **OpenSwoole 25**          | C++ extension (fork of Swoole 4.8)     | same as Swoole                                                         | same as Swoole                                       |
| **Workerman 5**            | PHP userland (`Http::input`/`decode`)  | epoll through ext-event (or `stream_select`), parsing in PHP           | each worker, with `reusePort`                        |
| **RoadRunner 2025**        | Go                                     | Go parses, serializes the request, pipe to a PHP worker, then back     | one Go process                                       |
| **FrankenPHP (worker mode)** | Go (Caddy)                           | Go parses, crosses into embedded ZTS PHP through cgo, then back        | one Go process                                       |
| **DIY**                    | our own PHP parser, built for 5 routes | ext-event or ext-uv loop, raw `fread`/`fwrite` on the sockets          | each process, with `SO_REUSEPORT`                    |

## Strengths and weaknesses

### Swoole

- **For:** the HTTP parser, the event loop and the response writer are all in C. PHP only runs our handler. That's
  the least PHP code per request of all the options.
- **Against:** a big extension (compiled with `pecl`, a few minutes on 1 vCPU). Its `Request`/`Response` objects
  cost a bit on every request, even the headers we never read.
- **Leaderboard:** 71,000 users twice (#24, #28), stuck on the fd ceiling with the CPU at 66 to 71 %, at 94 to
  101 µs/req. Both use `SWOOLE_BASE` with 1 worker and no coroutines (details in [prior-art.md](prior-art.md)).

### OpenSwoole

- **For:** same design as Swoole.
- **Against:** forked from an older Swoole, slower development. Nothing it does better on paper.
- **Leaderboard:** 37,000 with the pype framework on top (#337), so it says little about the raw runtime.

### Workerman

- **For:** pure PHP plus ext-event: small, easy to read and to patch. Historically one of the top PHP entries in
  TechEmpower. `reusePort` gives each worker its own fd budget.
- **Against:** the HTTP parsing runs in PHP, so it costs more PHP opcodes per request than Swoole.
- **Checked (5.2.4):** 5 static caches between requests, none can be switched off. `TcpConnection` keeps up to 512
  decoded `Request` objects keyed by the whole raw request, and `Http`/`Request` cache the header length, headers,
  query strings and bodies. No data, response or JWT result, but a grey zone for rules 5 and 7.
- **D10:** `build.sh` patches the 5 caches out (`TcpConnection` request cache, `Http::input`, `Request` headers,
  query string and body), and fails loudly if a patch doesn't apply, like tzimpel's Swoole patch. The bake-off
  measures the patched Workerman, plus one run with the stock caches to see what they buy.
- **Flips to Workerman's loop with our own parser** if the patched parser can't come within 30 % of Swoole on a no-op
  route.
- **Leaderboard:** no entry.

### RoadRunner

- **For:** Go handles 15k+ connections easily, PHP workers stay simple.
- **Against:** every request crosses a process boundary twice (serialize, pipe, unserialize, then the same for the
  response). On 1 vCPU, Go and the PHP workers fight for the same core, and every crossing is a context switch.
  One Go process holds all the connections, so it hits the same 65,535 fd ceiling.
- **Leaderboard:** no entry. Theory: the slowest of the "modern" options here.

### FrankenPHP (worker mode)

- **For:** no IPC, PHP runs inside the Go process. One binary, modern.
- **Against:** cgo crossings on every request, Caddy's middleware, and a thread-safe (ZTS) PHP build, which is
  slower than the non-thread-safe one. One process, same fd ceiling.
- **Leaderboard:** 19,000 to 21,000 with Symfony (#40, #338), but Symfony costs a lot on its own. The raw number is
  unknown.

### DIY (our own loop and parser)

- **For:** we only parse what the 5 routes need: the request line, `Authorization`, `Content-Length`, the body.
  No objects, no headers array. In theory, the least work per request in PHP.
- **Against:** the most code to write and keep correct (pipelining, partial reads, keep-alive). The parser runs in
  PHP, so it has to beat Swoole's C parser plus its object overhead, which isn't a given.
- **Leaderboard:** no entry. The wildcard of the bake-off.

### Left out

- **AMPHP, ReactPHP:** pure-PHP generic stacks with promises or fibers on every request. Slower than Workerman on
  paper, with no advantage for this workload.
- **ngx-php, PHP-FPM, Apache mod_php:** excluded by D1.

## What the bake-off measures

Same handler everywhere: `GET /posts/:id` (one SQLite read, one small JSON) and a `GET /health`-like no-op.

- **µs CPU per request** at a fixed request rate (cgroup `cpu.stat` divided by the request count): the leaderboard's
  own metric.
- **Max idle keep-alive connections** before errors, and **RSS per connection**.
- **p99 at a fixed rate**, to see the jitter of each runtime (Go GC, PHP GC, context switches).
