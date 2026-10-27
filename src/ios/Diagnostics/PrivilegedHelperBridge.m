#import "PrivilegedHelperBridge.h"
#import "HelperProcessRunner.h"
#import <UIKit/UIKit.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

static NSString *const RootEnabled = @"agent.tools.rootHelper.enabled";
static NSString *const FridaEnabled = @"agent.tools.fridaProcesses.enabled";
static NSString *const FridaRiskAccepted = @"agent.tools.fridaProcesses.risk.v1";
static dispatch_queue_t PrivilegedQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ q = dispatch_queue_create("app.openminis.privileged-helper", DISPATCH_QUEUE_SERIAL); });
    return q;
}
static NSString *HelperPath(void) {
    return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"minis-privileged-helper"];
}
BOOL OpenMinisPrivilegedHelperPackaged(void) {
    NSString *path = HelperPath();
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode)
        && !S_ISLNK(st.st_mode) && (st.st_mode & (S_IWGRP | S_IWOTH)) == 0
        && access(path.fileSystemRepresentation, X_OK) == 0;
}
NSString *OpenMinisNativeIdentity(void) {
    return [NSString stringWithFormat:@"Native iOS GUI uid=%u euid=%u gid=%u egid=%u. iSH guest uid is unrelated. Helper packaged=%@.",
        getuid(), geteuid(), getgid(), getegid(), OpenMinisPrivilegedHelperPackaged() ? @"YES" : @"NO"];
}

static NSHashTable<OpenMinisPrivilegedRequest *> *Requests(void) {
    static NSHashTable *requests;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ requests = NSHashTable.weakObjectsHashTable; });
    return requests;
}
void OpenMinisCancelPrivilegedRequests(void) {
    NSHashTable *requests = Requests();
    @synchronized (requests) {
        for (OpenMinisPrivilegedRequest *request in requests.allObjects) [request cancel];
    }
}

@implementation OpenMinisPrivilegedRequest {
    NSString *_action;
    MinisHelperControl _control;
    BOOL _started;
}
- (instancetype)initWithAction:(NSString *)action {
    if ((self = [super init])) {
        _action = [action copy];
        MinisHelperControlInit(&_control);
        NSHashTable *requests = Requests();
        @synchronized (requests) { [requests addObject:self]; }
    }
    return self;
}
- (void)cancel { MinisHelperCancel(&_control); }
- (NSString *)authorizationRefusal {
    if (atomic_load(&_control.cancelled)) return @"ERROR: helper request cancelled.";
    BOOL isFrida = [_action isEqualToString:@"frida-processes"];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if (![_action isEqualToString:@"identity"] && !isFrida) return @"ERROR: helper action not allowlisted.";
    if (![d boolForKey:RootEnabled]) return @"ERROR: root helper is disabled in Settings > Tools.";
    if (isFrida && (![d boolForKey:FridaEnabled] || ![d boolForKey:FridaRiskAccepted])) return @"ERROR: experimental Frida query is disabled or risk acceptance was revoked.";
    if (!OpenMinisPrivilegedHelperPackaged()) return @"ERROR: signed helper unavailable; use the dedicated TrollStore package.";
    return nil;
}
- (void)runWithCompletion:(void (^)(NSString *))completion {
    @synchronized (self) {
        if (_started) { dispatch_async(dispatch_get_main_queue(), ^{ completion(@"ERROR: request already started."); }); return; }
        _started = YES;
    }
    // Never begin a privileged operation off main: registration and re-checking
    // must happen after any queued UI revocation has run.
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startAllowedRequest:completion]; });
        return;
    }
    [self startAllowedRequest:completion];
}
- (void)startAllowedRequest:(void (^)(NSString *))completion {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        completion(@"ERROR: privileged helpers require the active foreground app."); return;
    }
    __weak OpenMinisPrivilegedRequest *weakSelf = self;
    id background = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { [weakSelf cancel]; }];
    id setting = [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        OpenMinisPrivilegedRequest *request = weakSelf;
        if (!request) return;
        if ([request authorizationRefusal]) [request cancel];
    }];
    // Re-check AFTER installing revocation observers, closing the earlier gap.
    NSString *refusal = [self authorizationRefusal];
    if (refusal) {
        [NSNotificationCenter.defaultCenter removeObserver:background];
        [NSNotificationCenter.defaultCenter removeObserver:setting];
        completion(refusal); return;
    }
    dispatch_async(PrivilegedQueue(), ^{
        @autoreleasepool {
            // Last check after queueing: a toggle or background transition may
            // have revoked this request while it waited for the serial queue.
            __block NSString *lateRefusal = nil;
            dispatch_sync(dispatch_get_main_queue(), ^{
                lateRefusal = [self authorizationRefusal];
                if (!lateRefusal && UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
                    lateRefusal = @"ERROR: app left foreground before helper launch.";
            });
            if (lateRefusal) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSNotificationCenter.defaultCenter removeObserver:background];
                    [NSNotificationCenter.defaultCenter removeObserver:setting];
                    completion(lateRefusal ?: @"ERROR: app left foreground before helper launch.");
                });
                return;
            }
            MinisHelperResult result = MinisHelperRun(HelperPath().fileSystemRepresentation,
                self->_action.UTF8String, true, 14000, &self->_control);
            NSString *text = [self checkedResult:&result];
            MinisHelperResultFree(&result);
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter removeObserver:background];
                [NSNotificationCenter.defaultCenter removeObserver:setting];
                completion(text);
            });
        }
    });
}
- (NSString *)checkedResult:(MinisHelperResult *)r {
    NSString *prefix = OpenMinisNativeIdentity();
    if (r->cancelled) return [prefix stringByAppendingString:@"\nERROR: helper cancelled; child reaped."];
    if (r->timed_out) return [prefix stringByAppendingString:@"\nERROR: helper timed out; child killed and reaped."];
    if (r->output_limit) return [prefix stringByAppendingString:@"\nERROR: helper output limit exceeded; child killed and reaped."];
    if (r->spawn_error) return [NSString stringWithFormat:@"%@\nERROR: persona/spawn failed (%d: %s). No root capability verified. TrollStore/jailbreak permission support must be checked on device.", prefix, r->spawn_error, strerror(r->spawn_error)];
    if (r->term_signal) return [NSString stringWithFormat:@"%@\nERROR: helper terminated by signal %d. Do not keep retrying protocol probes.", prefix, r->term_signal];
    NSData *data = r->out_data ? [NSData dataWithBytes:r->out_data length:r->out_size] : nil;
    NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    if (![json isKindOfClass:NSDictionary.class] || ![json[@"protocol"] isKindOfClass:NSNumber.class] ||
        [json[@"protocol"] intValue] != 1 || ![json[@"action"] isEqual:_action]) return [prefix stringByAppendingString:@"\nERROR: invalid helper result; root capability not verified."];
    BOOL root = [json[@"root_verified"] isKindOfClass:NSNumber.class] && [json[@"root_verified"] boolValue]
        && [json[@"uid"] isKindOfClass:NSNumber.class] && [json[@"uid"] intValue] == 0
        && [json[@"euid"] isKindOfClass:NSNumber.class] && [json[@"euid"] intValue] == 0
        && [json[@"gid"] isKindOfClass:NSNumber.class] && [json[@"gid"] intValue] == 0
        && [json[@"egid"] isKindOfClass:NSNumber.class] && [json[@"egid"] intValue] == 0;
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithObjects:prefix,
        root ? @"Helper real uid/euid/gid/egid=0 verified for this operation. GUI is not changed to uid0; iSH is still emulated." : @"ERROR: helper did not verify all real root IDs.", nil];
    NSString *version = [json[@"server_package_version"] isKindOfClass:NSString.class] ? json[@"server_package_version"] : @"unknown";
    [lines addObject:[@"Installed Frida package metadata: " stringByAppendingString:version]];
    BOOL ok = root && r->exit_code == 0 && [json[@"ok"] isKindOfClass:NSNumber.class] && [json[@"ok"] boolValue];
    if (!ok) {
        NSString *detail = [json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] : @"helper operation failed";
        [lines addObject:[NSString stringWithFormat:@"ERROR: %@ (exit %d)", detail, r->exit_code]];
    } else if ([_action isEqualToString:@"frida-processes"]) {
        [lines addObject:@"Frida Core client 17.9.10; explicit loopback socket-only query. Listing does not prove attach permission."];
        NSArray *processes = [json[@"processes"] isKindOfClass:NSArray.class] ? json[@"processes"] : nil;
        if (!processes || processes.count > 300) return [prefix stringByAppendingString:@"\nERROR: invalid process list."];
        for (id item in processes) {
            if (![item isKindOfClass:NSDictionary.class] || ![item[@"name"] isKindOfClass:NSString.class] || ![item[@"pid"] isKindOfClass:NSNumber.class]) continue;
            NSString *name = [item[@"name"] stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
            [lines addObject:[NSString stringWithFormat:@"%@\t%@", item[@"pid"], name]];
        }
        if (!processes.count) [lines addObject:@"Empty process list; cause and permissions remain undetermined."];
    }
    return [lines componentsJoinedByString:@"\n"];
}
@end
