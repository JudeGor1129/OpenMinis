#import <Foundation/Foundation.h>
#import "HelperResponseValidation.h"

// Tests the production validator only: no helper, persona, or system writes.
static int failures;
#define CHECK(test) do { if (!(test)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #test); failures++; } } while (0)
static NSMutableDictionary *Success(void) {
    return [@{@"protocol": @2, @"action": @"identity", @"ok": @YES,
        @"root_verified": @YES, @"uid": @0, @"euid": @0, @"gid": @0,
        @"egid": @0, @"stage": @"identity"} mutableCopy];
}
int main(void) {
    @autoreleasepool {
        NSDictionary *valid = MinisValidateHelperResponse(Success(), @"identity", 0);
        CHECK([valid[@"ok"] boolValue]); CHECK([valid[@"root_verified"] boolValue]);
        CHECK([valid[@"exit_code"] isEqual:@0]);
        NSDictionary *early = @{@"protocol": @2, @"action": @"read", @"ok": @NO,
            @"code": @"invalid_request_path", @"stage": @"request_validation",
            @"error": @"Request is outside the app-container request directory.",
            @"uid": @0, @"euid": @0, @"gid": @0, @"egid": @0, @"root_verified": @YES,
            @"content": @"must not leak on failure", @"unreviewed": @"ignored"};
        NSDictionary *failure = MinisValidateHelperResponse(early, @"read", 1);
        CHECK(![failure[@"ok"] boolValue]);
        CHECK([failure[@"code"] isEqual:@"invalid_request_path"]);
        CHECK([failure[@"stage"] isEqual:@"request_validation"]);
        CHECK([failure[@"error"] isEqual:early[@"error"]]);
        CHECK([failure[@"root_verified"] boolValue]);
        CHECK(failure[@"content"] == nil && failure[@"unreviewed"] == nil);
        failure = MinisValidateHelperResponse(@{@"protocol": @2, @"action": @"identity",
            @"ok": @NO, @"code": @"request_open_failed", @"error": @"Cannot open request safely."}, @"identity", 1);
        CHECK([failure[@"code"] isEqual:@"request_open_failed"]);
        CHECK(![failure[@"root_verified"] boolValue]);
        for (NSString *key in @[@"uid", @"euid", @"gid", @"egid"]) {
            NSMutableDictionary *source = Success(); [source removeObjectForKey:key];
            CHECK(![MinisValidateHelperResponse(source, @"identity", 0)[@"ok"] boolValue]);
            source[key] = @"0";
            CHECK(![MinisValidateHelperResponse(source, @"identity", 0)[@"ok"] boolValue]);
            source[key] = @NO;
            CHECK(![MinisValidateHelperResponse(source, @"identity", 0)[@"ok"] boolValue]);
            source[key] = @0.5;
            CHECK(![MinisValidateHelperResponse(source, @"identity", 0)[@"ok"] boolValue]);
            source[key] = @501;
            failure = MinisValidateHelperResponse(source, @"identity", 0);
            CHECK(![failure[@"ok"] boolValue]); CHECK([failure[key] isEqual:@501]);
        }
        failure = MinisValidateHelperResponse(Success(), @"identity", 77);
        CHECK([failure[@"code"] isEqual:@"exit_mismatch"]); CHECK(![failure[@"ok"] boolValue]);
        CHECK(![MinisValidateHelperResponse(Success(), @"read", 0)[@"ok"] boolValue]);
        CHECK(![MinisValidateHelperResponse(@[], @"identity", 0)[@"ok"] boolValue]);
        printf("RESULT %s: production helper response validator (%d failures); no privileged work executed.\n", failures ? "FAIL" : "PASS", failures);
    }
    return failures ? 1 : 0;
}
