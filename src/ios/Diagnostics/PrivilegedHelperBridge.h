#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL OpenMinisPrivilegedHelperPackaged(void);
FOUNDATION_EXPORT NSString *OpenMinisNativeIdentity(void);
/// Synchronously invalidates queued/running requests before a UI opt-out returns.
FOUNDATION_EXPORT void OpenMinisCancelPrivilegedRequests(void);
/// Single-use, bounded allowlisted child operation. Cancellation never touches
/// the GUI process. Persona success is verified from the child's actual IDs.
@interface OpenMinisPrivilegedRequest : NSObject
- (instancetype)initWithAction:(NSString *)action;
- (void)runWithCompletion:(void (^)(NSString *result))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
