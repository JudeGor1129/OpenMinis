// Persona lookup and SO_NOSIGPIPE need Darwin extensions even when the
// portable runner tests request the strict POSIX.1-2008 feature set.
#if defined(__APPLE__) && !defined(_DARWIN_C_SOURCE)
#define _DARWIN_C_SOURCE 1
#endif
#include "HelperProcessRunner.h"
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <spawn.h>
#include <stdint.h>
#include <sys/socket.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
#ifdef __APPLE__
#include <dlfcn.h>
#endif

enum { MINIS_LAUNCH_PENDING = 0, MINIS_LAUNCH_REVOKED = 1, MINIS_LAUNCH_COMMITTED = 2 };
void MinisHelperControlInit(MinisHelperControl *c) {
    atomic_init(&c->cancelled, false);
    atomic_init(&c->launch_state, MINIS_LAUNCH_PENDING);
}
void MinisHelperCancel(MinisHelperControl *c) {
    int pending = MINIS_LAUNCH_PENDING;
    // State transition linearizes cancellation against the launch permit.
    atomic_compare_exchange_strong(&c->launch_state, &pending, MINIS_LAUNCH_REVOKED);
    atomic_store(&c->cancelled, true);
}
static int safe_channel(int p[2]) {
    if (socketpair(AF_UNIX, SOCK_STREAM, 0, p) < 0) return errno;
    for (int i = 0; i < 2; i++) {
        if (p[i] < 4) {
            int newfd = fcntl(p[i], F_DUPFD_CLOEXEC, 4);
            if (newfd < 0) { int e = errno; close(p[0]); close(p[1]); return e; }
            close(p[i]); p[i] = newfd;
        }
        if (fcntl(p[i], F_SETFD, FD_CLOEXEC) < 0) {
            int e = errno; close(p[0]); close(p[1]); return e;
        }
    }
    return 0;
}
static int write_launch_permit(int fd) {
#ifdef SO_NOSIGPIPE
    int enabled = 1;
    if (setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, sizeof(enabled)) < 0) return errno;
    const int flags = 0;
#else
    const int flags = MSG_NOSIGNAL;
#endif
    const char permit = 'G';
    ssize_t n;
    do { n = send(fd, &permit, 1, flags); } while (n < 0 && errno == EINTR);
    return n == 1 ? 0 : errno;
}
void MinisHelperResultFree(MinisHelperResult *r) {
    free(r->out_data); free(r->err_data); r->out_data = r->err_data = NULL;
}
static uint64_t now_ms(void) {
    struct timespec t;
    clock_gettime(CLOCK_MONOTONIC, &t);
    return (uint64_t)t.tv_sec * 1000 + (uint64_t)t.tv_nsec / 1000000;
}
static int safe_pipe(int p[2]) {
    if (pipe(p) < 0) return errno;
    for (int i = 0; i < 2; i++) {
        if (p[i] < 4) {
            int newfd = fcntl(p[i], F_DUPFD_CLOEXEC, 4);
            if (newfd < 0) { int e = errno; close(p[0]); close(p[1]); return e; }
            close(p[i]); p[i] = newfd;
        }
        if (fcntl(p[i], F_SETFD, FD_CLOEXEC) < 0) {
            int e = errno; close(p[0]); close(p[1]); return e;
        }
    }
    return 0;
}
static int persona(posix_spawnattr_t *attr) {
#ifdef __APPLE__
    typedef int (*SetPersona)(const posix_spawnattr_t *, uid_t, uint32_t);
    typedef int (*SetID)(const posix_spawnattr_t *, uid_t);
    SetPersona set_persona = (SetPersona)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    SetID set_uid = (SetID)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    SetID set_gid = (SetID)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
    if (!set_persona || !set_uid || !set_gid) return ENOTSUP;
    int e = set_persona(attr, 99, 1); // TrollStore convention; not a root guarantee.
    if (!e) e = set_uid(attr, 0);
    if (!e) e = set_gid(attr, 0);
    return e;
#else
    (void)attr; return ENOTSUP;
#endif
}
static void drain(int *fd, char *data, size_t *size, MinisHelperResult *r) {
    if (*fd < 0) return;
    char bytes[8192];
    for (;;) {
        ssize_t n = read(*fd, bytes, sizeof(bytes));
        if (n > 0) {
            size_t available = MINIS_HELPER_OUTPUT_LIMIT - r->out_size - r->err_size;
            size_t take = (size_t)n < available ? (size_t)n : available;
            if (take) { memcpy(data + *size, bytes, take); *size += take; data[*size] = 0; }
            if (take != (size_t)n) { r->output_limit = true; return; }
        } else if (n == 0) { close(*fd); *fd = -1; return; }
        else if (errno == EINTR) { continue; }
        else if (errno == EAGAIN || errno == EWOULDBLOCK) { return; }
        else { close(*fd); *fd = -1; return; }
    }
}

static void pump_request(int *fd, const unsigned char header[4], const void *data,
                         size_t size, size_t *sent, MinisHelperResult *r) {
    if (*fd < 0) return;
#ifdef SO_NOSIGPIPE
    const int flags = 0; // configured once before entering the event loop
#else
    const int flags = MSG_NOSIGNAL;
#endif
    // Bound work per event-loop tick so timeout/cancel checks cannot starve.
    size_t budget = 64 * 1024;
    while (*sent < size + 4 && budget) {
        const unsigned char *p = *sent < 4 ? header + *sent
            : (const unsigned char *)data + *sent - 4;
        size_t count = *sent < 4 ? 4 - *sent : size + 4 - *sent;
        if (count > budget) count = budget;
        ssize_t n = send(*fd, p, count, flags);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) return;
        if (n <= 0) { r->request_error = n == 0 ? EIO : errno; close(*fd); *fd = -1; return; }
        *sent += (size_t)n; budget -= (size_t)n;
    }
    if (*sent == size + 4) { (void)shutdown(*fd, SHUT_WR); close(*fd); *fd = -1; }
}

MinisHelperResult MinisHelperRun(const char *executable, const char *action,
    const void *requestData, size_t requestSize, bool rootPersona, unsigned timeout_ms,
    MinisHelperControl *control) {
    MinisHelperResult r = { .exit_code = -1 };
    if (!executable || executable[0] != '/' || !action || !action[0] ||
        (!requestData && requestSize) || requestSize > 3u * 1024u * 1024u || timeout_ms == 0) { r.spawn_error = EINVAL; return r; }
    if (control && atomic_load(&control->cancelled)) { r.cancelled = true; return r; }
    r.out_data = calloc(MINIS_HELPER_OUTPUT_LIMIT + 1, 1);
    r.err_data = calloc(MINIS_HELPER_OUTPUT_LIMIT + 1, 1);
    if (!r.out_data || !r.err_data) {
        free(r.out_data); free(r.err_data);
        r.out_data = r.err_data = NULL;
        r.spawn_error = ENOMEM; return r;
    }
    int out[2], err[2], life[2], request[2];
    if ((r.spawn_error = safe_pipe(out))) { MinisHelperResultFree(&r); return r; }
    if ((r.spawn_error = safe_pipe(err))) {
        close(out[0]); close(out[1]); MinisHelperResultFree(&r); return r;
    }
    if ((r.spawn_error = safe_channel(life))) {
        close(out[0]); close(out[1]); close(err[0]); close(err[1]);
        MinisHelperResultFree(&r); return r;
    }
    if ((r.spawn_error = safe_channel(request))) {
        close(out[0]); close(out[1]); close(err[0]); close(err[1]);
        close(life[0]); close(life[1]); MinisHelperResultFree(&r); return r;
    }
#ifdef SO_NOSIGPIPE
    int noSigPipe = 1;
    if (setsockopt(request[1], SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, sizeof(noSigPipe)) < 0) {
        r.spawn_error = errno;
        close(out[0]); close(out[1]); close(err[0]); close(err[1]);
        close(life[0]); close(life[1]); close(request[0]); close(request[1]);
        return r;
    }
#endif
    // safe_pipe/safe_channel reserve 0..3; no source can alias child fd3.
    posix_spawnattr_t attr;
    posix_spawn_file_actions_t actions;
    int e = posix_spawnattr_init(&attr);
    if (e) goto pipes;
    e = posix_spawn_file_actions_init(&actions);
    if (e) { posix_spawnattr_destroy(&attr); goto pipes; }
#define TRY_CALL(call) do { if ((e = (call))) goto cleanup; } while (0)
    short flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK;
#ifdef POSIX_SPAWN_CLOEXEC_DEFAULT
    flags |= POSIX_SPAWN_CLOEXEC_DEFAULT;
#endif
    TRY_CALL(posix_spawnattr_setflags(&attr, flags));
    TRY_CALL(posix_spawnattr_setpgroup(&attr, 0));
    sigset_t empty;
    sigemptyset(&empty);
    TRY_CALL(posix_spawnattr_setsigmask(&attr, &empty));
    if (rootPersona) TRY_CALL(persona(&attr));
    // FD 0 is the one-byte launch/revocation lease. FD 3 is a distinct framed
    // JSON request channel; request bodies never touch disk or argv.
    TRY_CALL(posix_spawn_file_actions_adddup2(&actions, life[0], STDIN_FILENO));
    TRY_CALL(posix_spawn_file_actions_adddup2(&actions, request[0], 3));
    TRY_CALL(posix_spawn_file_actions_adddup2(&actions, out[1], STDOUT_FILENO));
    TRY_CALL(posix_spawn_file_actions_adddup2(&actions, err[1], STDERR_FILENO));
    for (int i = 0; i < 2; i++) {
        TRY_CALL(posix_spawn_file_actions_addclose(&actions, life[i]));
        TRY_CALL(posix_spawn_file_actions_addclose(&actions, request[i]));
        TRY_CALL(posix_spawn_file_actions_addclose(&actions, out[i]));
        TRY_CALL(posix_spawn_file_actions_addclose(&actions, err[i]));
    }
    char *args[] = { (char *)executable, (char *)action, NULL };
    char *env[] = { "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/var/empty", "TMPDIR=/tmp", "LANG=C", NULL };
    pid_t pid = -1;
    if (control && atomic_load(&control->cancelled)) {
        r.cancelled = true; e = ECANCELED; goto cleanup;
    }
    e = posix_spawn(&pid, executable, &actions, &attr, args, env);
cleanup:
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attr);
pipes:
    close(out[1]); close(err[1]); close(life[0]); close(request[0]);
    if (e) {
        close(out[0]); close(err[0]); close(life[1]); close(request[1]);
        if (r.cancelled && e == ECANCELED) return r;
        r.spawn_error = e; return r;
    }
    if (control) {
        int pending = MINIS_LAUNCH_PENDING;
        if (!atomic_compare_exchange_strong(&control->launch_state, &pending, MINIS_LAUNCH_COMMITTED)) {
            r.cancelled = true;
            close(life[1]); life[1] = -1;
            kill(-pid, SIGKILL); kill(pid, SIGKILL);
            while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
            close(out[0]); close(err[0]); close(request[1]);
            return r;
        }
    }
    int permit_error = write_launch_permit(life[1]);
    if (permit_error) {
        if (control && atomic_load(&control->cancelled)) r.cancelled = true;
        else r.spawn_error = permit_error;
        close(life[1]); life[1] = -1;
        kill(-pid, SIGKILL); kill(pid, SIGKILL);
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
        close(out[0]); close(err[0]); close(request[1]);
        return r;
    }
    if (fcntl(out[0], F_SETFL, O_NONBLOCK) < 0 || fcntl(err[0], F_SETFL, O_NONBLOCK) < 0 ||
        fcntl(request[1], F_SETFL, O_NONBLOCK) < 0) {
        int saved_error = errno;
        close(life[1]); life[1] = -1;
        kill(-pid, SIGKILL); kill(pid, SIGKILL);
        while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
        close(out[0]); close(err[0]); close(request[1]); r.spawn_error = saved_error; return r;
    }
    uint32_t length = (uint32_t)requestSize;
    unsigned char requestHeader[4] = {(unsigned char)(length >> 24), (unsigned char)(length >> 16),
        (unsigned char)(length >> 8), (unsigned char)length};
    size_t requestSent = 0;
    if (!strcmp(action, "identity")) { close(request[1]); request[1] = -1; }
    uint64_t started = now_ms();
    bool reaped = false, killed = false;
    int status = 0;
    while (!reaped || out[0] >= 0 || err[0] >= 0) {
        if (!reaped) {
            pid_t w = waitpid(pid, &status, WNOHANG);
            if (w == pid) reaped = true;
            else if (w < 0 && errno != EINTR) { reaped = true; r.spawn_error = errno; }
        }
        if (control && atomic_load(&control->cancelled)) r.cancelled = true;
        if (now_ms() - started >= timeout_ms) r.timed_out = true;
        if (!killed && (r.cancelled || r.timed_out || r.output_limit)) {
            close(life[1]); life[1] = -1;
            kill(-pid, SIGKILL);
            if (!reaped) kill(pid, SIGKILL);
            killed = true;
        }
        if ((killed || reaped) && request[1] >= 0) { close(request[1]); request[1] = -1; }
        if (killed) {
            if (out[0] >= 0) { close(out[0]); out[0] = -1; }
            if (err[0] >= 0) { close(err[0]); err[0] = -1; }
            if (!reaped) {
                pid_t w;
                do { w = waitpid(pid, &status, 0); } while (w < 0 && errno == EINTR);
                if (w < 0) r.spawn_error = errno;
                reaped = true;
            }
            break;
        }
        struct pollfd fds[3] = {
            {out[0], POLLIN, 0}, {err[0], POLLIN, 0}, {request[1], POLLOUT, 0}
        };
        int poll_result = poll(fds, 3, 25);
        if (poll_result < 0 && errno != EINTR) { r.spawn_error = errno; r.cancelled = true; continue; }
        drain(&out[0], r.out_data, &r.out_size, &r);
        drain(&err[0], r.err_data, &r.err_size, &r);
        if (!r.output_limit && !r.cancelled && !r.timed_out)
            pump_request(&request[1], requestHeader, requestData, requestSize, &requestSent, &r);
    }
    if (!r.spawn_error && reaped) {
        if (WIFEXITED(status)) r.exit_code = WEXITSTATUS(status);
        else if (WIFSIGNALED(status)) r.term_signal = WTERMSIG(status);
    }
    if (life[1] >= 0) close(life[1]);
    if (request[1] >= 0) close(request[1]);
    return r;
#undef TRY_CALL
}
