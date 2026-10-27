#import "FridaCoreBridge.h"
#import "PrivilegedHelperBridge.h"
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

// Core is deliberately never imported, initialized or enumerated in the GUI.
// The opt-in helper uses a socket-only backend in a short-lived child process.
static BOOL LoopbackPortOpen(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags < 0 || fcntl(fd, F_SETFL, flags | O_NONBLOCK) < 0) { close(fd); return NO; }
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    struct sockaddr_in addr = {0};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(27042);
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL open = NO;
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) open = YES;
    else if (errno == EINPROGRESS) {
        struct pollfd p = {fd, POLLOUT, 0};
        if (poll(&p, 1, 1000) > 0) {
            int err = 0; socklen_t size = sizeof(err);
            open = getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &size) == 0 && err == 0;
        }
    }
    close(fd);
    return open;
}
NSArray<NSString *> *OpenMinisFridaServerDiagnostics(void) {
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:OpenMinisNativeIdentity()];
    BOOL found = NO, executable = NO;
    for (NSString *path in @[@"/var/jb/usr/sbin/frida-server", @"/var/jb/usr/bin/frida-server", @"/usr/sbin/frida-server", @"/usr/bin/frida-server"]) {
        if (access(path.fileSystemRepresentation, F_OK) != 0) continue;
        found = YES;
        BOOL canExecute = access(path.fileSystemRepresentation, X_OK) == 0;
        executable |= canExecute;
        [lines addObject:[NSString stringWithFormat:@"Server binary: %@ (%@ from this app's access check)", path, canExecute ? @"executable" : @"execution not permitted"]];
    }
    if (!found) [lines addObject:@"No server binary was visible in the known paths from this app's actual identity."];
    else if (!executable) [lines addObject:@"A server file exists but this app cannot execute it. This is not evidence that no server is already running."];
    BOOL open = LoopbackPortOpen();
    [lines addObject:[NSString stringWithFormat:@"Port 127.0.0.1:27042: %@", open ? @"OPEN (listener identity/protocol unverified)" : @"CLOSED or inaccessible from this app"]];
    [lines addObject:@"A TCP port check does not identify Frida, verify its version, or prove attach capability. No root server was started or modified."];
    return lines;
}
BOOL OpenMinisFridaDiagnosticsAvailable(void) { return YES; }
// Core remains unavailable IN THIS PROCESS even when the separate helper exists.
BOOL OpenMinisFridaCoreAvailable(void) { return NO; }
NSString *OpenMinisFridaCoreStatus(void) {
    NSMutableArray *lines = [NSMutableArray arrayWithObject:@"Frida Core probing remains disabled in the GUI; status performs no protocol requests. Experimental process queries run only in an explicitly enabled isolated helper."];
    [lines addObjectsFromArray:OpenMinisFridaServerDiagnostics()];
    return [lines componentsJoinedByString:@"\n"];
}
static dispatch_queue_t OpenMinisFridaQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("app.openminis.frida-diagnostics", DISPATCH_QUEUE_SERIAL); });
    return queue;
}
void OpenMinisFridaCoreStatusAsync(void (^completion)(NSString *)) {
    dispatch_async(OpenMinisFridaQueue(), ^{
        @autoreleasepool {
            NSString *result = OpenMinisFridaCoreStatus();
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    });
}
void OpenMinisFridaProcessesAsync(void (^completion)(NSString *)) {
    OpenMinisPrivilegedRequest *request = [[OpenMinisPrivilegedRequest alloc] initWithAction:@"frida-processes"];
    [request runWithCompletion:completion];
}
