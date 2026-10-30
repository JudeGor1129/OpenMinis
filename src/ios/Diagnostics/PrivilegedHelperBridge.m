#import "PrivilegedHelperBridge.h"
#import "HelperProcessRunner.h"
#import "HelperResponseValidation.h"
#import "SessionSystemAccessPolicy.h"
#import <UIKit/UIKit.h>
#include <errno.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

NSString *OpenMinisSystemAccessSessionKey(NSString *sessionID) {
    return MinisSessionSystemAccessKey(sessionID);
}

static dispatch_queue_t PrivilegedQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.openminis.system-access", DISPATCH_QUEUE_SERIAL); });
    return queue;
}
static NSString *HelperPath(void) {
    return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"minis-privileged-helper"];
}
BOOL OpenMinisPrivilegedHelperPackaged(void) {
    NSString *path = HelperPath();
    struct stat st;
    return lstat(path.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode)
        && !S_ISLNK(st.st_mode) && !(st.st_mode & (S_IWGRP | S_IWOTH))
        && (st.st_mode & S_IXUSR) != 0;
}
NSString *OpenMinisNativeIdentity(void) {
    return [NSString stringWithFormat:@"GUI uid=%u euid=%u gid=%u egid=%u; helper=%@",
        getuid(), geteuid(), getgid(), getegid(), OpenMinisPrivilegedHelperPackaged() ? @"packaged" : @"missing"];
}
static NSString *JSONError(NSString *action, NSString *code, NSString *message) {
    NSDictionary *object = @{ @"protocol": @2, @"ok": @NO, @"action": action ?: @"unknown",
        @"code": code ?: @"bridge_error", @"error": message ?: @"Bridge request failed.",
        @"root_verified": @NO, @"stage": @"bridge" };
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:NULL];
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"{\"ok\":false}";
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
void OpenMinisCancelPrivilegedRequestsForSession(NSString *sessionID) {
    NSHashTable *requests = Requests();
    @synchronized (requests) {
        for (OpenMinisPrivilegedRequest *request in requests.allObjects)
            if ([request.sessionID isEqualToString:sessionID]) [request cancel];
    }
}
static NSData *RequestFrameBody(NSString *action, NSDictionary *payload, NSString *sessionID, NSError **error) {
    NSMutableDictionary *body = [payload mutableCopy] ?: [NSMutableDictionary dictionary];
    body[@"protocol"] = @2; body[@"action"] = action;
    if (sessionID) body[@"session_id"] = sessionID;
    else [body removeObjectForKey:@"session_id"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:error];
    if (data && data.length > 3 * 1024 * 1024) {
        if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:EMSGSIZE userInfo:nil];
        return nil;
    }
    return data;
}

@implementation OpenMinisPrivilegedRequest {
    NSString *_action;
    NSString *_sessionID;
    NSString *_requestedMode;
    NSData *_requestBody;
    NSError *_encodingError;
    BOOL _identityProbe;
    MinisHelperControl _control;
    BOOL _started;
}
- (instancetype)initWithAction:(NSString *)action payload:(NSDictionary *)payload sessionID:(NSString *)sessionID {
    if ((self = [super init])) {
        _action = [action copy];
        _sessionID = [sessionID copy];
        _requestedMode = [payload[@"mode"] isKindOfClass:NSString.class] ? [payload[@"mode"] copy] : nil;
        NSError *error = nil;
        _requestBody = [RequestFrameBody(_action, payload, _sessionID, &error) copy];
        _encodingError = error;
        MinisHelperControlInit(&_control);
        NSHashTable *requests = Requests();
        @synchronized (requests) { [requests addObject:self]; }
    }
    return self;
}
+ (instancetype)identityProbe {
    OpenMinisPrivilegedRequest *request = [[self alloc] initWithAction:@"identity" payload:@{} sessionID:nil];
    request->_identityProbe = YES;
    return request;
}
- (NSString *)sessionID { return _sessionID; }
- (void)cancel { MinisHelperCancel(&_control); }
- (NSString *)authorizationRefusal {
    if (atomic_load(&_control.cancelled)) return @"Request cancelled.";
    NSString *refusal = MinisSessionSystemAccessRefusal(_action, _sessionID, _requestedMode,
                                                       NSUserDefaults.standardUserDefaults, _identityProbe);
    if (refusal) return refusal;
    if (!OpenMinisPrivilegedHelperPackaged()) return @"Signed system helper is unavailable; install the dedicated TrollStore build.";
    return nil;
}
- (void)runWithCompletion:(void (^)(NSString *))completion {
    @synchronized (self) {
        if (_started) { dispatch_async(dispatch_get_main_queue(), ^{ completion(JSONError(self->_action, @"already_started", @"Request already started.")); }); return; }
        _started = YES;
    }
    if (!NSThread.isMainThread) {
        dispatch_async(dispatch_get_main_queue(), ^{ [self startAllowedRequest:completion]; });
        return;
    }
    [self startAllowedRequest:completion];
}
- (void)startAllowedRequest:(void (^)(NSString *))completion {
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) {
        completion(JSONError(_action, @"foreground_required", @"System access requires the active foreground app.")); return;
    }
    __weak OpenMinisPrivilegedRequest *weakSelf = self;
    id background = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) { (void)note; [weakSelf cancel]; }];
    id settings = [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *note) {
        (void)note;
        OpenMinisPrivilegedRequest *request = weakSelf;
        if (request && [request authorizationRefusal]) [request cancel];
    }];
    NSString *refusal = [self authorizationRefusal];
    if (refusal) {
        [NSNotificationCenter.defaultCenter removeObserver:background];
        [NSNotificationCenter.defaultCenter removeObserver:settings];
        completion(JSONError(_action, @"authorization_refused", refusal)); return;
    }
    // The bytes and requested mode were frozen at initialization. Rechecking
    // defaults above and immediately before launch cannot enlarge this request.
    NSData *requestBody = _requestBody;
    if (!requestBody) {
        [NSNotificationCenter.defaultCenter removeObserver:background];
        [NSNotificationCenter.defaultCenter removeObserver:settings];
        completion(JSONError(_action, @"request_encoding_failed", _encodingError.localizedDescription)); return;
    }
    dispatch_async(PrivilegedQueue(), ^{
        @autoreleasepool {
            __block NSString *lateRefusal = nil;
            dispatch_sync(dispatch_get_main_queue(), ^{
                lateRefusal = [self authorizationRefusal];
                if (!lateRefusal && UIApplication.sharedApplication.applicationState != UIApplicationStateActive)
                    lateRefusal = @"App left foreground before helper launch.";
            });
            if (lateRefusal) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [NSNotificationCenter.defaultCenter removeObserver:background];
                    [NSNotificationCenter.defaultCenter removeObserver:settings];
                    completion(JSONError(self->_action, @"authorization_revoked", lateRefusal));
                });
                return;
            }
            MinisHelperResult result = MinisHelperRun(HelperPath().fileSystemRepresentation,
                self->_action.UTF8String, requestBody.bytes, requestBody.length,
                true, 20000, &self->_control);
            NSString *response = [self checkedResult:&result];
            MinisHelperResultFree(&result);
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSNotificationCenter.defaultCenter removeObserver:background];
                [NSNotificationCenter.defaultCenter removeObserver:settings];
                completion(response);
            });
        }
    });
}
- (NSString *)checkedResult:(MinisHelperResult *)result {
    if (result->cancelled) return JSONError(_action, @"cancelled", @"Helper request was cancelled and reaped.");
    if (result->timed_out) return JSONError(_action, @"timeout", @"Helper request timed out and was killed.");
    if (result->output_limit) return JSONError(_action, @"output_limit", @"Helper exceeded the output limit and was killed.");
    if (result->spawn_error) return JSONError(_action, @"spawn_failed", [NSString stringWithFormat:@"Persona spawn failed: %d (%s).", result->spawn_error, strerror(result->spawn_error)]);
    // Prefer the helper's own JSON (it carries real IDs and stage); only
    // synthesize a channel error when the helper produced no reply at all.
    if (result->request_error && result->exit_code != 0 && result->out_size == 0)
        return JSONError(_action, @"request_channel_failed", [NSString stringWithFormat:@"Request channel failed: %d (%s).", result->request_error, strerror(result->request_error)]);
    if (result->term_signal) return JSONError(_action, @"signal", [NSString stringWithFormat:@"Helper terminated by signal %d.", result->term_signal]);
    NSData *data = result->out_data ? [NSData dataWithBytes:result->out_data length:result->out_size] : nil;
    id raw = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
    NSDictionary *checked = MinisValidateHelperResponse(raw, _action, result->exit_code);
    NSData *checkedData = [NSJSONSerialization dataWithJSONObject:checked options:0 error:NULL];
    NSString *text = checkedData ? [[NSString alloc] initWithData:checkedData encoding:NSUTF8StringEncoding] : nil;
    return text ?: JSONError(_action, @"invalid_utf8", @"Helper response was not UTF-8 JSON.");
}
@end
