#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Non-invasive GUI diagnostics; Core remains disabled in the GUI process.
/// Experimental read-only listing is isolated in a dedicated signed helper.
FOUNDATION_EXPORT BOOL OpenMinisFridaCoreAvailable(void);
/// Safe server-file and loopback-port diagnostics; does not initialize Frida Core.
FOUNDATION_EXPORT BOOL OpenMinisFridaDiagnosticsAvailable(void);
/// Run only on the serialized worker through the async entry point.
FOUNDATION_EXPORT NSString *OpenMinisFridaCoreStatus(void);
FOUNDATION_EXPORT void OpenMinisFridaCoreStatusAsync(void (^completion)(NSString *result));
/// Opt-in isolated-helper socket-only query at 127.0.0.1:27042.
/// No GUI initialization, automatic local discovery, attach/spawn or scripts.
FOUNDATION_EXPORT void OpenMinisFridaProcessesAsync(void (^completion)(NSString *result));
/// Filesystem/port facts about a user-installed Frida server: binary presence,
/// executability and whether anything listens on the default port. Never
/// starts a server and never speaks the Frida protocol.
FOUNDATION_EXPORT NSArray<NSString *> *OpenMinisFridaServerDiagnostics(void);

NS_ASSUME_NONNULL_END
