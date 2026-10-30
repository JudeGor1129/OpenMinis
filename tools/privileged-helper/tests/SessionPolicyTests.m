#import <Foundation/Foundation.h>
#import "SessionSystemAccessPolicy.h"
#include <stdio.h>

// Runs the production pure policy only. No helper/persona/system-file access.
static int failures;
#define CHECK(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); ++failures; } } while (0)
int main(void) {
    @autoreleasepool {
        NSString *suite = [@"om.session-policy.tests." stringByAppendingString:NSUUID.UUID.UUIDString];
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:suite];
        NSString *a = @"session.a", *b = @"session_a";
        NSString *ka = MinisSessionSystemAccessKey(a), *kb = MinisSessionSystemAccessKey(b);
        CHECK(ka && kb && ![ka isEqualToString:kb]);
        CHECK(MinisSessionSystemAccessKey(nil) == nil);
        CHECK(MinisSessionSystemAccessKey(@"") == nil);
        CHECK(MinisSessionSystemAccessKey(@"__new__draft") == nil);
        CHECK(MinisSessionSystemAccessKey(@"__grp__draft") == nil);
        [d setBool:YES forKey:@"system.access.enabled"];
        [d setObject:@"expert" forKey:@"system.access.mode"];
        CHECK(MinisSessionSystemAccessRefusal(@"read", a, @"readonly", d, NO) != nil);
        [d setObject:@"readonly" forKey:ka];
        CHECK(MinisSessionSystemAccessRefusal(@"read", a, @"readonly", d, NO) == nil);
        CHECK(MinisSessionSystemAccessRefusal(@"identity", a, @"readonly", d, NO) == nil);
        CHECK(MinisSessionSystemAccessRefusal(@"write", a, @"readonly", d, NO) != nil);
        CHECK(MinisSessionSystemAccessRefusal(@"rollback", a, @"readonly", d, NO) != nil);
        CHECK(MinisSessionSystemAccessRefusal(@"read", b, @"readonly", d, NO) != nil);
        [d setObject:@"limited" forKey:ka];
        CHECK(MinisSessionSystemAccessRefusal(@"write", a, @"limited", d, NO) == nil);
        CHECK(MinisSessionSystemAccessRefusal(@"write", a, @"expert", d, NO) != nil);
        [d setObject:@"expert" forKey:ka];
        // A permission upgrade never upgrades the frozen request mode itself.
        CHECK(MinisSessionSystemAccessRefusal(@"write", a, @"readonly", d, NO) != nil);
        [d setObject:@"readonly" forKey:ka];
        CHECK(MinisSessionSystemAccessRefusal(@"write", a, @"limited", d, NO) != nil);
        [d removeObjectForKey:ka];
        CHECK(MinisSessionSystemAccessRefusal(@"identity", a, @"readonly", d, NO) != nil);
        CHECK(MinisSessionSystemAccessRefusal(@"identity", nil, nil, d, YES) == nil);
        CHECK(MinisSessionSystemAccessRefusal(@"read", nil, @"readonly", d, YES) != nil);
        [d setObject:@"invalid-mode" forKey:ka];
        CHECK(MinisSessionSystemAccessRefusal(@"read", a, @"readonly", d, NO) != nil);
        CHECK(MinisSessionSystemAccessRefusal(@"delete", a, @"expert", d, NO) != nil);
        CHECK(MinisSessionAuditOwnerMatches(@{@"session_id": a}, a));
        CHECK(!MinisSessionAuditOwnerMatches(@{@"session_id": a}, b));
        CHECK(!MinisSessionAuditOwnerMatches(@{}, a));
        CHECK(!MinisSessionAuditOwnerMatches(@{@"session_id": @7}, a));
        [d removePersistentDomainForName:suite];
        printf("RESULT %s: production session permission/rollback-owner policy (%d failures), no privileged operations.\n", failures ? "FAIL" : "PASS", failures);
    }
    return failures ? 1 : 0;
}
