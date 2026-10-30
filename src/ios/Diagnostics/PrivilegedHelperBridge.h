#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL OpenMinisPrivilegedHelperPackaged(void);
FOUNDATION_EXPORT NSString *OpenMinisNativeIdentity(void);
FOUNDATION_EXPORT void OpenMinisCancelPrivilegedRequests(void);
FOUNDATION_EXPORT void OpenMinisCancelPrivilegedRequestsForSession(NSString *sessionID);
FOUNDATION_EXPORT NSString * _Nullable OpenMinisSystemAccessSessionKey(NSString * _Nullable sessionID);

/// One short-lived allowlisted helper request. The JSON body (at most 3 MiB)
/// is framed onto the helper's dedicated FD 3 request channel; it never touches
/// disk, and file content and credentials never appear in argv.
@interface OpenMinisPrivilegedRequest : NSObject
@property(nonatomic, copy, readonly, nullable) NSString *sessionID;
- (instancetype)initWithAction:(NSString *)action
                      payload:(NSDictionary *)payload
                    sessionID:(nullable NSString *)sessionID
    NS_SWIFT_NAME(init(action:payload:sessionID:));
/// Read-only helper identity diagnostics, not a system-file permission grant.
+ (instancetype)identityProbe NS_SWIFT_NAME(identityProbe());
- (void)runWithCompletion:(void (^)(NSString *resultJSON))completion;
- (void)cancel;
@end
NS_ASSUME_NONNULL_END
