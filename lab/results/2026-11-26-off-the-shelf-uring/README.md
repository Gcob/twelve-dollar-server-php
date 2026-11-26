# Off-the-shelf io_uring: Swoole's `uring_socket` and `ext-mrloop`

Phase 8 asks whether an io_uring loop that already exists could cost fewer microseconds per request than phase 7's submission (`ext-event`, 2 processes,
about 59 µs a request on the AWS bench) or than our own ring (`lab/servers/uring-noop.php`). Two off-the-shelf options were looked at: our app served by
Swoole's coroutine HTTP server on its io_uring sockets, which was built, run and measured here, and `ext-mrloop`, whose code was read.

Everything measured here ran on the Docker Desktop VM of a Mac (arm64, kernel 6.12, 1 CPU and 2 GiB for the server, PHP 8.5.13): smokes of the harness
and counts, never a verdict on the x86 bench. A number that was read from code and not run says so.

## Swoole 6.2.6 on io_uring sockets (`php-lab:8.5-uring`, `lab/servers/swoole-co.php`)

### What was built

- `lab/images/install-liburing.sh`: liburing 2.15 from its tag's tarball (sha256 pinned), under `/usr/local`; the script refuses a version under 2.8 before it
  downloads anything (Ubuntu 24.04 ships 2.5, Swoole wants 2.8 or later).
- `php-lab:8.5-uring`: the `8.5` image with Swoole configured `--enable-uring_socket --with-liburing-dir=/usr/local`. `php --ri swoole` prints
  `io_uring => enabled` and `uring_socket => enabled`; the build stops if either is missing.
- `lab/servers/swoole-co.php`: the challenge app (`lab/app/app.php`) in one `Co\run`, one `Swoole\Coroutine\Http\Server`, every request answered by
  `handler_handle()`. It prints `loop: swoole-co, uring` (`swoole-co, epoll` on a Swoole built without io_uring: the 8.5 image says so, `check_swoole_co`).
- It passes the challenge's own 42 checks: `lab/challenge-test.sh --image 8.5-uring --server lab/servers/swoole-co.php --ext swoole --seccomp-unconfined`
  prints `passed=42 failed=0`.

### The sockets really are on io_uring

`lab/syscalls.sh` (`strace -c -f` for 20 s on the server at 2,000 req/s, 39,880 requests counted by the aggregator, `--seccomp-unconfined`):
`io_uring_enter` 0.627 a request; `recvfrom`, `sendto`, `accept4` and `write`: none (0 calls). The rest are the app's own calls: `fcntl` 2.455 (SQLite's file
locks), `pwrite64` 0.574, `epoll_pwait` 0.565 (the loop waits on the ring's eventfd), `pread64` 0.064; 4.287 system calls a request in all.

### The harness smoke (not a verdict)

One step-lab pair, round 1 (the reference runs last), 7,500 req/s for 60 s, think scale 0.02, no seccomp filter on either side, `--expect-loop` on both
(`ref=epoll`, `swoole-co=swoole-co, uring`); the reference is phase 7's submission. One pair each, no A/A floor: the harness works, the numbers are not judged.
The raw runs stay in the factory's `lab/`.

| Idle connections | Huge pages for the swoole-co process | swoole-co µs/req | reference µs/req | swoole-co achieved req/s | both valid |
|---|---|---|---|---|---|
| 3,000 | the VM's (`always`) | 43.6 | 33.8 | 7,451 | yes |
| 20,000 | off (`SWOOLE_CO_THP_OFF=1`) | 53.0 | not run | 7,426 | yes |
| 60,000 | off | 221.7 | 32.9 | 4,449 (fails the 97 % rule) | yes |

The reference's cost does not move with the idle count; swoole-co's does, and at 60,000 it cannot carry the offered rate. The cause was not traced. The 60,000
run is the Done-when's own number; the first attempt at it (with the VM's huge pages on) was OOM-killed, see below.

### What a connection costs in memory

`lab/conns.sh --app` (a server that is the app: it starts on a fresh copy of the seed and the requests are `GET /health`) holds idle keep-alive connections
one at a time and reads the server's Pss, `memory.current` and OOM kills at each step. The first runs, in the VM as it is, stopped early:

| Run | Connections held | Stopped because | Pss per connection (slope) |
|---|---|---|---|
| default C stack (2 MiB) | 12,000 (13,530 at the end) | server OOM-killed | 160.5 KiB |
| `stack_size` 131072 | 20,000 (21,450 at the end) | server OOM-killed | 99.1 KiB |
| `stack_size` 65536 (the smallest Swoole accepts) | 123 | the app answered `200` with an empty body (bad answer); the cause was not traced | not read |

The cost comes from the VM's kernel having transparent huge pages on `always` (`/sys/kernel/mm/transparent_hugepage/enabled`): the server's memory is
mostly 2 MiB-aligned mappings (a coroutine's C stack, PHP's own chunks). At 3,000 connections `smaps_rollup` said `AnonHugePages: 878,592 kB` of `Rss: 942,796 kB`:
a connection pays for whole huge pages it does not use. With `SWOOLE_CO_THP_OFF=1` (`prctl(PR_SET_THP_DISABLE)` through FFI, before anything else is mapped):

| Run | Connections held | Stopped because | Pss per connection (slope) | Pss at the last step |
|---|---|---|---|---|
| default C stack, to 64,000 | 64,000 of 64,000 planned | no ceiling: every planned step held | 21.1 KiB | 1,342 MiB |
| default C stack | 30,000 of 30,000 | no ceiling | 21.1 KiB | 642 MiB |
| `stack_size` 131072 | 40,000 of 40,000 | no ceiling | 21.1 KiB | 849 MiB |

With huge pages off the stack size makes no difference (21.1 KiB either way), the 2 GiB is not the wall, and 64,000 connections sit in one process. `memory.current`
(which counts the page cache of the seed copy and the kernel's socket memory too) grows 29 KiB a connection and reaches the 2 GiB limit at 64,000 without an OOM kill.
The baseline, one request and no idle connection, is Pss 23.4 MiB. The files of this folder are the runs' JSON and tables (`conns-*.json`, `conns-*.txt`).

**To 71,000 and 135,000 connections**, by the slopes, a straight line from the 64,000 held to the numbers asked for (beyond the range measured):

| Connections | Pss, one process | Pss plus the kernel's socket memory (the `memory.current` slope) |
|---|---|---|
| 71,000 | about 1.45 GiB | about 2.2 GiB (2.0 without the seed copy's 250 MB of page cache, which the kernel can drop): at the 2 GiB limit |
| 135,000 | about 2.7 GiB | about 4.0 GiB: over it |

One process of Swoole's cannot go past its file-descriptor limit anyway: the sockets are plain descriptors (`lab/lib.sh` gives the container 65,535), so 135,000 needs
more than one process, which this server (one `Co\run`) does not do. With huge pages on, 160 KiB a connection does not fit even 13,000.
**To check on the bench:** `cat /sys/kernel/mm/transparent_hugepage/enabled` on the x86 box; where it says `madvise` or `never`, the 21 KiB figure is the one that applies.

### What differs, and one limit found on the way

`swoole-co.php` answers with the same status and body as the DIY server but not the same bytes: Swoole adds `Server`, `Date` and `Connection: keep-alive` and picks its own
reason phrases, accepts chunked request bodies, and listens with a backlog of 512 (the DIY server's is 4,096); its header lists them. The default socket read timeout of a
coroutine server is 60 s and closes idle connections: `Coroutine::set(['socket_read_timeout' => -1])` is what keeps them (a `read_timeout` in the server's own `set()`
is ignored; the first 3,000-idle run was INVALID for that reason: the server closed its 3,000 idle connections after 60 s).

## ext-mrloop: a read of its code

Phase 8 asks whether an io_uring loop that already exists could cost fewer microseconds per request than the submission's `ext-event` loop
(about 59 µs on the AWS bench) or than our own ring (`lab/servers/uring-noop.php`). `ext-mrloop` is the PHP extension that wraps an
io_uring event loop. This is the audit that decides whether it gets a screen (a quick measurement) or not.

Nothing was built or run: the code was read in a scratch folder and never committed, and the extension was not built into a lab image. Every
answer is a file and a line. A claim that comes from reading the code and not from running it says so.

### What was read

| Repository | Commit | Date of the commit | Licence |
|---|---|---|---|
| `ringPHP/php-mrloop` (the PHP extension) | `d15cd3d17e8022152e43935428bab9a64c0d3a95` | 2024-12-26 | MIT (`LICENSE`) |
| `markreedz/mrloop` (the C library the extension wraps) | `0a8c72ad13dafc5165516cdf3bf9897ca6ae5c1e` | 2024-04-13 | MIT (`LICENSE`) |

Read on 2026-11-26, from the head of each default branch. The extension does not link the library, it includes its source: `src/loop.h:10` is
`#include "mrloop.c"`, so the library's file is compiled into the extension (`config.m4:41` wants the library's folder, `config.m4:48` puts it on
the include path). In what follows `loop.c` and `loop.h` are the extension's `src/` files, and `mrloop.c` and `mrloop.h` the library's.

Open issues, from the repositories' public pages: `php-mrloop` has 1 (a request for a ReactPHP adapter), `mrloop` has 0. The extension's last
change to its code is 2024-12-25 (`bf3ac27`, "modify extension internals"); neither repository has had a commit since.

### The questions

#### Direct descriptors, or one descriptor per connection?

One descriptor per connection, and a table of 1,024 slots that the descriptor number indexes.

- A connection is accepted with the `accept()` system call, not with an io_uring operation: `mrloop.c:146`. Then two `fcntl` calls (`mrloop.c:153`).
- No registered files, no direct descriptors, no fixed buffers for sockets: the library's `io_uring_prep_*` calls are `poll_add`, `readv`, `writev`
  and `write_fixed` (`mrloop.c:84, 99, 113, 123, 134, 446, 456, 472, 488, 499`), and no line of either file mentions `register`, `multishot`,
  `SQPOLL`, `FILE_INDEX` or a provided buffer ring (searched in `mrloop.c` and `mrloop.h`: 0 matches).
- The loop keeps the events of a connection in two arrays indexed **by the descriptor number**: `read_events[MAX_CONN]` and
  `read_data_events[MAX_CONN]` (`mrloop.h:60-61`, filled at `mrloop.c:51-56`, used at `mrloop.c:131` and `167-168`), with `MAX_CONN` at 1,024
  (`mrloop.h:34`). Nothing checks the descriptor against the size. From the code (not run): a connection that gets a descriptor of 1,024 or
  more (about the 1,010th of a process, after the standard streams and the loop's own descriptors) writes past the end of the array. The extension's own default is the same 1,024 (`loop.h:33`) and the
  `max_conn` argument of `tcpServer()` does nothing: its call into the library takes no such argument (`loop.c:364-368`: `MRLOOP_H` is never
  defined, so the four-argument branch is the one compiled; the README says as much for libraries without the parameter).

So one process cannot hold 65,535 connections, or 5,000: the structure stops at about 1,000.

#### Multishot accept and receive?

No. Accept is a `poll_add` on the listening socket (`mrloop.c:379` arms it), then, when it fires, a plain `accept()` (`mrloop.c:146`), then the
poll is armed again (`mrloop.c:186`): one submission and one completion per connection, plus the system call. Receive is a `poll_add`
(`_urpoll`, `mrloop.c:81-88`), then, when it fires, a `readv` (`_read`, `mrloop.c:129-139`), then a poll again (`mrloop.c:287`): two submissions
and two completions per received buffer.

#### One `io_uring_enter` per turn, or per operation?

Per operation. Every helper that adds a submission entry submits it on the spot: `_urpoll` (`mrloop.c:86`), `_read` (`mrloop.c:137`),
`mr_flush` (`mrloop.c:439`, called by the extension after each write: `loop.c:323, 479, 530, 581`), `mr_writevf` (`mrloop.c:458`). The loop
waits for one completion at a time (`io_uring_wait_cqe`, `mrloop.c:241, 244`) and releases it with `io_uring_cqe_seen` (`mrloop.c:313`). The ring is
created with 128 entries and no flags (`mrloop.c:36`): no `SINGLE_ISSUER`, no `DEFER_TASKRUN`, no batching of a turn.

From the code (not run), what one request on a connection that was just accepted costs in system calls: `accept`, 2 `fcntl`, `getpeername`
(`loop.c:270`), 2 submissions to arm the new connection's poll and the listener's (`mrloop.c:176, 186`), 1 to submit the `readv`, 1 to submit the
`writev` (`loop.c:322-323`), a `dup` (`loop.c:303`) and a `close` (`mrloop.c:435`), and the `io_uring_enter` calls that wait for the completions in
between: nine or more calls a request, against 0.63 `io_uring_enter` and no `recvfrom`, `sendto` or `accept4` for Swoole's coroutine server on its
io_uring sockets (`lab/servers/swoole-co.php`, counted by `lab/syscalls.sh`).

#### Who parses HTTP, and how does a PHP callback get a request and return a response?

Nobody parses HTTP. `tcpServer()` hands the bytes of one `readv` to the PHP callback as a string, with an array of the client's address, port
and descriptor, and writes back the string the callback returns (`loop.c:282-324`):

- the string is made with `ZVAL_STRING` from the buffer (`loop.c:298`), so it stops at the first NUL byte, and the buffer is 8,132 bytes
  (`loop.h:26`, `loop.c:264`): a request is whatever one read brought, cut at 8,132 bytes;
- the callback returns the **whole** response as a string (status line, headers, body), which is written with one `writev` (`loop.c:317-324`);
- there is no picohttpparser: `loop.h:45` still declares `typedef struct phr_header phr_header_t` and `loop.h:27` a header limit of 100, and
  nothing uses either. The commit that removed the HTTP code is `bf3ac27` ("remove parseHttpRequest() and parseHttpResponse() functions").

So an HTTP server on it would parse requests in PHP, as the DIY server does today, and would not save the parser's cost.

#### Partial reads and writes, pipelining, keep-alive

- **Partial read:** a request split over two reads reaches the callback as two calls, with no buffering between them (`loop.c:282-329` keeps no
  state per connection but the buffer). A request longer than 8,132 bytes is cut.
- **Pipelining:** two requests in one read reach the callback as one string.
- **Partial write:** the result of the `writev` is dropped. Its submission carries `user_data = 0` (`mr_writev`, `mrloop.c:447`) and the loop
  skips a completion with no event (`mrloop.c:255-258`), so a short write loses the rest of the response without a trace. The `iovec` points at
  the callback's returned string (`loop.c:319-322`), which the extension frees right after the submission (`loop.c:326`): if the kernel does not
  finish the write inside the submit call, it reads freed memory. From the code, not run.
- **Keep-alive: none.** The receive callback returns 1 (`loop.c:328`), and the loop closes the connection when the callback returns non-zero
  (`mrloop.c:282-283`). Every connection serves one request. The descriptor handed to the PHP callback is a `dup()` that nothing closes
  (`loop.c:303`), so the socket stays open in the kernel with nobody reading it: a second request on it would never be answered. The challenge's
  load keeps connections open, and the lab's idle connections would each get one `/health` and then none.

#### How memory is freed

Not on the request path (all from the code, not run):

- the two arguments of each callback call, the string and the array, are never destroyed: only the result is (`loop.c:298-303` build `args`,
  `loop.c:326` frees `result`), so each request leaks a string and an array;
- the connection record, its address string and its 8,132-byte buffer are freed only when a read returns 0 bytes (`loop.c:287-295`), but the
  callback's `return 1` closes the connection first (`mrloop.c:282-283`), so each connection leaks all three; the address string is also
  `emalloc`ed and left uninitialised when `getpeername` fails (`loop.c:262-278`);
- `mr_close` is `close(fd)` and a comment (`mrloop.c:433-436`): events still in flight for that descriptor are not cancelled, and the array
  slots are reused by the next connection that gets the number.

The extension's pull request #7, closed, is titled "Fix buffer overflows in `addWriteStream`, `parseHttpRequest`, and `parseHttpResponse`".

#### Tests

`tests/` holds 9 `.phpt` files, 251 lines in all: `init()`, `addReadStream()`, `addWriteStream()`, `addSignal()`, `addTimer()`,
`addPeriodicTimer()`, `writev()` on the standard output, `writev()` on a bad descriptor, `futureTick()`. None calls `tcpServer()`: no test
accepts a connection, reads a request, answers it or closes a socket. The library has no tests (`mrloop` holds `examples/` and a `todo` file whose first
line is "Add tests").

#### Does it build against PHP 8.5?

Not shown. `config.m4:18` refuses PHP under 8.1 and has no upper limit, so `./configure` accepts 8.5. The CI matrix is PHP 8.1 to 8.4
(`.github/workflows/ci.yml:12`), runs only on pushes to the `develop` branch (`ci.yml:3-5`), builds a thread-safe PHP (`ci.yml:20-22`), and
clones the heads of `mrloop` and `liburing` without a pin (`ci.yml:25-26`). `config.m4:48` replaces `CFLAGS` as a whole (`-g -O3 -luring -I...`)
and `config.m4:24-33` looks for `liburing.so` only under `/usr/local/lib` and `/usr/lib` (the lab's liburing is in `/usr/local/lib`). The 8.5.13 headers of the lab's image still define `empty_fcall_info`, which `loop.c` uses (`Zend/zend_API.h`, lines 733 to 736); nothing else
was checked, and whether the C compiles on 8.5 was not tried: the audit was to read, not to build.

### Reading the answers against the two things the lever must beat

The lever is worth a screen only if it could beat both phase 7's server and our own ring on the two counts that matter: one process past 65,535
connections, and fewer system calls a request.

- **Past 65,535 connections in one process:** no. The loop's tables hold 1,024 descriptors (`mrloop.h:34, 60-61`) and are indexed without a
  check. Our own ring holds 60,000 on one ring with 10 descriptors in the process (`lab/servers/uring-noop.php`, header).
- **Fewer system calls a request:** no. It accepts with `accept()`, submits every operation on its own, arms a poll before every read, and
  closes after every request, which is more calls than the `ext-event` loop's `accept4`, `recvfrom`, `sendto` a request, not fewer.
- **A server a challenge could run:** no keep-alive, no HTTP parsing, no partial-write handling, and a leak of a descriptor and a few
  allocations a request: it could not pass the challenge's own test suite on a kept-alive connection, and would stop on its own at the
  process's descriptor limit.

## Verdicts

verdict swoole uring_socket: no screen. It is on io_uring (0.63 `io_uring_enter` a request, no `recvfrom`, `sendto` or `accept4`) and 64,000 connections fit in 1.3 GiB once the VM's huge pages are off, but in the smoke it costs more per request than the reference at every idle count run (43.6 against 33.8 µs at 3,000, 53 at 20,000, 221.7 and 4,449 req/s of 7,500 at 60,000: one pair each, on the Mac), and one process still stops at 65,535 descriptors.

verdict ext-mrloop: no screen. Its server mode closes every connection after one request and indexes its state by descriptor in a 1,024-slot table, so it can neither keep 60,000 connections nor serve a kept-alive client, and it spends more system calls per request than the loop it would replace.
