#import <Foundation/Foundation.h>
#include <signal.h>
#include <pthread.h>
#include <unistd.h>
#include <errno.h>
#include <string.h>
#include <frida-core.h>
#include "HelperLease.h"

// This helper is signed only inside the explicit TrollStore build. It accepts
// exactly two read-only verbs; no shell, filenames, PID targets or scripts.
static void Emit(NSDictionary *value, int code) __attribute__((noreturn));
static void Emit(NSDictionary *value, int code) {
    NSData *json = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    if (!json || json.length > 250 * 1024) _exit(74);
    const char *p = json.bytes;
    size_t count = json.length;
    while (count) {
        ssize_t n = write(STDOUT_FILENO, p, count);
        if (n > 0) { p += n; count -= n; }
        else if (n < 0 && errno == EINTR) continue;
        else _exit(74);
    }
    (void)write(STDOUT_FILENO, "\n", 1);
    _exit(code); // Short-lived worker; never run arbitrary teardown in the GUI.
}
static NSString *PackageVersion(void) {
    // Metadata only: this cannot attest the version of the listening process.
    for (NSString *path in @[@"/var/jb/var/lib/dpkg/status", @"/var/jb/Library/dpkg/status", @"/var/lib/dpkg/status"]) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
        if (!attrs || [attrs[NSFileSize] unsignedLongLongValue] > 2 * 1024 * 1024) continue;
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        for (NSString *paragraph in [text componentsSeparatedByString:@"\n\n"]) {
            if (![paragraph hasPrefix:@"Package: re.frida.server\n"]) continue;
            BOOL installed = [paragraph containsString:@"Status: install ok installed"];
            if (!installed) return nil;
            for (NSString *line in [paragraph componentsSeparatedByString:@"\n"]) {
                if ([line hasPrefix:@"Version: "]) return [line substringFromIndex:9];
            }
        }
    }
    return nil;
}
static NSDictionary *Identity(NSString *action) {
    NSString *version = PackageVersion();
    return @{
        @"protocol": @1, @"action": action,
        @"uid": @(getuid()), @"euid": @(geteuid()),
        @"gid": @(getgid()), @"egid": @(getegid()),
        @"root_verified": @(getuid() == 0 && geteuid() == 0 && getgid() == 0 && getegid() == 0),
        @"server_package_version": version ?: (id)[NSNull null],
        @"client_version": @"17.9.10",
        @"scope": @"This helper process only. GUI and iSH identities are unchanged."
    };
}
static void Processes(void) __attribute__((noreturn));
static void Processes(void) {
    NSMutableDictionary *result = [Identity(@"frida-processes") mutableCopy];
    if (![result[@"root_verified"] boolValue]) {
        result[@"ok"] = @NO; result[@"error"] = @"Helper did not obtain real uid/euid 0.";
        Emit(result, 77);
    }
    NSString *installed = PackageVersion();
    if (![installed isEqualToString:@"17.9.10"]) {
        result[@"ok"] = @NO;
        result[@"error"] = @"Frida package metadata is absent or not exactly 17.9.10; protocol probe refused. Package metadata does not attest listener identity.";
        Emit(result, 78);
    }
    // A hard process watchdog supplements cooperative protocol cancellation.
    alarm(12);
    frida_init();
    // NEVER use the default manager constructor: it enables a local backend.
    FridaDeviceManager *manager = frida_device_manager_new_with_socket_backend_only();
    FridaRemoteDeviceOptions *remote = frida_remote_device_options_new();
    frida_remote_device_options_set_keepalive_interval(remote, 0);
    GCancellable *cancel = g_cancellable_new();
    g_object_ref(cancel);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 6 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        g_cancellable_cancel(cancel); g_object_unref(cancel);
    });
    GError *error = NULL;
    FridaDevice *device = frida_device_manager_add_remote_device_sync(manager,
        "127.0.0.1:27042", remote, cancel, &error);
    FridaProcessQueryOptions *options = NULL;
    FridaProcessList *list = NULL;
    if (device && !error) {
        options = frida_process_query_options_new();
        list = frida_device_enumerate_processes_sync(device, options, cancel, &error);
    }
    NSMutableArray *processes = [NSMutableArray array];
    if (list && !error) {
        gint count = frida_process_list_size(list);
        for (gint i = 0; i < MIN(count, 300); i++) {
            FridaProcess *process = frida_process_list_get(list, i);
            const gchar *name = frida_process_get_name(process);
            NSString *n = name ? [NSString stringWithUTF8String:name] : nil;
            if (n.length > 256) n = [n substringToIndex:256];
            [processes addObject:@{@"pid": @(frida_process_get_pid(process)), @"name": n ?: @"<invalid name>"}];
            frida_unref(process);
        }
        result[@"process_count"] = @(count);
        result[@"truncated"] = @(count > 300);
    }
    result[@"ok"] = @(list != NULL && error == NULL);
    result[@"endpoint"] = @"127.0.0.1:27042";
    result[@"backend"] = @"socket-only remote client; no Darwin local backend";
    result[@"processes"] = processes;
    result[@"warning"] = @"Read-only listing is not proof of attach permission. Process isolation does not prevent a server/kernel reboot. No runtime server version attestation.";
    if (error) {
        NSString *message = [NSString stringWithUTF8String:error->message];
        result[@"error"] = message ? [message substringToIndex:MIN(message.length, 1600)] : @"Frida protocol query failed.";
        g_clear_error(&error);
    } else if (!list) { result[@"error"] = @"Frida returned no process list."; }
    BOOL ok = [result[@"ok"] boolValue];
    if (list) frida_unref(list);
    if (options) frida_unref(options);
    if (device) frida_unref(device);
    frida_unref(remote);
    g_object_unref(cancel);
    // Bound cleanup independently of an already-cancelled query.
    GCancellable *closeCancel = g_cancellable_new();
    g_object_ref(closeCancel);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        g_cancellable_cancel(closeCancel); g_object_unref(closeCancel);
    });
    frida_device_manager_close_sync(manager, closeCancel, NULL);
    g_object_unref(closeCancel);
    frida_unref(manager);
    Emit(result, ok ? 0 : 69);
}
static int AwaitLaunchPermit(void) {
    return MinisHelperAwaitLaunchPermit(STDIN_FILENO);
}
static void *ParentLease(void *unused) {
    (void)unused;
    MinisHelperWaitForRevocation(STDIN_FILENO);
    return NULL;
}
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        alarm(12);
        // Synchronously consume the permit before any identity or Frida work.
        if (!AwaitLaunchPermit()) _exit(125);
        pthread_t lease;
        if (pthread_create(&lease, NULL, ParentLease, NULL) != 0) _exit(70);
        pthread_detach(lease);
        if (argc != 2) Emit(@{@"ok": @NO, @"error": @"Exactly one allowlisted action is required."}, 64);
        if (strcmp(argv[1], "identity") == 0) {
            NSMutableDictionary *identity = [Identity(@"identity") mutableCopy];
            identity[@"ok"] = identity[@"root_verified"];
            if (![identity[@"ok"] boolValue]) identity[@"error"] = @"Real helper uid/euid 0 was not granted.";
            Emit(identity, [identity[@"ok"] boolValue] ? 0 : 77);
        }
        if (strcmp(argv[1], "frida-processes") == 0) Processes();
        Emit(@{@"ok": @NO, @"error": @"Action not allowlisted. No arbitrary shell or script execution."}, 64);
    }
}
