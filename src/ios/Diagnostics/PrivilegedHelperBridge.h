#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL OpenMinisPrivilegedHelperPackaged(void);
FOUNDATION_EXPORT NSString *OpenMinisNativeIdentity(void);
FOUNDATION_EXPORT void OpenMinisCancelPrivilegedRequests(void);

/// One short-lived allowlisted helper request. The JSON body (at most 3 MiB)
/// is framed onto the helper's dedicated FD 3 request channel; it never touches
/// disk, and file content and credentials never appear in argv.
@interface OpenMinisPrivilegedRequest : NSObject
- (instancetype)initWithAction:(NSString *)action
                      payload:(NSDictionary *)payload
    NS_SWIFT_NAME(init(action:payload:));
- (void)runWithCompletion:(void (^)(NSString *resultJSON))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
