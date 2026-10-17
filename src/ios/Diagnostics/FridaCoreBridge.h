#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Minimal, optional Frida Core bridge. This only verifies that the embedded
/// client can initialize and enumerate the local device manager. It does not
/// attach to processes or execute scripts.
FOUNDATION_EXPORT BOOL OpenMinisFridaCoreAvailable(void);
FOUNDATION_EXPORT NSString *OpenMinisFridaCoreStatus(void);

NS_ASSUME_NONNULL_END
