#import <Foundation/Foundation.h>
#import "OMToolchain.h"
#include <mach-o/loader.h>
#include <string.h>

static void Require(BOOL condition, NSString *message) {
    if (!condition) {
        NSLog(@"FAIL: %@", message);
        exit(1);
    }
}

static NSString *WriteHeader(NSString *directory, NSString *name, cpu_type_t type,
                             cpu_subtype_t subtype, uint32_t magic) {
    struct mach_header_64 header;
    memset(&header, 0, sizeof(header));
    header.magic = magic;
    header.cputype = type;
    header.cpusubtype = subtype;
    NSString *path = [directory stringByAppendingPathComponent:name];
    Require([[NSData dataWithBytes:&header length:sizeof(header)] writeToFile:path atomically:YES], @"write synthetic header");
    return path;
}

int main(void) {
    @autoreleasepool {
        NSDictionary<NSString *, NSString *> *status = [OMToolchain capabilityStatus];
        Require([status[@"compiler_linked"] isEqualToString:@"no"], @"compiler must be disabled");
        Require([status[@"state"] isEqualToString:@"unavailable"], @"resources must not imply compiler availability");
        Require(status[@"reason"].length > 0, @"unavailable reason");
        [OMToolchain initializeRuntimes];
        [OMToolchain initializeRuntimes];
        for (NSUInteger i = 0; i < 2; ++i) {
            NSString *out = @"old stdout";
            NSString *err = @"old stderr";
            OMToolchainStatus result = [OMToolchain runCC1:@[] stdout:&out stderr:&err];
            Require(result == OMToolchainStatusUnavailable && out.length == 0 && err.length > 0, @"compile unavailable, outputs overwritten");
            result = [OMToolchain runLinker:@[] stdout:&out stderr:&err];
            Require(result == OMToolchainStatusUnavailable && out.length == 0 && err.length > 0, @"link unavailable, outputs overwritten");
        }
        Require([OMToolchain runCC1:@[] stdout:NULL stderr:NULL] == OMToolchainStatusUnavailable, @"nullable diagnostic slots");
        Require([OMToolchain runLinker:@[] stdout:NULL stderr:NULL] == OMToolchainStatusUnavailable, @"nullable linker slots");

        NSString *sdk = @"/explicit/sdk";
        NSString *resource = @"/explicit/resource";
        [OMToolchain resolveDefaultPathsForSysroot:&sdk resourceDir:&resource];
        Require([sdk isEqualToString:@"/explicit/sdk"] && [resource isEqualToString:@"/explicit/resource"], @"preserve explicit paths");
        [OMToolchain resolveDefaultPathsForSysroot:NULL resourceDir:NULL];
        NSArray *args = [OMToolchain cc1ArgumentsForSource:@"test.m" outputPath:@"test.o" sysroot:sdk resourceDir:resource archName:@"arm64" minimumIOS:@"16.0"];
        Require([args containsObject:@"arm64-apple-ios16.0"], @"target triple");
        Require([args containsObject:@"-fobjc-arc"] && [args containsObject:@"objective-c"], @"Objective-C selection");
        NSUInteger resourceIndex = [args indexOfObject:@"-resource-dir"];
        Require(resourceIndex != NSNotFound && resourceIndex + 1 < args.count && [args[resourceIndex + 1] isEqual:resource], @"resource root (not include directory)");
        NSArray *cpp = [OMToolchain cc1ArgumentsForSource:@"test.cpp" outputPath:@"test.o" sysroot:sdk resourceDir:resource archName:@"arm64e" minimumIOS:nil];
        Require([cpp containsObject:@"c++"] && ![cpp containsObject:@"-fobjc-arc"], @"C++ selection");
        Require([cpp containsObject:@"arm64e-apple-ios14.0"], @"default target minimum");

        NSString *directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        Require([[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL], @"test directory");
        Require([OMToolchain architectureOfMachOAtPath:[directory stringByAppendingPathComponent:@"missing"]] == OMOutputArchUnknown, @"missing file");
        NSString *shortFile = [directory stringByAppendingPathComponent:@"short"];
        Require([[NSData dataWithBytes:"abc" length:3] writeToFile:shortFile atomically:YES], @"short fixture");
        Require([OMToolchain architectureOfMachOAtPath:shortFile] == OMOutputArchUnknown, @"truncated header");
        NSString *arm64 = WriteHeader(directory, @"arm64", CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64_ALL, MH_MAGIC_64);
        NSString *arm64e = WriteHeader(directory, @"arm64e", CPU_TYPE_ARM64, CPU_SUBTYPE_ARM64E, MH_MAGIC_64);
        NSString *capability = WriteHeader(directory, @"arm64e-capability", CPU_TYPE_ARM64, (cpu_subtype_t)0x80000002, MH_MAGIC_64);
        NSString *other = WriteHeader(directory, @"x86", CPU_TYPE_X86_64, 0, MH_MAGIC_64);
        NSString *badMagic = WriteHeader(directory, @"bad-magic", CPU_TYPE_ARM64, 0, 0);
        Require([OMToolchain architectureOfMachOAtPath:arm64] == OMOutputArchArm64, @"arm64 subtype");
        Require([OMToolchain architectureOfMachOAtPath:arm64e] == OMOutputArchArm64e, @"arm64e subtype");
        Require([OMToolchain architectureOfMachOAtPath:capability] == OMOutputArchArm64e, @"mask capability bits");
        Require([OMToolchain architectureOfMachOAtPath:other] == OMOutputArchUnknown, @"non ARM64");
        Require([OMToolchain architectureOfMachOAtPath:badMagic] == OMOutputArchUnknown, @"invalid magic");
        Require([[NSFileManager defaultManager] removeItemAtPath:directory error:NULL], @"remove fixtures");
        puts("Disabled bridge host tests passed (no LLVM compilation tested).");
    }
    return 0;
}
