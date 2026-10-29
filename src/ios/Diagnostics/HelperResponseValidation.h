#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>

// Pure validation: missing IDs, strings, booleans and fractional numbers never
// count as uid0. Error replies preserve code/stage/IDs but never file contents.
static inline BOOL MinisHelperHasZeroID(NSDictionary *object, NSString *key) {
    id value = object[key];
    return [value isKindOfClass:NSNumber.class] &&
        CFGetTypeID((__bridge CFTypeRef)value) != CFBooleanGetTypeID() &&
        [(NSNumber *)value compare:@0] == NSOrderedSame;
}

static inline NSDictionary *MinisValidateHelperResponse(id raw, NSString *action, int exitCode) {
    NSDictionary *object = [raw isKindOfClass:NSDictionary.class] ? raw : nil;
    if (![object[@"protocol"] isEqual:@2] || ![object[@"action"] isEqual:action] ||
        ![object[@"ok"] isKindOfClass:NSNumber.class]) {
        return @{@"protocol": @2, @"action": action, @"ok": @NO,
                 @"code": @"invalid_response", @"root_verified": @NO,
                 @"exit_code": @(exitCode),
                 @"error": @"Helper returned an invalid protocol envelope."};
    }
    BOOL root = [object[@"root_verified"] isKindOfClass:NSNumber.class] &&
        [object[@"root_verified"] boolValue] &&
        MinisHelperHasZeroID(object, @"uid") && MinisHelperHasZeroID(object, @"euid") &&
        MinisHelperHasZeroID(object, @"gid") && MinisHelperHasZeroID(object, @"egid");
    BOOL claimedOK = [object[@"ok"] boolValue];
    if (claimedOK && root && exitCode == 0) {
        NSMutableDictionary *success = [object mutableCopy];
        success[@"exit_code"] = @0;
        return success;
    }
    NSMutableDictionary *failure = [@{@"protocol": @2, @"action": action,
        @"ok": @NO, @"root_verified": @(root), @"exit_code": @(exitCode)} mutableCopy];
    for (NSString *key in @[@"uid", @"euid", @"gid", @"egid"])
        if ([object[key] isKindOfClass:NSNumber.class]) failure[key] = object[key];
    for (NSString *key in @[@"code", @"stage", @"error"])
        if ([object[key] isKindOfClass:NSString.class])
            failure[key] = [(NSString *)object[key] substringToIndex:MIN([(NSString *)object[key] length], 1600)];
    if (claimedOK) {
        failure[@"code"] = root ? @"exit_mismatch" : @"root_not_verified";
        failure[@"error"] = root ? @"Helper success envelope had a non-zero exit code."
            : @"Helper did not verify all real uid/euid/gid/egid values as 0.";
    } else if (!failure[@"code"]) {
        failure[@"code"] = @"helper_failed";
    }
    if (!failure[@"error"]) failure[@"error"] = @"Helper operation failed; inspect code and stage.";
    return failure;
}
