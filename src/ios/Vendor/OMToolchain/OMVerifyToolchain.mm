//
//  OMVerifyToolchain.mm
//  End-to-end verification harness for the in-process toolchain.
//
//  Being able to compile something is not evidence that the *arm64e* path is
//  correct. A toolchain missing the arm64e lld patch still links happily and
//  still reports success — it just emits cpusubtype 0 (arm64) and A-key
//  prologues instead of B-key. Those two failure modes are invisible unless
//  this checks the bytes.
//
//  What this checks, in order:
//    1. An arm64e object compiles.
//    2. Its prologue is PACIBSP (0xd503237f, B-key) — not 0xdac103fe (A-key).
//    3. The linked dylib carries cpusubtype 0x80000002.
//
//  Expected B-key sequence, as observed in shipping arm64e tweaks:
//      prologue     0xd503237f  PACIBSP
//      epilogue     0xd50323ff  AUTIBSP
//      return       0xd65f0fff  RETAB
//  An A-key build instead shows 0xdac103fe + RETAA (0xd65f0bff).
//

#import <Foundation/Foundation.h>
#import <mach-o/loader.h>
#import <mach-o/fat.h>

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#import "OMToolchain.h"

static const uint32_t kPACIBSP = 0xD503237Fu; // sign LR with B key
static const uint32_t kAUTIBSP = 0xD50323FFu; // authenticate LR with B key
static const uint32_t kRETAB   = 0xD65F0FFFu;
static const uint32_t kPACIASP = 0xD503233Fu; // A-key equivalents
static const uint32_t kRETAA   = 0xD65F0BFFu;
static const uint32_t kShiftPACIAA = 0xDAC103FEu; // the A-key form a clang 14 emits

// A non-leaf function is required: a leaf function needs no frame and carries
// no return-address signing, so it would prove nothing.
static const char *kFixture =
    "#import <Foundation/Foundation.h>\n"
    "@interface OMVerifyProbe : NSObject\n"
    "- (int)compute:(int)x;\n"
    "@end\n"
    "@implementation OMVerifyProbe\n"
    "- (int)compute:(int)x {\n"
    "    NSArray *values = @[@(x)];\n"
    "    NSString *text = [values description];\n"
    "    return (int)(x + text.length);\n"
    "}\n"
    "@end\n";

typedef struct {
    uint32_t pacibsp, autibsp, retab, paciasp, retaa, otherPacia;
    uint64_t textBytes;
} PacTally;

/// Scans __text of a thin arm64 Mach-O and counts PAC instructions.
static BOOL ScanPAC(const char *path, PacTally *out) {
    memset(out, 0, sizeof(*out));
    NSData *data = [NSData dataWithContentsOfFile:@(path)
                                          options:NSDataReadingMappedIfSafe
                                            error:NULL];
    if (data.length < sizeof(struct mach_header_64)) return NO;

    const uint8_t *base = (const uint8_t *)data.bytes;
    struct mach_header_64 header;
    memcpy(&header, base, sizeof(header));
    if (header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64) return NO;

    size_t cursor = sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < header.ncmds; i++) {
        if (cursor + sizeof(struct load_command) > data.length) return NO;
        const struct load_command *lc =
            (const struct load_command *)(base + cursor);
        if (lc->cmdsize == 0 || cursor + lc->cmdsize > data.length) return NO;

        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg =
                (const struct segment_command_64 *)lc;
            for (uint32_t s = 0; s < seg->nsects; s++) {
                const struct section_64 *sec =
                    (const struct section_64 *)((const uint8_t *)seg +
                        sizeof(struct segment_command_64) + s * sizeof(struct section_64));
                if (strncmp(sec->sectname, "__text", 16) != 0) continue;

                const uint8_t *code = base + sec->offset;
                uint64_t words = sec->size / 4;
                out->textBytes = sec->size;
                for (uint64_t w = 0; w < words; w++) {
                    uint32_t insn = 0;
                    memcpy(&insn, code + w * 4, 4);
                    switch (insn) {
                        case kPACIBSP: out->pacibsp++; break;
                        case kAUTIBSP: out->autibsp++; break;
                        case kRETAB:   out->retab++;   break;
                        case kPACIASP: out->paciasp++; break;
                        case kRETAA:   out->retaa++;   break;
                        case kShiftPACIAA: out->otherPacia++; break;
                        default: break;
                    }
                }
            }
        }
        cursor += lc->cmdsize;
    }
    return YES;
}

int main(int argc, char **argv) {
    (void)argc;
    (void)argv;
    @autoreleasepool {
        printf("== OpenMinis in-process toolchain verification ==\n\n");

        NSString *tmp = NSTemporaryDirectory();
        NSString *src = [tmp stringByAppendingPathComponent:@"om_verify.m"];
        NSString *obj = [tmp stringByAppendingPathComponent:@"om_verify.o"];
        NSString *dylib = [tmp stringByAppendingPathComponent:@"om_verify.dylib"];

        NSError *err = nil;
        if (![@(kFixture) writeToFile:src atomically:YES
                             encoding:NSUTF8StringEncoding error:&err]) {
            printf("FAIL: cannot write fixture: %s\n", err.description.UTF8String);
            return 2;
        }
        printf("fixture: %s\n\n", src.UTF8String);

        [OMToolchain initializeRuntimes];

        // ---- 1. compile ----------------------------------------------------
        NSString *outText = nil, *errText = nil;
        NSArray *cc1 = [OMToolchain cc1ArgumentsForSource:src
                                               outputPath:obj
                                                  sysroot:nil
                                              resourceDir:nil
                                                 archName:@"arm64e"
                                               minimumIOS:@"14.0"];
        printf("cc1 args: %s\n\n", [[cc1 componentsJoinedByString:@" "] UTF8String]);

        OMToolchainStatus st = [OMToolchain runCC1:cc1 stdout:&outText stderr:&errText];
        printf("--- clang stdout ---\n%s\n", outText.UTF8String ?: "");
        printf("--- clang stderr ---\n%s\n", errText.UTF8String ?: "");
        if (st != OMToolchainStatusOK) {
            printf("FAIL: compile returned status %ld\n", (long)st);
            return 2;
        }
        printf("PASS: compiled\n\n");

        // ---- 2. object PAC form -------------------------------------------
        PacTally tally;
        if (!ScanPAC(obj.UTF8String, &tally)) {
            printf("FAIL: could not read __text from object\n");
            return 2;
        }
        printf("arm64e object __text=%llu B  PACIBSP=%u AUTIBSP=%u RETAB=%u\n",
               tally.textBytes, tally.pacibsp, tally.autibsp, tally.retab);
        printf("                           A-key PACIASP=%u RETAA=%u PACIA-literal=%u\n",
               tally.paciasp, tally.retaa, tally.otherPacia);

        BOOL objectUsesBKey = tally.pacibsp > 0 &&
            (tally.autibsp > 0 || tally.retab > 0) &&
            tally.paciasp == 0 && tally.retaa == 0 && tally.otherPacia == 0;
        if (!objectUsesBKey) {
            printf("\nFAIL: object is not B-key arm64e\n");
            if (tally.otherPacia || tally.paciasp || tally.retaa) {
                printf("      it was produced with the A key (PACIA/RETAA), which is the\n"
                       "      form an unpatched clang emits for an arm64e triple.\n");
            } else {
                printf("      no return-address signing found at all: the fixture may have\n"
                       "      been compiled as a leaf function, or PAC is disabled.\n");
            }
            return 3;
        }
        printf("PASS: object uses B-key return signing\n\n");

        // ---- 3. link -------------------------------------------------------
        NSArray *ld64 = @[ @"-arch", @"arm64e",
                           @"-dylib",
                           @"-platform_version", @"ios", @"14.0", @"16.5",
                           @"-o", dylib,
                           @"-install_name", @"@rpath/om_verify.dylib",
                           @"-framework", @"Foundation",
                           obj ];
        st = [OMToolchain runLinker:ld64 stdout:&outText stderr:&errText];
        printf("--- ld64 stdout ---\n%s\n", outText.UTF8String ?: "");
        printf("--- ld64 stderr ---\n%s\n", errText.UTF8String ?: "");
        if (st != OMToolchainStatusOK) {
            printf("FAIL: link returned status %ld\n", (long)st);
            return 4;
        }

        OMOutputArch arch = [OMToolchain architectureOfMachOAtPath:dylib];
        printf("linked dylib arch: %s\n",
               arch == OMOutputArchArm64e ? "arm64e (0x80000002)" :
               arch == OMOutputArchArm64 ? "arm64 (0)" : "unknown");
        if (arch != OMOutputArchArm64e) {
            printf("\nFAIL: the linker did not emit arm64e.\n"
                   "      This is the signature of a toolchain missing the lld\n"
                   "      MachO arm64e backend: it links happily but degrades to arm64.\n"
                   "      Check that deps/patches/llvm-arm64e-twork.diff applied and that\n"
                   "      lld/MachO/Arch/ARM64e.cpp exists in the build tree.\n");
            return 5;
        }

        if (!ScanPAC(dylib.UTF8String, &tally)) {
            printf("FAIL: could not read linked dylib\n");
            return 5;
        }
        printf("linked dylib PACIBSP=%u AUTIBSP=%u RETAB=%u  PACIASP=%u RETAA=%u\n\n",
               tally.pacibsp, tally.autibsp, tally.retab, tally.paciasp, tally.retaa);
        BOOL linkedUsesBKey = tally.pacibsp > 0 &&
            (tally.autibsp > 0 || tally.retab > 0) &&
            tally.paciasp == 0 && tally.retaa == 0 && tally.otherPacia == 0;
        if (!linkedUsesBKey) {
            printf("FAIL: linked output lost B-key signing\n");
            return 5;
        }

        printf("PASS: arm64e object + arm64e dylib with B-key signing\n");
        printf("\n== verification complete ==\n");
        return 0;
    }
}
