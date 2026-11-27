// Diagnostic probe (not part of the lab): the older buffer path. IORING_OP_PROVIDE_BUFFERS (bgid 1, 8 buffers of 4 KiB), then a multishot
// receive with IOSQE_BUFFER_SELECT on a socketpair: one write of 100 bytes must come back as a CQE with IORING_CQE_F_BUFFER and
// IORING_CQE_F_MORE. Build: gcc -O2 -o provide provide.c -luring
#include <liburing.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/utsname.h>

static char bufs[8][4096];

int main(void) {
    struct utsname u; uname(&u); printf("kernel %s\n", u.release);
    struct io_uring ring;
    int r = io_uring_queue_init(8, &ring, 0);
    printf("queue_init: %d\n", r);
    if (r < 0) return 1;

    struct io_uring_sqe *sqe = io_uring_get_sqe(&ring);
    io_uring_prep_provide_buffers(sqe, bufs, 4096, 8, 1, 0);
    io_uring_submit(&ring);
    struct io_uring_cqe *cqe;
    r = io_uring_wait_cqe(&ring, &cqe);
    printf("provide_buffers (bgid 1, 8 x 4096): wait=%d res=%d (%s)\n", r, r < 0 ? r : cqe->res, (r < 0 ? -r : (cqe->res < 0 ? -cqe->res : 0)) ? strerror(r < 0 ? -r : -cqe->res) : "ok");
    int provided = (r == 0 && cqe->res >= 0);
    if (r == 0) io_uring_cqe_seen(&ring, cqe);
    if (!provided) { printf("RESULT provide_buffers: REFUSED\n"); return 2; }

    int sv[2];
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) < 0) { perror("socketpair"); return 1; }
    sqe = io_uring_get_sqe(&ring);
    io_uring_prep_recv_multishot(sqe, sv[0], NULL, 0, 0);
    sqe->flags |= IOSQE_BUFFER_SELECT;
    sqe->buf_group = 1;
    io_uring_submit(&ring);
    char msg[100]; memset(msg, 'x', sizeof msg);
    if (write(sv[1], msg, sizeof msg) != sizeof msg) { perror("write"); return 1; }
    r = io_uring_wait_cqe(&ring, &cqe);
    if (r < 0) { printf("RESULT multishot_recv: wait=%d (%s)\n", r, strerror(-r)); return 3; }
    unsigned fl = cqe->flags; int res = cqe->res;
    printf("multishot recv CQE: res=%d flags=0x%x BUFFER=%s MORE=%s buffer_id=%u\n", res, fl,
           (fl & IORING_CQE_F_BUFFER) ? "yes" : "no", (fl & IORING_CQE_F_MORE) ? "yes" : "no", fl >> IORING_CQE_BUFFER_SHIFT);
    int ok = res == 100 && (fl & IORING_CQE_F_BUFFER) && (fl & IORING_CQE_F_MORE);
    io_uring_cqe_seen(&ring, cqe);
    printf("RESULT provide_buffers + multishot recv: %s\n", ok ? "OK" : "FAILED");
    return ok ? 0 : 4;
}
