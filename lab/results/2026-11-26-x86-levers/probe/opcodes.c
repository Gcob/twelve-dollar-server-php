// Diagnostic probe (not part of the lab): which io_uring_register opcodes does this kernel know? An unknown opcode answers EINVAL; a known
// one with an absent buffer group answers ENOENT. Build: gcc -O2 -o opcodes opcodes.c -luring
#include <liburing.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/syscall.h>
#include <sys/utsname.h>

static void try(int fd, const char *name, unsigned op, void *arg, unsigned n) {
    long r = syscall(__NR_io_uring_register, fd, op, arg, n);
    printf("%-28s opcode %2u: ret=%ld errno=%d (%s)\n", name, op, r, r < 0 ? errno : 0, r < 0 ? strerror(errno) : "ok");
}

int main(void) {
    struct utsname u; uname(&u); printf("kernel %s\n", u.release);
    struct io_uring ring;
    if (io_uring_queue_init(8, &ring, 0) < 0) return 1;
    int fd = ring.ring_fd;
    struct io_uring_buf_reg reg; memset(&reg, 0, sizeof reg);
    reg.bgid = 99;
    try(fd, "UNREGISTER_PBUF_RING (absent)", IORING_UNREGISTER_PBUF_RING, &reg, 1);
    unsigned long status[10]; memset(status, 0, sizeof status); status[0] = 99;
    try(fd, "PBUF_STATUS (absent)", 26, status, 1);
    struct io_uring_file_index_range fr; memset(&fr, 0, sizeof fr);
    try(fd, "FILE_ALLOC_RANGE", IORING_REGISTER_FILE_ALLOC_RANGE, &fr, 0);
    try(fd, "REGISTER_PERSONALITY(NULL)", IORING_REGISTER_PERSONALITY, NULL, 0);
    try(fd, "an opcode far out of range", 200, &reg, 1);
    return 0;
}
