/*
 * The C declarations of lab/servers/ring-server.php, given to FFI::cdef() (libc.so.6 is the library): the kernel's io_uring
 * structures (include/uapi/linux/io_uring.h, the same on x86_64 and aarch64) and the few libc functions the server calls.
 * Only the types and prototypes below exist: no C code is compiled. (mmap and munmap are declared in the server file, with integers
 * for addresses.) A copy of lab/servers/uring-noop.h, which the spike's results cite and which stays as it is.
 *
 * The sizes are checked at boot (sqe_t 64, params_t 120, ...), so a wrong field shows at once.
 */

/* io_uring_sqe, 64 bytes. file_index shares its place with splice_fd_in; off holds addr2 for an accept. */
typedef struct {
    uint8_t opcode;
    uint8_t flags;
    uint16_t ioprio;
    int32_t fd;
    uint64_t off;
    uint64_t addr;
    uint32_t len;
    uint32_t op_flags;
    uint64_t user_data;
    uint16_t buf_index;
    uint16_t personality;
    uint32_t file_index;
    uint64_t addr3;
    uint64_t pad2;
} sqe_t;

/* io_uring_params, 120 bytes, with the two offset blocks of io_sqring_offsets and io_cqring_offsets (40 bytes each). */
typedef struct {
    uint32_t head;
    uint32_t tail;
    uint32_t ring_mask;
    uint32_t ring_entries;
    uint32_t flags;
    uint32_t dropped;
    uint32_t array;
    uint32_t resv1;
    uint64_t user_addr;
} sq_off_t;

typedef struct {
    uint32_t head;
    uint32_t tail;
    uint32_t ring_mask;
    uint32_t ring_entries;
    uint32_t overflow;
    uint32_t cqes;
    uint32_t flags;
    uint32_t resv1;
    uint64_t user_addr;
} cq_off_t;

typedef struct {
    uint32_t sq_entries;
    uint32_t cq_entries;
    uint32_t flags;
    uint32_t sq_thread_cpu;
    uint32_t sq_thread_idle;
    uint32_t features;
    uint32_t wq_fd;
    uint32_t resv[3];
    sq_off_t sq_off;
    cq_off_t cq_off;
} params_t;

/* io_uring_rsrc_register, 32 bytes: the sparse table of direct descriptors. */
typedef struct {
    uint32_t nr;
    uint32_t flags;
    uint64_t resv2;
    uint64_t data;
    uint64_t tags;
} rsrc_register_t;

/* io_uring_buf_reg, 40 bytes: the provided buffer ring. */
typedef struct {
    uint64_t ring_addr;
    uint32_t ring_entries;
    uint16_t bgid;
    uint16_t flags;
    uint64_t resv[3];
} buf_reg_t;

/* io_uring_buf, 16 bytes: one entry of the provided buffer ring (the ring's tail lives in the first entry's last two bytes). */
typedef struct {
    uint64_t addr;
    uint32_t len;
    uint16_t bid;
    uint16_t resv;
} buf_t;

/* io_uring_getevents_arg (24 bytes) and the __kernel_timespec it points to: a wait with a timeout. The kernel of the bench (6.8)
 * wants `pad` to be 0: it is never written (kernel 6.12 reads min_wait_usec there, a batching knob this server does not use). */
typedef struct {
    uint64_t sigmask;
    uint32_t sigmask_sz;
    uint32_t pad;
    uint64_t ts;
} getevents_arg_t;

typedef struct {
    int64_t tv_sec;
    int64_t tv_nsec;
} timespec_t;

typedef struct {
    uint64_t cur;
    uint64_t max;
} rlimit_t;

long syscall(long number, ...);
int socket(int domain, int type, int protocol);
int setsockopt(int fd, int level, int optname, const void *optval, uint32_t optlen);
int bind(int fd, const void *addr, uint32_t addrlen);
int listen(int fd, int backlog);
int getrlimit(int resource, rlimit_t *rlim);
int *__errno_location(void);
