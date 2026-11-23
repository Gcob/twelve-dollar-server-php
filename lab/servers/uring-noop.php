<?php
// A spike: an HTTP server whose event loop is an io_uring ring driven through PHP's FFI (no C is compiled). It answers
// GET /noop like the DIY server does (lab/servers/diy-connection.php, same bytes) and, so a stress test can pair each answer with
// its request, echoes `id=<digits>` of `GET /noop?id=<digits>` as `{"status":"ok","id":<digits>}`. Every other route goes to
// handler.php, like the DIY server, so lab/conformance.sh runs on it. The challenge's app is not on the ring.
//
// What the ring does, and the memory-ordering design that makes plain FFI reads and writes safe:
// - No SQPOLL. IORING_SETUP_SINGLE_ISSUER and IORING_SETUP_DEFER_TASKRUN: the kernel posts completions and takes submissions only
//   inside our own io_uring_enter, on our thread. So the heads and tails are read and written only around that call, and a plain
//   store to the submission tail needs no barrier of its own (the syscall entry orders it). IORING_SETUP_SUBMIT_ALL.
//   IORING_SETUP_NO_SQARRAY (kernel 6.6+): the slot of an SQE is its index in the ring, no index array to keep.
// - One io_uring_enter per turn of the loop: it submits what the turn built and waits for at least one completion (with a timeout,
//   so the loop can print its statistics and, with two rings, look at the other ring). A full submission queue forces one more
//   submit-only enter in the middle of a turn: counted as `flushes`.
// - Connections are direct descriptors: multishot accept into a sparse table of fixed files (IORING_FILE_INDEX_ALLOC), as large as
//   RLIMIT_NOFILE allows (the kernel refuses a bigger one with EMFILE), so a connection takes no file descriptor of the process.
//   Receive is multishot from a provided buffer ring (a pool shared by all connections, nothing held per idle connection), send is
//   one SEND of the response copied into a pooled slot, and a server-side close is a shutdown linked to the close of the descriptor
//   (the multishot receive keeps the socket alive until the shutdown ends it).
// - SQEs are written in place in the ring's mapped memory, field by field, which a first micro bench priced at about half of
//   pack() + FFI::memcpy. CQEs are read once per turn: one FFI::string of all of them and one unpack().
//
// The settings are the lab's: SQ 4096 entries, CQ 32768, 4096 receive buffers of 2048 bytes (8 MiB), 2048 send slots of 8 KiB (16 MiB).
//
// Where the spike got (smoke runs on an aarch64 Docker VM with 6.12 kernel and PHP 8.5, one CPU for the server, quiet VM): every step of
// the spike's plan was reached. conformance: 8 of 8 cases. stress: 2,000,000 requests with unique ids over 1,000 connections, one at a
// time and pipelined, 0 mismatches, 0 lost. connections: 60,000 held and answered on one ring with 10 file descriptors in the process,
// and 80,000 over two rings (11 descriptors). CPU per request at 7,000 req/s on /noop: about the DIY server's (20.1 against 19.5
// microseconds the same evening) because a turn handles one request at that rate, so the ring pays one io_uring_enter per request
// and the kernel's TCP work, which both servers pay, dominates. At 24,000 req/s: 10.5 against the DIY server's 11.3, and 9.1 with
// URING_MIN_COMPLETE=8 URING_MIN_WAIT_US=100, which makes a turn handle 6 requests.
//
// Docker's default seccomp filter refuses io_uring (EPERM): lab/macro.sh, lab/conformance.sh, lab/conns.sh and lab/stress.sh take
// --seccomp-unconfined for this server, and no other server uses it.
//
// URING_RINGS=2 (default 1) adds a second ring with its own table, for more connections than one table holds (the kernel limits a table
// to RLIMIT_NOFILE, and the lab's limit is 65,535). Both rings accept from the same listening socket; the loop waits on the first ring
// with a timeout of URING_WAIT_US microseconds (default 500) and enters the second when its IORING_SQ_TASKRUN flag shows work
// (IORING_SETUP_TASKRUN_FLAG): without the flag and the timeout the second ring could stall, because its deferred work runs only in
// an io_uring_enter of its own.
//
// URING_MIN_COMPLETE (default 1) and URING_MIN_WAIT_US (default 0, off): a turn waits for that many completions, or returns after that many
// microseconds with the ones that came when at least one did. They make a turn batch requests under load, at the price of a latency
// of up to the wait; off, a turn handles whatever one completion brought, which at a low rate is one request.
//
// Port: PORT (default 8080). FFI is built into the lab's images and needs no extension; the lab scripts load `sockets event` for
// the DIY server and `swoole` by default, so run this one with `--ext sockets` (loaded, never used) to keep the PHP the same.

require __DIR__ . '/handler.php';

if (!extension_loaded('FFI')) {
    fwrite(STDERR, "uring-noop: FFI is not loaded\n");
    exit(1);
}
if (!in_array(php_uname('m'), ['x86_64', 'aarch64'], true)) {
    // The io_uring syscalls are 425 to 427 on both; the sockets' constants below are the same on both.
    fwrite(STDERR, 'uring-noop: only x86_64 and aarch64 are known, this is ' . php_uname('m') . "\n");
    exit(1);
}

final class UringRing
{
    // io_uring_setup flags.
    private const SETUP_CQSIZE = 1 << 3;
    private const SETUP_SUBMIT_ALL = 1 << 7;
    private const SETUP_TASKRUN_FLAG = 1 << 9;
    private const SETUP_SINGLE_ISSUER = 1 << 12;
    private const SETUP_DEFER_TASKRUN = 1 << 13;
    private const SETUP_NO_SQARRAY = 1 << 16;
    private const SQ_TASKRUN = 1 << 2;
    private const ENTER_GETEVENTS = 1;
    private const ENTER_EXT_ARG = 1 << 3;
    private const REGISTER_FILES2 = 13;
    private const REGISTER_PBUF_RING = 22;
    private const RSRC_REGISTER_SPARSE = 1;
    private const OFF_SQES = 0x10000000;
    private const SYS_SETUP = 425;
    private const SYS_ENTER = 426;
    private const SYS_REGISTER = 427;

    // Opcodes and SQE flags.
    private const OP_ACCEPT = 13;
    private const OP_ASYNC_CANCEL = 14;
    private const OP_CLOSE = 19;
    private const OP_SEND = 26;
    private const OP_RECV = 27;
    private const OP_SHUTDOWN = 34;
    private const SQE_FIXED_FILE = 1;
    private const SQE_IO_LINK = 4;
    private const SQE_BUFFER_SELECT = 32;
    private const ACCEPT_MULTISHOT = 1;
    private const RECV_MULTISHOT = 2;
    private const FILE_INDEX_ALLOC = 0xFFFFFFFF;
    private const CQE_F_BUFFER = 1;
    private const CQE_F_MORE = 2;
    private const MSG_NOSIGNAL = 0x4000;
    private const O_NONBLOCK = 0x800;
    private const SHUT_RDWR = 2;
    private const ENOBUFS = 105;
    private const ECANCELED = 125;
    /** Descriptors of the table kept free: the accept stops before the table is full (see onAccept). */
    private const TABLE_MARGIN = 16;
    private const EINTR = 4;
    private const EAGAIN = 11;
    private const EBUSY = 16;
    private const ETIME = 62;

    // What a user_data holds: the kind of operation in bits 0 to 2, the direct descriptor in bits 3 to 18, its generation (how many
    // times it was closed, to ignore the late completions of a closed connection) in bits 19 to 26, a send slot from bit 27.
    private const T_ACCEPT = 0;
    private const T_RECV = 1;
    private const T_SEND = 2;
    private const T_CLOSE = 3;
    private const T_SHUTDOWN = 4;
    private const T_CANCEL = 5;

    private const SQ_ENTRIES = 4096;
    private const CQ_ENTRIES = 32768;
    private const BUF_COUNT = 4096;
    private const BUF_SIZE = 2048;
    private const SLOT_COUNT = 2048;
    private const SLOT_SIZE = 8192;
    private const MAX_TABLE = 65535;
    private const HEADER_LIMIT = 8192;
    private const BODY_LIMIT = 1048576;

    private const HEAD = [
        200 => "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ",
        400 => "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: ",
        404 => "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: ",
        500 => "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: ",
    ];
    private const NOOP = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 15\r\n\r\n{\"status\":\"ok\"}";
    private const BAD_REQUEST = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 23\r\n\r\n{\"error\":\"bad request\"}";
    private const INTERNAL_ERROR = '{"error":"internal server error"}';

    // What the loop counted since the process started (the main script prints their differences each second).
    public int $turns = 0;
    public int $flushes = 0;
    public int $cqes = 0;
    public int $requests = 0;
    public int $accepted = 0;
    public int $acceptPauses = 0;
    public int $open = 0;

    public readonly int $tableSize;
    public readonly int $ringFd;
    private readonly FFI\CData $params;
    private readonly FFI\CData $sqHeadP;
    private readonly FFI\CData $sqTailP;
    private readonly FFI\CData $sqFlagsP;
    private readonly FFI\CData $cqHeadP;
    private readonly FFI\CData $cqTailP;
    private readonly FFI\CData $cqes0;
    private readonly FFI\CData $sqes;
    private readonly FFI\CData $bufRing;
    private readonly FFI\CData $bufTailP;
    private readonly FFI\CData $bufBase;
    private readonly FFI\CData $arg;
    private readonly FFI\CData $ts;
    private readonly int $argAddr;
    private readonly FFI\CData $errnoP;
    private readonly int $sqMask;
    private readonly int $cqEntries;
    private readonly int $bufAddr;
    private readonly int $listenFd;
    private readonly int $acceptLimit;
    /** @var list<FFI\CData> */
    private array $slotPtr = [];
    /** @var list<int> */
    private array $slotAddr = [];

    private int $sqTail = 0;
    private int $sqHeadSeen = 0;
    private int $cqHead = 0;
    private int $bufTail = 0;
    /** @var list<int> free send slots, a stack */
    private array $freeSlots = [];
    private int $freeCount = 0;
    /** @var list<int> connections waiting for a send slot */
    private array $waitQ = [];
    /** @var array<int, int> direct descriptor => generation */
    private array $gens;
    /** @var array<int, string> a request that is not whole yet, by descriptor */
    private array $partial = [];
    /** @var array<int, string> the bytes of the send in flight, by descriptor */
    private array $inflight = [];
    /** @var array<int, string> bytes to send once the one in flight is done (or a slot is free) */
    private array $pend = [];
    /** @var array<int, true> connections to close once their last send is done */
    private array $closing = [];
    private bool $acceptPaused = false;
    private bool $pauseReported = false;

    // What parseHead() found in the request it just read.
    private string $method = '';
    private string $target = '';
    private int $bodyLength = 0;
    private bool $closeAfter = false;

    /**
     * @param FFI $ffi the declarations of uring-noop.h
     * @param FFI $ffiAddr an FFI whose mmap() returns the address as an integer (see map())
     * @param int $minComplete completions a turn waits for; with $minWaitUs above 0 the kernel returns after that many microseconds
     *                         when at least one is there (IORING_ENTER_EXT_ARG's min_wait_usec, kernel 6.12+), so a turn batches under load
     */
    public function __construct(private readonly FFI $ffi, private readonly FFI $ffiAddr, int $listenFd, private readonly string $name,
        private readonly int $minComplete = 1, private readonly int $minWaitUs = 0)
    {
        $this->listenFd = $listenFd;
        $this->errnoP = $ffi->__errno_location();
        $rl = $ffi->new('rlimit_t');
        if ($ffi->getrlimit(7, FFI::addr($rl)) !== 0) {
            throw new RuntimeException('getrlimit(RLIMIT_NOFILE) failed');
        }
        $this->tableSize = min($rl->cur, self::MAX_TABLE);
        $this->gens = array_fill(0, $this->tableSize, 0);
        $this->acceptLimit = $this->tableSize - self::TABLE_MARGIN;

        $params = $ffi->new('params_t');
        $params->flags = self::SETUP_CQSIZE | self::SETUP_SUBMIT_ALL | self::SETUP_TASKRUN_FLAG | self::SETUP_SINGLE_ISSUER
            | self::SETUP_DEFER_TASKRUN | self::SETUP_NO_SQARRAY;
        $params->cq_entries = self::CQ_ENTRIES;
        $this->params = $params;
        $fd = $ffi->syscall(self::SYS_SETUP, self::SQ_ENTRIES, FFI::addr($params));
        if ($fd < 0) {
            throw new RuntimeException("[$name] io_uring_setup failed, errno " . $this->errno() . ' (1 is the seccomp filter: run the container with --seccomp-unconfined)');
        }
        $this->ringFd = $fd;
        if (!($params->features & 1)) {
            throw new RuntimeException("[$name] the kernel does not map both rings at once (IORING_FEAT_SINGLE_MMAP)");
        }

        // The submission and completion rings are one mapping.
        $ringBytes = max($params->sq_off->array + $params->sq_entries * 4, $params->cq_off->cqes + $params->cq_entries * 16);
        $ring = $this->map($ringBytes, 0x01 | 0x8000, $fd, 0);
        $this->sqHeadP = $ffi->cast('uint32_t*', $ring + $params->sq_off->head);
        $this->sqTailP = $ffi->cast('uint32_t*', $ring + $params->sq_off->tail);
        $this->sqFlagsP = $ffi->cast('uint32_t*', $ring + $params->sq_off->flags);
        $this->sqMask = $params->sq_entries - 1;
        $this->cqHeadP = $ffi->cast('uint32_t*', $ring + $params->cq_off->head);
        $this->cqTailP = $ffi->cast('uint32_t*', $ring + $params->cq_off->tail);
        $this->cqes0 = $ffi->cast('uint8_t*', $ring + $params->cq_off->cqes);
        $this->cqEntries = $params->cq_entries;
        $this->sqes = $ffi->cast('sqe_t*', $this->map($params->sq_entries * 64, 0x01 | 0x8000, $fd, self::OFF_SQES));

        // The table of direct descriptors.
        $register = $ffi->new('rsrc_register_t');
        $register->nr = $this->tableSize;
        $register->flags = self::RSRC_REGISTER_SPARSE;
        if ($ffi->syscall(self::SYS_REGISTER, $fd, self::REGISTER_FILES2, FFI::addr($register), FFI::sizeof($register)) < 0) {
            throw new RuntimeException("[$name] registering a sparse table of {$this->tableSize} files failed, errno " . $this->errno());
        }

        // The receive buffers and their ring.
        $bufAddr = $this->map(self::BUF_COUNT * self::BUF_SIZE, 0x02 | 0x20, -1, 0);
        $this->bufAddr = $bufAddr;
        // Why a local: FFI::cast() takes its second argument by reference, which a readonly property refuses.
        $this->bufBase = $ffi->cast('uint8_t*', $bufAddr);
        $bufRingMem = $this->map(self::BUF_COUNT * 16, 0x02 | 0x20, -1, 0);
        $this->bufRing = $ffi->cast('buf_t*', $bufRingMem);
        // The ring's tail is the last two bytes of its first entry.
        $this->bufTailP = $ffi->cast('uint16_t*', $bufRingMem + 14);
        $reg = $ffi->new('buf_reg_t');
        $reg->ring_addr = $bufRingMem;
        $reg->ring_entries = self::BUF_COUNT;
        $reg->bgid = 0;
        if ($ffi->syscall(self::SYS_REGISTER, $fd, self::REGISTER_PBUF_RING, FFI::addr($reg), 1) < 0) {
            throw new RuntimeException("[$name] registering the buffer ring failed, errno " . $this->errno());
        }
        for ($bid = 0; $bid < self::BUF_COUNT; $bid++) {
            $this->putBuffer($bid);
        }

        // The send slots.
        $slots = $this->map(self::SLOT_COUNT * self::SLOT_SIZE, 0x02 | 0x20, -1, 0);
        for ($s = 0; $s < self::SLOT_COUNT; $s++) {
            $this->slotAddr[$s] = $slots + $s * self::SLOT_SIZE;
            $this->slotPtr[$s] = $ffi->cast('uint8_t*', $this->slotAddr[$s]);
            $this->freeSlots[$s] = $s;
        }
        $this->freeCount = self::SLOT_COUNT;

        // The wait with a timeout: the extended argument of io_uring_enter and the timespec it points to, in a page of their own.
        $misc = $this->map(4096, 0x02 | 0x20, -1, 0);
        $this->arg = $ffi->cast('getevents_arg_t*', $misc);
        $this->argAddr = $misc;
        $this->ts = $ffi->cast('timespec_t*', $misc + 64);
        $this->arg->ts = $misc + 64;
        $this->arg->min_wait_usec = $minWaitUs;
    }

    private function errno(): int
    {
        return $this->errnoP[0];
    }

    /**
     * An anonymous or ring mapping, as an integer address; fails loudly (MAP_FAILED is -1).
     * Why an integer: FFI::cast('uintptr_t', $pointer) reads 0 for a pointer mmap() returned, and arithmetic on one pointer cast to
     * several types changes the earlier ones, so every pointer here is made with cast('<type>*', <integer address>).
     */
    private function map(int $bytes, int $flags, int $fd, int $offset): int
    {
        $address = $this->ffiAddr->mmap(null, $bytes, 3, $flags, $fd, $offset);
        if ($address === -1) {
            throw new RuntimeException("[{$this->name}] mmap of $bytes bytes failed, errno " . $this->errno());
        }
        return $address;
    }

    /** Memory of the process that this ring holds: the buffers, the slots and the rings' queues, in bytes (for the boot line). */
    public static function pooledBytes(): int
    {
        return self::BUF_COUNT * self::BUF_SIZE + self::SLOT_COUNT * self::SLOT_SIZE;
    }

    public static function describe(): string
    {
        return 'sq=' . self::SQ_ENTRIES . ' cq=' . self::CQ_ENTRIES . ' recv_buffers=' . self::BUF_COUNT . 'x' . self::BUF_SIZE
            . ' send_slots=' . self::SLOT_COUNT . 'x' . self::SLOT_SIZE;
    }

    /** Hands a receive buffer back to the kernel: its entry at the ring's tail (published once per turn). */
    private function putBuffer(int $bid): void
    {
        $b = $this->bufRing[$this->bufTail & (self::BUF_COUNT - 1)];
        $b->addr = $this->bufAddr + $bid * self::BUF_SIZE;
        $b->len = self::BUF_SIZE;
        $b->bid = $bid;
        $this->bufTail++;
    }

    /** True when the kernel has work waiting for an io_uring_enter of ours (read from the submission queue's flags). */
    public function hasWork(): bool
    {
        return ($this->sqFlagsP[0] & self::SQ_TASKRUN) !== 0;
    }

    /** True when SQEs were queued and no enter has submitted them yet. */
    public function hasQueued(): bool
    {
        return $this->sqTail !== $this->sqHeadSeen;
    }

    /** Submits what is queued. With $wait it also waits for completions (see the constructor) for at most $timeoutNs. */
    private function enter(bool $wait, int $timeoutNs): void
    {
        $this->sqTailP[0] = $this->sqTail;
        $this->bufTailP[0] = $this->bufTail;
        $toSubmit = ($this->sqTail - $this->sqHeadSeen) & 0xFFFFFFFF;
        if ($wait) {
            $this->ts->tv_sec = intdiv($timeoutNs, 1000000000);
            $this->ts->tv_nsec = $timeoutNs % 1000000000;
            $r = $this->ffi->syscall(self::SYS_ENTER, $this->ringFd, $toSubmit, $this->minComplete,
                self::ENTER_GETEVENTS | self::ENTER_EXT_ARG, $this->argAddr, 24);
        } else {
            $r = $this->ffi->syscall(self::SYS_ENTER, $this->ringFd, $toSubmit, 0, self::ENTER_GETEVENTS, 0, 0);
        }
        if ($r < 0) {
            $errno = $this->errno();
            if ($errno !== self::EINTR && $errno !== self::ETIME && $errno !== self::EBUSY && $errno !== self::EAGAIN) {
                throw new RuntimeException("[{$this->name}] io_uring_enter failed, errno $errno");
            }
        }
        $this->sqHeadSeen = $this->sqHeadP[0];
    }

    /** The submission queue is full: submit now, without waiting. */
    private function flush(): void
    {
        $this->flushes++;
        $this->sqTailP[0] = $this->sqTail;
        $this->bufTailP[0] = $this->bufTail;
        $this->ffi->syscall(self::SYS_ENTER, $this->ringFd, ($this->sqTail - $this->sqHeadSeen) & 0xFFFFFFFF, 0, 0, 0, 0);
        $this->sqHeadSeen = $this->sqHeadP[0];
        if ($this->sqTail - $this->sqHeadSeen >= self::SQ_ENTRIES) {
            throw new RuntimeException("[{$this->name}] the submission queue did not drain");
        }
    }

    /** The next free submission slot, its 14 fields to be written by the caller (all of them: the slot may hold an older SQE). */
    private function sqe(): FFI\CData
    {
        if ($this->sqTail - $this->sqHeadSeen >= self::SQ_ENTRIES) {
            $this->flush();
        }
        return $this->sqes[$this->sqTail++ & $this->sqMask];
    }

    private function prep(int $opcode, int $flags, int $ioprio, int $fd, int $off, int $addr, int $len, int $opFlags, int $userData, int $bufIndex, int $fileIndex): void
    {
        $s = $this->sqe();
        $s->opcode = $opcode;
        $s->flags = $flags;
        $s->ioprio = $ioprio;
        $s->fd = $fd;
        $s->off = $off;
        $s->addr = $addr;
        $s->len = $len;
        $s->op_flags = $opFlags;
        $s->user_data = $userData;
        $s->buf_index = $bufIndex;
        $s->file_index = $fileIndex;
    }

    public function armAccept(): void
    {
        // personality, addr3 and pad2 are never written: they stay zero.
        $this->prep(self::OP_ACCEPT, 0, self::ACCEPT_MULTISHOT, $this->listenFd, 0, 0, 0, self::O_NONBLOCK, self::T_ACCEPT, 0, self::FILE_INDEX_ALLOC);
    }

    private function armRecv(int $idx): void
    {
        $this->prep(self::OP_RECV, self::SQE_FIXED_FILE | self::SQE_BUFFER_SELECT, self::RECV_MULTISHOT, $idx, 0, 0, 0, 0,
            self::T_RECV | $idx << 3 | $this->gens[$idx] << 19, 0, 0);
    }

    /** Ends a connection: the generation moves on, its state goes, and the descriptor closes (after a shutdown when we end it). */
    private function closeConn(int $idx, bool $shutdown): void
    {
        $gen = ($this->gens[$idx] + 1) & 0xFF;
        $this->gens[$idx] = $gen;
        unset($this->partial[$idx], $this->inflight[$idx], $this->pend[$idx], $this->closing[$idx]);
        $this->open--;
        if ($this->acceptPaused && $this->open < $this->acceptLimit - self::TABLE_MARGIN) {
            $this->acceptPaused = false;
            $this->armAccept();
        }
        if ($shutdown) {
            $this->prep(self::OP_SHUTDOWN, self::SQE_FIXED_FILE | self::SQE_IO_LINK, 0, $idx, 0, 0, self::SHUT_RDWR, 0,
                self::T_SHUTDOWN | $idx << 3 | $gen << 19, 0, 0);
        }
        $this->prep(self::OP_CLOSE, 0, 0, 0, 0, 0, 0, 0, self::T_CLOSE | $idx << 3 | $gen << 19, 0, $idx + 1);
    }

    /** One turn: submit, wait for a completion (at most $timeoutNs), handle every completion that is there. False: nothing came. */
    public function turn(int $timeoutNs): bool
    {
        $this->enter($timeoutNs > 0, $timeoutNs);
        $this->turns++;
        $tail = $this->cqTailP[0];
        $n = ($tail - $this->cqHead) & 0xFFFFFFFF;
        if ($n === 0) {
            return false;
        }
        $start = $this->cqHead & ($this->cqEntries - 1);
        $first = min($n, $this->cqEntries - $start);
        $raw = FFI::string($this->cqes0 + $start * 16, $first * 16);
        if ($first < $n) {
            $raw .= FFI::string($this->cqes0, ($n - $first) * 16);
        }
        $this->cqHead += $n;
        $this->cqHeadP[0] = $this->cqHead;
        $this->cqes += $n;
        // A CQE is two 64-bit words: user_data, then res (low 32 bits, signed) and flags (high 32 bits).
        $words = unpack('P*', $raw);
        $limit = 2 * $n;
        for ($i = 1; $i <= $limit; $i += 2) {
            $ud = $words[$i];
            $x = $words[$i + 1];
            $res = $x & 0xFFFFFFFF;
            if ($res >= 0x80000000) {
                $res -= 0x100000000;
            }
            $flags = ($x >> 32) & 0xFFFFFFFF;
            $kind = $ud & 7;
            if ($kind === self::T_RECV) {
                $this->onRecv($ud, $res, $flags);
            } elseif ($kind === self::T_SEND) {
                $this->onSend($ud, $res);
            } elseif ($kind === self::T_ACCEPT) {
                $this->onAccept($res, $flags);
            }
        }
        return true;
    }

    private function onAccept(int $res, int $flags): void
    {
        if ($res >= 0) {
            $this->accepted++;
            $this->open++;
            $this->armRecv($res);
            // Why a limit below the table's size: an accept that finds the table full has already taken the connection off the listening
            // queue, and the kernel drops it (the client sees the connection closed). So the accept is cancelled while there is still room,
            // the clients wait in the backlog (or another ring takes them) and it is armed again once connections have closed.
            if ($this->open >= $this->acceptLimit && !$this->acceptPaused) {
                $this->acceptPaused = true;
                $this->acceptPauses++;
                $this->prep(self::OP_ASYNC_CANCEL, 0, 0, 0, 0, self::T_ACCEPT, 0, 0, self::T_CANCEL, 0, 0);
                return;
            }
        } elseif ($res === -self::ECANCELED) {
            return; // the accept this ring cancelled itself
        } else {
            // The accept failed: stop accepting until a connection closes.
            $this->acceptPaused = true;
            $this->acceptPauses++;
            if (!$this->pauseReported) {
                $this->pauseReported = true;
                fwrite(STDERR, "uring-noop[{$this->name}]: accept failed with " . -$res . " at {$this->open} connections: " .
                    "accepting again when one closes, clients wait in the backlog meanwhile\n");
            }
            return;
        }
        if (!($flags & self::CQE_F_MORE) && !$this->acceptPaused) {
            $this->armAccept();
        }
    }

    private function onRecv(int $ud, int $res, int $flags): void
    {
        $data = '';
        if ($flags & self::CQE_F_BUFFER) {
            $bid = $flags >> 16;
            if ($res > 0) {
                $data = FFI::string($this->bufBase + $bid * self::BUF_SIZE, $res);
            }
            $this->putBuffer($bid);
        }
        $idx = ($ud >> 3) & 0xFFFF;
        if ((($ud >> 19) & 0xFF) !== $this->gens[$idx]) {
            return;
        }
        if ($res > 0) {
            if (isset($this->closing[$idx])) {
                return; // what comes after a request that ends the connection is not answered
            }
            if (isset($this->partial[$idx])) {
                $data = $this->partial[$idx] . $data;
                unset($this->partial[$idx]);
            }
            $out = $this->parse($idx, $data);
            if ($out !== '') {
                $this->send($idx, $out);
            }
            if (!($flags & self::CQE_F_MORE) && !isset($this->closing[$idx])) {
                $this->armRecv($idx);
            }
        } elseif ($res === -self::ENOBUFS) {
            // The buffers ran out for a moment: the receive ended, and the buffers are back by now.
            $this->armRecv($idx);
        } else {
            // 0 is the client leaving, below 0 a reset or another error: either way the receive has ended.
            $this->closeConn($idx, false);
        }
    }

    private function onSend(int $ud, int $res): void
    {
        $slot = $ud >> 27;
        $this->freeSlots[$this->freeCount++] = $slot;
        $idx = ($ud >> 3) & 0xFFFF;
        if ((($ud >> 19) & 0xFF) === $this->gens[$idx]) {
            $sent = $this->inflight[$idx];
            unset($this->inflight[$idx]);
            if ($res < 0) {
                $this->closeConn($idx, false);
            } else {
                if ($res < strlen($sent)) {
                    $this->pend[$idx] = substr($sent, $res) . ($this->pend[$idx] ?? '');
                }
                if (isset($this->pend[$idx])) {
                    $this->flushPending($idx);
                } elseif (isset($this->closing[$idx])) {
                    $this->closeConn($idx, true);
                }
            }
        }
        while ($this->waitQ !== [] && $this->freeCount > 0) {
            $w = array_shift($this->waitQ);
            if (isset($this->pend[$w]) && !isset($this->inflight[$w])) {
                $this->flushPending($w);
            }
        }
    }

    private function send(int $idx, string $data): void
    {
        if (isset($this->inflight[$idx]) || isset($this->pend[$idx])) {
            $this->pend[$idx] = ($this->pend[$idx] ?? '') . $data;
        } elseif ($this->freeCount === 0) {
            $this->pend[$idx] = $data;
            $this->waitQ[] = $idx;
        } else {
            $this->startSend($idx, $data);
        }
    }

    private function flushPending(int $idx): void
    {
        $data = $this->pend[$idx];
        unset($this->pend[$idx]);
        if ($this->freeCount === 0) {
            $this->pend[$idx] = $data;
            $this->waitQ[] = $idx;
            return;
        }
        $this->startSend($idx, $data);
    }

    /** Precondition: no send in flight on $idx and a free slot. A response over one slot goes out in pieces, one send at a time. */
    private function startSend(int $idx, string $data): void
    {
        $len = strlen($data);
        if ($len > self::SLOT_SIZE) {
            $this->pend[$idx] = substr($data, self::SLOT_SIZE);
            $data = substr($data, 0, self::SLOT_SIZE);
            $len = self::SLOT_SIZE;
        }
        $slot = $this->freeSlots[--$this->freeCount];
        FFI::memcpy($this->slotPtr[$slot], $data, $len);
        $this->inflight[$idx] = $data;
        $s = $this->sqe();
        $s->opcode = self::OP_SEND;
        $s->flags = self::SQE_FIXED_FILE;
        $s->ioprio = 0;
        $s->fd = $idx;
        $s->off = 0;
        $s->addr = $this->slotAddr[$slot];
        $s->len = $len;
        $s->op_flags = self::MSG_NOSIGNAL;
        $s->user_data = self::T_SEND | $idx << 3 | $this->gens[$idx] << 19 | $slot << 27;
        $s->buf_index = 0;
        $s->file_index = 0;
    }

    /**
     * Answers every complete request in $data and keeps what is not whole yet. Returns the responses, in order.
     * A request that says `Connection: close` (or HTTP/1.0 without keep-alive), or that cannot be parsed, ends the parsing: the
     * connection closes once what was answered is sent.
     */
    private function parse(int $idx, string $data): string
    {
        $length = strlen($data);
        $pos = 0;
        $out = '';
        while (true) {
            $end = strpos($data, "\r\n\r\n", $pos);
            if ($end === false) {
                if ($length - $pos > self::HEADER_LIMIT) {
                    $out .= self::BAD_REQUEST;
                    $this->closing[$idx] = true;
                } elseif ($pos < $length) {
                    $this->partial[$idx] = $pos === 0 ? $data : substr($data, $pos);
                }
                break;
            }
            if ($end + 4 - $pos > self::HEADER_LIMIT || !$this->parseHead(substr($data, $pos, $end - $pos))) {
                $out .= self::BAD_REQUEST;
                $this->closing[$idx] = true;
                break;
            }
            $bodyStart = $end + 4;
            if ($length - $bodyStart < $this->bodyLength) {
                $this->partial[$idx] = substr($data, $pos);
                break;
            }
            $body = $this->bodyLength === 0 ? '' : substr($data, $bodyStart, $this->bodyLength);
            $pos = $bodyStart + $this->bodyLength;
            $this->requests++;
            $target = $this->target;
            if ($this->method === 'GET' && $target === '/noop') {
                $out .= self::NOOP;
            } elseif ($this->method === 'GET' && str_starts_with($target, '/noop?id=') && strlen($target) <= 29 && ctype_digit($id = substr($target, 9))) {
                $payload = '{"status":"ok","id":' . $id . '}';
                $out .= self::HEAD[200] . strlen($payload) . "\r\n\r\n" . $payload;
            } else {
                // Why: an exception that escaped here would end the loop for every connection.
                try {
                    [$status, $payload] = handler_handle($this->method, $target, $body);
                } catch (Throwable $e) {
                    fwrite(STDERR, 'uring-noop: the handler failed: ' . get_class($e) . ': ' . $e->getMessage() . "\n");
                    [$status, $payload] = [500, self::INTERNAL_ERROR];
                }
                $out .= self::HEAD[$status] . strlen($payload) . "\r\n\r\n" . $payload;
            }
            if ($this->closeAfter) {
                $this->closing[$idx] = true;
                break;
            }
            if ($pos >= $length) {
                break;
            }
        }
        return $out;
    }

    /** Reads the request line and the headers (without their final blank line) into the properties, like the DIY server's parser. */
    private function parseHead(string $head): bool
    {
        $eol = strpos($head, "\r\n");
        $line = $eol === false ? $head : substr($head, 0, $eol);
        $sp1 = strpos($line, ' ');
        $sp2 = strrpos($line, ' ');
        if ($sp1 === false || $sp1 === 0 || $sp2 < $sp1 + 2) {
            return false;
        }
        $version = substr($line, $sp2 + 1);
        if ($version !== 'HTTP/1.1' && $version !== 'HTTP/1.0') {
            return false;
        }
        $this->method = substr($line, 0, $sp1);
        $this->target = substr($line, $sp1 + 1, $sp2 - $sp1 - 1);
        if (!ctype_alpha($this->method) || str_contains($this->target, ' ')) {
            return false;
        }

        $this->bodyLength = 0;
        $close = false;
        $keepAlive = false;
        $hasLength = false;
        if ($eol !== false) {
            foreach (explode("\r\n", substr($head, $eol + 2)) as $header) {
                $colon = strpos($header, ':');
                // Why: a space or a tab before the colon, or a line fold, would make a server that skips it and one that reads it
                // disagree on where the body ends (RFC 9112, 5.1: answer 400).
                if ($colon === false || $colon === 0 || $header[$colon - 1] === ' ' || $header[$colon - 1] === "\t" || $header[0] === ' ' || $header[0] === "\t") {
                    return false;
                }
                if ($colon === 14 && strncasecmp($header, 'content-length', 14) === 0) {
                    $value = trim(substr($header, 15), " \t");
                    if ($hasLength || !ctype_digit($value) || strlen($value) > 7 || (int) $value > self::BODY_LIMIT) {
                        return false;
                    }
                    $hasLength = true;
                    $this->bodyLength = (int) $value;
                } elseif ($colon === 10 && strncasecmp($header, 'connection', 10) === 0) {
                    $value = strtolower(substr($header, 11));
                    $close = str_contains($value, 'close');
                    $keepAlive = str_contains($value, 'keep-alive');
                } elseif ($colon === 17 && strncasecmp($header, 'transfer-encoding', 17) === 0) {
                    return false;
                }
            }
        }
        $this->closeAfter = $close || ($version === 'HTTP/1.0' && !$keepAlive);
        return true;
    }
}

/** The listening socket as a plain descriptor (the ring accepts from it): non-blocking, TCP_NODELAY (inherited by what it accepts). */
function uring_listen(FFI $ffi, string $address, int $port, int $backlog): int
{
    // AF_INET 2, SOCK_STREAM 1 | SOCK_NONBLOCK 0x800 | SOCK_CLOEXEC 0x80000.
    $fd = $ffi->socket(2, 1 | 0x800 | 0x80000, 0);
    if ($fd < 0) {
        fwrite(STDERR, "uring-noop: socket() failed\n");
        exit(1);
    }
    $one = $ffi->new('int');
    $one->cdata = 1;
    // SOL_SOCKET 1 / SO_REUSEADDR 2; IPPROTO_TCP 6 / TCP_NODELAY 1.
    $ffi->setsockopt($fd, 1, 2, FFI::addr($one), 4);
    $ffi->setsockopt($fd, 6, 1, FFI::addr($one), 4);
    $addr = $ffi->new('char[16]');
    $packed = pack('vnN', 2, $port, ip2long($address)) . str_repeat("\0", 8);
    FFI::memcpy($addr, $packed, 16);
    if ($ffi->bind($fd, $addr, 16) !== 0 || $ffi->listen($fd, $backlog) !== 0) {
        fwrite(STDERR, "uring-noop: cannot listen on $address:$port\n");
        exit(1);
    }
    return $fd;
}

/** One `ring:` line: what the loop did since the last one. Requests per turn is the number the ring's cost per request depends on. */
function uring_stats_line(array $rings, array &$last): ?string
{
    $now = ['turns' => 0, 'flushes' => 0, 'cqes' => 0, 'requests' => 0, 'accepted' => 0, 'pauses' => 0, 'open' => 0];
    foreach ($rings as $r) {
        $now['turns'] += $r->turns;
        $now['flushes'] += $r->flushes;
        $now['cqes'] += $r->cqes;
        $now['requests'] += $r->requests;
        $now['accepted'] += $r->accepted;
        $now['pauses'] += $r->acceptPauses;
        $now['open'] += $r->open;
    }
    $d = [];
    foreach ($now as $k => $v) {
        $d[$k] = $k === 'open' ? $v : $v - ($last[$k] ?? 0);
    }
    $last = $now;
    if ($d['turns'] === 0 && $d['accepted'] === 0) {
        return null;
    }
    $busy = $d['requests'] > 0 ? $d['turns'] : 0;
    return sprintf('ring: turns=%d requests=%d cqes=%d flushes=%d accepted=%d open=%d accept_pauses=%d requests_per_turn=%s cqes_per_turn=%s',
        $d['turns'], $d['requests'], $d['cqes'], $d['flushes'], $d['accepted'], $d['open'], $d['pauses'],
        $busy > 0 ? sprintf('%.2f', $d['requests'] / $busy) : 'n/a', $d['turns'] > 0 ? sprintf('%.2f', $d['cqes'] / $d['turns']) : 'n/a');
}

$port = (int) (getenv('PORT') ?: 8080);
$ringCount = (int) (getenv('URING_RINGS') ?: 1);
$waitUs = (int) (getenv('URING_WAIT_US') ?: 500);
$minComplete = (int) (getenv('URING_MIN_COMPLETE') ?: 1);
$minWaitUs = (int) (getenv('URING_MIN_WAIT_US') ?: 0);
$backlog = 4096;
if ($ringCount < 1 || $ringCount > 2) {
    fwrite(STDERR, "uring-noop: URING_RINGS must be 1 or 2\n");
    exit(1);
}

// The database copy takes a few seconds, so the server listens only once it is done.
handler_boot();

$ffi = FFI::cdef(file_get_contents(__DIR__ . '/uring-noop.h'), 'libc.so.6');
$ffiAddr = FFI::cdef('intptr_t mmap(void *addr, size_t length, int prot, int flags, int fd, long offset);', 'libc.so.6');
foreach (['sqe_t' => 64, 'params_t' => 120, 'rsrc_register_t' => 32, 'buf_reg_t' => 40, 'buf_t' => 16, 'getevents_arg_t' => 24, 'timespec_t' => 16] as $type => $size) {
    if (FFI::sizeof($ffi->type($type)) !== $size) {
        fwrite(STDERR, "uring-noop: $type is " . FFI::sizeof($ffi->type($type)) . " bytes, the kernel's is $size\n");
        exit(1);
    }
}
$listenFd = uring_listen($ffi, '0.0.0.0', $port, $backlog);
$rings = [];
try {
    for ($i = 0; $i < $ringCount; $i++) {
        $rings[] = new UringRing($ffi, $ffiAddr, $listenFd, 'ring' . $i, $minComplete, $minWaitUs);
    }
} catch (RuntimeException $e) {
    fwrite(STDERR, 'uring-noop: ' . $e->getMessage() . "\n");
    exit(1);
}
foreach ($rings as $ring) {
    $ring->armAccept();
}
echo "listening on 0.0.0.0:$port\n";
echo 'loop: io_uring through FFI, ' . $ringCount . ' ring' . ($ringCount > 1 ? 's' : '') . ', table ' . $rings[0]->tableSize . ' each, ' . UringRing::describe() . "\n";
echo "socket: backlog=$backlog tcp_nodelay=1\n";

// The loop. One ring: one enter per turn, with a one-second timeout so the statistics come out when the server is idle. Two rings:
// the wait is on the first, short, and the second is entered when the kernel says it has work.
$last = [];
$next = time() + 1;
$count = 0;
if ($ringCount === 1) {
    $only = $rings[0];
    while (true) {
        $got = $only->turn(1000000000);
        if (!$got || (++$count & 63) === 0) {
            if (time() >= $next) {
                $next = time() + 1;
                if (($line = uring_stats_line($rings, $last)) !== null) {
                    echo $line, "\n";
                }
            }
        }
    }
}
[$first, $second] = $rings;
while (true) {
    $got = $first->turn($waitUs * 1000);
    // Why also when it has something queued: only an enter of its own submits what a ring's turn queued (its first accept, its sends), and
    // a turn can queue more that completes at once, so the second ring goes on while its turns find completions.
    if ($second->hasWork() || $second->hasQueued()) {
        do {
            $more = $second->turn(0);
            $got = $got || $more;
        } while ($more);
    }
    if (!$got || (++$count & 63) === 0) {
        if (time() >= $next) {
            $next = time() + 1;
            if (($line = uring_stats_line($rings, $last)) !== null) {
                echo $line, "\n";
            }
        }
    }
}
