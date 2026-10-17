#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Minimal, optional Frida Core bridge. This only verifies that the embedded
/// client can initialize and enumerate the local device manager. It does not
/// attach to processes or execute scripts.
FOUNDATION_EXPORT BOOL OpenMinisFridaCoreAvailable(void);
/// Run only on the serialized worker through the async entry point.
FOUNDATION_EXPORT NSString *OpenMinisFridaCoreStatus(void);
FOUNDATION_EXPORT void OpenMinisFridaCoreStatusAsync(void (^completion)(NSString *result));

NS_ASSUME_NONNULL_END
