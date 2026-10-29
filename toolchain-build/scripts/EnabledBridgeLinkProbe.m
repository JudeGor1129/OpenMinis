// Link-only iPhoneOS executable. Do not install or execute this probe.
// Its references keep bridge methods live, forcing clang/LLVM and ld64 symbols
// to resolve in the final executable. No dynamic_lookup or dead-strip is used.
#import <Foundation/Foundation.h>
#import "OMToolchain.h"

int main(void) {
    @autoreleasepool {
        [OMToolchain initializeRuntimes];
        NSDictionary<NSString *, NSString *> *status = [OMToolchain capabilityStatus];
        NSString *out = nil;
        NSString *err = nil;
        OMToolchainStatus compiler = [OMToolchain runCC1:@[] stdout:&out stderr:&err];
        OMToolchainStatus linker = [OMToolchain runLinker:@[] stdout:&out stderr:&err];
        return (status.count && compiler == OMToolchainStatusBadArguments && linker == OMToolchainStatusBadArguments) ? 0 : 1;
    }
}
