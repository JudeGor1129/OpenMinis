#ifndef MINIS_ROOT_COMMAND_PROCESS_H
#define MINIS_ROOT_COMMAND_PROCESS_H
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <fcntl.h>
#include <poll.h>
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <sys/wait.h>
#include <time.h>
#define MINIS_ROOT_OUTPUT_CAP 65536u

typedef struct { pthread_mutex_t lock; pid_t pid; int revoked; } MinisRootChildControl;
typedef struct {
    char *out, *err;
    size_t outSize, errSize;
    int spawnError, waitError, exitCode, signal, timedOut, cancelled, truncated;
} MinisRootChildResult;
static inline uint64_t MRNowMS(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000u + (uint64_t)t.tv_nsec / 1000000u;
}
static inline void MRChildFree(MinisRootChildResult *r) {
    free(r->out); free(r->err); r->out = r->err = NULL;
}
static inline void MRChildRevoke(MinisRootChildControl *c) {
    pthread_mutex_lock(&c->lock); c->revoked = 1;
    if (c->pid > 0) { (void)kill(-c->pid, SIGKILL); (void)kill(c->pid, SIGKILL); }
    pthread_mutex_unlock(&c->lock);
}
static inline int MRChildPipe(int p[2]) {
    if (pipe(p)) return errno;
    for (int i = 0; i < 2; i++) {
        if (p[i] < 5) {
            int fd = fcntl(p[i], F_DUPFD_CLOEXEC, 5);
            if (fd < 0) { int e = errno; close(p[0]); close(p[1]); return e; }
            close(p[i]); p[i] = fd;
        }
        if (fcntl(p[i], F_SETFD, FD_CLOEXEC) < 0) {
            int e = errno; close(p[0]); close(p[1]); return e;
        }
    }
    return 0;
}
// Bounded draining prevents a continuously writing child starving timeout.
// used points directly at r->outSize or r->errSize: increment it only once.
static inline void MRChildDrain(int *fd, char *buf, size_t *used, MinisRootChildResult *r) {
    char tmp[4096]; size_t budget = 65536;
    while (*fd >= 0 && budget) {
        ssize_t n = read(*fd, tmp, sizeof(tmp));
        if (n > 0) {
            size_t usedTotal = r->outSize + r->errSize;
            size_t room = usedTotal < MINIS_ROOT_OUTPUT_CAP ? MINIS_ROOT_OUTPUT_CAP - usedTotal : 0;
            size_t take = (size_t)n < room ? (size_t)n : room;
            if (take) { memcpy(buf + *used, tmp, take); *used += take; buf[*used] = 0; }
            if (take != (size_t)n) r->truncated = 1;
            budget = (size_t)n >= budget ? 0 : budget - (size_t)n;
        } else if (!n) { close(*fd); *fd = -1; }
        else if (errno == EINTR) continue;
        else if (errno == EAGAIN || errno == EWOULDBLOCK) break;
        else { close(*fd); *fd = -1; }
    }
}
static inline MinisRootChildResult MRRunChild(const char *program, char *const argv[],
                                               unsigned timeoutMS, MinisRootChildControl *control) {
    MinisRootChildResult r = { .exitCode = -1 };
    if (!program || program[0] != '/' || !argv || !argv[0] || !control || !timeoutMS) {
        r.spawnError = EINVAL; return r;
    }
    r.out = calloc(MINIS_ROOT_OUTPUT_CAP + 1u, 1); r.err = calloc(MINIS_ROOT_OUTPUT_CAP + 1u, 1);
    if (!r.out || !r.err) { r.spawnError = ENOMEM; MRChildFree(&r); return r; }
    int o[2], e[2];
    if ((r.spawnError = MRChildPipe(o))) return r;
    if ((r.spawnError = MRChildPipe(e))) { close(o[0]); close(o[1]); return r; }
    posix_spawn_file_actions_t a; posix_spawnattr_t at;
    int x = posix_spawn_file_actions_init(&a);
    if (x) goto fail_pipes;
    x = posix_spawnattr_init(&at);
    if (x) { posix_spawn_file_actions_destroy(&a); goto fail_pipes; }
#define MR_CALL(z) do { if ((x = (z))) goto spawn_cleanup; } while (0)
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF;
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    sigset_t empty, def; sigemptyset(&empty); sigemptyset(&def);
    sigaddset(&def, SIGPIPE); sigaddset(&def, SIGTERM);
    MR_CALL(posix_spawnattr_setflags(&at, flags));
    MR_CALL(posix_spawnattr_setpgroup(&at, 0));
    MR_CALL(posix_spawnattr_setsigmask(&at, &empty));
    MR_CALL(posix_spawnattr_setsigdefault(&at, &def));
    MR_CALL(posix_spawn_file_actions_addopen(&a, STDIN_FILENO, "/dev/null", O_RDONLY, 0));
    MR_CALL(posix_spawn_file_actions_adddup2(&a, o[1], STDOUT_FILENO));
    MR_CALL(posix_spawn_file_actions_adddup2(&a, e[1], STDERR_FILENO));
    for (int i = 0; i < 2; i++) {
        MR_CALL(posix_spawn_file_actions_addclose(&a, o[i]));
        MR_CALL(posix_spawn_file_actions_addclose(&a, e[i]));
    }
    char *env[] = { "PATH=/var/jb/usr/bin:/var/jb/usr/sbin:/usr/bin:/bin:/usr/sbin:/sbin",
                    "HOME=/var/empty", "LANG=C", "LC_ALL=C", "TMPDIR=/var/jb/var/tmp", NULL };
    pid_t pid = -1;
    pthread_mutex_lock(&control->lock);
    if (control->revoked) { x = ECANCELED; r.cancelled = 1; }
    else { x = posix_spawn(&pid, program, &a, &at, argv, env); if (!x) control->pid = pid; }
    pthread_mutex_unlock(&control->lock);
spawn_cleanup:
    posix_spawn_file_actions_destroy(&a); posix_spawnattr_destroy(&at);
fail_pipes:
    close(o[1]); close(e[1]);
    if (x) { close(o[0]); close(e[0]); r.spawnError = x; return r; }
    (void)fcntl(o[0], F_SETFL, O_NONBLOCK); (void)fcntl(e[0], F_SETFL, O_NONBLOCK);
    uint64_t started = MRNowMS(); int reaped = 0, status = 0, killed = 0;
    while (!reaped || o[0] >= 0 || e[0] >= 0) {
        struct pollfd f[2] = {{o[0], POLLIN | POLLHUP, 0}, {e[0], POLLIN | POLLHUP, 0}};
        (void)poll(f, 2, 25);
        MRChildDrain(&o[0], r.out, &r.outSize, &r);
        MRChildDrain(&e[0], r.err, &r.errSize, &r);
        if (!reaped) {
            pid_t w = waitpid(pid, &status, WNOHANG);
            if (w == pid) reaped = 1;
            else if (w < 0 && errno != EINTR) { r.waitError = errno; reaped = 1; }
        }
        pthread_mutex_lock(&control->lock); int revoked = control->revoked; pthread_mutex_unlock(&control->lock);
        if (!killed && (revoked || MRNowMS() - started >= timeoutMS)) {
            r.cancelled = revoked; r.timedOut = !revoked; killed = 1;
            (void)kill(-pid, SIGKILL); if (!reaped) (void)kill(pid, SIGKILL);
        }
        if (killed) {
            if (o[0] >= 0) { close(o[0]); o[0] = -1; }
            if (e[0] >= 0) { close(e[0]); e[0] = -1; }
            if (!reaped) {
                pid_t w; do { w = waitpid(pid, &status, 0); } while (w < 0 && errno == EINTR);
                if (w == pid) reaped = 1;
                else { r.waitError = errno; reaped = 1; }
            }
        }
    }
    pthread_mutex_lock(&control->lock); control->pid = 0; pthread_mutex_unlock(&control->lock);
    if (!r.waitError) {
        if (WIFEXITED(status)) r.exitCode = WEXITSTATUS(status);
        else if (WIFSIGNALED(status)) r.signal = WTERMSIG(status);
    }
    return r;
#undef MR_CALL
}
#endif
