#ifndef MINIS_HELPER_PROCESS_RUNNER_H
#define MINIS_HELPER_PROCESS_RUNNER_H
#include <stdatomic.h>
#include <stddef.h>
#include <stdbool.h>

#define MINIS_HELPER_OUTPUT_LIMIT (256u * 1024u)
typedef struct { atomic_bool cancelled; atomic_int launch_state; } MinisHelperControl;
typedef struct {
    int spawn_error;
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
/// Fixed executable + one action, never a shell. On Apple rootPersona sets
/// checked persona attrs; elsewhere it fails ENOTSUP. Drains both pipes,
/// caps combined output, kills/reaps on timeout/cancel, CLOEXEC all extra FDs.
MinisHelperResult MinisHelperRun(const char *executable, const char *action,
    bool rootPersona, unsigned timeout_ms, MinisHelperControl *control);
void MinisHelperResultFree(MinisHelperResult *result);
#endif
