// Diagnostic probe (not part of the lab): does this kernel accept IORING_REGISTER_PBUF_RING from liburing?
#include <liburing.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <sys/utsname.h>

int main(void) {
    struct utsname u; uname(&u); printf("kernel %s\n", u.release);
    struct io_uring ring;
    int r = io_uring_queue_init(8, &ring, 0);
    printf("queue_init: %d\n", r);
    if (r < 0) return 1;
    int ret = 0;
    struct io_uring_buf_ring *br = io_uring_setup_buf_ring(&ring, 8, 0, 0, &ret);
    printf("io_uring_setup_buf_ring (liburing %d.%d): %s, ret=%d (%s)\n", IO_URING_VERSION_MAJOR, IO_URING_VERSION_MINOR, br ? "ok" : "NULL", ret, ret < 0 ? strerror(-ret) : "ok");
    void *mem; posix_memalign(&mem, 4096, 4096);
    memset(mem, 0, 4096);
    struct io_uring_buf_reg reg; memset(&reg, 0, sizeof(reg));
    reg.ring_addr = (unsigned long)mem; reg.ring_entries = 8; reg.bgid = 5;
    ret = io_uring_register_buf_ring(&ring, &reg, 0);
    printf("io_uring_register_buf_ring (aligned memalign, bgid 5): ret=%d (%s)\n", ret, ret < 0 ? strerror(-ret) : "ok");
    printf("sizeof(io_uring_buf_reg)=%zu\n", sizeof(reg));
    return 0;
}
