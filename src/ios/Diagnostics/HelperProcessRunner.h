#ifndef MINIS_HELPER_PROCESS_RUNNER_H
#define MINIS_HELPER_PROCESS_RUNNER_H
#include <stdatomic.h>
#include <stddef.h>
#include <stdbool.h>

#define MINIS_HELPER_OUTPUT_LIMIT (256u * 1024u)
typedef struct { atomic_bool cancelled; atomic_int launch_state; } MinisHelperControl;
typedef struct {
    int spawn_error;
    int request_error;
    int exit_code;
    int term_signal;
    bool timed_out;
    bool cancelled;
    bool output_limit;
    size_t out_size, err_size;
    char *out_data, *err_data;
} MinisHelperResult;
void MinisHelperControlInit(MinisHelperControl *control);
void MinisHelperCancel(MinisHelperControl *control);
/// Fixed executable + allowlisted action, never a shell. argv is exactly
/// {executable, action}. FD 0 carries the one-byte launch/revocation lease;
/// FD 3 carries one frame (4-byte big-endian length + requestData, at most
/// 3 MiB) sent without blocking alongside output draining. "identity" gets no
/// frame (FD 3 EOF). On Apple rootPersona sets checked persona attrs; elsewhere
/// it fails ENOTSUP. Caps combined output, kills/reaps on timeout/cancel, and
/// CLOEXECs every other FD.
MinisHelperResult MinisHelperRun(const char *executable, const char *action,
    const void *requestData, size_t requestSize, bool rootPersona,
    unsigned timeout_ms, MinisHelperControl *control);
void MinisHelperResultFree(MinisHelperResult *result);
#endif
