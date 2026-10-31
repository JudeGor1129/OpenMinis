//
//  test-stdio-capture.c
//  Host unit test for src/ios/Vendor/OMToolchain/OMStdioCapture.h.
//
//  The capture runs on device inside the ld64 call, where a mistake is
//  expensive to find: a leaked descriptor breaks the host's own stderr for the
//  rest of the process, and an unrestored descriptor silently swallows later
//  diagnostics. Both are testable on the host with no iOS SDK, so they are
//  tested here rather than discovered in a build report.
//
//  Build (glibc/musl both gate mkstemp and pread behind a feature macro):
//
//    clang -std=c11 -Wall -Wextra -Werror -D_POSIX_C_SOURCE=200809L \
//          -I<OMToolchain dir> test-stdio-capture.c -o t && ./t
//
//  The app build needs none of that: Apple's headers expose both under the
//  strict modes Xcode uses.
//

#include "OMStdioCapture.h"

#include <dirent.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>

static int failures = 0;

/// Results are staged in memory and emitted through flush_report().
///
/// A check() running *while a capture is live* cannot print to stdout: fd 1 is
/// the capture file, so the line would end up inside the capture and never
/// reach the terminal. That would hide a real failure, so every result is
/// staged here and flushed whenever fd 1 is ours, plus once more at the end.
static char g_report[8192];
static size_t g_reportLength = 0;
static size_t g_reportEmitted = 0;

static void flush_report(void) {
    if (g_reportLength > g_reportEmitted) {
        fwrite(g_report + g_reportEmitted, 1, g_reportLength - g_reportEmitted, stdout);
        fflush(stdout);
        g_reportEmitted = g_reportLength;
    }
}

static void append(const char *text) {
    size_t length = strlen(text);
    size_t room = sizeof(g_report) - g_reportLength - 1;
    if (length > room) length = room;
    memcpy(g_report + g_reportLength, text, length);
    g_reportLength += length;
    g_report[g_reportLength] = '\0';
    if (!OMStdioCaptureIsLive()) flush_report();
}

static void check(int condition, const char *what) {
    if (condition) {
        append("ok   ");
    } else {
        failures++;
        append("FAIL ");
    }
    append(what);
    append("\n");
}

static char g_dir[512];

/// Number of directory entries whose name starts with `prefix`.
static int count_prefixed(const char *directory, const char *prefix) {
    DIR *dir = opendir(directory);
    if (dir == NULL) return -1;
    int count = 0;
    size_t prefixLength = strlen(prefix);
    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strncmp(entry->d_name, prefix, prefixLength) == 0) count++;
    }
    closedir(dir);
    return count;
}

static int fd_stat(int fd, struct stat *out) {
    return fstat(fd, out) == 0;
}

static int same_file(int fd, const struct stat *expected) {
    struct stat current;
    if (!fd_stat(fd, &current)) return 0;
    return current.st_dev == expected->st_dev && current.st_ino == expected->st_ino;
}

/// The header moves fd 1 and fd 2, so the test has to look at them directly.
static void test_round_trip(void) {
    printf("-- round trip\n");
    struct stat stdoutBefore, stderrBefore;
    check(fd_stat(STDOUT_FILENO, &stdoutBefore), "stdout stat before capture");
    check(fd_stat(STDERR_FILENO, &stderrBefore), "stderr stat before capture");

    fprintf(stderr, "pre-capture line that must not be collected\n");
    fflush(stderr);

    OMStdioCapture capture;
    OMStdioCaptureInit(&capture);
    check(OMStdioCaptureBegin(&capture, g_dir) == 1, "Begin succeeds");

    struct stat during;
    check(fd_stat(STDERR_FILENO, &during) && S_ISREG(during.st_mode),
          "stderr is a regular file while capturing");
    check(fd_stat(STDOUT_FILENO, &during) && S_ISREG(during.st_mode),
          "stdout is a regular file while capturing");

    fprintf(stderr, "ld64: library not found for -lSystem\n");
    fprintf(stdout, "linker stdout line\n");
    fflush(stdout);

    char out[4096];
    char err[4096];
    OMStdioCaptureEnd(&capture, out, sizeof(out), err, sizeof(err));

    check(strstr(err, "library not found for -lSystem") != NULL,
          "captured stderr carries the ld64 message");
    check(strstr(err, "pre-capture line") == NULL,
          "stderr written before Begin is not captured");
    check(strstr(err, "linker stdout line") == NULL,
          "stdout does not leak into the stderr buffer");
    check(strstr(out, "linker stdout line") != NULL,
          "captured stdout carries the stdout line");
    check(strstr(out, "library not found") == NULL,
          "stderr does not leak into the stdout buffer");

    check(same_file(STDOUT_FILENO, &stdoutBefore), "stdout restored to the original file");
    check(same_file(STDERR_FILENO, &stderrBefore), "stderr restored to the original file");
    check(count_prefixed(g_dir, "om-ld64-") == 0, "no capture files left behind");

    // A restored stderr must still accept writes; otherwise every later
    // diagnostic in the process disappears.
    fprintf(stderr, "after-capture line\n");
    fflush(stderr);
}

static void test_read_is_bounded(void) {
    printf("-- bounded read\n");
    OMStdioCapture capture;
    OMStdioCaptureInit(&capture);
    check(OMStdioCaptureBegin(&capture, g_dir) == 1, "Begin succeeds for the long line");

    for (int i = 0; i < 64; i++) fprintf(stderr, "0123456789abcdef");
    fflush(stderr);

    char err[64];
    memset(err, 'Z', sizeof(err));
    OMStdioCaptureEnd(&capture, NULL, 0, err, sizeof(err));

    check(err[sizeof(err) - 1] == '\0', "captured text is NUL terminated");
    check(strlen(err) == sizeof(err) - 1, "captured text fills exactly cap-1 bytes");
    check(strstr(err, "0123456789abcdef") != NULL, "captured text starts at the first byte");
    check(count_prefixed(g_dir, "om-ld64-") == 0, "long capture removed its files");
}

static void test_abandon_and_idempotence(void) {
    printf("-- abandon form and repeated End\n");
    struct stat stderrBefore;
    check(fd_stat(STDERR_FILENO, &stderrBefore), "stderr stat before abandon");

    OMStdioCapture capture;
    OMStdioCaptureInit(&capture);
    check(OMStdioCaptureBegin(&capture, g_dir) == 1, "Begin succeeds for abandon");
    fprintf(stderr, "dropped on the floor\n");
    fflush(stderr);

    OMStdioCaptureEnd(&capture, NULL, 0, NULL, 0);
    check(same_file(STDERR_FILENO, &stderrBefore), "abandon restores stderr");
    check(count_prefixed(g_dir, "om-ld64-") == 0, "abandon removes its files");

    OMStdioCaptureEnd(&capture, NULL, 0, NULL, 0);
    OMStdioCaptureRestore(&capture);
    check(same_file(STDERR_FILENO, &stderrBefore), "repeated restore is harmless");
    check(count_prefixed(g_dir, "om-ld64-") == 0, "repeated End leaves no files");
}

static void test_refuses_bad_usage(void) {
    printf("-- refused usage\n");
    struct stat stderrBefore;
    check(fd_stat(STDERR_FILENO, &stderrBefore), "stderr stat before refused usage");

    OMStdioCapture capture;
    OMStdioCaptureInit(&capture);
    check(OMStdioCaptureBegin(&capture, "/nonexistent/om/capture/dir") == 0,
          "Begin rejects a missing directory");
    check(same_file(STDERR_FILENO, &stderrBefore), "rejected Begin leaves stderr alone");
    check(count_prefixed(g_dir, "om-ld64-") == 0, "rejected Begin creates no files");

    check(OMStdioCaptureBegin(&capture, g_dir) == 1, "Begin succeeds for the nesting check");
    OMStdioCapture nested;
    OMStdioCaptureInit(&nested);
    check(OMStdioCaptureBegin(&nested, g_dir) == 0, "a second capture refuses to nest");
    check(count_prefixed(g_dir, "om-ld64-") == 2, "nested refusal leaves the first capture intact");

    char err[128];
    OMStdioCaptureEnd(&capture, NULL, 0, err, sizeof(err));
    check(same_file(STDERR_FILENO, &stderrBefore), "outer capture restored stderr");
    check(count_prefixed(g_dir, "om-ld64-") == 0, "outer capture removed both files");

    // A refused Begin must not leave the guard latched, or the next call in
    // the process silently stops being captured.
    OMStdioCapture reused;
    OMStdioCaptureInit(&reused);
    check(OMStdioCaptureBegin(&reused, g_dir) == 1, "End releases the capture slot");
    OMStdioCaptureEnd(&reused, NULL, 0, NULL, 0);
    check(count_prefixed(g_dir, "om-ld64-") == 0, "released capture cleaned up");
}

static void test_restore_without_end(void) {
    printf("-- restore without reading\n");
    struct stat stderrBefore;
    check(fd_stat(STDERR_FILENO, &stderrBefore), "stderr stat before restore-only");

    OMStdioCapture capture;
    OMStdioCaptureInit(&capture);
    check(OMStdioCaptureBegin(&capture, g_dir) == 1, "Begin succeeds for restore-only");
    OMStdioCaptureRestore(&capture);
    check(same_file(STDERR_FILENO, &stderrBefore), "restore-only puts stderr back");

    // This is the exception path: descriptors are back, files still on disk.
    check(count_prefixed(g_dir, "om-ld64-") == 2, "restore-only leaves files for the reader");
    OMStdioCaptureEnd(&capture, NULL, 0, NULL, 0);
    check(count_prefixed(g_dir, "om-ld64-") == 0, "trailing End still cleans up");
}

int main(void) {
    snprintf(g_dir, sizeof(g_dir), "/tmp/om-stdio-capture-test-%d", (int)getpid());
    if (mkdir(g_dir, 0700) != 0) {
        printf("cannot create %s\n", g_dir);
        return 2;
    }

    test_round_trip();
    test_read_is_bounded();
    test_abandon_and_idempotence();
    test_refuses_bad_usage();
    test_restore_without_end();

    /* Anything a check reported while a capture was live has not reached the
       terminal yet. */
    flush_report();
    check(count_prefixed(g_dir, "om-ld64-") == 0, "no capture files left behind at the end");
    flush_report();

    rmdir(g_dir);
    if (failures != 0) {
        printf("\n%d check(s) failed\n", failures);
        return 1;
    }
    printf("\nall stdio capture checks passed\n");
    return 0;
}
