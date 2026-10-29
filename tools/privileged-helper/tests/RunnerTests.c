#define _POSIX_C_SOURCE 200809L
#include "HelperProcessRunner.h"
#include <dirent.h>
#include <errno.h>
#include <pthread.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

static int failures;
static const char *fixture;
static const char request[] = "{\"protocol\":2,\"action\":\"read\"}";
#define REQ request, sizeof(request) - 1
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __func__, __LINE__, #c); ++failures; } } while (0)
static double now(void) {
    struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t);
    return (double)t.tv_sec + (double)t.tv_nsec / 1000000000.0;
}
static void report(const char *name, int before) {
    printf("%s %s\n", failures == before ? "PASS" : "FAIL", name);
}
static void clean_exit(const MinisHelperResult *r, int code) {
    CHECK(r->spawn_error == 0); CHECK(r->exit_code == code);
    CHECK(r->term_signal == 0); CHECK(!r->timed_out);
    CHECK(!r->cancelled); CHECK(!r->output_limit);
}
static void reaped(const MinisHelperResult *r) {
    CHECK(r->out_data != NULL && r->out_size != 0);
    if (!r->out_data) return;
    char *end = NULL; long id = strtol(r->out_data, &end, 10);
    CHECK(id > 1 && end && *end == '\n');
    if (id <= 1) return;
    errno = 0; CHECK(kill((pid_t)id, 0) == -1 && errno == ESRCH);
    int status; errno = 0;
    CHECK(waitpid((pid_t)id, &status, WNOHANG) == -1 && errno == ECHILD);
}
static int fd_count(void) {
#ifdef __linux__
    DIR *dir = opendir("/proc/self/fd");
    if (!dir) return -1;
    int count = 0; struct dirent *entry;
    while ((entry = readdir(dir)))
        if (strcmp(entry->d_name, ".") && strcmp(entry->d_name, "..")) ++count;
    closedir(dir); return count;
#else
    return -1;
#endif
}
static void *cancel_after_100ms(void *arg) {
    struct timespec remaining = {0, 100000000};
    while (nanosleep(&remaining, &remaining) < 0 && errno == EINTR) {}
    MinisHelperCancel(arg); return NULL;
}
static void test_identity(void) {
    int before = failures;
    MinisHelperResult r = MinisHelperRun(fixture, "identity", REQ, false, 3000, NULL);
    clean_exit(&r, 0);
    char expected[160];
    snprintf(expected, sizeof(expected), "uid=%lu euid=%lu gid=%lu egid=%lu\n",
        (unsigned long)getuid(), (unsigned long)geteuid(),
        (unsigned long)getgid(), (unsigned long)getegid());
    CHECK(r.out_data && !strcmp(r.out_data, expected)); CHECK(r.err_size == 0);
    MinisHelperResultFree(&r); CHECK(!r.out_data && !r.err_data);
    report("ordinary identity (rootPersona=false), exit 0", before);
}
static void test_dual(void) {
    int before = failures; double start = now();
    MinisHelperResult r = MinisHelperRun(fixture, "dual", REQ, false, 3000, NULL);
    clean_exit(&r, 0); CHECK(now() - start < 3.0);
    CHECK(r.out_size == 98304 && r.err_size == 98304);
    if (r.out_data) for (size_t i = 0; i < r.out_size; ++i) CHECK(r.out_data[i] == 'O');
    if (r.err_data) for (size_t i = 0; i < r.err_size; ++i) CHECK(r.err_data[i] == 'E');
    CHECK(r.out_data && r.out_data[r.out_size] == 0);
    CHECK(r.err_data && r.err_data[r.err_size] == 0);
    MinisHelperResultFree(&r); report("dual pipes: 96 KiB each, exact separate bytes, no deadlock", before);
}
static void test_limit(void) {
    int before = failures; double start = now();
    MinisHelperResult r = MinisHelperRun(fixture, "overflow", REQ, false, 3000, NULL);
    CHECK(r.spawn_error == 0); CHECK(r.output_limit); CHECK(!r.timed_out && !r.cancelled);
    CHECK(r.out_size + r.err_size == MINIS_HELPER_OUTPUT_LIMIT);
    CHECK(r.out_size > 0 && r.err_size > 0);
    CHECK(r.term_signal == SIGKILL && r.exit_code == -1); CHECK(now() - start < 3.0);
    reaped(&r); MinisHelperResultFree(&r); report("combined 256 KiB cap kills and reaps child", before);
}
static void test_timeout(void) {
    int before = failures; double start = now();
    MinisHelperResult r = MinisHelperRun(fixture, "block", REQ, false, 180, NULL);
    CHECK(r.spawn_error == 0); CHECK(r.timed_out); CHECK(!r.cancelled && !r.output_limit);
    CHECK(r.term_signal == SIGKILL && r.exit_code == -1);
    CHECK(now() - start >= 0.15 && now() - start < 2.0);
    reaped(&r); MinisHelperResultFree(&r); report("timeout SIGKILL/waitpid, no zombie", before);
}
static void test_cancel(void) {
    int before = failures; MinisHelperControl control; MinisHelperControlInit(&control);
    pthread_t thread; int e = pthread_create(&thread, NULL, cancel_after_100ms, &control);
    CHECK(e == 0); if (e) { report("pthread cancellation", before); return; }
    double start = now();
    MinisHelperResult r = MinisHelperRun(fixture, "block", REQ, false, 3000, &control);
    CHECK(pthread_join(thread, NULL) == 0);
    CHECK(r.spawn_error == 0 && r.cancelled); CHECK(!r.timed_out && !r.output_limit);
    CHECK(r.term_signal == SIGKILL && r.exit_code == -1);
    CHECK(now() - start >= 0.08 && now() - start < 2.0);
    reaped(&r); MinisHelperResultFree(&r); report("pthread 100 ms cancel kills and reaps child", before);
}
static void test_status(void) {
    int before = failures;
    MinisHelperResult r = MinisHelperRun(fixture, "exit7", REQ, false, 3000, NULL);
    clean_exit(&r, 7); MinisHelperResultFree(&r);
    r = MinisHelperRun(fixture, "sigterm", REQ, false, 3000, NULL);
    CHECK(r.spawn_error == 0 && r.exit_code == -1 && r.term_signal == SIGTERM);
    CHECK(!r.timed_out && !r.cancelled && !r.output_limit); MinisHelperResultFree(&r);
    report("exit 7 and SIGTERM are distinct results", before);
}
static void test_spawn_and_preflag(void) {
    int before = failures;
    MinisHelperResult invalid = MinisHelperRun(fixture, "frame", NULL, 16, false, 3000, NULL);
    CHECK(invalid.spawn_error == EINVAL && invalid.exit_code == -1 && !invalid.out_data && !invalid.err_data);
    MinisHelperResultFree(&invalid);
    invalid = MinisHelperRun(fixture, "frame", request, 3u * 1024u * 1024u + 1u, false, 3000, NULL);
    CHECK(invalid.spawn_error == EINVAL && invalid.exit_code == -1 && !invalid.out_data && !invalid.err_data);
    MinisHelperResultFree(&invalid);
    invalid = MinisHelperRun("relative-helper", "frame", REQ, false, 3000, NULL);
    CHECK(invalid.spawn_error == EINVAL && invalid.exit_code == -1 && !invalid.out_data && !invalid.err_data);
    MinisHelperResultFree(&invalid);
    report("NULL body, >3 MiB body and relative executable are rejected before spawn", before);
    before = failures;
    /* A child path under an executable regular file cannot exist. */
    char *missing = malloc(strlen(fixture) + 16); CHECK(missing != NULL);
    if (!missing) return;
    sprintf(missing, "%s/no-such-child", fixture);
    MinisHelperResult r = MinisHelperRun(missing, "identity", REQ, false, 3000, NULL);
    CHECK(r.spawn_error == ENOTDIR || r.spawn_error == ENOENT);
    CHECK(r.exit_code == -1 && r.term_signal == 0 && !r.cancelled);
    MinisHelperResultFree(&r); report("unknown executable produces spawn error", before);
    before = failures;
    MinisHelperControl control; MinisHelperControlInit(&control); MinisHelperCancel(&control);
    r = MinisHelperRun(missing, "identity", REQ, false, 3000, &control);
    CHECK(r.cancelled && r.spawn_error == 0 && r.exit_code == -1);
    CHECK(!r.timed_out && !r.output_limit && r.term_signal == 0);
    CHECK(!r.out_data && !r.err_data && !r.out_size && !r.err_size);
    MinisHelperResultFree(&r); free(missing);
    report("pre-cancelled control returns before spawn", before);
}
static void test_persona(void) {
#ifdef __APPLE__
    puts("SKIP Darwin rootPersona (no privileged persona calls)");
#else
    int before = failures;
    MinisHelperResult r = MinisHelperRun(fixture, "identity", REQ, true, 3000, NULL);
    CHECK(r.spawn_error == ENOTSUP && r.exit_code == -1 && r.term_signal == 0);
    CHECK(!r.out_size && !r.err_size && !r.cancelled && !r.timed_out && !r.output_limit);
    MinisHelperResultFree(&r); report("Linux rootPersona rejects with ENOTSUP", before);
#endif
}

static unsigned long checksum(const unsigned char *data, size_t size) {
    unsigned long sum = 0;
    for (size_t i = 0; i < size; ++i) sum = (sum * 31u + data[i]) & 0xffffffffu;
    return sum;
}
static void expect_frame(const unsigned char *data, size_t size, const char *name) {
    int before = failures; double start = now();
    MinisHelperResult r = MinisHelperRun(fixture, "frame", data, size, false, 5000, NULL);
    clean_exit(&r, 0); CHECK(r.request_error == 0); CHECK(now() - start < 5.0);
    char expected[96];
    snprintf(expected, sizeof(expected), "frame=%lu sum=%lu\n", (unsigned long)size, checksum(data, size));
    CHECK(r.out_data && !strcmp(r.out_data, expected));
    if (r.out_data && strcmp(r.out_data, expected)) fprintf(stderr, "INFO got %s", r.out_data);
    MinisHelperResultFree(&r); report(name, before);
}
static void test_request_frames(void) {
    expect_frame((const unsigned char *)request, sizeof(request) - 1, "FD3 small JSON frame delivered byte-exact");
    size_t big = 3u * 1024u * 1024u;
    unsigned char *data = malloc(big); CHECK(data != NULL);
    if (!data) return;
    for (size_t i = 0; i < big; ++i) data[i] = (unsigned char)(i * 131u + 7u);
    expect_frame(data, big, "FD3 3 MiB frame delivered without deadlock");
    free(data);
}
static void test_request_peer_exit(void) {
    int before = failures; double start = now();
    size_t big = 2u * 1024u * 1024u;
    unsigned char *data = calloc(big, 1); CHECK(data != NULL);
    if (!data) return;
    /* Child exits without reading FD 3: runner must not hang and must reap exit 0. */
    MinisHelperResult r = MinisHelperRun(fixture, "noread", data, big, false, 3000, NULL);
    CHECK(r.spawn_error == 0 && r.exit_code == 0 && r.term_signal == 0);
    CHECK(!r.timed_out && !r.cancelled); CHECK(now() - start < 3.0);
    CHECK(r.out_data && !strcmp(r.out_data, "NOREAD\n"));
    CHECK(r.request_error == 0 || r.request_error == EPIPE || r.request_error == ECONNRESET);
    MinisHelperResultFree(&r); free(data);
    report("child exit before reading FD3 does not hang; real status reaped", before);
}
static void test_identity_closes_request(void) {
    int before = failures;
    /* The fixture's identity verb requires FD3 EOF and exits 82 on any byte. */
    MinisHelperResult r = MinisHelperRun(fixture, "identity", REQ, false, 3000, NULL);
    clean_exit(&r, 0); MinisHelperResultFree(&r);
    report("identity receives no request bytes (FD3 EOF)", before);
}
static void test_inherited_fds(void) {
    int before = failures;
    MinisHelperResult r = MinisHelperRun(fixture, "fds", REQ, false, 3000, NULL);
    clean_exit(&r, 0); MinisHelperResultFree(&r);
    report("child inherits only fds 0..3", before);
}
static void test_fd_rounds(void) {
    int before = failures, initial = fd_count();
    if (initial < 0) { puts("SKIP /proc/self/fd unavailable (Darwin supported)"); return; }
    for (int round = 0; round < 16; ++round) {
        MinisHelperResult r = MinisHelperRun(fixture, "identity", REQ, false, 3000, NULL);
        clean_exit(&r, 0); MinisHelperResultFree(&r);
        r = MinisHelperRun(fixture, "dual", REQ, false, 3000, NULL);
        clean_exit(&r, 0); MinisHelperResultFree(&r);
        r = MinisHelperRun(fixture, "frame", REQ, false, 3000, NULL);
        clean_exit(&r, 0); MinisHelperResultFree(&r);
        r = MinisHelperRun(fixture, "overflow", REQ, false, 3000, NULL);
        CHECK(r.output_limit && r.term_signal == SIGKILL); reaped(&r); MinisHelperResultFree(&r);
        r = MinisHelperRun(fixture, "block", REQ, false, 30, NULL);
        CHECK(r.timed_out && r.term_signal == SIGKILL); reaped(&r); MinisHelperResultFree(&r);
        MinisHelperControl c; MinisHelperControlInit(&c); MinisHelperCancel(&c);
        r = MinisHelperRun(fixture, "identity", REQ, false, 3000, &c);
        CHECK(r.cancelled); MinisHelperResultFree(&r);
        r = MinisHelperRun("/dev/null/no-such-executable", "identity", REQ, false, 3000, NULL);
        CHECK(r.spawn_error == ENOTDIR || r.spawn_error == ENOENT); MinisHelperResultFree(&r);
#ifndef __APPLE__
        r = MinisHelperRun(fixture, "identity", REQ, true, 3000, NULL);
        CHECK(r.spawn_error == ENOTSUP); MinisHelperResultFree(&r);
#endif
        CHECK(fd_count() == initial);
    }
    printf("INFO fd baseline=%d final=%d rounds=16\n", initial, fd_count());
    report("16 mixed rounds without fd leaks", before);
}
static void watchdog(int signo) {
    (void)signo;
    static const char message[] = "FAIL test watchdog: runner did not return\n";
    (void)write(STDERR_FILENO, message, sizeof(message) - 1); _exit(124);
}
int main(int argc, char **argv) {
    if (argc != 2 || argv[1][0] != '/') { fputs("usage: runner-tests /absolute/fixture\n", stderr); return 2; }
    fixture = argv[1]; setvbuf(stdout, NULL, _IOLBF, 0);
    signal(SIGALRM, watchdog); alarm(120);
#ifndef __APPLE__
    /* Darwin uses SO_NOSIGPIPE on the request socket. Some Linux emulators
       (iSH) ignore MSG_NOSIGNAL, so ignore SIGPIPE here; the peer-exit test
       still asserts the runner reaps the child and reports its real status. */
    signal(SIGPIPE, SIG_IGN);
#endif
    test_identity(); test_dual(); test_limit(); test_timeout(); test_cancel();
    test_status(); test_spawn_and_preflag(); test_persona();
    test_request_frames(); test_request_peer_exit(); test_identity_closes_request();
    test_inherited_fds(); test_fd_rounds();
#ifndef __APPLE__
    // Linux CI owns the test process's complete child set. macOS hosted
    // runners may have unrelated supervision children; every child spawned by
    // this runner is already checked by reaped() using its exact PID.
    int status; errno = 0;
    CHECK(waitpid(-1, &status, WNOHANG) == -1 && errno == ECHILD);
#endif
    alarm(0);
    printf("RESULT %s (%d failures)\n", failures ? "FAIL" : "PASS", failures);
    return failures ? 1 : 0;
}
