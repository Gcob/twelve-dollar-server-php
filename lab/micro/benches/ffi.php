<?php
// What an io_uring event loop written in PHP, through PHP's FFI, would do per request, priced one operation at a time,
// next to what it would replace (the socket reads and writes of PHP's streams). Format: "Micro benchmarks" in lab/README.md.
//
// The loop this prices: one io_uring_enter per turn, submissions (SQEs, 64 bytes) packed with pack() into one string and
// copied into the ring with one FFI::memcpy, completions (CQEs, 16 bytes) read with one FFI::string and unpack().
//
// ffi.enable stays at the CLI's default, preload: it allows FFI in CLI scripts, so FFI::cdef works without a flag.
//
// The numbers of the batch cases are per batch of 32, divide by 32 for one SQE or CQE. Each run closure also fetches its
// context from an array (a few ns, inside every number).

// The layouts are the kernel's include/uapi/linux/io_uring.h, which do not change between kernel versions and are the same on
// x86_64 and aarch64 (both little-endian: pack's l, v, V and P are the host's byte order, which is the kernel's).
//
// struct io_uring_sqe, 64 bytes:   off  size
//   u8  opcode                        0   1
//   u8  flags                         1   1
//   u16 ioprio                        2   2
//   s32 fd                            4   4
//   u64 off (or addr2)                8   8
//   u64 addr (or splice_off_in)      16   8
//   u32 len                          24   4
//   u32 op flags (msg_flags, ...)    28   4
//   u64 user_data                    32   8
//   u16 buf_index (or buf_group)     40   2
//   u16 personality                  42   2
//   u32 splice_fd_in (or file_index) 44   4
//   u64 addr3                        48   8
//   u64 pad2[1]                      56   8
// struct io_uring_cqe, 16 bytes: u64 user_data at 0, s32 res at 8, u32 flags at 12.
const FFI_BENCH_SQE_FORMAT = 'CCvlPPVVPvvVPP';
const FFI_BENCH_CQE_FORMAT = 'Pud/lres/Vfl';
const FFI_BENCH_CDEF = '
    typedef struct { uint8_t opcode; uint8_t flags; uint16_t ioprio; int32_t fd; uint64_t off; uint64_t addr;
                     uint32_t len; uint32_t op_flags; uint64_t user_data; uint16_t buf_index; uint16_t personality;
                     uint32_t splice_fd_in; uint64_t addr3; uint64_t pad2; } sqe_t;
    typedef struct { uint64_t user_data; int32_t res; uint32_t flags; } cqe_t;
    long syscall(long number, ...);
    void *malloc(size_t size);
    void *memset(void *s, int c, size_t n);
';

// getpid is 39 on x86_64 and 172 on aarch64.
define('FFI_BENCH_SYS_GETPID', match (php_uname('m')) {
    'x86_64' => 39,
    'aarch64' => 172,
    default => throw new RuntimeException('no getpid syscall number for ' . php_uname('m')),
});

/** An SQE written down by hand, field by field (SEND, fd 7, 200 bytes, MSG_NOSIGNAL), as the kernel reads it. */
function ffi_bench_sqe_bytes(int $userData = 0x0102030405060708): string
{
    return hex2bin(implode('', [
        '1a', '00', '0000',         // opcode 26 (IORING_OP_SEND), flags, ioprio
        '07000000',                 // fd 7
        '0000000000000000',         // off
        '8877665544332211',         // addr 0x1122334455667788
        'c8000000',                 // len 200
        '00400000',                 // op flags 0x4000 (MSG_NOSIGNAL)
        bin2hex(ffi_bench_le64($userData)),
        '0000', '0000', '00000000', // buf_index, personality, splice_fd_in
        '0000000000000000',         // addr3
        '0000000000000000',         // pad2
    ]));
}

/** Little-endian 64 bits written byte by byte, independent of pack(). */
function ffi_bench_le64(int $v): string
{
    $bytes = '';
    for ($i = 0; $i < 8; $i++) {
        $bytes .= chr(($v >> (8 * $i)) & 0xff);
    }
    return $bytes;
}

/** $n bytes that do not repeat within the sizes used here, so a copy from the wrong offset shows. */
function ffi_bench_payload(int $n): string
{
    $s = '';
    for ($i = 0; $i < $n; $i++) {
        $s .= chr(($i * 7 + intdiv($i, 251)) % 256);
    }
    return $s;
}

/**
 * One FFI object for the whole process, kept alive on purpose: a CData made from an FFI object that has been freed has a
 * dangling type, and reads and writes on it fail with "over data boundary" or "non C struct" errors.
 */
function ffi_bench_ffi(): FFI
{
    static $ffi = null;
    if ($ffi === null) {
        $ffi = FFI::cdef(FFI_BENCH_CDEF, 'libc.so.6');
        if (FFI::sizeof($ffi->type('sqe_t')) !== 64 || FFI::sizeof($ffi->type('cqe_t')) !== 16) {
            throw new LogicException('the struct declarations are not 64 and 16 bytes');
        }
    }
    return $ffi;
}

/** A zeroed C buffer from malloc: a void* like the one mmap gives for a ring. */
function ffi_bench_buffer(FFI $ffi, int $size): FFI\CData
{
    $buffer = $ffi->malloc($size);
    $ffi->memset($buffer, 0, $size);
    return $buffer;
}

/** The same 32 submissions two ways write the same bytes: user_data goes up by one each. */
function ffi_bench_expected_sqes(int $count, int $firstUserData): string
{
    $expected = '';
    for ($i = 0; $i < $count; $i++) {
        $expected .= ffi_bench_sqe_bytes($firstUserData + $i);
    }
    return $expected;
}

/** A pair of connected non-blocking streams, and the one the bench writes to first. */
function ffi_bench_unix_pair(): array
{
    $pair = stream_socket_pair(STREAM_PF_UNIX, STREAM_SOCK_STREAM, STREAM_IPPROTO_IP);
    stream_set_blocking($pair[0], false);
    stream_set_blocking($pair[1], false);
    return $pair;
}

/** The same over TCP on loopback, the transport the server really uses (the kernel does more work per send and receive). */
function ffi_bench_tcp_pair(): array
{
    $server = stream_socket_server('tcp://127.0.0.1:0', $errno, $error);
    if ($server === false) {
        throw new RuntimeException("no loopback listener: $error");
    }
    // Why tcp_nodelay: without it a small write after an unanswered one can wait for the first one's ack.
    $client = stream_socket_client('tcp://' . stream_socket_get_name($server, false), $errno, $error, 5, STREAM_CLIENT_CONNECT,
        stream_context_create(['socket' => ['tcp_nodelay' => true]]));
    $accepted = stream_socket_accept($server, 5);
    if ($client === false || $accepted === false) {
        throw new RuntimeException('the loopback pair did not connect');
    }
    stream_set_blocking($client, false);
    stream_set_blocking($accepted, false);
    return [$client, $accepted, $server];
}

/** A write then a read of $bytes on the pair, like one request's send and receive; the read asks for 8192 like the server's. */
function ffi_bench_socket_case(Closure $pair, int $bytes): array
{
    return [
        // The streams stay in the context: a stream that is dropped is closed.
        'setup' => static fn() => [$pair(), ffi_bench_payload($bytes)],
        'run' => static function (array $c) {
            fwrite($c[0][0], $c[1]);
            return fread($c[0][1], 8192);
        },
        'check' => static fn($result, array $c) => $result === $c[1] ?: 'the read did not return what was written',
    ];
}

function ffi_bench_eagain_case(Closure $pair): array
{
    return [
        'setup' => static fn() => $pair(),
        'run' => static fn(array $streams) => fread($streams[1], 8192),
        'check' => static fn($result) => $result === '' ?: 'a read with nothing to read returned ' . var_export($result, true),
    ];
}

function ffi_bench_memcpy_case(int $bytes): array
{
    return [
        'setup' => static fn() => [ffi_bench_buffer($ffi = ffi_bench_ffi(), 8192), ffi_bench_payload($bytes), $ffi],
        'run' => static function (array $c) use ($bytes) {
            FFI::memcpy($c[0], $c[1], $bytes);
        },
        'check' => static fn($result, array $c) => FFI::string($c[0], $bytes) === $c[1] ?: 'the buffer does not hold the string',
    ];
}

function ffi_bench_string_case(int $bytes): array
{
    return [
        'setup' => static function () use ($bytes) {
            $buffer = ffi_bench_buffer(ffi_bench_ffi(), 8192);
            $payload = ffi_bench_payload($bytes);
            FFI::memcpy($buffer, $payload, $bytes);
            return [$buffer, $payload];
        },
        'run' => static fn(array $c) => FFI::string($c[0], $bytes),
        'check' => static fn($result, array $c) => $result === $c[1] ?: 'FFI::string did not return the buffer',
    ];
}

/** One CQE through the struct, for the batch cases: user_data first + i, res 3 i - 5, flags i & 3. */
function ffi_bench_fill_cqes(FFI $ffi, FFI\CData $buffer, int $count, int $firstUserData): void
{
    $cqes = $ffi->cast('cqe_t*', $buffer);
    for ($i = 0; $i < $count; $i++) {
        $cqes[$i]->user_data = $firstUserData + $i;
        $cqes[$i]->res = 3 * $i - 5;
        $cqes[$i]->flags = $i & 3;
    }
}

function ffi_bench_cqe_batch_setup(): array
{
    $ffi = ffi_bench_ffi();
    $buffer = ffi_bench_buffer($ffi, 8192);
    ffi_bench_fill_cqes($ffi, $buffer, 32, 1_000_000);
    $format = '';
    for ($i = 0; $i < 32; $i++) {
        $format .= "Pud$i/lres$i/Vfl$i" . ($i < 31 ? '/' : '');
    }
    return [$buffer, $format];
}

$sqeFields = static function (FFI\CData $sqe): void {
    $sqe->opcode = 26;
    $sqe->fd = 7;
    $sqe->addr = 0x1122334455667788;
    $sqe->len = 200;
    $sqe->op_flags = 0x4000;
    $sqe->user_data = 0x0102030405060708;
};

return [
    // 1. One FFI call that enters the kernel, against the native call that does the same.
    'syscall/getmypid() native' => [
        'run' => static fn() => getmypid(),
        'check' => static fn($result) => $result === (int)readlink('/proc/self') ?: "got $result, /proc/self says " . readlink('/proc/self'),
    ],
    'syscall/FFI syscall(getpid), 1 argument' => [
        'setup' => static fn() => ffi_bench_ffi(),
        'run' => static fn(FFI $ffi) => $ffi->syscall(FFI_BENCH_SYS_GETPID),
        'check' => static fn($result) => $result === (int)readlink('/proc/self') ?: "got $result, /proc/self says " . readlink('/proc/self'),
    ],
    // io_uring_enter takes six arguments: the call is the same shape, so its argument conversion is priced too.
    'syscall/FFI syscall(getpid), 6 arguments' => [
        'setup' => static fn() => ffi_bench_ffi(),
        'run' => static fn(FFI $ffi) => $ffi->syscall(FFI_BENCH_SYS_GETPID, 3, 1, 0, 8, 0, 0),
        'check' => static fn($result) => $result === (int)readlink('/proc/self') ?: "got $result, /proc/self says " . readlink('/proc/self'),
    ],

    // 2. A field of a C struct shaped like an SQE.
    'cdata/write one u64 field of an SQE' => [
        'setup' => static fn() => ffi_bench_ffi()->new('sqe_t'),
        'run' => static fn(FFI\CData $sqe) => $sqe->user_data = 0x0102030405060708,
        'check' => static fn($result, FFI\CData $sqe) => $sqe->user_data === 0x0102030405060708 ?: 'the field does not hold the value',
    ],
    'cdata/read one u64 field of an SQE' => [
        'setup' => static function () {
            $sqe = ffi_bench_ffi()->new('sqe_t');
            $sqe->user_data = 0x0102030405060708;
            return $sqe;
        },
        'run' => static fn(FFI\CData $sqe) => $sqe->user_data,
        'check' => static fn($result) => $result === 0x0102030405060708 ?: "read $result",
    ],
    // The 6 fields a send sets; the bytes must be the ones pack() writes in the pack cases below.
    'cdata/write the 6 fields of a send SQE' => [
        'setup' => static fn() => ffi_bench_ffi()->new('sqe_t'),
        'run' => static function (FFI\CData $sqe) use ($sqeFields) {
            $sqeFields($sqe);
        },
        'check' => static fn($result, FFI\CData $sqe) => FFI::string(FFI::addr($sqe), 64) === ffi_bench_sqe_bytes() ?: 'the struct does not hold the SQE bytes',
    ],
    // The other way to submit: every field of the SQE written in place in the ring (a stale field from the slot's last use
    // would be read by the kernel, so all 14 are written, not only the 6 a send needs). Compare with pack + memcpy below.
    'cdata/write all 14 fields of an SQE in the ring (sqes[i])' => [
        'setup' => static function () {
            $ffi = ffi_bench_ffi();
            $buffer = ffi_bench_buffer($ffi, 8192);
            return [$ffi->cast('sqe_t*', $buffer), $buffer];
        },
        'run' => static function (array $c) {
            $sqe = $c[0][5];
            $sqe->opcode = 26;
            $sqe->flags = 0;
            $sqe->ioprio = 0;
            $sqe->fd = 7;
            $sqe->off = 0;
            $sqe->addr = 0x1122334455667788;
            $sqe->len = 200;
            $sqe->op_flags = 0x4000;
            $sqe->user_data = 0x0102030405060708;
            $sqe->buf_index = 0;
            $sqe->personality = 0;
            $sqe->splice_fd_in = 0;
            $sqe->addr3 = 0;
            $sqe->pad2 = 0;
        },
        'check' => static fn($result, array $c) => FFI::string($c[1], 8192) === str_repeat("\0", 5 * 64) . ffi_bench_sqe_bytes() . str_repeat("\0", 8192 - 6 * 64)
            ?: 'the ring does not hold the SQE at slot 5 only',
    ],
    // The ring's head and tail words: a u32 through a pointer, no struct.
    'cdata/write a u32 through a pointer (ring tail)' => [
        'setup' => static function () {
            $ffi = ffi_bench_ffi();
            return $ffi->cast('uint32_t*', ffi_bench_buffer($ffi, 64));
        },
        'run' => static fn(FFI\CData $tail) => $tail[3] = 123456,
        'check' => static fn($result, FFI\CData $tail) => $tail[3] === 123456 && $tail[2] === 0 ?: 'the word is not at index 3 only',
    ],
    'cdata/read a u32 through a pointer (ring tail)' => [
        'setup' => static function () {
            $ffi = ffi_bench_ffi();
            $tail = $ffi->cast('uint32_t*', ffi_bench_buffer($ffi, 64));
            $tail[3] = 123456;
            return $tail;
        },
        'run' => static fn(FFI\CData $tail) => $tail[3],
        'check' => static fn($result) => $result === 123456 ?: "read $result",
    ],

    // 3. A PHP string copied into a preallocated C buffer.
    'memcpy/64 B (one SQE)' => ffi_bench_memcpy_case(64),
    'memcpy/200 B (a post)' => ffi_bench_memcpy_case(200),
    'memcpy/5 KB (a feed)' => ffi_bench_memcpy_case(5120),
    // The destination of a real copy is the ring base plus an offset: pointer arithmetic makes one more CData per call.
    'memcpy/64 B at a pointer + offset' => [
        'setup' => static function () {
            $ffi = ffi_bench_ffi();
            $buffer = ffi_bench_buffer($ffi, 8192);
            return [$buffer, $ffi->cast('char*', $buffer), ffi_bench_payload(64)];
        },
        'run' => static function (array $c) {
            FFI::memcpy($c[1] + 128, $c[2], 64);
        },
        'check' => static fn($result, array $c) => FFI::string($c[0], 192) === str_repeat("\0", 128) . $c[2] ?: 'the bytes are not at offset 128',
    ],

    // 4. A C buffer read into a PHP string.
    'string/16 B (one CQE)' => ffi_bench_string_case(16),
    'string/200 B (a request)' => ffi_bench_string_case(200),
    'string/5 KB' => ffi_bench_string_case(5120),

    // 5. The ring's two formats, through pack() and unpack().
    'pack/one 64-byte SQE' => [
        'setup' => static fn() => [7, 0x1122334455667788, 200, 0x0102030405060708],
        'run' => static fn(array $c) => pack(FFI_BENCH_SQE_FORMAT, 26, 0, 0, $c[0], 0, $c[1], $c[2], 0x4000, $c[3], 0, 0, 0, 0, 0),
        'check' => static fn($result) => $result === ffi_bench_sqe_bytes() ?: 'pack() wrote ' . bin2hex($result),
    ],
    'unpack/one 16-byte CQE' => [
        // user_data 0x0102030405060708, res -11 (EAGAIN), flags 2
        'setup' => static fn() => hex2bin('0807060504030201' . 'f5ffffff' . '02000000'),
        'run' => static fn(string $cqe) => unpack(FFI_BENCH_CQE_FORMAT, $cqe),
        'check' => static fn($result) => $result === ['ud' => 0x0102030405060708, 'res' => -11, 'fl' => 2] ?: 'unpack() gave ' . json_encode($result),
    ],

    // 6. A batch of 32. Submissions: packed into one string, one memcpy into the ring.
    'batch/32 SQEs: pack() in a loop, one memcpy' => [
        'setup' => static function () {
            $ffi = ffi_bench_ffi();
            return [ffi_bench_buffer($ffi, 8192), 1_000_000];
        },
        'run' => static function (array $c) {
            $sqes = '';
            for ($i = 0; $i < 32; $i++) {
                $sqes .= pack(FFI_BENCH_SQE_FORMAT, 26, 0, 0, 7, 0, 0x1122334455667788, 200, 0x4000, $c[1] + $i, 0, 0, 0, 0, 0);
            }
            FFI::memcpy($c[0], $sqes, 2048);
        },
        'check' => static fn($result, array $c) => FFI::string($c[0], 2048) === ffi_bench_expected_sqes(32, $c[1]) ?: 'the ring does not hold the 32 SQEs',
    ],
    'batch/32 SQEs: one pack() of 32, one memcpy' => [
        'setup' => static function () {
            $ffi = ffi_bench_ffi();
            return [ffi_bench_buffer($ffi, 8192), 1_000_000, str_repeat(FFI_BENCH_SQE_FORMAT, 32)];
        },
        'run' => static function (array $c) {
            $args = [];
            for ($i = 0; $i < 32; $i++) {
                array_push($args, 26, 0, 0, 7, 0, 0x1122334455667788, 200, 0x4000, $c[1] + $i, 0, 0, 0, 0, 0);
            }
            FFI::memcpy($c[0], pack($c[2], ...$args), 2048);
        },
        'check' => static fn($result, array $c) => FFI::string($c[0], 2048) === ffi_bench_expected_sqes(32, $c[1]) ?: 'the ring does not hold the 32 SQEs',
    ],
    // Completions: one FFI::string, then one unpack() with 96 named fields or 32 unpack() with an offset.
    'batch/32 CQEs: one FFI::string, one unpack()' => [
        'setup' => static fn() => ffi_bench_cqe_batch_setup(),
        'run' => static fn(array $c) => unpack($c[1], FFI::string($c[0], 512)),
        'check' => static function (array $result) {
            for ($i = 0; $i < 32; $i++) {
                if (($result["ud$i"] ?? null) !== 1_000_000 + $i || ($result["res$i"] ?? null) !== 3 * $i - 5 || ($result["fl$i"] ?? null) !== ($i & 3)) {
                    return "CQE $i is wrong: " . json_encode([$result["ud$i"] ?? null, $result["res$i"] ?? null, $result["fl$i"] ?? null]);
                }
            }
            return count($result) === 96 ?: 'the result has ' . count($result) . ' fields, not 96';
        },
    ],
    'batch/32 CQEs: one FFI::string, 32 unpack() with an offset' => [
        'setup' => static fn() => ffi_bench_cqe_batch_setup(),
        'run' => static function (array $c) {
            $raw = FFI::string($c[0], 512);
            $cqes = [];
            for ($i = 0; $i < 32; $i++) {
                $cqes[] = unpack(FFI_BENCH_CQE_FORMAT, $raw, $i * 16);
            }
            return $cqes;
        },
        'check' => static function (array $result) {
            for ($i = 0; $i < 32; $i++) {
                if (($result[$i] ?? null) !== ['ud' => 1_000_000 + $i, 'res' => 3 * $i - 5, 'fl' => $i & 3]) {
                    return "CQE $i is wrong: " . json_encode($result[$i] ?? null);
                }
            }
            return count($result) === 32 ?: 'the result has ' . count($result) . ' CQEs, not 32';
        },
    ],

    // 7. What it would remove: PHP's own socket calls (each one includes its syscall). A write then a read is one request's
    // send and receive. The unix pair is the cheapest transport (a floor for what the kernel does inside the call);
    // loopback TCP is what the server uses.
    'socket/fwrite + fread 200 B, unix pair' => ffi_bench_socket_case(ffi_bench_unix_pair(...), 200),
    'socket/fwrite + fread 5 KB, unix pair' => ffi_bench_socket_case(ffi_bench_unix_pair(...), 5120),
    'socket/fread with nothing to read (EAGAIN), unix pair' => ffi_bench_eagain_case(ffi_bench_unix_pair(...)),
    'socket/fwrite + fread 200 B, tcp loopback' => ffi_bench_socket_case(ffi_bench_tcp_pair(...), 200),
    'socket/fwrite + fread 5 KB, tcp loopback' => ffi_bench_socket_case(ffi_bench_tcp_pair(...), 5120),
    'socket/fread with nothing to read (EAGAIN), tcp loopback' => ffi_bench_eagain_case(ffi_bench_tcp_pair(...)),
];
