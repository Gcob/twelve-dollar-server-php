<?php
// The challenge app's event loop on io_uring rings driven through PHP's FFI (no C is compiled, no liburing: raw syscalls). It is the
// ring of lab/servers/uring-noop.php (5a's spike, which stays as it is: its results cite it) with the DIY server's HTTP/1.1 parser and
// answers (lab/servers/diy-connection.php) in place of the spike's `/noop` echo, and with what an app needs to be correct under
// pressure: splits, pipelining, short sends, responses longer than a send slot, a send pool that runs full, a receive pool that runs dry.
// lab/app/server.php boots it with APP_RING=1 (one process, APP_RINGS rings, one by default); lab/servers/bake-ring.php boots it on the
// bake-off's handler so that lab/conformance.sh runs on it. Nothing here is the submission's.
//
// The memory-ordering design that makes plain FFI reads and writes safe:
// - No SQPOLL. IORING_SETUP_SINGLE_ISSUER and IORING_SETUP_DEFER_TASKRUN: the kernel posts completions and takes submissions only inside
//   our own io_uring_enter, on our thread. So the heads and tails are read and written only around that call, and a plain store to the
//   submission tail needs no barrier of its own (the syscall entry orders it). IORING_SETUP_SUBMIT_ALL.
//   IORING_SETUP_NO_SQARRAY (kernel 6.6+): the slot of an SQE is its index in the ring, no index array to keep.
// - One io_uring_enter per turn of the loop: it submits what the turn built and waits for at least one completion (one second at most, so
//   the statistics line comes out when the server is idle). A full submission queue forces one more submit-only enter in the middle of a
//   turn: counted as `flushes`. Nothing newer than kernel 6.8 (the bench's) is used: no min_wait_usec, no batching knob.
// - Connections are direct descriptors: accept into a sparse table of fixed files (IORING_FILE_INDEX_ALLOC), as large as
//   RLIMIT_NOFILE allows (the kernel refuses a bigger one with EMFILE, and the lab's limit is 65,535), so a connection takes no file
//   descriptor of the process. A table is per ring: APP_RINGS rings (1 to 4) in the one process hold that many tables of connections. Receive is multishot from a provided buffer ring (a pool shared by all connections, nothing held per idle
//   connection), send is one SEND of the response copied into a pooled slot, and a server-side close is a shutdown linked to the close
//   of the descriptor (the multishot receive keeps the socket alive until the shutdown ends it).
// - SQEs are written in place in the ring's mapped memory, field by field; CQEs are read once per turn: one FFI::string, one unpack().
// - Accepts are single, a window of at most ACCEPT_WINDOW waiting and never more than the table has free slots for (topUpAccepts()): no
//   connection is ever taken that has no slot, however large a burst the backlog holds.
// - Several rings (RingLoop): all of them accept from the one listening socket; a ring arms accepts only when the ring before it is full.
//   The loop blocks on the ring that had completions in its last turn (never always the first: connections fill the first ring and the
//   traffic that comes after lands on the next), and in the same turn enters every other ring that has work (its IORING_SQ_TASKRUN flag
//   is set: only an io_uring_enter of its own runs its deferred work) or SQEs queued (only its own enter submits them).
// - At boot every ring is built before the server listens. A step the kernel refuses (setup, mapping, the table, the buffer ring) is a
//   RingRefused with the step and the errno: the caller falls back to the DIY loop (lab/app/server.php) and says so.
//
// What the loop does about the cases a stress run of `GET /noop` never shows:
// - A request split over several receives is kept (`partial`) and assembled before it is parsed. Pipelined requests are answered in
//   order: the responses of one receive go out as one send.
// - A short send is resubmitted from where it stopped. A response longer than a send slot (8 KiB) gets a mapping sized for it, unmapped when
//   its send completes: never truncated, never dropped. When every slot is in use a connection waits for one (`send_waits`).
// - The receive pool can run dry (more receives complete in one turn than there are buffers: the kernel ends the multishot receive with
//   ENOBUFS, `recv_dry`): those connections are armed again at the next turn, once the buffers are back and at most as many as there are
//   buffers, in the order they ran dry (arming them all at once would make most of them fail again).
// - A connection that has WRITE_LIMIT bytes of responses waiting for the client stops being parsed (`stalls`), like the DIY loop stops
//   reading: its input waits in `partial` and is parsed when its sends drain. A client that sends more than STALL_INPUT_LIMIT meanwhile is
//   dropped.
// - A peer that closes or resets mid-response: the receive or the send fails, the connection is freed and its slot is given back when the
//   send's own completion arrives (a slot is never reused before that).
//
// Port: PORT (default 8080), host: HOST (an IPv4 address). Test knobs, unset by default: URING_RECV_BUFFERS (a power of two, 2 to 32768; default
// 4096 buffers of 2048 bytes) and URING_SEND_SLOTS (1 to 8192; default 2048 slots of 8 KiB), to make a pool run dry or full with a few
// connections; URING_TABLE_SIZE (32 to 65535: a table smaller than RLIMIT_NOFILE gives), to fill a ring's table with a few connections and make
// the next ring take the rest; URING_FAIL_STEP (files or buffer_ring: that step of the boot of the last ring is asked for something the kernel
// refuses, to see the fallback to the DIY loop of lab/app/server.php). Docker's default seccomp filter refuses io_uring (EPERM): the lab's scripts take --seccomp-unconfined for this server.

if (!extension_loaded('FFI')) {
    fwrite(STDERR, "ring-server: FFI is not loaded\n");
    exit(1);
}
if (!in_array(php_uname('m'), ['x86_64', 'aarch64'], true)) {
    // The io_uring syscalls are 425 to 427 on both; the sockets' constants below are the same on both.
    fwrite(STDERR, 'ring-server: only x86_64 and aarch64 are known, this is ' . php_uname('m') . "\n");
    exit(1);
}

/** A step of the ring's boot that the kernel refused (Docker's seccomp filter, a kernel without io_uring, a limit): the step's name and the errno. */
final class RingRefused extends RuntimeException
{
    public function __construct(public readonly string $step, public readonly int $errnoValue, string $detail = '')
    {
        parent::__construct("$step $errnoValue" . ($detail === '' ? '' : " ($detail)"));
    }
}

/** What the rings share: the connections open on all of them, which the soft limit counts. */
final class RingTotals
{
    public int $open = 0;
}

final class AppRing
{
    // io_uring_setup flags.
    private const SETUP_CQSIZE = 1 << 3;
    private const SETUP_SUBMIT_ALL = 1 << 7;
    private const SETUP_TASKRUN_FLAG = 1 << 9;
    private const SETUP_SINGLE_ISSUER = 1 << 12;
    private const SETUP_DEFER_TASKRUN = 1 << 13;
    private const SETUP_NO_SQARRAY = 1 << 16;
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
    private const OP_CLOSE = 19;
    private const OP_SEND = 26;
    private const OP_RECV = 27;
    private const OP_SHUTDOWN = 34;
    private const SQE_FIXED_FILE = 1;
    private const SQE_IO_LINK = 4;
    private const SQE_BUFFER_SELECT = 32;
    private const RECV_MULTISHOT = 2;
    private const FILE_INDEX_ALLOC = 0xFFFFFFFF;
    private const CQE_F_BUFFER = 1;
    private const CQE_F_MORE = 2;
    private const MSG_NOSIGNAL = 0x4000;
    private const O_NONBLOCK = 0x800;
    private const SHUT_RDWR = 2;
    private const ENOBUFS = 105;
    private const ECANCELED = 125;
    private const ECONNABORTED = 103;
    /** Accepts one ring keeps waiting on the listening socket at most (see topUpAccepts()). */
    private const ACCEPT_WINDOW = 64;
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

    private const SQ_TASKRUN = 1 << 2;
    private const SQ_ENTRIES = 4096;
    private const CQ_ENTRIES = 32768;
    private const BUF_SIZE = 2048;
    private const SLOT_SIZE = 8192;
    private const MAX_TABLE = 65535;
    private const PAGE = 4096;

    /** The DIY connection's limits (lab/servers/diy-connection.php), the same numbers: the answers do not change with the loop. */
    private const WRITE_LIMIT = 1048576;
    private const HEADER_LIMIT = 8192;
    private const BODY_LIMIT = 1048576;
    /** Input a stalled connection may keep waiting (see parse()): past it the client is dropped. */
    private const STALL_INPUT_LIMIT = 4194304;

    private const HEAD = [
        200 => "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ",
        201 => "HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nContent-Length: ",
        400 => "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: ",
        401 => "HTTP/1.1 401 Unauthorized\r\nContent-Type: application/json\r\nContent-Length: ",
        404 => "HTTP/1.1 404 Not Found\r\nContent-Type: application/json\r\nContent-Length: ",
        500 => "HTTP/1.1 500 Internal Server Error\r\nContent-Type: application/json\r\nContent-Length: ",
        503 => "HTTP/1.1 503 Service Unavailable\r\nContent-Type: application/json\r\nContent-Length: ",
    ];
    private const INTERNAL_ERROR = '{"error":"internal server error"}';
    private const BAD_REQUEST = "HTTP/1.1 400 Bad Request\r\nContent-Type: application/json\r\nContent-Length: 23\r\n\r\n{\"error\":\"bad request\"}";

    // What the loop counted since the process started (the stats line prints their differences each second).
    public int $turns = 0;
    public int $flushes = 0;
    public int $cqes = 0;
    public int $requests = 0;
    public int $accepted = 0;
    public int $acceptPauses = 0;
    public int $open = 0;
    public int $shortSends = 0;
    public int $bigSends = 0;
    public int $sendWaits = 0;
    public int $recvDry = 0;
    public int $stalls = 0;
    /** Responses that said `Connection: close` because more than the soft limit of connections were open (the client had not asked). */
    public int $limitCloses = 0;

    public readonly int $tableSize;
    public readonly int $ringFd;
    public readonly int $recvBuffers;
    public readonly int $sendSlots;
    private readonly ?int $softLimit;
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
    private readonly ?AppRing $previous;
    private readonly ?string $failStep;
    private int $listenFd = -1;
    /** @var list<array{int, int}> the mappings this ring made (address, bytes), unmapped by release() */
    private array $maps = [];
    private int $fdToClose = -1;
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
    /** @var list<int> connections waiting for a send slot, and the index of the first one */
    private array $waitQ = [];
    private int $waitHead = 0;
    /** @var array<int, array{int, int}> the one-off mappings of the responses longer than a slot, by the number their send carries: address, bytes */
    private array $bigMaps = [];
    private int $bigSeq = 0;
    /** @var array<int, int> direct descriptor => generation */
    private array $gens;
    /** @var array<int, string> input that is not a whole request yet, by descriptor */
    private array $partial = [];
    /** @var array<int, string> the bytes of the send in flight, by descriptor */
    private array $inflight = [];
    /** @var array<int, string> bytes to send once the one in flight is done (or a slot is free) */
    private array $pend = [];
    /** @var array<int, true> connections to close once their last send is done */
    private array $closing = [];
    /** @var array<int, true> connections whose parsing waits for their responses to be sent (see parse()) */
    private array $stalled = [];
    /** @var list<int> connections whose receive ended for want of a buffer, waiting to be armed again (descriptor | generation << 16) */
    private array $dryQ = [];
    /** Accepts submitted and not completed. */
    private int $acceptsOut = 0;
    /** Slots of the table taken: connections open, and closed ones whose descriptor has not been given back yet (its close has not completed). */
    private int $used = 0;
    private bool $tableFull = false;
    /** An accept failed for a reason that is not the table: no more are armed until a connection closes. */
    private bool $acceptPaused = false;
    private bool $pauseReported = false;

    // What parseHead() found in the request it just read.
    private string $method = '';
    private string $target = '';
    private string $authorization = '';
    private int $bodyLength = 0;
    private bool $closeAfter = false;

    /**
     * @param FFI $ffi the declarations of ring-server.h
     * @param FFI $ffiAddr an FFI whose mmap() and munmap() take and return addresses as integers (see map())
     * @param RingTotals $totals the open connections of every ring, shared by them
     * @param array{recv_buffers?: int, send_slots?: int, table_size?: int, soft_limit?: ?int, fail_step?: ?string, previous?: ?AppRing} $options
     *        the ring before this one (it accepts first: see topUpAccepts()), pool sizes (a power of
     *        two of receive buffers, the table of direct descriptors that RLIMIT_NOFILE does not already make smaller), the soft connection limit (a response built while more connections than this are open, on all the rings, says
     *        `Connection: close` and ends its connection), and a test hook: the step ('files' or 'buffer_ring') to ask the kernel for something
     *        it refuses
     * @throws RingRefused when the kernel refuses a step of the boot (every resource taken until then is given back)
     */
    public function __construct(private readonly FFI $ffi, private readonly FFI $ffiAddr, private readonly string $name, private readonly RingTotals $totals, array $options = [])
    {
        $this->recvBuffers = $options['recv_buffers'] ?? 4096;
        $this->sendSlots = $options['send_slots'] ?? 2048;
        $this->softLimit = $options['soft_limit'] ?? null;
        $this->errnoP = $ffi->__errno_location();
        $this->failStep = $options['fail_step'] ?? null;
        $rl = $ffi->new('rlimit_t');
        if ($ffi->getrlimit(7, FFI::addr($rl)) !== 0) {
            throw new RuntimeException('getrlimit(RLIMIT_NOFILE) failed');
        }
        $this->tableSize = min($rl->cur, self::MAX_TABLE, $options['table_size'] ?? self::MAX_TABLE);
        $this->gens = array_fill(0, $this->tableSize, 0);
        $this->previous = $options['previous'] ?? null;
        try {
            $this->build();
        } catch (RingRefused $e) {
            $this->release();
            throw $e;
        }
    }

    /** Everything that asks the kernel for something: the ring, its mappings, the table of direct descriptors, the buffer ring, the pools. */
    private function build(): void
    {
        $ffi = $this->ffi;
        $params = $ffi->new('params_t');
        $params->flags = self::SETUP_CQSIZE | self::SETUP_SUBMIT_ALL | self::SETUP_TASKRUN_FLAG | self::SETUP_SINGLE_ISSUER
            | self::SETUP_DEFER_TASKRUN | self::SETUP_NO_SQARRAY;
        $params->cq_entries = self::CQ_ENTRIES;
        $this->params = $params;
        $fd = $ffi->syscall(self::SYS_SETUP, self::SQ_ENTRIES, FFI::addr($params));
        if ($fd < 0) {
            // 1 is Docker's default seccomp filter (run the container with --seccomp-unconfined), 38 and 95 a kernel without io_uring.
            throw new RingRefused('setup', $this->errno());
        }
        $this->fdToClose = $fd;
        $this->ringFd = $fd;
        if (!($params->features & 1)) {
            throw new RingRefused('single_mmap', 95, 'the kernel does not map both rings at once');
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
        // Why 0 entries for the test hook: the kernel answers EINVAL, a real refusal of this step.
        $register->nr = $this->failStep === 'files' ? 0 : $this->tableSize;
        $register->flags = self::RSRC_REGISTER_SPARSE;
        if ($ffi->syscall(self::SYS_REGISTER, $fd, self::REGISTER_FILES2, FFI::addr($register), FFI::sizeof($register)) < 0) {
            throw new RingRefused('files', $this->errno(), "a sparse table of {$this->tableSize} files");
        }

        // The receive buffers and their ring.
        $bufAddr = $this->map($this->recvBuffers * self::BUF_SIZE, 0x02 | 0x20, -1, 0);
        $this->bufAddr = $bufAddr;
        // Why a local: FFI::cast() takes its second argument by reference, which a readonly property refuses.
        $this->bufBase = $ffi->cast('uint8_t*', $bufAddr);
        $bufRingMem = $this->map($this->recvBuffers * 16, 0x02 | 0x20, -1, 0);
        $this->bufRing = $ffi->cast('buf_t*', $bufRingMem);
        // The ring's tail is the last two bytes of its first entry.
        $this->bufTailP = $ffi->cast('uint16_t*', $bufRingMem + 14);
        $reg = $ffi->new('buf_reg_t');
        $reg->ring_addr = $bufRingMem;
        // Why 0 entries for the test hook: the kernel answers EINVAL, a real refusal of this step.
        $reg->ring_entries = $this->failStep === 'buffer_ring' ? 0 : $this->recvBuffers;
        $reg->bgid = 0;
        if ($ffi->syscall(self::SYS_REGISTER, $fd, self::REGISTER_PBUF_RING, FFI::addr($reg), 1) < 0) {
            throw new RingRefused('buffer_ring', $this->errno());
        }
        for ($bid = 0; $bid < $this->recvBuffers; $bid++) {
            $this->putBuffer($bid);
        }

        // The send slots.
        $slots = $this->map($this->sendSlots * self::SLOT_SIZE, 0x02 | 0x20, -1, 0);
        for ($s = 0; $s < $this->sendSlots; $s++) {
            $this->slotAddr[$s] = $slots + $s * self::SLOT_SIZE;
            $this->slotPtr[$s] = $ffi->cast('uint8_t*', $this->slotAddr[$s]);
            $this->freeSlots[$s] = $s;
        }
        $this->freeCount = $this->sendSlots;

        // The wait with a timeout: the extended argument of io_uring_enter and the timespec it points to, in a page of their own. The
        // argument's `pad` field stays 0 (the kernel of the bench, 6.8, refuses anything else there).
        $misc = $this->map(self::PAGE, 0x02 | 0x20, -1, 0);
        $this->arg = $ffi->cast('getevents_arg_t*', $misc);
        $this->argAddr = $misc;
        $this->ts = $ffi->cast('timespec_t*', $misc + 64);
        $this->arg->ts = $misc + 64;
    }

    private function errno(): int
    {
        return $this->errnoP[0];
    }

    /** Gives the kernel's resources back: the ring's mappings, then the ring (and with it its table and its buffer ring). */
    public function release(): void
    {
        foreach ($this->maps as [$address, $bytes]) {
            $this->ffiAddr->munmap($address, $bytes);
        }
        $this->maps = [];
        if ($this->fdToClose >= 0) {
            $this->ffi->close($this->fdToClose);
            $this->fdToClose = -1;
        }
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

    /**
     * An anonymous or ring mapping, as an integer address; fails loudly (MAP_FAILED is -1). The mappings of the boot are kept to be given
     * back if a later step of the boot is refused ($boot); the one-off mappings of long responses are the loop's to unmap.
     * Why an integer: FFI::cast('uintptr_t', $pointer) reads 0 for a pointer mmap() returned, and arithmetic on one pointer cast to
     * several types changes the earlier ones, so every pointer here is made with cast('<type>*', <integer address>).
     */
    private function map(int $bytes, int $flags, int $fd, int $offset, bool $boot = true): int
    {
        $address = $this->ffiAddr->mmap(null, $bytes, 3, $flags, $fd, $offset);
        if ($address === -1) {
            throw new RingRefused('mmap', $this->errno(), "$bytes bytes");
        }
        if ($boot) {
            $this->maps[] = [$address, $bytes];
        }
        return $address;
    }

    /** The pools this ring holds, for the boot line. */
    public function describe(): string
    {
        return 'table=' . $this->tableSize . ' sq=' . self::SQ_ENTRIES . ' cq=' . self::CQ_ENTRIES . ' recv_buffers=' . $this->recvBuffers . 'x' . self::BUF_SIZE
            . ' send_slots=' . $this->sendSlots . 'x' . self::SLOT_SIZE;
    }

    /** Hands a receive buffer back to the kernel: its entry at the ring's tail (published once per turn). */
    private function putBuffer(int $bid): void
    {
        $b = $this->bufRing[$this->bufTail & ($this->recvBuffers - 1)];
        $b->addr = $this->bufAddr + $bid * self::BUF_SIZE;
        $b->len = self::BUF_SIZE;
        $b->bid = $bid;
        $this->bufTail++;
    }

    /** Submits what is queued, and waits for at least one completion for at most $timeoutNs (0: does not wait). */
    private function enter(int $timeoutNs): void
    {
        $this->sqTailP[0] = $this->sqTail;
        $this->bufTailP[0] = $this->bufTail;
        $toSubmit = ($this->sqTail - $this->sqHeadSeen) & 0xFFFFFFFF;
        if ($timeoutNs > 0) {
            $this->ts->tv_sec = intdiv($timeoutNs, 1000000000);
            $this->ts->tv_nsec = $timeoutNs % 1000000000;
            $r = $this->ffi->syscall(self::SYS_ENTER, $this->ringFd, $toSubmit, 1, self::ENTER_GETEVENTS | self::ENTER_EXT_ARG, $this->argAddr, 24);
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

    /** Tells the ring which socket the connections come from (all the rings accept from the same one) and arms its first accepts. */
    public function armAccept(int $listenFd): void
    {
        $this->listenFd = $listenFd;
        $this->topUpAccepts();
    }

    /** True when every slot of the table is taken or promised to an accept (or accepting failed): nothing more can be armed here. */
    public function isFull(): bool
    {
        return $this->acceptPaused || $this->tableSize - $this->used - $this->acceptsOut <= 0;
    }

    /**
     * Keeps up to ACCEPT_WINDOW single accepts waiting, never more than the table has free slots for: an accept that finds the table full has
     * already taken the connection off the listening queue and the kernel drops it, and a multishot accept takes the whole backlog in one go
     * (up to 4,096 connections here and on the bench), so no margin below the table's end is safe in a burst. With at most as many accepts
     * waiting as there are free slots, no connection can be taken that has nowhere to go. A connection arriving past that waits in the
     * backlog, and a ring that gets a slot back (a close completes) arms an accept that takes it at once: an accept tries before it waits.
     * First fit: a ring arms accepts only when the ring before it is full, so the connections fill the first ring, then the next.
     */
    public function topUpAccepts(): void
    {
        if ($this->acceptPaused) {
            return;
        }
        $room = $this->tableSize - $this->used - $this->acceptsOut;
        if ($room <= 0) {
            if (!$this->tableFull) {
                $this->tableFull = true;
                $this->acceptPauses++;
            }
            return;
        }
        $this->tableFull = false;
        if ($this->previous !== null && !$this->previous->isFull()) {
            return;
        }
        for ($want = min(self::ACCEPT_WINDOW - $this->acceptsOut, $room); $want > 0; $want--) {
            // personality, addr3 and pad2 are never written: they stay zero. No multishot flag: one accept, one connection.
            $this->prep(self::OP_ACCEPT, 0, 0, $this->listenFd, 0, 0, 0, self::O_NONBLOCK, self::T_ACCEPT, 0, self::FILE_INDEX_ALLOC);
            $this->acceptsOut++;
        }
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
        unset($this->partial[$idx], $this->inflight[$idx], $this->pend[$idx], $this->closing[$idx], $this->stalled[$idx]);
        $this->open--;
        $this->totals->open--;
        if ($shutdown) {
            $this->prep(self::OP_SHUTDOWN, self::SQE_FIXED_FILE | self::SQE_IO_LINK, 0, $idx, 0, 0, self::SHUT_RDWR, 0,
                self::T_SHUTDOWN | $idx << 3 | $gen << 19, 0, 0);
        }
        $this->prep(self::OP_CLOSE, 0, 0, 0, 0, 0, 0, 0, self::T_CLOSE | $idx << 3 | $gen << 19, 0, $idx + 1);
    }

    /**
     * Arms again the receives that ended for want of a buffer, at most as many as there are buffers: all of them have been given back by
     * now, and arming more at once would only make the extra ones fail again. True when some are still waiting for the next turn.
     */
    private function rearmDry(): bool
    {
        foreach (array_splice($this->dryQ, 0, $this->recvBuffers) as $key) {
            $idx = $key & 0xFFFF;
            if ($key >> 16 === $this->gens[$idx] && !isset($this->closing[$idx])) {
                $this->armRecv($idx);
            }
        }
        return $this->dryQ !== [];
    }

    /** One turn: submit, wait for a completion (at most $timeoutNs), handle every completion that is there. False: nothing came. */
    public function turn(int $timeoutNs): bool
    {
        if ($this->dryQ !== [] && $this->rearmDry()) {
            $timeoutNs = 0; // some receives still wait to be armed: there is no time to wait for anything else
        }
        $this->enter($timeoutNs);
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
                $this->onAccept($res);
            } elseif ($kind === self::T_CLOSE) {
                $this->onClose($ud, $res);
            }
        }
        $this->topUpAccepts();
        return true;
    }

    /** What this ring counted since the process started, by the name the `ring:` line gives it. */
    public function counters(): array
    {
        return ['turns' => $this->turns, 'flushes' => $this->flushes, 'cqes' => $this->cqes, 'requests' => $this->requests, 'accepted' => $this->accepted,
            'accept_pauses' => $this->acceptPauses, 'short_sends' => $this->shortSends, 'big_sends' => $this->bigSends, 'send_waits' => $this->sendWaits,
            'recv_dry' => $this->recvDry, 'stalls' => $this->stalls, 'limit_closes' => $this->limitCloses];
    }

    /** Send slots in use now (a value, not a count). */
    public function slotsInUse(): int
    {
        return $this->sendSlots - $this->freeCount;
    }

    private function onAccept(int $res): void
    {
        $this->acceptsOut--;
        if ($res >= 0) {
            $this->accepted++;
            $this->open++;
            $this->used++;
            $this->totals->open++;
            $this->armRecv($res);
        } elseif ($res !== -self::ECONNABORTED) {
            // The accept failed (the client left before it was taken is not one): stop accepting until a connection closes.
            $this->acceptPaused = true;
            $this->acceptPauses++;
            if (!$this->pauseReported) {
                $this->pauseReported = true;
                fwrite(STDERR, "ring-server[{$this->name}]: accept failed with " . -$res . " at {$this->open} connections: " .
                    "accepting again when one closes, clients wait in the backlog meanwhile\n");
            }
        }
    }

    /** A close completed: its slot is free again. One that was cancelled with its shutdown (the link broke) is closed again, on its own. */
    private function onClose(int $ud, int $res): void
    {
        if ($res === -self::ECANCELED) {
            $this->prep(self::OP_CLOSE, 0, 0, 0, 0, 0, 0, 0, $ud, 0, (($ud >> 3) & 0xFFFF) + 1);
            return;
        }
        $this->used--;
        $this->acceptPaused = false;
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
            if (isset($this->stalled[$idx])) {
                $this->partial[$idx] .= $data;
                if (strlen($this->partial[$idx]) > self::STALL_INPUT_LIMIT) {
                    $this->closeConn($idx, true);
                    return;
                }
            } else {
                if (isset($this->partial[$idx])) {
                    $data = $this->partial[$idx] . $data;
                    unset($this->partial[$idx]);
                }
                $out = $this->parse($idx, $data);
                if ($out !== '') {
                    $this->send($idx, $out);
                }
            }
            if (!($flags & self::CQE_F_MORE) && !isset($this->closing[$idx])) {
                $this->armRecv($idx);
            }
        } elseif ($res === -self::ENOBUFS) {
            // The buffers ran out for a moment (more receives completed in this turn than there are buffers): the receive ended. It is armed
            // again at the next turn, after the buffers went back (rearmDry()).
            $this->recvDry++;
            $this->dryQ[] = $idx | $this->gens[$idx] << 16;
        } else {
            // 0 is the client leaving, below 0 a reset or another error: either way the receive has ended. A client that left while a send
            // is in flight may never read it: the shutdown makes that send fail instead of waiting for it forever.
            $this->closeConn($idx, $res === 0 && isset($this->inflight[$idx]));
        }
    }

    private function onSend(int $ud, int $res): void
    {
        $slot = $ud >> 27;
        if (isset($this->bigMaps[$slot])) {
            $this->ffiAddr->munmap($this->bigMaps[$slot][0], $this->bigMaps[$slot][1]);
            unset($this->bigMaps[$slot]);
        } else {
            $this->freeSlots[$this->freeCount++] = $slot;
        }
        $idx = ($ud >> 3) & 0xFFFF;
        if ((($ud >> 19) & 0xFF) === $this->gens[$idx]) {
            $sent = $this->inflight[$idx];
            unset($this->inflight[$idx]);
            if ($res < 0) {
                $this->closeConn($idx, false);
            } else {
                if ($res < strlen($sent)) {
                    $this->shortSends++;
                    $this->pend[$idx] = substr($sent, $res) . ($this->pend[$idx] ?? '');
                }
                if (isset($this->pend[$idx])) {
                    $this->flushPending($idx);
                } elseif (isset($this->closing[$idx])) {
                    $this->closeConn($idx, true);
                }
                if (isset($this->stalled[$idx]) && !isset($this->closing[$idx]) && $this->queued($idx) < self::WRITE_LIMIT) {
                    $this->resume($idx);
                }
            }
        }
        while ($this->waitHead < count($this->waitQ) && $this->freeCount > 0) {
            $w = $this->waitQ[$this->waitHead++];
            if (isset($this->pend[$w]) && !isset($this->inflight[$w])) {
                $this->flushPending($w);
            }
        }
        if ($this->waitHead === count($this->waitQ)) {
            $this->waitQ = [];
            $this->waitHead = 0;
        }
    }

    /** Response bytes of a connection that the client has not been given yet: the send in flight and what waits. */
    private function queued(int $idx): int
    {
        return strlen($this->inflight[$idx] ?? '') + strlen($this->pend[$idx] ?? '');
    }

    /** The responses of a stalled connection went out: parses the input that waited. */
    private function resume(int $idx): void
    {
        unset($this->stalled[$idx]);
        $data = $this->partial[$idx] ?? '';
        unset($this->partial[$idx]);
        $out = $this->parse($idx, $data);
        if ($out !== '') {
            $this->send($idx, $out);
        }
    }

    private function send(int $idx, string $data): void
    {
        if (isset($this->inflight[$idx]) || isset($this->pend[$idx])) {
            $this->pend[$idx] = ($this->pend[$idx] ?? '') . $data;
        } elseif ($this->freeCount === 0 && strlen($data) <= self::SLOT_SIZE) {
            $this->pend[$idx] = $data;
            $this->waitFor($idx);
        } else {
            $this->startSend($idx, $data);
        }
    }

    private function flushPending(int $idx): void
    {
        $data = $this->pend[$idx];
        unset($this->pend[$idx]);
        if ($this->freeCount === 0 && strlen($data) <= self::SLOT_SIZE) {
            $this->pend[$idx] = $data;
            $this->waitFor($idx);
            return;
        }
        $this->startSend($idx, $data);
    }

    private function waitFor(int $idx): void
    {
        $this->sendWaits++;
        $this->waitQ[] = $idx;
    }

    /**
     * Precondition: no send in flight on $idx, and a free slot unless the response is longer than one. A response longer than a slot goes
     * out from a mapping of its own, sized for it (to whole pages), that is unmapped when its send completes.
     */
    private function startSend(int $idx, string $data): void
    {
        $len = strlen($data);
        if ($len > self::SLOT_SIZE) {
            $bytes = intdiv($len + self::PAGE - 1, self::PAGE) * self::PAGE;
            $addr = $this->map($bytes, 0x02 | 0x20, -1, 0, false);
            FFI::memcpy($this->ffi->cast('uint8_t*', $addr), $data, $len);
            $slot = $this->sendSlots + $this->bigSeq++;
            $this->bigMaps[$slot] = [$addr, $bytes];
            $this->bigSends++;
        } else {
            $slot = $this->freeSlots[--$this->freeCount];
            $addr = $this->slotAddr[$slot];
            FFI::memcpy($this->slotPtr[$slot], $data, $len);
        }
        $this->inflight[$idx] = $data;
        $s = $this->sqe();
        $s->opcode = self::OP_SEND;
        $s->flags = self::SQE_FIXED_FILE;
        $s->ioprio = 0;
        $s->fd = $idx;
        $s->off = 0;
        $s->addr = $addr;
        $s->len = $len;
        $s->op_flags = self::MSG_NOSIGNAL;
        $s->user_data = self::T_SEND | $idx << 3 | $this->gens[$idx] << 19 | $slot << 27;
        $s->buf_index = 0;
        $s->file_index = 0;
    }

    /**
     * Answers every complete request in $data and keeps what is not whole yet (in `partial`). Returns the responses, in order.
     * A request that says `Connection: close` (or HTTP/1.0 without keep-alive), or that cannot be parsed, ends the parsing: the connection
     * closes once what was answered is sent. A connection whose responses waiting for the client reach WRITE_LIMIT stops here: the rest
     * of its input waits in `partial` until its sends drain (resume()).
     * The parsing and the answers are those of DiyConnection::parse() and respond(), byte for byte.
     */
    private function parse(int $idx, string $data): string
    {
        $length = strlen($data);
        $pos = 0;
        $out = '';
        $waiting = $this->queued($idx);
        while (true) {
            if ($waiting + strlen($out) >= self::WRITE_LIMIT) {
                $this->stalls++;
                $this->stalled[$idx] = true;
                $this->partial[$idx] = $pos === 0 ? $data : substr($data, $pos);
                break;
            }
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
            // Why: an exception that escaped here would end the loop for every connection.
            try {
                [$status, $payload] = handler_handle($this->method, $this->target, $body, $this->authorization);
            } catch (Throwable $e) {
                fwrite(STDERR, 'ring-server: the handler failed: ' . get_class($e) . ': ' . $e->getMessage() . "\n");
                [$status, $payload] = [500, self::INTERNAL_ERROR];
            }
            if ($this->softLimit !== null && $this->totals->open > $this->softLimit) {
                $out .= self::HEAD[$status] . strlen($payload) . "\r\nConnection: close\r\n\r\n" . $payload;
                $this->limitCloses += (int) !$this->closeAfter;
                $this->closing[$idx] = true;
                break;
            }
            $out .= self::HEAD[$status] . strlen($payload) . "\r\n\r\n" . $payload;
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

    /** Reads the request line and the headers (without their final blank line) into the properties. False: it cannot be parsed. */
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
        $this->authorization = '';
        $close = false;
        $keepAlive = false;
        $hasLength = false;
        if ($eol !== false) {
            foreach (explode("\r\n", substr($head, $eol + 2)) as $header) {
                $colon = strpos($header, ':');
                // Why: a space or a tab before the colon (`Content-Length : 5`) would make a server that skips it and one that reads it
                // disagree on where the body ends (RFC 9112, 5.1: answer 400); a line that starts with one is an obsolete line fold.
                if ($colon === false || $colon === 0 || $header[$colon - 1] === ' ' || $header[$colon - 1] === "\t" || $header[0] === ' ' || $header[0] === "\t") {
                    return false;
                }
                if ($colon === 14 && strncasecmp($header, 'content-length', 14) === 0) {
                    $value = trim(substr($header, 15), " \t");
                    // Why: two Content-Length headers, or one that is not plain digits, are how requests get smuggled.
                    if ($hasLength || !ctype_digit($value) || strlen($value) > 7 || (int) $value > self::BODY_LIMIT) {
                        return false;
                    }
                    $hasLength = true;
                    $this->bodyLength = (int) $value;
                } elseif ($colon === 10 && strncasecmp($header, 'connection', 10) === 0) {
                    $value = strtolower(substr($header, 11));
                    $close = str_contains($value, 'close');
                    $keepAlive = str_contains($value, 'keep-alive');
                } elseif ($colon === 13 && strncasecmp($header, 'authorization', 13) === 0) {
                    $this->authorization = trim(substr($header, 14), " \t");
                } elseif ($colon === 17 && strncasecmp($header, 'transfer-encoding', 17) === 0) {
                    // Chunked bodies are not supported: k6 never sends one, and the challenge's clients send Content-Length.
                    return false;
                }
            }
        }
        $this->closeAfter = $close || ($version === 'HTTP/1.0' && !$keepAlive);
        return true;
    }
}

/**
 * The rings of one process and the loop that serves them. One ring: one io_uring_enter per turn, waiting up to a second (so the statistics
 * line comes out when the server is idle). Several: the wait is on the ring that had completions in the last turn, short, and in the same
 * turn every other ring is entered when its IORING_SQ_TASKRUN flag says the kernel has work for it, or when it has SQEs queued: no ring's
 * work waits on an idle ring beyond that short wait. Why the wait is short: a ring's deferred work (a connection arriving, a receive that
 * completed) runs only inside an io_uring_enter of that ring, so what happens on another ring while the loop sleeps on one is seen when
 * its wait ends.
 */
final class RingLoop
{
    private const WAIT_NS = 500000;
    private const IDLE_WAIT_NS = 1000000000;

    /** @var list<array<string, int>> each ring's counters at the previous `ring:` line */
    private array $last = [];

    /** @param list<AppRing> $rings */
    public function __construct(public readonly FFI $ffi, public readonly FFI $ffiAddr, private readonly array $rings, private readonly RingTotals $totals)
    {
    }

    public function count(): int
    {
        return count($this->rings);
    }

    /** The `loop:` line's text, from the number of rings (`ring, 1 ring`, `ring, 3 rings`). */
    public function loopLine(): string
    {
        $n = count($this->rings);
        return "ring, $n ring" . ($n > 1 ? 's' : '');
    }

    /** The pools of a ring, for the boot line (every ring has the same ones). */
    public function describe(): string
    {
        return $this->rings[0]->describe();
    }

    public function armAccept(int $listenFd): void
    {
        foreach ($this->rings as $ring) {
            $ring->armAccept($listenFd);
        }
    }

    public function release(): void
    {
        foreach ($this->rings as $ring) {
            $ring->release();
        }
    }

    /** Serves forever. With $telemetry a `ring:` line is printed each second. */
    public function run(bool $telemetry): never
    {
        $rings = $this->rings;
        $n = count($rings);
        $active = 0;
        $next = time() + 1;
        $count = 0;
        while (true) {
            $got = $activeGot = $rings[$active]->turn($n === 1 ? self::IDLE_WAIT_NS : self::WAIT_NS);
            if ($n > 1) {
                $moved = -1;
                // Why on every ring: a ring arms accepts when the one before it is full, which this turn may have just made so.
                foreach ($rings as $ring) {
                    $ring->topUpAccepts();
                }
                for ($i = 0; $i < $n; $i++) {
                    if ($i === $active || !($rings[$i]->hasWork() || $rings[$i]->hasQueued())) {
                        continue;
                    }
                    // Why a loop: a turn that handled completions queued more SQEs, which only the next enter of that ring submits.
                    do {
                        $more = $rings[$i]->turn(0);
                        if ($more) {
                            $moved = $i;
                        }
                    } while ($more);
                }
                if ($moved >= 0) {
                    $got = true;
                    // The ring to block on next: the one that had completions; the same one when it still does.
                    if (!$activeGot) {
                        $active = $moved;
                    }
                }
            }
            if ($telemetry && (!$got || (++$count & 63) === 0) && time() >= $next) {
                $next = time() + 1;
                if (($line = $this->statsLine()) !== null) {
                    echo $line, "\n";
                }
            }
        }
    }

    /**
     * One `ring:` line: what the loop did since the last one, all rings added (`open` and `slots_in_use` are the values now). Requests per turn is
     * the number the ring's cost per request depends on. With several rings each one's open connections, turns and requests per turn follow
     * (`ring0_open=`...). Null when nothing happened.
     */
    public function statsLine(): ?string
    {
        $d = [];
        $perRing = [];
        foreach ($this->rings as $i => $ring) {
            $now = $ring->counters();
            foreach ($now as $k => $v) {
                $diff = $v - ($this->last[$i][$k] ?? 0);
                $perRing[$i][$k] = $diff;
                $d[$k] = ($d[$k] ?? 0) + $diff;
            }
            $this->last[$i] = $now;
        }
        if ($d['turns'] === 0 && $d['accepted'] === 0) {
            return null;
        }
        $slots = 0;
        foreach ($this->rings as $ring) {
            $slots += $ring->slotsInUse();
        }
        $busy = $d['requests'] > 0 ? $d['turns'] : 0;
        $line = sprintf('ring: turns=%d requests=%d cqes=%d flushes=%d accepted=%d open=%d accept_pauses=%d short_sends=%d big_sends=%d send_waits=%d recv_dry=%d stalls=%d limit_closes=%d slots_in_use=%d requests_per_turn=%s cqes_per_turn=%s',
            $d['turns'], $d['requests'], $d['cqes'], $d['flushes'], $d['accepted'], $this->totals->open, $d['accept_pauses'], $d['short_sends'], $d['big_sends'],
            $d['send_waits'], $d['recv_dry'], $d['stalls'], $d['limit_closes'], $slots,
            $busy > 0 ? sprintf('%.2f', $d['requests'] / $busy) : 'n/a', $d['turns'] > 0 ? sprintf('%.2f', $d['cqes'] / $d['turns']) : 'n/a');
        if (count($this->rings) > 1) {
            foreach ($this->rings as $i => $ring) {
                $r = $perRing[$i];
                $line .= sprintf(' ring%d_open=%d ring%d_turns=%d ring%d_requests=%d ring%d_requests_per_turn=%s', $i, $ring->open, $i, $r['turns'], $i, $r['requests'], $i,
                    $r['requests'] > 0 && $r['turns'] > 0 ? sprintf('%.2f', $r['requests'] / $r['turns']) : 'n/a');
            }
        }
        return $line;
    }
}

/** The listening socket as a plain descriptor (the ring accepts from it): non-blocking, TCP_NODELAY (inherited by what it accepts). */
function ring_listen(FFI $ffi, string $address, int $port, int $backlog): int
{
    // AF_INET 2, SOCK_STREAM 1 | SOCK_NONBLOCK 0x800 | SOCK_CLOEXEC 0x80000.
    $fd = $ffi->socket(2, 1 | 0x800 | 0x80000, 0);
    if ($fd < 0) {
        fwrite(STDERR, "ring-server: socket() failed\n");
        exit(1);
    }
    $one = $ffi->new('int');
    $one->cdata = 1;
    // SOL_SOCKET 1 / SO_REUSEADDR 2; IPPROTO_TCP 6 / TCP_NODELAY 1.
    $ffi->setsockopt($fd, 1, 2, FFI::addr($one), 4);
    $ffi->setsockopt($fd, 6, 1, FFI::addr($one), 4);
    $addr = $ffi->new('char[16]');
    $ip = ip2long($address);
    if ($ip === false) {
        fwrite(STDERR, "ring-server: HOST must be an IPv4 address, got '$address'\n");
        exit(1);
    }
    $packed = pack('vnN', 2, $port, $ip) . str_repeat("\0", 8);
    FFI::memcpy($addr, $packed, 16);
    if ($ffi->bind($fd, $addr, 16) !== 0 || $ffi->listen($fd, $backlog) !== 0) {
        fwrite(STDERR, "ring-server: cannot listen on $address:$port\n");
        exit(1);
    }
    return $fd;
}

/** A whole number from the environment between $min and $max, or $default when it is unset; exits with a message when it is out of range. */
function ring_env_int(string $name, int $default, int $min, int $max): int
{
    $value = getenv($name);
    if ($value === false || $value === '') {
        return $default;
    }
    if (!ctype_digit($value) || (int) $value < $min || (int) $value > $max) {
        fwrite(STDERR, "ring-server: $name must be a whole number from $min to $max, got '$value'\n");
        exit(1);
    }
    return (int) $value;
}

/**
 * Builds the rings: the whole of the boot that asks the kernel for something (setup with its flags, the table of direct descriptors, the buffer
 * ring, for every ring). Nothing listens yet. A step the kernel refuses throws RingRefused, with every ring built so far given back.
 * Test hook URING_FAIL_STEP=files|buffer_ring: that step asks the kernel for something it refuses, on the last ring (the ones before it
 * were built, so the give-back is exercised).
 *
 * @param ?int $softLimit see AppRing's `soft_limit`; it counts the open connections of all the rings together
 * @throws RingRefused
 */
function ring_open(int $count, ?int $softLimit): RingLoop
{
    $recvBuffers = ring_env_int('URING_RECV_BUFFERS', 4096, 2, 32768);
    if (($recvBuffers & ($recvBuffers - 1)) !== 0) {
        fwrite(STDERR, "ring-server: URING_RECV_BUFFERS must be a power of two, got $recvBuffers\n");
        exit(1);
    }
    $sendSlots = ring_env_int('URING_SEND_SLOTS', 2048, 1, 8192);
    $tableSize = ring_env_int('URING_TABLE_SIZE', 65535, 32, 65535);
    $failStep = getenv('URING_FAIL_STEP');
    if ($failStep === false || $failStep === '') {
        $failStep = null;
    } elseif (!in_array($failStep, ['files', 'buffer_ring'], true)) {
        fwrite(STDERR, "ring-server: URING_FAIL_STEP must be files or buffer_ring, got '$failStep'\n");
        exit(1);
    }
    $ffi = FFI::cdef(file_get_contents(__DIR__ . '/ring-server.h'), 'libc.so.6');
    $ffiAddr = FFI::cdef("intptr_t mmap(void *addr, size_t length, int prot, int flags, int fd, long offset);\nint munmap(intptr_t addr, size_t length);", 'libc.so.6');
    foreach (['sqe_t' => 64, 'params_t' => 120, 'rsrc_register_t' => 32, 'buf_reg_t' => 40, 'buf_t' => 16, 'getevents_arg_t' => 24, 'timespec_t' => 16] as $type => $size) {
        if (FFI::sizeof($ffi->type($type)) !== $size) {
            fwrite(STDERR, "ring-server: $type is " . FFI::sizeof($ffi->type($type)) . " bytes, the kernel's is $size\n");
            exit(1);
        }
    }
    $totals = new RingTotals();
    $rings = [];
    try {
        for ($i = 0; $i < $count; $i++) {
            $rings[] = new AppRing($ffi, $ffiAddr, 'ring' . $i, $totals, ['recv_buffers' => $recvBuffers, 'send_slots' => $sendSlots, 'table_size' => $tableSize,
                'soft_limit' => $softLimit, 'fail_step' => $i === $count - 1 ? $failStep : null, 'previous' => $rings[$i - 1] ?? null]);
        }
    } catch (RingRefused $e) {
        foreach ($rings as $built) {
            $built->release();
        }
        throw $e;
    } catch (RuntimeException $e) {
        fwrite(STDERR, 'ring-server: ' . $e->getMessage() . "\n");
        exit(1);
    }
    return new RingLoop($ffi, $ffiAddr, $rings, $totals);
}

/** ring_open() for a caller with no other loop to fall back to: a refusal ends the process with its message. */
function ring_open_or_exit(int $count, ?int $softLimit): RingLoop
{
    try {
        return ring_open($count, $softLimit);
    } catch (RingRefused $e) {
        fwrite(STDERR, "ring-server: io_uring refused: {$e->getMessage()} (errno 1 is Docker's seccomp filter: run the container with --seccomp-unconfined)\n");
        exit(1);
    }
}

/**
 * Listens and runs the rings on the global handler_handle(): never returns. Prints the boot lines the lab's scripts read: `listening on`,
 * `loop: ring, <n> ring(s)`, `ring-settings:` (the pools) and `socket:`. $afterListening is called once the rings are up, to print what the
 * caller adds (the app's soft limit and variants); the boot lines the harnesses wait on come last.
 *
 * @param ?Closure(): void $afterListening called between the listening line and the loop line
 */
function ring_serve(RingLoop $loop, string $host, int $port, bool $telemetry, ?Closure $afterListening = null): never
{
    $backlog = 4096;
    $listenFd = ring_listen($loop->ffi, $host, $port, $backlog);
    $loop->armAccept($listenFd);
    echo "listening on $host:$port\n";
    if ($afterListening !== null) {
        $afterListening();
    }
    echo 'loop: ' . $loop->loopLine() . "\n";
    echo 'ring-settings: ' . $loop->describe() . "\n";
    echo "socket: backlog=$backlog tcp_nodelay=1\n";
    $loop->run($telemetry);
}
