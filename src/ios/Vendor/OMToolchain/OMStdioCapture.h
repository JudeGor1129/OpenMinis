//
//  OMStdioCapture.h
//  Minis
//
//  Collects the process's stdout/stderr for the duration of one call into a
//  library that was written as a command-line tool.
//
//  Why this exists
//  ---------------
//  The vendored ld64 reports every failure the way a CLI does:
//
//      catch (const char* msg) { fprintf(stderr, "%s\n", msg); return 1; }
//
//  build-ld64-inprocess.py turns that `exit(n)` into `return n` so the host
//  survives, but the message still goes to file descriptor 2. Inside the app
//  fd 2 is not connected to anything the host can read back, so a failed link
//  arrived as
//
//      OMToolchain: ld64 exited with status 1
//
//  with no reason attached, and a 0.2 ms failure cannot be told apart from a
//  "library not found" or a bad output path. The descriptor has to be moved
//  while the call is in flight, which is all this header does.
//
//  Contract
//  --------
//  * Begin() moves fd 1 and fd 2 onto two temporary files in `directory`.
//  * End() flushes, restores the original descriptors, reads both files back
//    into caller buffers (**always NUL-terminated**) and unlinks them.
//  * End() with NULL output buffers is the abandon form: it only restores.
//  * End(), Restore() and Begin() are idempotent, so an exception path can
//    restore unconditionally without tracking which step failed.
//  * At most one capture may be live at a time (see "One capture at a time").
//  * Nothing here allocates through C++ or Objective-C, so it is safe inside
//    the @try/@catch that wraps the ld64 call.
//
//  Only stdout/stderr are touched. stdin is left alone.
//
//  One capture at a time
//  ---------------------
//  A second Begin() while any capture is live is refused rather than nested.
//  Nesting would look like it worked and then quietly swallow the outer
//  capture: the inner End() would restore fd 1/2 and leave the outer capture
//  reading a file that is no longer being written to. The guard is per
//  translation unit, which matches the intended use: one host, one call in
//  flight, restored before the next call. Concurrent calls from several
//  threads are not supported; the caller serialises them.
//

#ifndef OM_STDIO_CAPTURE_H
#define OM_STDIO_CAPTURE_H

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#ifdef __cplusplus
extern "C" {
#endif

#define OM_STDIO_CAPTURE_PATH_MAX 512

typedef struct {
    int  active;        /* 1 once both descriptors have been moved */
    int  stdout_moved;  /* fd 1 currently points at fd_out */
    int  stderr_moved;  /* fd 2 currently points at fd_err */
    int  saved_stdout;  /* dup() of the caller's fd 1, -1 when not held */
    int  saved_stderr;  /* dup() of the caller's fd 2, -1 when not held */
    int  fd_out;        /* temp file holding captured stdout, -1 when not held */
    int  fd_err;        /* temp file holding captured stderr, -1 when not held */
    char path_out[OM_STDIO_CAPTURE_PATH_MAX];
    char path_err[OM_STDIO_CAPTURE_PATH_MAX];
} OMStdioCapture;

/// The capture that currently owns fd 1/2, or NULL. Per translation unit.
///
/// A function-local static keeps the slot out of the file's namespace, so a
/// translation unit that includes this header without using it emits no
/// unused-variable diagnostics under -Werror.
static inline OMStdioCapture **OMStdioCaptureOwnerSlot(void) {
    static OMStdioCapture *owner = NULL;
    return &owner;
}

/// True while fd 1/2 belong to a capture. Callers that want to print their own
/// progress can use this to avoid printing into the capture file.
static inline int OMStdioCaptureIsLive(void) {
    return *OMStdioCaptureOwnerSlot() != NULL;
}

static inline void OMStdioCaptureInit(OMStdioCapture *capture) {
    if (capture == NULL) return;
    memset(capture, 0, sizeof(*capture));
    capture->saved_stdout = -1;
    capture->saved_stderr = -1;
    capture->fd_out = -1;
    capture->fd_err = -1;
}

/* Closes and unlinks the temp files. Only valid while nothing is redirected. */
static inline void OMStdioCaptureDropFiles(OMStdioCapture *capture) {
    if (capture == NULL) return;
    if (capture->fd_out >= 0) { close(capture->fd_out); capture->fd_out = -1; }
    if (capture->fd_err >= 0) { close(capture->fd_err); capture->fd_err = -1; }
    if (capture->path_out[0] != '\0') { unlink(capture->path_out); capture->path_out[0] = '\0'; }
    if (capture->path_err[0] != '\0') { unlink(capture->path_err); capture->path_err[0] = '\0'; }
}

/* Hands fd 1 and fd 2 back to the caller. Safe to call twice, safe to call
   after a partial Begin(), and safe to call on a capture that never started.
   Leaves the temp fds open so the captured bytes can still be read. */
static inline void OMStdioCaptureRestore(OMStdioCapture *capture) {
    if (capture == NULL) return;
    if (capture->stdout_moved) {
        /* Bytes the callee left in the stdio buffer belong in the capture, so
           push them out before the descriptor moves back. */
        fflush(stdout);
        dup2(capture->saved_stdout, STDOUT_FILENO);
        capture->stdout_moved = 0;
    }
    if (capture->stderr_moved) {
        fflush(stderr);
        dup2(capture->saved_stderr, STDERR_FILENO);
        capture->stderr_moved = 0;
    }
    if (capture->saved_stdout >= 0) { close(capture->saved_stdout); capture->saved_stdout = -1; }
    if (capture->saved_stderr >= 0) { close(capture->saved_stderr); capture->saved_stderr = -1; }
    capture->active = 0;
    OMStdioCapture **slot = OMStdioCaptureOwnerSlot();
    if (*slot == capture) *slot = NULL;
}

static inline int OMStdioCaptureBegin(OMStdioCapture *capture, const char *directory) {
    if (capture == NULL || directory == NULL || directory[0] == '\0') return 0;
    if (capture->active || capture->fd_out >= 0 || capture->fd_err >= 0) return 0;
    if (OMStdioCaptureIsLive()) return 0;

    int written = snprintf(capture->path_out, sizeof(capture->path_out),
                           "%s/om-ld64-stdout.XXXXXX", directory);
    if (written < 0 || (size_t)written >= sizeof(capture->path_out)) return 0;
    written = snprintf(capture->path_err, sizeof(capture->path_err),
                       "%s/om-ld64-stderr.XXXXXX", directory);
    if (written < 0 || (size_t)written >= sizeof(capture->path_err)) {
        capture->path_out[0] = '\0';
        return 0;
    }

    capture->fd_out = mkstemp(capture->path_out);
    if (capture->fd_out < 0) {
        capture->path_out[0] = '\0';
        capture->path_err[0] = '\0';
        return 0;
    }
    capture->fd_err = mkstemp(capture->path_err);
    if (capture->fd_err < 0) {
        OMStdioCaptureDropFiles(capture);
        return 0;
    }

    do {
        /* The caller's own earlier output must not land in the capture. */
        fflush(stdout);
        fflush(stderr);

        capture->saved_stdout = dup(STDOUT_FILENO);
        if (capture->saved_stdout < 0) break;
        if (dup2(capture->fd_out, STDOUT_FILENO) < 0) break;
        capture->stdout_moved = 1;

        capture->saved_stderr = dup(STDERR_FILENO);
        if (capture->saved_stderr < 0) break;
        if (dup2(capture->fd_err, STDERR_FILENO) < 0) break;
        capture->stderr_moved = 1;
    } while (0);

    if (!capture->stdout_moved || !capture->stderr_moved) {
        /* Undo whatever moved, then give up. Undoing matters: a half-moved
           fd 1 left pointing at a file that DropFiles is about to unlink
           would cost the process its stdout for good. */
        OMStdioCaptureRestore(capture);
        OMStdioCaptureDropFiles(capture);
        return 0;
    }

    capture->active = 1;
    *OMStdioCaptureOwnerSlot() = capture;
    return 1;
}

/* Reads at most cap-1 bytes and always terminates. Returns the length read. */
static inline size_t OMStdioCaptureRead(int fd, char *destination, size_t cap) {
    size_t used = 0;
    if (fd < 0 || destination == NULL || cap == 0) return 0;
    while (used + 1 < cap) {
        ssize_t got = pread(fd, destination + used, cap - 1 - used, (off_t)used);
        if (got <= 0) break;
        used += (size_t)got;
    }
    destination[used] = '\0';
    return used;
}

static inline void OMStdioCaptureEnd(OMStdioCapture *capture,
                                     char *outText, size_t outCap,
                                     char *errText, size_t errCap) {
    if (capture == NULL) return;
    OMStdioCaptureRestore(capture);
    if (outText != NULL && outCap > 0) OMStdioCaptureRead(capture->fd_out, outText, outCap);
    if (errText != NULL && errCap > 0) OMStdioCaptureRead(capture->fd_err, errText, errCap);
    OMStdioCaptureDropFiles(capture);
}

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* OM_STDIO_CAPTURE_H */
