#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Whether the embedded Frida Core client is compiled into this build.
/// All calls still go through a user-installed frida-server on loopback;
/// Minis never uses the in-process backend.
FOUNDATION_EXPORT BOOL OpenMinisFridaCoreAvailable(void);
/// Safe server-file and loopback-port diagnostics; does not initialize Frida Core.
FOUNDATION_EXPORT BOOL OpenMinisFridaDiagnosticsAvailable(void);
/// True if compiled with Frida Core; does not prove server connectivity or attach capability.
FOUNDATION_EXPORT BOOL OpenMinisFridaScriptAvailable(void);
/// Run only on the serialized worker through the async entry point.
FOUNDATION_EXPORT NSString *OpenMinisFridaCoreStatus(void);
FOUNDATION_EXPORT void OpenMinisFridaCoreStatusAsync(void (^completion)(NSString *result));
/// Server-visible process list (remote device only; never the local backend).
FOUNDATION_EXPORT void OpenMinisFridaProcessesAsync(void (^completion)(NSString *result));
/// Attach to `target` (pid or process name), load `source`, collect script
/// messages for `timeoutSeconds` (clamped to 1...30), then unload and detach.
/// Operations run on a serial queue with cooperative cancellation; a blocked
/// Frida call is not guaranteed to stop on time. Completion is on the main queue.
FOUNDATION_EXPORT void OpenMinisFridaRunScriptAsync(NSString *target,
                                                    NSString *source,
                                                    double timeoutSeconds,
                                                    void (^completion)(NSString *result));
/// Filesystem/port facts about a user-installed Frida server: binary presence,
/// executability and whether anything listens on the default port. Never
/// starts a server.
FOUNDATION_EXPORT NSArray<NSString *> *OpenMinisFridaServerDiagnostics(void);

NS_ASSUME_NONNULL_END
