#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Optional embedded Frida Core diagnostics: status and read-only process
/// enumeration. Does not attach to processes, spawn targets or execute scripts.
FOUNDATION_EXPORT BOOL OpenMinisFridaCoreAvailable(void);
/// Run only on the serialized worker through the async entry point.
FOUNDATION_EXPORT NSString *OpenMinisFridaCoreStatus(void);
FOUNDATION_EXPORT void OpenMinisFridaCoreStatusAsync(void (^completion)(NSString *result));
/// Read-only built-in local/socket process queries, no attach/spawn/scripts.
/// The socket backend may contact an existing local Frida service.
FOUNDATION_EXPORT void OpenMinisFridaProcessesAsync(void (^completion)(NSString *result));
/// Filesystem/port facts about a user-installed Frida server: binary presence,
/// executability and whether anything listens on the default port. Never
/// starts a server and never speaks the Frida protocol.
FOUNDATION_EXPORT NSArray<NSString *> *OpenMinisFridaServerDiagnostics(void);

NS_ASSUME_NONNULL_END
