#import "FridaCoreBridge.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <string.h>
#include <stdlib.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

#if __has_include(<frida-core.h>)
#import <frida-core.h>
#define OPENMINIS_HAS_FRIDA_CORE 1
#else
#define OPENMINIS_HAS_FRIDA_CORE 0
#endif

// [T-frida-remote-only]
//
// Minis talks to a user-installed frida-server over loopback. It never uses the
// in-process ("local") backend: that path was disabled after reboot reports on
// iOS 15 jailbreak devices, and it would need task_for_pid entitlements anyway.
// The root-owned server performs injection, so this process only needs to be
// able to open a TCP connection to 127.0.0.1:27042.
//
// Hard limits, all enforced here rather than in the UI:
//   * exactly one endpoint (loopback, default port) — never a discovered or
//     user-supplied host, so a tool call cannot be turned into a network probe;
//   * one serial queue for every frida call, so sessions never interleave;
//   * synchronous calls use a cooperative cancellation deadline; a blocked
//     library call may not stop immediately;
//   * script messages are bounded, and cleanup is attempted before completion.
static NSString *const OpenMinisFridaEndpoint = @"127.0.0.1:27042";
static const double OpenMinisFridaMaxTimeoutSeconds = 30.0;
static const NSUInteger OpenMinisFridaMaxMessages = 400;
static const NSUInteger OpenMinisFridaMaxMessageBytes = 16384;
static const NSUInteger OpenMinisFridaMaxTranscriptBytes = 131072;

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

/// Concrete, actionable server diagnostics. Reports the three facts that
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
        [lines addObject:@"Server binary: none found in /var/jb/usr/sbin, /var/jb/usr/bin, /usr/sbin, /usr/bin."];
    }

    BOOL listening = OpenMinisTCPPortOpen("127.0.0.1", 27042);
    [lines addObject:[NSString stringWithFormat:@"Port 127.0.0.1:27042: %@",
                      listening ? @"OPEN (listener detected; protocol unverified)" : @"CLOSED (nothing is listening)"]];
    if (!listening) {
        [lines addObject:@"A closed port means no listener, not a sandbox denial. Minis cannot start a root-owned server."];
        [lines addObject:@"Start it from a root shell: launchctl bootstrap system /var/jb/Library/LaunchDaemons/re.frida.server.plist"];
        [lines addObject:@"After a reboot the jailbreak launcher normally restarts it automatically."];
    }
    [lines addObject:@"Verify that client and server versions are compatible; a listening port does not prove this."];
    return lines;
}

BOOL OpenMinisFridaDiagnosticsAvailable(void) {
    return YES;
}

BOOL OpenMinisFridaCoreAvailable(void) {
#if OPENMINIS_HAS_FRIDA_CORE
    return YES;
#else
    return NO;
#endif
}

/// True when this build may actually attach and run scripts.
BOOL OpenMinisFridaScriptAvailable(void) {
    return OpenMinisFridaCoreAvailable();
}

#if OPENMINIS_HAS_FRIDA_CORE
static void OpenMinisFridaInitialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ frida_init(); });
}
#endif

static dispatch_queue_t OpenMinisFridaQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("app.openminis.frida", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

#if OPENMINIS_HAS_FRIDA_CORE
/// Cooperative cancellation deadline; Frida must honor GCancellable. This is
/// not a guaranteed hard timeout. The delayed block owns its own reference:
/// the operation may finish before the deadline fires.
static GCancellable *OpenMinisFridaDeadline(double seconds) {
    GCancellable *cancel = g_cancellable_new();
    GCancellable *heldCancel = g_object_ref(cancel);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        g_cancellable_cancel(heldCancel);
        g_object_unref(heldCancel);
    });
    return cancel;
}
#endif

NSString *OpenMinisFridaCoreStatus(void) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
#if OPENMINIS_HAS_FRIDA_CORE
    [lines addObject:[NSString stringWithFormat:@"Frida Core client %s embedded (remote-only backend).", frida_version_string()]];
    [lines addObject:[NSString stringWithFormat:@"Endpoint: %@", OpenMinisFridaEndpoint]];
#else
    [lines addObject:@"Frida Core is not embedded in this build; only server diagnostics are available."];
#endif
    [lines addObjectsFromArray:OpenMinisFridaServerDiagnostics()];
    return [lines componentsJoinedByString:@"\n"];
}

void OpenMinisFridaCoreStatusAsync(void (^completion)(NSString *)) {
    dispatch_async(OpenMinisFridaQueue(), ^{
        @autoreleasepool {
            NSString *result = OpenMinisFridaCoreStatus();
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    });
}

#if OPENMINIS_HAS_FRIDA_CORE

/// Connects the loopback server only. Never enumerates devices: device
/// enumeration is what exposes the in-process backend, and that backend is
/// deliberately unavailable here.
static FridaDevice *OpenMinisFridaOpenServer(FridaDeviceManager **outManager,
                                             GCancellable *cancel,
                                             GError **error) {
    FridaDeviceManager *manager = frida_device_manager_new();
    if (manager == NULL) return NULL;
    FridaDevice *device = frida_device_manager_add_remote_device_sync(
        manager, OpenMinisFridaEndpoint.UTF8String, NULL, cancel, error);
    if (device == NULL) {
        g_object_unref(manager);
        return NULL;
    }
    if (outManager != NULL) *outManager = manager;
    return device;
}

static NSString *OpenMinisFridaErrorLine(NSString *stage, GError *error) {
    if (error == NULL) return [NSString stringWithFormat:@"ERROR: %@ failed without a message.", stage];
    NSString *message = [NSString stringWithUTF8String:error->message] ?: @"unknown error";
    g_error_free(error);
    return [NSString stringWithFormat:@"ERROR: %@: %@", stage, message];
}

/// Resolves a pid from a numeric target or an exact (then case-insensitive)
/// process-name match on the server's process list.
static BOOL OpenMinisFridaResolvePID(FridaDevice *device, NSString *target,
                                     GCancellable *cancel, guint *outPID,
                                     NSMutableArray<NSString *> *lines, NSString **errorLine) {
    NSString *trimmed = [target stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) {
        *errorLine = @"ERROR: target is required.";
        return NO;
    }
    NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
    if ([trimmed rangeOfCharacterFromSet:[digits invertedSet]].location == NSNotFound) {
        unsigned long long value = strtoull(trimmed.UTF8String, NULL, 10);
        if (value > 0 && value <= UINT32_MAX) {
            *outPID = (guint)value;
            return YES;
        }
    }

    GError *error = NULL;
    FridaProcessList *processes = frida_device_enumerate_processes_sync(device, NULL, cancel, &error);
    if (error != NULL) {
        *errorLine = OpenMinisFridaErrorLine(@"enumerate processes", error);
        return NO;
    }
    if (processes == NULL) {
        *errorLine = @"ERROR: server returned no process list.";
        return NO;
    }

    guint match = 0;
    NSUInteger matchCount = 0;
    NSString *foldedTarget = trimmed.lowercaseString;
    gint count = frida_process_list_size(processes);
    for (gint i = 0; i < count; i++) {
        FridaProcess *process = frida_process_list_get(processes, i);
        NSString *name = [NSString stringWithUTF8String:frida_process_get_name(process)] ?: @"";
        if ([name isEqualToString:trimmed] || [name.lowercaseString isEqualToString:foldedTarget]) {
            match = frida_process_get_pid(process);
            matchCount++;
        }
        g_object_unref(process);
    }
    g_object_unref(processes);

    if (matchCount == 1) {
        *outPID = match;
        return YES;
    }
    *errorLine = matchCount > 1
        ? [NSString stringWithFormat:@"ERROR: multiple processes are named \"%@\"; use a PID from frida_processes.", trimmed]
        : [NSString stringWithFormat:@"ERROR: no running process named \"%@\". Call frida_processes to list targets.", trimmed];
    return NO;
}

@interface OpenMinisFridaMessageCollector : NSObject
@property(nonatomic, strong) NSMutableArray<NSString *> *lines;
@property(nonatomic) NSUInteger transcriptBytes;
@property(nonatomic) BOOL truncated;
@end

@implementation OpenMinisFridaMessageCollector
- (instancetype)init {
    self = [super init];
    if (self) _lines = [NSMutableArray array];
    return self;
}
@end

static void OpenMinisFridaReleaseCollector(gpointer data, GClosure *closure) {
    (void)closure;
    CFBridgingRelease(data);
}

static gboolean OpenMinisFridaStopLoop(gpointer userData) {
    g_main_loop_quit((GMainLoop *)userData);
    return G_SOURCE_REMOVE;
}

/// Frida's "message" GObject signal callback includes the emitting script.
static void OpenMinisFridaOnMessage(FridaScript *script, const gchar *message,
                                    GBytes *data, gpointer user_data) {
    @autoreleasepool {
        OpenMinisFridaMessageCollector *collector = (__bridge OpenMinisFridaMessageCollector *)user_data;
        if (message == NULL) return;
        gsize rawLength = strnlen(message, OpenMinisFridaMaxMessageBytes + 1);
        NSString *json = nil;
        if (rawLength > OpenMinisFridaMaxMessageBytes) {
            json = @"[error] Frida message exceeded 16 KiB and was truncated.";
        } else {
            json = [[NSString alloc] initWithBytes:message length:rawLength encoding:NSUTF8StringEncoding];
        }
        if (json.length == 0) return;
        NSDictionary *object = nil;
        NSData *payload = [json dataUsingEncoding:NSUTF8StringEncoding];
        if (payload != nil) {
            id parsed = [NSJSONSerialization JSONObjectWithData:payload options:0 error:NULL];
            if ([parsed isKindOfClass:NSDictionary.class]) object = parsed;
        }
        NSString *type = [object[@"type"] isKindOfClass:NSString.class] ? object[@"type"] : @"message";
        NSString *line = nil;
        if ([type isEqualToString:@"log"]) {
            line = [NSString stringWithFormat:@"[log] %@", object[@"payload"] ?: @""];
        } else if ([type isEqualToString:@"send"]) {
            id sent = object[@"payload"];
            NSString *text = [sent isKindOfClass:NSString.class] ? sent : [sent description];
            line = [NSString stringWithFormat:@"[send] %@", text ?: @""];
        } else if ([type isEqualToString:@"error"]) {
            NSString *description = [object[@"description"] isKindOfClass:NSString.class] ? object[@"description"] : json;
            NSString *stack = [object[@"stack"] isKindOfClass:NSString.class] ? object[@"stack"] : @"";
            line = stack.length > 0
                ? [NSString stringWithFormat:@"[error] %@\n%@", description, stack]
                : [NSString stringWithFormat:@"[error] %@", description];
        } else {
            line = [NSString stringWithFormat:@"[%@] %@", type, json];
        }
        @synchronized (collector) {
            NSUInteger bytes = [line lengthOfBytesUsingEncoding:NSUTF8StringEncoding];
            if (collector.lines.count >= OpenMinisFridaMaxMessages ||
                collector.transcriptBytes + bytes > OpenMinisFridaMaxTranscriptBytes) {
                if (!collector.truncated) {
                    collector.truncated = YES;
                    [collector.lines addObject:@"… transcript limit reached; later messages were dropped."];
                }
                return;
            }
            collector.transcriptBytes += bytes;
            [collector.lines addObject:line];
        }
    }
}

#endif

void OpenMinisFridaProcessesAsync(void (^completion)(NSString *)) {
    dispatch_async(OpenMinisFridaQueue(), ^{
        @autoreleasepool {
            NSMutableArray<NSString *> *lines = [NSMutableArray array];
#if OPENMINIS_HAS_FRIDA_CORE
            OpenMinisFridaInitialize();
            GCancellable *cancel = OpenMinisFridaDeadline(15);
            GError *error = NULL;
            FridaDeviceManager *manager = NULL;
            FridaDevice *device = OpenMinisFridaOpenServer(&manager, cancel, &error);
            if (device == NULL) {
                [lines addObject:OpenMinisFridaErrorLine(@"connect 127.0.0.1:27042", error)];
                [lines addObjectsFromArray:OpenMinisFridaServerDiagnostics()];
            } else {
                FridaProcessList *processes = frida_device_enumerate_processes_sync(device, NULL, cancel, &error);
                if (error != NULL) {
                    [lines addObject:OpenMinisFridaErrorLine(@"enumerate processes", error)];
                } else if (processes != NULL) {
                    gint count = frida_process_list_size(processes);
                    [lines addObject:[NSString stringWithFormat:@"Processes: %d (server-visible, output capped at 300)", count]];
                    gint printed = 0;
                    for (gint i = 0; i < count && printed < 300; i++, printed++) {
                        FridaProcess *process = frida_process_list_get(processes, i);
                        [lines addObject:[NSString stringWithFormat:@"%u\t%s",
                                          frida_process_get_pid(process), frida_process_get_name(process)]];
                        g_object_unref(process);
                    }
                    if (count == 0) {
                        [lines addObject:@"WARNING: the server returned an empty list; that is not proof about any specific process."];
                    }
                    g_object_unref(processes);
                } else {
                    [lines addObject:@"ERROR: server returned no process list."];
                }
                g_object_unref(device);
                if (manager != NULL) {
                    frida_device_manager_close_sync(manager, cancel, NULL);
                    g_object_unref(manager);
                }
            }
            g_object_unref(cancel);
#else
            [lines addObject:@"ERROR: Frida Core is not embedded in this build."];
            [lines addObjectsFromArray:OpenMinisFridaServerDiagnostics()];
#endif
            NSString *result = [lines componentsJoinedByString:@"\n"];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    });
}

void OpenMinisFridaRunScriptAsync(NSString *target,
                                  NSString *source,
                                  double timeoutSeconds,
                                  void (^completion)(NSString *)) {
    NSString *safeTarget = [target copy] ?: @"";
    NSString *safeSource = [source copy] ?: @"";
    double bounded = MIN(MAX(timeoutSeconds, 1.0), OpenMinisFridaMaxTimeoutSeconds);
    dispatch_async(OpenMinisFridaQueue(), ^{
        @autoreleasepool {
            NSMutableArray<NSString *> *lines = [NSMutableArray array];
#if OPENMINIS_HAS_FRIDA_CORE
            if (safeTarget.length == 0 || safeSource.length == 0 ||
                [safeTarget lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 512 ||
                [safeSource lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 262144) {
                [lines addObject:@"ERROR: target and source required; maximum target 512 bytes and source 256 KiB."];
            } else {
                OpenMinisFridaInitialize();
                GMainContext *context = g_main_context_new();
                g_main_context_push_thread_default(context);
                [lines addObject:[NSString stringWithFormat:@"frida %s · %@ · attach", frida_version_string(), OpenMinisFridaEndpoint]];

                GCancellable *cancel = OpenMinisFridaDeadline(bounded + 15);
                GError *error = NULL;
                FridaDeviceManager *manager = NULL;
                FridaDevice *device = OpenMinisFridaOpenServer(&manager, cancel, &error);
                FridaSession *session = NULL;
                FridaScript *script = NULL;
                BOOL loaded = NO;

                if (device == NULL) {
                    [lines addObject:OpenMinisFridaErrorLine(@"connect 127.0.0.1:27042", error)];
                    [lines addObjectsFromArray:OpenMinisFridaServerDiagnostics()];
                } else {
                    guint pid = 0;
                    NSString *resolveError = nil;
                    if (OpenMinisFridaResolvePID(device, safeTarget, cancel, &pid, lines, &resolveError)) {
                        [lines addObject:[NSString stringWithFormat:@"target: %@ (pid %u)", safeTarget, pid]];
                        session = frida_device_attach_sync(device, pid, NULL, cancel, &error);
                        if (session == NULL) {
                            [lines addObject:OpenMinisFridaErrorLine(
                                @"attach", error)];
                        } else {
                            FridaScriptOptions *options = frida_script_options_new();
                            frida_script_options_set_runtime(options, FRIDA_SCRIPT_RUNTIME_QJS);
                            script = frida_session_create_script_sync(
                                session, safeSource.UTF8String, options, cancel, &error);
                            g_clear_object(&options);
                            if (script == NULL) {
                                [lines addObject:OpenMinisFridaErrorLine(@"create script", error)];
                            } else {
                                OpenMinisFridaMessageCollector *collector = [[OpenMinisFridaMessageCollector alloc] init];
                                g_signal_connect_data(script, "message",
                                                      G_CALLBACK(OpenMinisFridaOnMessage),
                                                      (__bridge_retained void *)collector,
                                                      OpenMinisFridaReleaseCollector, 0);
                                frida_script_load_sync(script, cancel, &error);
                                if (error != NULL) {
                                    [lines addObject:OpenMinisFridaErrorLine(@"load script", error)];
                                } else {
                                    loaded = YES;
                                    [lines addObject:[NSString stringWithFormat:
                                        @"script loaded · collecting messages for %.1fs", bounded]];
                                    GMainLoop *loop = g_main_loop_new(context, FALSE);
                                    GSource *timer = g_timeout_source_new((guint)(bounded * 1000));
                                    g_source_set_callback(timer, OpenMinisFridaStopLoop, loop, NULL);
                                    g_source_attach(timer, context);
                                    g_main_loop_run(loop);
                                    g_source_destroy(timer);
                                    g_source_unref(timer);
                                    g_main_loop_unref(loop);
                                    @synchronized (collector) {
                                        [lines addObjectsFromArray:collector.lines];
                                    }
                                    [lines addObject:@"script finished collecting; detaching"];
                                }
                                // Stop delivery before tearing anything down: a
                                // message must never race the freed collector.
                                g_signal_handlers_disconnect_by_func(
                                    script, G_CALLBACK(OpenMinisFridaOnMessage), (__bridge void *)collector);
                                if (loaded) {
                                    frida_script_unload_sync(script, cancel, NULL);
                                }
                                g_object_unref(script);
                                script = NULL;
                            }
                            frida_session_detach_sync(session, cancel, NULL);
                            g_object_unref(session);
                            session = NULL;
                        }
                    } else if (resolveError != nil) {
                        [lines addObject:resolveError];
                    }
                    g_object_unref(device);
                    if (manager != NULL) {
                        frida_device_manager_close_sync(manager, cancel, NULL);
                        g_object_unref(manager);
                    }
                }
                g_object_unref(cancel);
                g_main_context_pop_thread_default(context);
                g_main_context_unref(context);
                [lines addObject:loaded ? @"detach requested" : @"no script was loaded"];
            }
#else
            [lines addObject:@"ERROR: Frida Core is not embedded in this build; rebuild with the verified devkit."];
            [lines addObjectsFromArray:OpenMinisFridaServerDiagnostics()];
#endif
            NSString *result = [lines componentsJoinedByString:@"\n"];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    });
}
