#ifndef MINIS_HELPER_LEASE_H
#define MINIS_HELPER_LEASE_H
#include <errno.h>
#include <stdlib.h>
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
#define MINIS_HELPER_REQUEST_FD 3
#define MINIS_HELPER_REQUEST_LIMIT (3u * 1024u * 1024u)

static inline int MinisHelperReadRequestFrame(int fd, unsigned char **outData, size_t *outSize) {
    unsigned char header[4]; size_t got = 0;
    while (got < sizeof(header)) {
        ssize_t n = read(fd, header + got, sizeof(header) - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return n == 0 ? ECONNRESET : errno;
        got += (size_t)n;
    }
    size_t size = ((size_t)header[0] << 24) | ((size_t)header[1] << 16) |
                  ((size_t)header[2] << 8) | (size_t)header[3];
    if (size < 2 || size > MINIS_HELPER_REQUEST_LIMIT) return EOVERFLOW;
    unsigned char *data = malloc(size);
    if (!data) return ENOMEM;
    got = 0;
    while (got < size) {
        ssize_t n = read(fd, data + got, size - got);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) { free(data); return n == 0 ? ECONNRESET : errno; }
        got += (size_t)n;
    }
    *outData = data; *outSize = size; return 0;
}
#endif
