// SPDX-License-Identifier: Apache-2.0
#import "ICNProtocol.h"
#import <sys/socket.h>
#import <sys/un.h>
#import <sys/stat.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <errno.h>
#import <fcntl.h>
// Public libproc entry exported by libSystem on iOS; absent in the trimmed SDK header set.
extern int proc_pidpath(int pid, void *buffer, uint32_t buffersize);

NSDictionary *ICNError(NSString *code, NSString *message) {
    return @{ @"error": @{ @"code": code, @"message": message } };
}
NSData *ICNJSON(NSDictionary *object) {
    return [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
}
NSDictionary *ICNJSONData(NSData *data) {
    id value = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}
void ICNSetTimeout(int fd, NSTimeInterval seconds) {
    struct timeval t = { (time_t)seconds, (suseconds_t)((seconds - (time_t)seconds)*1000000) };
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &t, sizeof(t));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &t, sizeof(t));
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, sizeof(yes));
    fcntl(fd, F_SETFD, FD_CLOEXEC);
}
BOOL ICNReadExact(int fd, void *buffer, size_t length) {
    size_t at = 0;
    while (at < length) {
        ssize_t n = recv(fd, (char *)buffer + at, length-at, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        at += n;
    }
    return YES;
}
BOOL ICNWriteExact(int fd, const void *buffer, size_t length) {
    size_t at = 0;
    while (at < length) {
        ssize_t n = send(fd, (char *)buffer + at, length-at, 0);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return NO;
        at += n;
    }
    return YES;
}
NSDictionary *ICNReadFrame(int fd, NSUInteger maximum) {
    uint32_t be;
    if (!ICNReadExact(fd, &be, sizeof(be))) return nil;
    uint32_t length = ntohl(be);
    if (!length || length > maximum) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:length];
    return ICNReadExact(fd, data.mutableBytes, length) ? ICNJSONData(data) : nil;
}
BOOL ICNWriteFrame(int fd, NSDictionary *object) {
    NSData *data = ICNJSON(object);
    if (!data || data.length > ICN_MAX_FRAME) return NO;
    uint32_t be = htonl((uint32_t)data.length);
    return ICNWriteExact(fd, &be, sizeof(be)) && ICNWriteExact(fd, data.bytes, data.length);
}
BOOL ICNVerifyPeer(int fd, BOOL daemonPeer) {
    uid_t uid = -1; gid_t gid = -1;
    if (getpeereid(fd, &uid, &gid) || uid != ICN_MOBILE_UID) return NO;
    pid_t pid = 0; socklen_t len = sizeof(pid);
    if (getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &len) || pid <= 0) return NO;
    char path[4096] = {0}, expected[4096] = {0}, normalized[4096] = {0};
    if (proc_pidpath(pid, path, sizeof(path)) <= 0) return NO;
    const char *wanted = daemonPeer ? ICN_DAEMON : "/System/Library/CoreServices/SpringBoard.app/SpringBoard";
    if (!realpath(wanted, expected)) return NO;
    // proc_pidpath may report the launchd-visible /var/jb path while realpath
    // resolves the same rootless binary into its preboot target. Compare both
    // after canonicalization, and never accept a caller-controlled suffix.
    if (!realpath(path, normalized)) return NO;
    return strcmp(normalized, expected) == 0;
}
BOOL ICNEnsureStateDirectory(void) {
    const char *path = [ICN_STATE fileSystemRepresentation];
    struct stat s;
    if (lstat(path, &s) == 0)
        return S_ISDIR(s.st_mode) && !S_ISLNK(s.st_mode) && s.st_uid == ICN_MOBILE_UID && (s.st_mode & 077) == 0;
    if (errno != ENOENT) return NO;
    if (mkdir(path, 0700) && errno != EEXIST) return NO;
    if (lstat(path, &s)) return NO;
    return S_ISDIR(s.st_mode) && !S_ISLNK(s.st_mode) && s.st_uid == ICN_MOBILE_UID && (s.st_mode & 077) == 0;
}
BOOL ICNSafeStateDirectory(void) {
    struct stat s;
    const char *path = [ICN_STATE fileSystemRepresentation];
    return lstat(path, &s) == 0 && S_ISDIR(s.st_mode) && !S_ISLNK(s.st_mode)
        && s.st_uid == ICN_MOBILE_UID && (s.st_mode & 077) == 0;
}
NSDictionary *ICNBridgeCall(NSString *method, NSDictionary *params, NSTimeInterval timeout) {
    if (!ICNSafeStateDirectory()) return ICNError(@"state_unavailable", @"Private bridge directory is missing or unsafe");
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return ICNError(@"bridge_unavailable", @"Cannot create bridge socket");
    ICNSetTimeout(fd, timeout);
    struct sockaddr_un addr = {0}; addr.sun_family = AF_UNIX;
    strlcpy(addr.sun_path, ICN_SOCKET, sizeof(addr.sun_path));
    NSDictionary *response;
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) || !ICNVerifyPeer(fd, NO)) {
        response = ICNError(@"bridge_unavailable", @"SpringBoard bridge not ready; no DDI fallback is used");
    } else if (!ICNWriteFrame(fd, @{ @"method": method, @"params": params ?: @{} })) {
        response = ICNError(@"bridge_unavailable", @"Cannot send bridge request");
    } else {
        response = ICNReadFrame(fd, ICN_MAX_FRAME) ?: ICNError(@"bridge_timeout", @"Bridge did not reply in time");
    }
    close(fd);
    return response;
}
