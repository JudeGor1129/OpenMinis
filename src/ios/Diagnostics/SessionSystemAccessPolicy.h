#pragma once
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN

// Pure permission/ownership checks. No persona calls, I/O or process launch.
static inline NSString * _Nullable MinisSessionSystemAccessKey(NSString * _Nullable sid) {
    if (![sid isKindOfClass:NSString.class] || sid.length == 0 || sid.length > 256 ||
        [sid hasPrefix:@"__"] ||
        [sid rangeOfCharacterFromSet:NSCharacterSet.controlCharacterSet].location != NSNotFound)
        return nil;
    return [@"system.access.session." stringByAppendingString:sid]; // exact, no ID aliasing
}

static inline NSInteger MinisSessionSystemAccessRank(NSString * _Nullable mode) {
    if ([mode isEqualToString:@"readonly"]) return 1;
    if ([mode isEqualToString:@"limited"]) return 2;
    if ([mode isEqualToString:@"expert"]) return 3;
    return 0; // absent, disabled or malformed -> fail closed
}

static inline BOOL MinisSessionAuditOwnerMatches(NSDictionary *metadata, NSString *sid) {
    return MinisSessionSystemAccessKey(sid) != nil &&
        [metadata[@"session_id"] isKindOfClass:NSString.class] &&
        [metadata[@"session_id"] isEqualToString:sid];
}

static inline NSString * _Nullable MinisSessionSystemAccessRefusal(
    NSString *action, NSString * _Nullable sid, NSString * _Nullable requestedMode,
    NSUserDefaults *defaults, BOOL identityProbe) {
    if (![@[@"identity", @"read", @"write", @"rollback", @"stage_chunk", @"stage_abort", @"plugin_install", @"root_command", @"file_stage_chunk", @"file_publish", @"file_abort"] containsObject:action])
        return @"Action is not allowlisted.";
    // Only the dedicated read-only identity factory may be unscoped.
    if (identityProbe)
        return [action isEqualToString:@"identity"] && !sid ? nil : @"Invalid identity probe.";
    NSString *key = MinisSessionSystemAccessKey(sid);
    if (!key) return @"A persisted session is required.";
    NSInteger granted = MinisSessionSystemAccessRank([defaults stringForKey:key]);
    NSInteger requested = MinisSessionSystemAccessRank(requestedMode);
    if (!granted) return @"System access is disabled for this session.";
    if (!requested || requested > granted) return @"Session permission changed or is insufficient.";
    if (([action isEqualToString:@"write"] || [action isEqualToString:@"rollback"] ||
         [action isEqualToString:@"stage_chunk"] || [action isEqualToString:@"stage_abort"] || [action isEqualToString:@"plugin_install"] ||
         [action isEqualToString:@"root_command"] || [action isEqualToString:@"file_stage_chunk"] ||
         [action isEqualToString:@"file_publish"] || [action isEqualToString:@"file_abort"]) && requested < 2)
        return @"This session is in read-only mode.";
    return nil;
}
NS_ASSUME_NONNULL_END
