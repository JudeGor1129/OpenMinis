#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// These availability queries are compile-time facts only, not server probes.
FOUNDATION_EXPORT BOOL OpenMinisFridaCoreAvailable(void);
FOUNDATION_EXPORT BOOL OpenMinisFridaDiagnosticsAvailable(void);
FOUNDATION_EXPORT BOOL OpenMinisFridaScriptAvailable(void);

/// Pure local file/permission checks and client BUILD VERSION; no Frida API,
/// process inspection, socket connection or server protocol request is made.
FOUNDATION_EXPORT NSString *OpenMinisFridaCoreStatus(void);
FOUNDATION_EXPORT NSArray<NSString *> *OpenMinisFridaServerDiagnostics(void);
/// Async completions are dispatched to the main queue.
FOUNDATION_EXPORT void OpenMinisFridaCoreStatusAsync(void (^completion)(NSString *result));
/// Runtime calls fail closed BEFORE initialization. Identity/path/starttime are
/// checked here; the decisive argv proof must come from the audited root helper
/// (the App cannot read a root process's argv). A saved launch plist is never
/// accepted as proof, and an unavailable/denied verdict refuses.
// Session authorization for that helper request is enforced App-side, against
// the App's per-session defaults; the root helper runs in a different process
// and cannot read them, so it never repeats that check. Build 278+ also carries
// the debug-class entitlements needed to read another process's arguments.
FOUNDATION_EXPORT void OpenMinisFridaGrantGuardedVerdict(int pid, double startSeconds,
                                                        double startMicros);
FOUNDATION_EXPORT void OpenMinisFridaProcessesAsync(void (^completion)(NSString *result));
/// Attach-only, user-installed mobile-owned App targets; critical/system/self
/// targets are refused. Cancellation is cooperative, not a guaranteed deadline.
/// Unload/detach/manager-close errors are returned rather than silently ignored.
FOUNDATION_EXPORT void OpenMinisFridaRunScriptAsync(NSString *target,
                                                    NSString *source,
                                                    double timeoutSeconds,
                                                    void (^completion)(NSString *result));

NS_ASSUME_NONNULL_END
