#define _GNU_SOURCE
#define _POSIX_C_SOURCE 200809L
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include "../HelperLease.h"

static void write_all(int fd, const void *data, size_t size) {
    const char *p = data;
    while (size) {
        ssize_t n = write(fd, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) _exit(90);
        p += n;
        size -= (size_t)n;
    }
}
static void pid_line(void) {
    char line[64];
    int n = snprintf(line, sizeof(line), "%ld\n", (long)getpid());
    write_all(STDOUT_FILENO, line, (size_t)n);
}
/* Reads one production-format frame from FD 3 and reports its size plus a
   simple checksum, so the runner test can verify exact delivery. */
static int echo_frame(void) {
    unsigned char *data = NULL; size_t size = 0;
    int e = MinisHelperReadRequestFrame(MINIS_HELPER_REQUEST_FD, &data, &size);
    if (e) {
        char line[64];
        int n = snprintf(line, sizeof(line), "frame_error=%d\n", e);
        write_all(STDOUT_FILENO, line, (size_t)n);
        return 3;
    }
    unsigned long sum = 0;
    for (size_t i = 0; i < size; ++i) sum = (sum * 31u + data[i]) & 0xffffffffu;
    free(data);
    char line[96];
    int n = snprintf(line, sizeof(line), "frame=%lu sum=%lu\n", (unsigned long)size, sum);
    write_all(STDOUT_FILENO, line, (size_t)n);
    return 0;
}
int main(int argc, char **argv) {
    if (argc != 2 || !argv[1][0]) return 64;
    if (!MinisHelperAwaitLaunchPermit(STDIN_FILENO)) return 125;
    if (!strcmp(argv[1], "frame")) return echo_frame();
    if (!strcmp(argv[1], "noread")) {
        /* Exits without reading FD 3: the runner must not hang or SIGPIPE. */
        write_all(STDOUT_FILENO, "NOREAD\n", 7);
        return 0;
    }
    if (!strcmp(argv[1], "fds")) {
        /* Only 0..3 may be inherited; any other open descriptor is a leak. */
        for (int fd = 4; fd < 256; ++fd) if (fcntl(fd, F_GETFD) >= 0) return 80;
        return fcntl(3, F_GETFD) >= 0 ? 0 : 81;
    }
    if (!strcmp(argv[1], "lease")) {
        write_all(STDOUT_FILENO, "READY\n", 6);
        MinisHelperWaitForRevocation(STDIN_FILENO);
        return 91;
    }
    if (!strcmp(argv[1], "identity")) {
        /* The runner sends no body for identity and closes its FD3 end. */
        char probe;
        ssize_t got;
        do { got = read(MINIS_HELPER_REQUEST_FD, &probe, 1); } while (got < 0 && errno == EINTR);
        if (got != 0) return 82;
        printf("uid=%lu euid=%lu gid=%lu egid=%lu\n", (unsigned long)getuid(),
               (unsigned long)geteuid(), (unsigned long)getgid(), (unsigned long)getegid());
        return 0;
    }
    if (!strcmp(argv[1], "exit7")) return 7;
    if (!strcmp(argv[1], "sigterm")) { raise(SIGTERM); return 91; }
    if (!strcmp(argv[1], "block")) { pid_line(); for (;;) pause(); }
    if (!strcmp(argv[1], "dual")) {
#ifdef __linux__
        /* Make the fixture's real pipes small, not a mocked pipe implementation. */
        /* iSH may return ENOSYS/EINVAL for pipe resizing. Real 96 KiB
           writes still exercise both pipes without relying on this option. */
        for (int fd = 1; fd <= 2; fd++) {
            if (fcntl(fd, F_SETPIPE_SZ, 4096) < 0 && errno != ENOSYS && errno != EINVAL && errno != ENOTSUP && errno != EPERM) return 92;
            int size = fcntl(fd, F_GETPIPE_SZ);
            if (size >= 98304) return 93;
        }
#endif
        char out[4096], err[4096];
        memset(out, 'O', sizeof(out)); memset(err, 'E', sizeof(err));
        for (int i = 0; i < 24; ++i) {
            /* stderr first also catches readers that drain stdout to EOF first. */
            write_all(2, err, sizeof(err)); write_all(1, out, sizeof(out));
        }
        return 0;
    }
    if (!strcmp(argv[1], "overflow")) {
        pid_line();
        char out[4096], err[4096];
        memset(out, 'O', sizeof(out)); memset(err, 'E', sizeof(err));
        /* Each stream alone stays below 256 KiB; only their sum exceeds it. */
        for (int i = 0; i < 40; ++i) {
            write_all(1, out, sizeof(out)); write_all(2, err, sizeof(err));
        }
        for (;;) pause();
    }
    return 64; /* No shell, commands, paths or arbitrary actions accepted. */
}
