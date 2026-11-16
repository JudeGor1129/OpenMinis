#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
FOUNDATION_EXPORT BOOL OpenMinisPrivilegedHelperPackaged(void);
FOUNDATION_EXPORT NSString *OpenMinisNativeIdentity(void);
FOUNDATION_EXPORT void OpenMinisCancelPrivilegedRequests(void);
FOUNDATION_EXPORT void OpenMinisCancelPrivilegedRequestsForSession(NSString *sessionID);
FOUNDATION_EXPORT NSString * _Nullable OpenMinisSystemAccessSessionKey(NSString * _Nullable sessionID);

/// One short-lived allowlisted helper request. Request bodies are framed on FD 3,
/// never placed in argv or disk. Results are JSON with stdout/stderr/exit code.
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
