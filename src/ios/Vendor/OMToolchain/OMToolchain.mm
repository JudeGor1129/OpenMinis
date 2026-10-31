//
//  OMToolchain.mm
//  In-process Clang + Mach-O linker runtime for the OpenMinis host process.
//
//  The front-end path deliberately reuses upstream clang's own driving code
//  rather than reimplementing it:
//
//      CompilerInvocation::CreateFromArgs
//          -> CompilerInstance (target, source manager, diagnostics)
//          -> clang::EmitObjAction
//          -> CompilerInstance::ExecuteAction
//
//  That chain is *exactly* what clang's `cc1_main` does, so the only thing this
//  file has to get right is the argument plumbing and diagnostics ownership.
//  EmitObjAction lives in clang's CodeGen library and is what actually writes
//  the object file, including pointer-authentication prologues/epilogues for
//  arm64e.
//

#import "OMToolchain.h"
#include <mach-o/loader.h>
#include <string.h>

// The normal app can build and expose accurate capability status before the
// matching LLVM archives and development headers are supplied. Enabling this
// switch requires real compiler/linker libraries; it never loads a library
// dynamically or falls back to a different architecture.
#ifndef OM_TOOLCHAIN_ENABLED
#define OM_TOOLCHAIN_ENABLED 0
#endif

#if OM_TOOLCHAIN_ENABLED
#include <exception>
#include <memory>
#include <string>
#include <vector>

// clang / LLVM
//
// No llvm/Support/Host.h: it was removed upstream (its declarations moved to
// TargetParser) and nothing here needs the *host* triple anyway -- the target
// triple is built from archName below ("%@-apple-ios%@").
#include "clang/Basic/Diagnostic.h"
#include "clang/Basic/DiagnosticIDs.h"
#include "clang/Basic/DiagnosticOptions.h"
#include "clang/Basic/FileManager.h"
#include "clang/Basic/TargetInfo.h"
#include "clang/CodeGen/CodeGenAction.h"
#include "clang/Frontend/CompilerInstance.h"
#include "clang/Frontend/CompilerInvocation.h"
#include "clang/Frontend/TextDiagnosticBuffer.h"
#include "clang/Frontend/TextDiagnosticPrinter.h"
#include "clang/Lex/Preprocessor.h"

#include "llvm/ADT/IntrusiveRefCntPtr.h"
#include "llvm/MC/TargetRegistry.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/VirtualFileSystem.h"
#include "llvm/Support/raw_ostream.h"

// Provided by the vendored, in-process ld64 build (see scripts/build-ios-toolchain.sh).
extern "C" int  om_ld64_main(int argc, const char *argv[]);
extern "C" void om_ld64_reset_options(void);
extern "C" void om_ld64_reset_state(void);
extern "C" void om_ld64_reset_branches(void);
extern "C" void om_ld64_reset_threads(void);

#include <mach-o/loader.h>
#include <mach-o/fat.h>
#include <sys/stat.h>

namespace {

/// Guards every LLVM/ld64 entry point. Both runtimes are process-global.
dispatch_queue_t OMQueue() {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.openminis.toolchain", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

/// `text` is moved into `*slot` if the caller asked for it.
void HandOut(NSString *text, NSString *_Nullable *_Nullable slot) {
    if (slot) *slot = text;
}

NSString *ToNSString(const std::string &s) {
    NSString *r = [[NSString alloc] initWithBytes:s.data()
                                           length:s.size()
                                         encoding:NSUTF8StringEncoding];
    return r ?: @"";
}

std::string ToStdString(NSString *s) {
    if (!s) return std::string();
    const char *utf8 = s.UTF8String;
    return utf8 ? std::string(utf8) : std::string();
}

/// Flattened, null-terminated storage for an argv built from NSStrings.
struct ArgvStorage {
    std::vector<std::string> owned;
    std::vector<const char *> argv;

    explicit ArgvStorage(NSArray<NSString *> *args, bool prependProgramName) {
        owned.reserve(args.count + 1);
        if (prependProgramName) owned.emplace_back("clang");
        for (NSString *a in args) owned.push_back(ToStdString(a));
        argv.reserve(owned.size() + 1);
        for (const std::string &s : owned) argv.push_back(s.c_str());
        argv.push_back(nullptr); // execvp-style terminator; ArrayRef excludes it
    }

    llvm::ArrayRef<const char *> arrayRef() const {
        return llvm::ArrayRef<const char *>(argv.data(), owned.size());
    }
};

} // namespace
#endif // OM_TOOLCHAIN_ENABLED

@implementation OMToolchain

+ (NSDictionary<NSString *, NSString *> *)capabilityStatus {
    NSString *sdk = nil;
    NSString *resource = nil;
    [self resolveDefaultPathsForSysroot:&sdk resourceDir:&resource];
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL headersReady = resource != nil;
    for (NSString *header in @[@"stddef.h", @"stdarg.h", @"stdint.h", @"ptrauth.h", @"arm_neon.h"]) {
        NSString *path = [[resource stringByAppendingPathComponent:@"include"] stringByAppendingPathComponent:header];
        if (!path || ![fm fileExistsAtPath:path]) headersReady = NO;
    }
    BOOL sdkReady = sdk && [fm fileExistsAtPath:[sdk stringByAppendingPathComponent:@"usr/include"]]
                        && [fm fileExistsAtPath:[sdk stringByAppendingPathComponent:@"System/Library/Frameworks/Foundation.framework/Headers"]];
    BOOL linked = OM_TOOLCHAIN_ENABLED != 0;
#if defined(OM_TOOLCHAIN_VERIFIED) && OM_TOOLCHAIN_VERIFIED
    BOOL verified = YES;
#else
    BOOL verified = NO;
#endif
    NSString *arch = @"unknown";
#if defined(__arm64e__)
    arch = @"arm64e";
#elif defined(__arm64__)
    arch = @"arm64";
#elif defined(__x86_64__)
    arch = @"x86_64";
#endif
    return @{@"compiler_linked": linked ? @"yes" : @"no",
             @"verification": verified ? @"passed" : @"missing",
             @"state": linked && verified && headersReady && sdkReady ? @"ready" : @"unavailable",
             @"host_architecture": arch,
             @"resource_headers": headersReady ? @"present" : @"missing",
             @"resource_dir": resource ?: @"",
             @"sdk": sdkReady ? @"present" : @"missing",
             @"sysroot": sdk ?: @"",
             @"reason": !linked ? @"此构建未链接 LLVM/ld64；准备好资源不代表已启用编译。"
                         : !verified ? @"已链接 LLVM/ld64，但尚未通过启用桥接编译与静态链接门禁。"
                         : !headersReady ? @"缺少与 LLVM 版本匹配的 Clang builtin headers。"
                         : !sdkReady ? @"缺少可用的 iOS SDK。"
                         : @"编译资源已通过配置门禁，仍需运行时编译与链接验证。"};
}

#if OM_TOOLCHAIN_ENABLED
+ (void)initializeRuntimes {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // arm64 codegen needs the AArch64 target, its MC layer and its asm
        // printer registered before the first CompilerInstance is created.
        LLVMInitializeAArch64TargetInfo();
        LLVMInitializeAArch64Target();
        LLVMInitializeAArch64TargetMC();
        LLVMInitializeAArch64AsmPrinter();
        LLVMInitializeAArch64AsmParser();
    });
}

#pragma mark - Front end

+ (OMToolchainStatus)runCC1:(NSArray<NSString *> *)cc1Arguments
                     stdout:(NSString *_Nullable *_Nullable)outText
                     stderr:(NSString *_Nullable *_Nullable)errText {
    if (cc1Arguments.count == 0) {
        HandOut(@"", outText);
        HandOut(@"OMToolchain: empty cc1 argument list\n", errText);
        return OMToolchainStatusBadArguments;
    }
    [self initializeRuntimes];

    __block OMToolchainStatus status = OMToolchainStatusInternalError;
    __block NSString *outString = @"";
    __block NSString *errString = @"";

    dispatch_sync(OMQueue(), ^{
        @try {
            // CreateFromArgs takes cc1 options only; argv[0] is a separate
            // argument. Accept an optional leading -cc1 from legacy callers.
            NSArray<NSString *> *frontendArguments = [cc1Arguments.firstObject isEqualToString:@"-cc1"]
                ? [cc1Arguments subarrayWithRange:NSMakeRange(1, cc1Arguments.count - 1)] : cc1Arguments;
            ArgvStorage argv(frontendArguments, /*prependProgramName=*/false);

            std::string outBuf, errBuf;
            llvm::raw_string_ostream outStream(outBuf);
            llvm::raw_string_ostream errStream(errBuf);

            // Setup follows clang's own cc1_main.cpp, which is the authority for
            // this sequence. Two API changes forced the shape:
            //   * DiagnosticOptions is no longer reference-counted
            //     (RefCountedBase was dropped), so it is a plain local here and
            //     every consumer takes it by reference.
            //   * CompilerInstance takes its invocation in the constructor;
            //     setInvocation() no longer exists.
            // Diagnostics from argument parsing are buffered so they can be
            // replayed through the real engine once the invocation is parsed --
            // there is no engine yet when CreateFromArgs runs.
            clang::DiagnosticOptions diagOpts;
            auto *diagsBuffer = new clang::TextDiagnosticBuffer();
            llvm::IntrusiveRefCntPtr<clang::DiagnosticIDs> diagIDs =
                clang::DiagnosticIDs::create();
            clang::DiagnosticsEngine parseDiags(diagIDs, diagOpts, diagsBuffer);

            auto invocation = std::make_shared<clang::CompilerInvocation>();
            const bool parsed = clang::CompilerInvocation::CreateFromArgs(
                *invocation, argv.arrayRef(), parseDiags, /*Argv0=*/"clang");

            // CreateFromArgs already ran ParseLangArgs/ParseCodeGenArgs and, for
            // an arm64e triple, setDefaultPointerAuthOptions — which is what
            // decides B-key return signing. Do not override it here.
            auto instance = std::make_unique<clang::CompilerInstance>(invocation);
            if (invocation->getFrontendOpts().Inputs.empty()) {
                errStream << "OMToolchain: no input file\n";
                status = OMToolchainStatusBadArguments;
                outStream.flush();
                errStream.flush();
                outString = ToNSString(outBuf);
                errString = ToNSString(errBuf);
                return;
            }

            // The file system must exist before the diagnostics engine, which
            // reads the warning-suppression mappings through it.
            instance->createVirtualFileSystem(llvm::vfs::getRealFileSystem(),
                                              diagsBuffer);

            // Pass our own client rather than relying on the zero-argument
            // overload: that one builds a TextDiagnosticPrinter aimed at
            // llvm::errs(), which would send clang's errors straight to the
            // process stderr and leave this method's errText empty. The printer
            // holds a reference to diagOpts, which outlives this block.
            instance->createDiagnostics(
                new clang::TextDiagnosticPrinter(errStream, diagOpts),
                /*ShouldOwnClient=*/true);
            diagsBuffer->FlushDiagnostics(instance->getDiagnostics());
            if (!parsed) {
                status = OMToolchainStatusDiagnostics;
                outStream.flush();
                errStream.flush();
                outString = ToNSString(outBuf);
                errString = ToNSString(errBuf);
                return;
            }

            // EmitObjAction is clang's object-file front-end action.
            clang::EmitObjAction action;
            const bool executed = instance->ExecuteAction(action);

            status = executed ? OMToolchainStatusOK : OMToolchainStatusDiagnostics;
            outStream.flush();
            errStream.flush();
            outString = ToNSString(outBuf);
            errString = ToNSString(errBuf);
        } @catch (NSException *e) {
            status = OMToolchainStatusInternalError;
            errString = [NSString stringWithFormat:@"OMToolchain: ObjC exception %@: %@\n",
                         e.name, e.reason];
        } @catch (...) {
            status = OMToolchainStatusInternalError;
            errString = @"OMToolchain: unknown exception in clang front end\n";
        }
    });

    HandOut(outString, outText);
    HandOut(errString, errText);
    return status;
}

#pragma mark - Linker

+ (OMToolchainStatus)runLinker:(NSArray<NSString *> *)ld64Arguments
                        stdout:(NSString *_Nullable *_Nullable)outText
                        stderr:(NSString *_Nullable *_Nullable)errText {
    if (ld64Arguments.count == 0) {
        HandOut(@"", outText);
        HandOut(@"OMToolchain: empty linker argument list\n", errText);
        return OMToolchainStatusBadArguments;
    }
    [self initializeRuntimes];

    __block OMToolchainStatus status = OMToolchainStatusInternalError;
    __block NSString *outString = @"";
    __block NSString *errString = @"";

    dispatch_sync(OMQueue(), ^{
        @try {
            // ld64 writes diagnostics to stderr and is not reentrant; the
            // vendored build provides explicit reset hooks for its singletons.
            om_ld64_reset_options();
            om_ld64_reset_state();
            om_ld64_reset_branches();
            om_ld64_reset_threads();

            ArgvStorage argv(ld64Arguments, /*prependProgramName=*/true);
            const int rc = om_ld64_main(static_cast<int>(argv.owned.size()),
                                        argv.argv.data());
            status = (rc == 0) ? OMToolchainStatusOK : OMToolchainStatusDiagnostics;
            if (rc != 0) {
                errString = [NSString stringWithFormat:
                             @"OMToolchain: ld64 exited with status %d\n", rc];
            }
        } @catch (NSException *e) {
            status = OMToolchainStatusInternalError;
            errString = [NSString stringWithFormat:@"OMToolchain: ObjC exception %@: %@\n",
                         e.name, e.reason];
        } @catch (...) {
            status = OMToolchainStatusInternalError;
            errString = @"OMToolchain: unknown exception in linker\n";
        }
    });

    HandOut(outString, outText);
    HandOut(errString, errText);
    return status;
}
#else
+ (void)initializeRuntimes {}

+ (OMToolchainStatus)runCC1:(NSArray<NSString *> *)arguments
                    stdout:(NSString *_Nullable *_Nullable)outText
                    stderr:(NSString *_Nullable *_Nullable)errText {
    (void)arguments;
    if (outText) *outText = @"";
    if (errText) *errText = @"OMToolchain: compiler is not linked in this build\n";
    return OMToolchainStatusUnavailable;
}

+ (OMToolchainStatus)runLinker:(NSArray<NSString *> *)arguments
                       stdout:(NSString *_Nullable *_Nullable)outText
                       stderr:(NSString *_Nullable *_Nullable)errText {
    (void)arguments;
    if (outText) *outText = @"";
    if (errText) *errText = @"OMToolchain: linker is not linked in this build\n";
    return OMToolchainStatusUnavailable;
}
#endif // OM_TOOLCHAIN_ENABLED

#pragma mark - Output inspection

+ (OMOutputArch)architectureOfMachOAtPath:(NSString *)path {
    NSData *data = [NSData dataWithContentsOfFile:path
                                          options:NSDataReadingMappedIfSafe
                                            error:NULL];
    if (data.length < sizeof(struct mach_header_64)) return OMOutputArchUnknown;

    const uint8_t *base = (const uint8_t *)data.bytes;
    uint32_t magic = 0;
    memcpy(&magic, base, sizeof(magic));

    // Only thin arm64 Mach-O is expected here; report unknown for fat/other.
    if (magic != MH_MAGIC_64) return OMOutputArchUnknown;

    struct mach_header_64 header;
    memcpy(&header, base, sizeof(header));
    if (header.cputype != CPU_TYPE_ARM64) return OMOutputArchUnknown;

    // Capability bits (0xff000000) are not part of the identity.
    const cpu_subtype_t subtype = header.cpusubtype & ~CPU_SUBTYPE_MASK;
    return (subtype == CPU_SUBTYPE_ARM64E) ? OMOutputArchArm64e : OMOutputArchArm64;
}

#pragma mark - Argument assembly

+ (void)resolveDefaultPathsForSysroot:(NSString *_Nullable *_Nullable)sysroot
                          resourceDir:(NSString *_Nullable *_Nullable)resourceDir {
    NSBundle *bundle = [NSBundle mainBundle];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (sysroot && *sysroot == nil) {
        NSString *candidate = [bundle.resourcePath stringByAppendingPathComponent:@"SDKs/iPhoneOS.sdk"];
        if ([fm fileExistsAtPath:[candidate stringByAppendingPathComponent:@"usr/include"]]) {
            *sysroot = candidate;
        }
    }
    if (resourceDir && *resourceDir == nil) {
        // -resource-dir takes the parent of include/, never include/ itself.
        for (NSString *name in @[@"clang-resource", @"ClangHeaders"]) {
            NSString *candidate = [bundle.resourcePath stringByAppendingPathComponent:name];
            NSString *header = [candidate stringByAppendingPathComponent:@"include/stddef.h"];
            if ([fm fileExistsAtPath:header]) {
                *resourceDir = candidate;
                break;
            }
        }
    }
}

+ (NSArray<NSString *> *)cc1ArgumentsForSource:(NSString *)sourcePath
                                    outputPath:(NSString *)objectPath
                                       sysroot:(NSString *)sysroot
                                  resourceDir:(NSString *)resourceDir
                                     archName:(NSString *)archName
                                    minimumIOS:(NSString *)minimumIOS {
    NSString *sdk = sysroot;
    NSString *res = resourceDir;
    [self resolveDefaultPathsForSysroot:&sdk resourceDir:&res];
    if (!minimumIOS) minimumIOS = @"14.0";

    NSMutableArray<NSString *> *args = [NSMutableArray array];
    [args addObject:@"-cc1"];
    [args addObject:@"-triple"];
    [args addObject:[NSString stringWithFormat:@"%@-apple-ios%@", archName, minimumIOS]];
    [args addObject:@"-resource-dir"];
    [args addObject:res ?: @""];
    if (sdk) {
        [args addObject:@"-isysroot"];
        [args addObject:sdk];
    }

    // Language selection follows the extension so ObjC/C++/asm all route here.
    NSString *ext = sourcePath.pathExtension.lowercaseString;
    NSString *lang = @"c";
    BOOL isObjC = NO;
    if ([ext isEqualToString:@"m"]) { lang = @"objective-c"; isObjC = YES; }
    else if ([ext isEqualToString:@"mm"]) { lang = @"objective-c++"; isObjC = YES; }
    else if ([ext isEqualToString:@"cpp"] || [ext isEqualToString:@"cc"] ||
             [ext isEqualToString:@"cxx"]) { lang = @"c++"; }

    if (isObjC) {
        [args addObject:@"-fobjc-runtime=ios-14.0"];
        [args addObject:@"-fobjc-arc"];
    }
    [args addObject:@"-emit-obj"];
    [args addObject:@"-o"];
    [args addObject:objectPath];
    [args addObject:@"-x"];
    [args addObject:lang];
    [args addObject:sourcePath];
    return args;
}

@end
