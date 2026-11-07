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
/// Runtime calls fail closed BEFORE initialization unless kernel-visible server
/// identity and argv prove --ignore-crashes and loopback-only listen. Permission
/// denial/unavailable metadata never falls back to trusting a saved launch plist.
FOUNDATION_EXPORT void OpenMinisFridaProcessesAsync(void (^completion)(NSString *result));
/// Attach-only, user-installed mobile-owned App targets; critical/system/self
/// targets are refused. Cancellation is cooperative, not a guaranteed deadline.
/// Unload/detach/manager-close errors are returned rather than silently ignored.
FOUNDATION_EXPORT void OpenMinisFridaRunScriptAsync(NSString *target,
                                                    NSString *source,
                                                    double timeoutSeconds,
                                                    void (^completion)(NSString *result));

NS_ASSUME_NONNULL_END
