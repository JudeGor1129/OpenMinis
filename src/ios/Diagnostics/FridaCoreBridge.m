#import "FridaCoreBridge.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <string.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#if __has_include(<frida-core.h>)
#import <frida-core.h>
#define OPENMINIS_HAS_FRIDA_CORE 1
#else
#define OPENMINIS_HAS_FRIDA_CORE 0
#endif

// The embedded Frida Core path is disabled at runtime after device reboot
// reports on iOS15 jailbreak devices. Keep the link probe and source wiring in
// place for compatibility work, but do not initialize Frida, enumerate local
// processes, or contact a socket until a device-specific compatibility review
// explicitly removes this gate.
#define OPENMINIS_FRIDA_RUNTIME_DISABLED 1

/// Non-blocking connect probe with a 1 s budget. Used only to tell the user
/// whether *their* frida-server is listening; it never speaks the Frida
/// protocol, so a failure here is not proof that attach would fail and a
/// success is not proof that attach would work.
static BOOL OpenMinisTCPPortOpen(const char *host, int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return NO;
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons((uint16_t)port);
    addr.sin_addr.s_addr = inet_addr(host);
    int flags = fcntl(fd, F_GETFL, 0);
    if (flags >= 0) fcntl(fd, F_SETFL, flags | O_NONBLOCK);
    BOOL open = NO;
    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) == 0) {
        open = YES;
    } else if (errno == EINPROGRESS) {
        fd_set wset;
        FD_ZERO(&wset);
        FD_SET(fd, &wset);
        struct timeval tv;
        tv.tv_sec = 1;
        tv.tv_usec = 0;
        if (select(fd + 1, NULL, &wset, NULL, &tv) > 0) {
            int soerr = 0;
            socklen_t len = sizeof(soerr);
            if (getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &len) == 0 && soerr == 0) open = YES;
        }
    }
    close(fd);
    return open;
}

/// Concrete, actionable server diagnostics. The previous output only said a
/// socket query failed, which is indistinguishable from a sandbox denial — so
/// users kept reinstalling the Frida package. Report the three facts that
/// actually decide the outcome: is a server binary on disk, is it executable,
/// and is anything listening on the default port.
NSArray<NSString *> *OpenMinisFridaServerDiagnostics(void) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSArray<NSString *> *candidates = @[
        @"/var/jb/usr/sbin/frida-server",
        @"/var/jb/usr/bin/frida-server",
        @"/usr/sbin/frida-server",
        @"/usr/bin/frida-server",
    ];
    NSString *foundPath = nil;
    for (NSString *path in candidates) {
        if (access(path.fileSystemRepresentation, F_OK) == 0) {
            BOOL executable = access(path.fileSystemRepresentation, X_OK) == 0;
            [lines addObject:[NSString stringWithFormat:@"Server binary: %@%@",
                              path, executable ? @" (executable)" : @" (NOT executable)"]];
            if (foundPath == nil && executable) foundPath = path;
        }
    }
    if (foundPath == nil) {
        [lines addObject:@"Server binary: none found in /var/jb/usr/sbin, /var/jb/usr/bin, /usr/sbin, /usr/bin. Install a Frida server package only if you intend to run one."];
    }

    BOOL listening = OpenMinisTCPPortOpen("127.0.0.1", 27042);
    [lines addObject:[NSString stringWithFormat:@"Port 127.0.0.1:27042: %@",
                      listening ? @"OPEN (a Frida server is listening)" : @"CLOSED (nothing is listening)"]];
    if (!listening) {
        [lines addObject:@"Cause of a failed socket backend is therefore the missing listener, not necessarily this app's sandbox."];
        [lines addObject:@"Remedy (requires root, then re-run this tool): launchctl bootstrap system /var/jb/Library/LaunchDaemons/re.frida.server.plist"];
        [lines addObject:@"Alternative remedy: reboot the device so the jailbreak launcher re-bootstraps its LaunchDaemons."];
        [lines addObject:@"This app cannot start a root-owned server process on its own."];
    }
    return lines;
}

BOOL OpenMinisFridaDiagnosticsAvailable(void) {
    return YES;
}

BOOL OpenMinisFridaCoreAvailable(void) {
#if OPENMINIS_FRIDA_RUNTIME_DISABLED
    return NO;
#else
    return OPENMINIS_HAS_FRIDA_CORE;
#endif
}

static void OpenMinisFridaInitialize(void) {
#if OPENMINIS_HAS_FRIDA_CORE
    static dispatch_once_t once;
    dispatch_once(&once, ^{ frida_init(); });
#endif
}

NSString *OpenMinisFridaCoreStatus(void) {
#if OPENMINIS_FRIDA_RUNTIME_DISABLED
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:
        @"Frida Core probing remains disabled for device safety; no Frida Core initialization or process enumeration was performed."];
    [lines addObjectsFromArray:OpenMinisFridaServerDiagnostics()];
    return [lines componentsJoinedByString:@"\n"];
#elif OPENMINIS_HAS_FRIDA_CORE
    // Frida is process-wide: never tear it down between tool calls.
    OpenMinisFridaInitialize();
    FridaDeviceManager *manager = frida_device_manager_new();
    if (manager == NULL) return @"ERROR: Frida device manager initialization failed.";
    GError *error = NULL;
    FridaDeviceList *devices = frida_device_manager_enumerate_devices_sync(manager, NULL, &error);
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"Frida Core %s initialized. No process attached; no scripts executed.", frida_version_string()]];
    if (error != NULL) {
        [lines addObject:[NSString stringWithFormat:@"ERROR: %s", error->message]];
        g_error_free(error);
    } else if (devices != NULL) {
        gint count = frida_device_list_size(devices);
        for (gint i = 0; i < MIN(count, 32); i++) {
            FridaDevice *device = frida_device_list_get(devices, i);
            [lines addObject:[NSString stringWithFormat:@"Device: %s (%s)",
                frida_device_get_name(device), frida_device_get_id(device)]];
            g_object_unref(device);
        }
        [lines addObject:@"Device enumeration is not proof of frida-server connectivity or attach permission."];
    }
    if (devices != NULL) g_object_unref(devices);
    [lines addObjectsFromArray:OpenMinisFridaServerDiagnostics()];
    frida_device_manager_close_sync(manager, NULL, NULL);
    g_object_unref(manager);
    return [lines componentsJoinedByString:@"\n"];
#else
    return @"ERROR: Frida Core is not embedded in this build.";
#endif
}

static dispatch_queue_t OpenMinisFridaQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("app.openminis.frida", DISPATCH_QUEUE_SERIAL); });
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
    dispatch_async(OpenMinisFridaQueue(), ^{
        @autoreleasepool {
            NSMutableArray<NSString *> *lines = [NSMutableArray array];
#if OPENMINIS_FRIDA_RUNTIME_DISABLED
            [lines addObject:@"ERROR: Frida process probing remains disabled for device safety; use frida_status for non-invasive server diagnostics."];
#elif OPENMINIS_HAS_FRIDA_CORE
            // Initialize once without performing another device enumeration.
            OpenMinisFridaInitialize();
            FridaDeviceManager *manager = frida_device_manager_new();
            if (manager == NULL) {
                dispatch_async(dispatch_get_main_queue(), ^{ completion(@"ERROR: Frida device manager initialization failed."); });
                return;
            }
            GError *error = NULL;
            FridaDeviceList *devices = frida_device_manager_enumerate_devices_sync(manager, NULL, &error);
            gint successfulQueries = 0;
            gint totalProcesses = 0;
            gint printed = 0;
            if (error != NULL) {
                [lines addObject:[NSString stringWithFormat:@"ERROR: Device enumeration: %s", error->message]];
                g_error_free(error);
            } else if (devices != NULL) {
                for (gint d = 0; d < frida_device_list_size(devices); d++) {
                    FridaDevice *device = frida_device_list_get(devices, d);
                    const gchar *deviceID = frida_device_get_id(device);
                    // Only the two built-in on-device endpoints. Never probe
                    // discovered USB devices or arbitrary network endpoints.
                    if (g_strcmp0(deviceID, "local") != 0 && g_strcmp0(deviceID, "socket") != 0) {
                        g_object_unref(device);
                        continue;
                    }
                    [lines addObject:[NSString stringWithFormat:@"Backend: %s (%s)", frida_device_get_name(device), deviceID]];
                    GCancellable *cancel = g_cancellable_new();
                    // Cancellation is cooperative; retain through the delayed
                    // block even when enumeration finishes before the deadline.
                    g_object_ref(cancel);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                        g_cancellable_cancel(cancel);
                        g_object_unref(cancel);
                    });
                    FridaProcessQueryOptions *options = frida_process_query_options_new();
                    GError *queryError = NULL;
                    FridaProcessList *processes = frida_device_enumerate_processes_sync(device, options, cancel, &queryError);
                    if (queryError != NULL) {
                        [lines addObject:[NSString stringWithFormat:@"WARNING: Backend query failed: %s", queryError->message]];
                        g_error_free(queryError);
                    } else if (processes != NULL) {
                        successfulQueries++;
                        gint count = frida_process_list_size(processes);
                        totalProcesses += count;
                        [lines addObject:[NSString stringWithFormat:@"Processes: %d. PID\tName (combined output limit: 300)", count]];
                        for (gint i = 0; i < count && printed < 300; i++, printed++) {
                            FridaProcess *process = frida_process_list_get(processes, i);
                            [lines addObject:[NSString stringWithFormat:@"%u\t%s", frida_process_get_pid(process), frida_process_get_name(process)]];
                            g_object_unref(process);
                        }
                        if (count == 0) [lines addObject:@"WARNING: Empty result from this backend; cause undetermined. This does not prove sandbox restrictions or the absence of running processes."];
                    } else {
                        [lines addObject:@"WARNING: Backend returned no process list."];
                    }
                    if (processes != NULL) g_object_unref(processes);
                    g_object_unref(options);
                    g_object_unref(cancel);
                    g_object_unref(device);
                }
            }
            if (devices != NULL) g_object_unref(devices);
            if (successfulQueries == 0) {
                [lines addObject:@"ERROR: No built-in backend completed process enumeration. Review backend errors; server connectivity and permissions are not established."];
                // The failure above is the exact symptom users misread as a
                // sandbox denial. Add the server-side facts so the cause is
                // visible without a shell.
                [lines addObjectsFromArray:OpenMinisFridaServerDiagnostics()];
            } else if (totalProcesses == 0) {
                [lines addObject:@"WARNING: All successful queries were empty. Process visibility remains unverified; do not claim a specific cause or attach capability."];
            }
            frida_device_manager_close_sync(manager, NULL, NULL);
            g_object_unref(manager);
            [lines addObject:@"Read-only enumeration; no process attached or script executed. Visibility is limited by this app's actual privileges; listing does not prove attach permission."];
#else
            [lines addObject:@"ERROR: Frida Core is not embedded in this build."];
#endif
            NSString *result = [lines componentsJoinedByString:@"\n"];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    });
}
