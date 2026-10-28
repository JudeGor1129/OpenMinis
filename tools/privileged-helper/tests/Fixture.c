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
int main(int argc, char **argv) {
    if (argc != 3 || argv[2][0] != '/') return 64;
    if (!MinisHelperAwaitLaunchPermit(STDIN_FILENO)) return 125;
    if (!strcmp(argv[1], "lease")) {
        write_all(STDOUT_FILENO, "READY\n", 6);
        MinisHelperWaitForRevocation(STDIN_FILENO);
        return 91;
    }
    if (!strcmp(argv[1], "identity")) {
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
