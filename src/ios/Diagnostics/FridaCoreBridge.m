#import "FridaCoreBridge.h"
#import "FridaSafetyPolicy.h"
#import <dispatch/dispatch.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdlib.h>
#include <unistd.h>
#include <math.h>

#if __has_include(<frida-core.h>)
#import <frida-core.h>
#define OPENMINIS_HAS_FRIDA_CORE 1
#else
#define OPENMINIS_HAS_FRIDA_CORE 0
#endif

/* Availability is compile-time only: neither schema construction nor settings
 * rendering may initialize Frida or inspect/connect to a running service.
 */
BOOL OpenMinisFridaDiagnosticsAvailable(void) { return YES; }
BOOL OpenMinisFridaCoreAvailable(void) { return OPENMINIS_HAS_FRIDA_CORE; }
BOOL OpenMinisFridaScriptAvailable(void) { return OPENMINIS_HAS_FRIDA_CORE; }

/* Local status is deliberately independent of the Frida SDK and networking.
 * #272 had a restart after status; causality remains unverified. The version
 * below is a build constant, checked against the CI-pinned devkit version.
 */
NSArray<NSString *> *OpenMinisFridaServerDiagnostics(void) {
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    for (NSString *path in @[@"/var/jb/usr/sbin/frida-server", @"/var/jb/usr/bin/frida-server",
                             @"/usr/sbin/frida-server", @"/usr/bin/frida-server"]) {
        if (access(path.fileSystemRepresentation, F_OK) == 0) {
            [lines addObject:[NSString stringWithFormat:@"Server file: %@ (%@)", path,
                access(path.fileSystemRepresentation, X_OK) == 0 ? @"executable" : @"not executable"]];
        }
    }
    if (lines.count == 0) [lines addObject:@"Server file: not found in known locations."];
    [lines addObject:@"Port 127.0.0.1:27042: NOT PROBED. Listener/protocol status is unknown."];
    [lines addObject:@"Runtime calls require a uniquely identified running root frida-server with --ignore-crashes and --listen=127.0.0.1:27042. Saved plist changes alone are not proof of the running mode."];
    return lines;
}

NSString *OpenMinisFridaCoreStatus(void) {
    NSLog(@"[FridaStage] local-status: no SDK initialization or network probe");
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObject:
        [NSString stringWithFormat:@"Frida client build version: %s (build constant; no Frida API called).",
         OPENMINIS_FRIDA_CLIENT_VERSION]];
    [lines addObject:OPENMINIS_HAS_FRIDA_CORE ? @"Client compiled in; runtime capability is unverified."
                                            : @"Client not compiled in; local status only."];
    [lines addObjectsFromArray:OpenMinisFridaServerDiagnostics()];
    return [lines componentsJoinedByString:@"\n"];
}

static dispatch_queue_t OpenMinisFridaQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("app.openminis.frida.guarded", DISPATCH_QUEUE_SERIAL); });
    return queue;
}

void OpenMinisFridaCoreStatusAsync(void (^completion)(NSString *)) {
    // Separate from runtime serialization: a blocked library call must not
    // prevent purely local status from completing.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        @autoreleasepool {
            NSString *result = OpenMinisFridaCoreStatus();
            dispatch_async(dispatch_get_main_queue(), ^{ completion(result); });
        }
    });
}

static NSString *OpenMinisFridaPathForPID(pid_t pid) {
    // proc_pidpath is exported by libSystem, but private libproc headers are
    // absent from the iOS SDK. Resolve only this read-only metadata function.
    typedef int (*PIDPathFunction)(int, void *, uint32_t);
    PIDPathFunction function = (PIDPathFunction)dlsym(RTLD_DEFAULT, "proc_pidpath");
    if (function == NULL) return nil;
    char path[4096] = { 0 };
    int count = function(pid, path, sizeof(path));
    if (count <= 0 || memchr(path, 0, sizeof(path)) == NULL) return nil;
    return [NSString stringWithUTF8String:path];
}

static BOOL OpenMinisFridaProcessInfo(pid_t pid, struct kinfo_proc *info) {
    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, pid };
    size_t size = sizeof(*info);
    memset(info, 0, sizeof(*info));
    return sysctl(mib, 4, info, &size, NULL, 0) == 0 &&
           size == sizeof(*info) && info->kp_proc.p_pid == pid;
}

static BOOL OpenMinisFridaSameProcess(const struct kinfo_proc *a, const struct kinfo_proc *b) {
    return a->kp_proc.p_pid == b->kp_proc.p_pid &&
           a->kp_proc.p_starttime.tv_sec == b->kp_proc.p_starttime.tv_sec &&
           a->kp_proc.p_starttime.tv_usec == b->kp_proc.p_starttime.tv_usec &&
           a->kp_eproc.e_ucred.cr_uid == b->kp_eproc.e_ucred.cr_uid;
}

/* Returns nil only with actual kernel-visible runtime evidence. Permissions,
 * unavailable metadata, ambiguity, or changed PID identity fail closed BEFORE
 * any Frida API. No server is launched/restarted; no socket is probed here.
 */
static NSString *OpenMinisFridaServerPreflight(void) {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@OPENMINIS_FRIDA_GUARDED_PREFERENCE])
        return @"ERROR: guarded Frida is off. Enable the new guarded-mode switch explicitly; the old #272 preference is not reused.";
    int mib[] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL, 0 };
    size_t size = 0;
    if (sysctl(mib, 4, NULL, &size, NULL, 0) != 0 || size == 0 || size > 4 * 1024 * 1024)
        return @"ERROR: cannot inspect the running server; no Frida initialization performed.";
    struct kinfo_proc *processes = calloc(1, size);
    if (processes == NULL) return @"ERROR: server preflight allocation failed.";
    if (sysctl(mib, 4, processes, &size, NULL, 0) != 0 || size % sizeof(*processes) != 0) {
        free(processes);
        return @"ERROR: process snapshot changed or access denied; no Frida initialization performed.";
    }
    struct kinfo_proc server = { 0 };
    NSUInteger count = 0;
    for (size_t i = 0; i < size / sizeof(*processes); i++) {
        if (strncmp(processes[i].kp_proc.p_comm, "frida-server", sizeof(processes[i].kp_proc.p_comm)) == 0) {
            server = processes[i];
            count++;
        }
    }
    free(processes);
    if (count != 1 || server.kp_proc.p_pid <= 1 || server.kp_eproc.e_ucred.cr_uid != 0 ||
        server.kp_proc.p_starttime.tv_sec <= 0)
        return @"ERROR: require exactly one running root frida-server; unavailable/ambiguous identity is refused.";
    NSString *path = OpenMinisFridaPathForPID(server.kp_proc.p_pid);
    if (path == nil) return @"ERROR: server executable path cannot be verified; no Frida initialization performed.";
    BOOL knownPath = NO;
    for (NSString *candidate in @[@"/var/jb/usr/sbin/frida-server", @"/var/jb/usr/bin/frida-server",
                                  @"/usr/sbin/frida-server", @"/usr/bin/frida-server"]) {
        if ([[candidate stringByResolvingSymlinksInPath] isEqualToString:[path stringByResolvingSymlinksInPath]])
            knownPath = YES;
    }
    if (!knownPath) return @"ERROR: server executable is outside known installed locations.";
    int argsMIB[] = { CTL_KERN, KERN_PROCARGS2, server.kp_proc.p_pid };
    size_t argsSize = OPENMINIS_FRIDA_MAX_PROCARGS_BYTES;
    void *bytes = calloc(1, argsSize);
    if (bytes == NULL) return @"ERROR: argument preflight allocation failed.";
    const char *argv[OPENMINIS_FRIDA_MAX_ARGUMENTS] = { 0 };
    int argc = 0;
    int argsResult = sysctl(argsMIB, 3, bytes, &argsSize, NULL, 0);
    int argsErrno = argsResult == 0 ? 0 : errno;
    BOOL guarded = argsResult == 0 &&
        OpenMinisFridaParseArguments(bytes, argsSize, argv, &argc) &&
        OpenMinisFridaArgumentsAreGuarded(argc, argv);
    if (guarded) {
        NSString *kernelExecutable = [NSString stringWithUTF8String:(const char *)bytes + sizeof(int32_t)];
        guarded = kernelExecutable != nil &&
            [[kernelExecutable stringByResolvingSymlinksInPath] isEqualToString:[path stringByResolvingSymlinksInPath]];
    }
    free(bytes); // Never print argv/environment; they may contain credentials.
    if (argsResult != 0) return [NSString stringWithFormat:
        @"ERROR: live server argv read was denied/unavailable (errno=%d); no Frida initialization performed. Root metadata permission is required; a saved plist is not a substitute.", argsErrno];
    struct kinfo_proc after;
    if (!OpenMinisFridaProcessInfo(server.kp_proc.p_pid, &after) ||
        !OpenMinisFridaSameProcess(&server, &after))
        return @"ERROR: server exited or PID identity changed during preflight.";
    if (!guarded) return @"ERROR: running server arguments could not prove --ignore-crashes plus loopback-only listen. Updating the launch plist without restarting the service is insufficient. No Frida initialization performed.";
    NSLog(@"[FridaStage] preflight accepted pid=%d; crash integration off; listener identity not protocol-verified", server.kp_proc.p_pid);
    return nil;
}

static NSString *OpenMinisFridaTargetPreflight(pid_t pid) {
    if (pid <= 1 || pid == getpid()) return @"ERROR: critical/self target refused.";
    struct kinfo_proc target;
    if (!OpenMinisFridaProcessInfo(pid, &target) || target.kp_eproc.e_ucred.cr_uid != 501)
        return @"ERROR: target must be a running mobile-owned user App; root/system targets refused.";
    NSString *path = OpenMinisFridaPathForPID(pid);
    if (!OpenMinisFridaIsUserAppPath(path.fileSystemRepresentation))
        return @"ERROR: only user-installed App executables are allowed in this guarded release; system daemons and SpringBoard are refused.";
    struct kinfo_proc after;
    if (target.kp_proc.p_starttime.tv_sec <= 0 ||
        !OpenMinisFridaProcessInfo(pid, &after) || !OpenMinisFridaSameProcess(&target, &after))
        return @"ERROR: target PID identity changed or could not be verified; attach refused.";
    return nil;
}

// Guarded runtime: metadata evidence is required before initializing Core.
static NSString *const OpenMinisFridaEndpoint = @"127.0.0.1:27042";
static const double OpenMinisFridaMaxTimeoutSeconds = 30.0;
static const NSUInteger OpenMinisFridaMaxMessages = 400;
static const NSUInteger OpenMinisFridaMaxMessageBytes = 16384;
static const NSUInteger OpenMinisFridaMaxTranscriptBytes = 131072;
#if OPENMINIS_HAS_FRIDA_CORE
static void OpenMinisFridaInitialize(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSLog(@"[FridaStage] init-begin (only after runtime argument proof)");
        frida_init();
        NSLog(@"[FridaStage] init-complete");
    });
}
#endif

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

#if OPENMINIS_HAS_FRIDA_CORE

/// Connects the loopback server only. Never enumerates devices: device
/// the actual server mode is rechecked before remote device creation.
/// Remote-only is not itself sufficient: the server needs --ignore-crashes.
static FridaDevice *OpenMinisFridaOpenServer(FridaDeviceManager **outManager,
                                             GCancellable *cancel,
                                             GError **error) {
    if (OpenMinisFridaServerPreflight() != nil) {
        g_set_error_literal(error, G_IO_ERROR, G_IO_ERROR_PERMISSION_DENIED,
                            "Guarded server runtime could not be reverified; refusing remote device creation");
        return NULL;
    }
    NSLog(@"[FridaStage] manager-create -> remote-device (no local enumeration)");
    FridaDeviceManager *manager = frida_device_manager_new();
    if (manager == NULL) return NULL;
    FridaDevice *device = frida_device_manager_add_remote_device_sync(
        manager, OpenMinisFridaEndpoint.UTF8String, NULL, cancel, error);
    if (device == NULL) {
        frida_unref(manager);
        return NULL;
    }
    if (outManager != NULL) *outManager = manager;
    return device;
}

static NSString *OpenMinisFridaErrorLine(NSString *stage, GError **errorPointer) {
    GError *error = *errorPointer;
    *errorPointer = NULL;
    if (error == NULL) return [NSString stringWithFormat:@"ERROR: %@ failed without a message.", stage];
    NSString *message = [NSString stringWithUTF8String:error->message] ?: @"unknown error";
    g_error_free(error);
    return [NSString stringWithFormat:@"ERROR: %@: %@", stage, message];
}

/// Resolves numeric PID or unique case-insensitive exact process name.
/// A separate native target check still runs before any attach.
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
        *errorLine = OpenMinisFridaErrorLine(@"enumerate processes", &error);
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
    frida_unref(processes);

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
    (void)CFBridgingRelease(data);
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
            NSString *preflightError = OpenMinisFridaServerPreflight();
            if (preflightError != nil) {
                [lines addObject:preflightError];
            } else {
            OpenMinisFridaInitialize();
            GCancellable *cancel = OpenMinisFridaDeadline(15);
            GError *error = NULL;
            FridaDeviceManager *manager = NULL;
            FridaDevice *device = OpenMinisFridaOpenServer(&manager, cancel, &error);
            if (device == NULL) {
                [lines addObject:OpenMinisFridaErrorLine(@"connect 127.0.0.1:27042", &error)];
                [lines addObjectsFromArray:OpenMinisFridaServerDiagnostics()];
            } else {
                FridaProcessList *processes = frida_device_enumerate_processes_sync(device, NULL, cancel, &error);
                if (error != NULL) {
                    [lines addObject:OpenMinisFridaErrorLine(@"enumerate processes", &error)];
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
                    frida_unref(processes);
                } else {
                    [lines addObject:@"ERROR: server returned no process list."];
                }
                frida_unref(device);
                if (manager != NULL) {
                    GCancellable *cleanup = OpenMinisFridaDeadline(5);
                    GError *cleanupError = NULL;
                    frida_device_manager_close_sync(manager, cleanup, &cleanupError);
                    if (cleanupError != NULL) [lines addObject:OpenMinisFridaErrorLine(@"manager close", &cleanupError)];
                    g_object_unref(cleanup);
                    frida_unref(manager);
                }
            }
            g_object_unref(cancel);
            }
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
    double bounded = isfinite(timeoutSeconds) ? MIN(MAX(timeoutSeconds, 1.0), OpenMinisFridaMaxTimeoutSeconds) : 5.0;
    dispatch_async(OpenMinisFridaQueue(), ^{
        @autoreleasepool {
            NSMutableArray<NSString *> *lines = [NSMutableArray array];
#if OPENMINIS_HAS_FRIDA_CORE
            NSString *preflightError = nil;
            BOOL unsafeTarget = [safeTarget caseInsensitiveCompare:@"launchd"] == NSOrderedSame ||
                [safeTarget caseInsensitiveCompare:@"SpringBoard"] == NSOrderedSame ||
                [safeTarget caseInsensitiveCompare:@"backboardd"] == NSOrderedSame ||
                [safeTarget isEqualToString:@"1"] || [safeTarget intValue] == getpid();
            if (unsafeTarget) {
                [lines addObject:@"ERROR: critical/self target refused before Frida initialization."];
            } else if (safeTarget.length == 0 || safeSource.length == 0 ||
                [safeTarget lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 512 ||
                [safeSource lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 262144) {
                [lines addObject:@"ERROR: target and source required; maximum target 512 bytes and source 256 KiB."];
            } else if ((preflightError = OpenMinisFridaServerPreflight()) != nil) {
                [lines addObject:preflightError];
            } else {
                NSLog(@"[FridaStage] script-request %@; source omitted", [NSUUID UUID].UUIDString);
                OpenMinisFridaInitialize();
                GMainContext *context = g_main_context_new();
                g_main_context_push_thread_default(context);
                [lines addObject:[NSString stringWithFormat:@"frida %s · %@ · attach", OPENMINIS_FRIDA_CLIENT_VERSION, OpenMinisFridaEndpoint]];

                GCancellable *cancel = OpenMinisFridaDeadline(bounded + 15);
                GError *error = NULL;
                FridaDeviceManager *manager = NULL;
                FridaDevice *device = OpenMinisFridaOpenServer(&manager, cancel, &error);
                FridaSession *session = NULL;
                FridaScript *script = NULL;
                BOOL loaded = NO;

                if (device == NULL) {
                    [lines addObject:OpenMinisFridaErrorLine(@"connect 127.0.0.1:27042", &error)];
                    [lines addObjectsFromArray:OpenMinisFridaServerDiagnostics()];
                } else {
                    guint pid = 0;
                    NSString *resolveError = nil;
                    if (OpenMinisFridaResolvePID(device, safeTarget, cancel, &pid, lines, &resolveError)) {
                        [lines addObject:[NSString stringWithFormat:@"target: %@ (pid %u)", safeTarget, pid]];
                        NSString *targetError = OpenMinisFridaTargetPreflight((pid_t)pid);
                        if (targetError != nil) {
                            [lines addObject:targetError];
                        } else {
                            NSLog(@"[FridaStage] attach-begin pid=%u", pid);
                            session = frida_device_attach_sync(device, pid, NULL, cancel, &error);
                        }
                        if (session == NULL) {
                            if (targetError == nil) [lines addObject:OpenMinisFridaErrorLine(@"attach", &error)];
                        } else {
                            FridaScriptOptions *options = frida_script_options_new();
                            frida_script_options_set_runtime(options, FRIDA_SCRIPT_RUNTIME_QJS);
                            script = frida_session_create_script_sync(
                                session, safeSource.UTF8String, options, cancel, &error);
                            g_clear_object(&options);
                            if (script == NULL) {
                                [lines addObject:OpenMinisFridaErrorLine(@"create script", &error)];
                            } else {
                                OpenMinisFridaMessageCollector *collector = [[OpenMinisFridaMessageCollector alloc] init];
                                g_signal_connect_data(script, "message",
                                                      G_CALLBACK(OpenMinisFridaOnMessage),
                                                      (__bridge_retained void *)collector,
                                                      OpenMinisFridaReleaseCollector, 0);
                                frida_script_load_sync(script, cancel, &error);
                                if (error != NULL) {
                                    [lines addObject:OpenMinisFridaErrorLine(@"load script", &error)];
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
                                    [lines addObject:@"script finished collecting; detaching"];
                                }
                                // Stop delivery before tearing anything down: a
                                // message must never race the freed collector.
                                g_signal_handlers_disconnect_by_func(
                                    script, G_CALLBACK(OpenMinisFridaOnMessage), (__bridge void *)collector);
                                @synchronized (collector) { [lines addObjectsFromArray:collector.lines]; }
                                GCancellable *cleanup = OpenMinisFridaDeadline(5);
                                GError *cleanupError = NULL;
                                if (loaded) {
                                    NSLog(@"[FridaStage] unload-begin");
                                    frida_script_unload_sync(script, cleanup, &cleanupError);
                                    if (cleanupError != NULL) [lines addObject:OpenMinisFridaErrorLine(@"unload", &cleanupError)];
                                }
                                g_object_unref(cleanup);
                                frida_unref(script);
                                script = NULL;
                            }
                            GCancellable *cleanup = OpenMinisFridaDeadline(5);
                            GError *cleanupError = NULL;
                            NSLog(@"[FridaStage] detach-begin");
                            frida_session_detach_sync(session, cleanup, &cleanupError);
                            if (cleanupError != NULL) [lines addObject:OpenMinisFridaErrorLine(@"detach", &cleanupError)];
                            else [lines addObject:@"session detached"];
                            g_object_unref(cleanup);
                            frida_unref(session);
                            session = NULL;
                        }
                    } else if (resolveError != nil) {
                        [lines addObject:resolveError];
                    }
                    frida_unref(device);
                    if (manager != NULL) {
                        GCancellable *cleanup = OpenMinisFridaDeadline(5);
                        GError *cleanupError = NULL;
                        frida_device_manager_close_sync(manager, cleanup, &cleanupError);
                        if (cleanupError != NULL) [lines addObject:OpenMinisFridaErrorLine(@"manager close", &cleanupError)];
                        g_object_unref(cleanup);
                        frida_unref(manager);
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
