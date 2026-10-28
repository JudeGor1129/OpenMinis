#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL OpenMinisPrivilegedHelperPackaged(void);
FOUNDATION_EXPORT NSString *OpenMinisNativeIdentity(void);
FOUNDATION_EXPORT void OpenMinisCancelPrivilegedRequests(void);

/// One short-lived allowlisted helper request. The JSON body is written to a
/// generated mode-0600 app-container file and consumed/unlinked by the helper;
/// file content and credentials never appear in argv.
@interface OpenMinisPrivilegedRequest : NSObject
- (instancetype)initWithAction:(NSString *)action payload:(NSDictionary *)payload;
- (void)runWithCompletion:(void (^)(NSString *resultJSON))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
