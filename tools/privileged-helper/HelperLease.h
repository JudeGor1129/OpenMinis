#ifndef MINIS_HELPER_LEASE_H
#define MINIS_HELPER_LEASE_H
#include <errno.h>
#include <unistd.h>

// Fixed one-byte protocol, not a command channel. Read synchronously before
// doing any privileged work; only then start the revocation monitor thread.
static inline int MinisHelperAwaitLaunchPermit(int fd) {
    char byte;
    ssize_t n;
    do { n = read(fd, &byte, 1); } while (n < 0 && errno == EINTR);
    return n == 1 && byte == 'G';
}
static inline void MinisHelperWaitForRevocation(int fd) {
    char byte;
    ssize_t n;
    do { n = read(fd, &byte, 1); } while (n < 0 && errno == EINTR);
    _exit(125); // EOF, error, or unexpected extra data revokes the lease.
}
#endif
