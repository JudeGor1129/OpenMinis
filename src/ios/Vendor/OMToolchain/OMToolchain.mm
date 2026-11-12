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

// ld64 reports failures with fprintf(stderr, ...), and inside the app fd 2
// goes nowhere the host can read, so a failed link used to arrive with no
// reason attached. This header moves fd 1/2 onto temp files for the duration
// of one call. Included unconditionally so the plain app configuration keeps
// compiling it too; with no toolchain linked nothing calls into it.
#include "OMStdioCapture.h"

// build-ld64-inprocess.py converts ld64's internal assert path into a C++
// exception caught by om_ld64_main. That preserves normal stack unwinding;
// attempting to recover from fatal signals with longjmp would cross live C++
// frames and is undefined behaviour. The stderr capture below retains the full
// assertion text so the host can report it and fence subsequent linker calls.

// Used by the capture helper below, which is compiled in both configurations.
// With the toolchain disabled nothing calls it, but it still has to compile:
// that is the shipping default, and it is the only configuration a machine
// without the LLVM archives can check locally.
#include <string>
#include <vector>

/// Bytes of linker output kept per stream.
#define OM_LINKER_CAPTURE_BYTES (16 * 1024)
/// EX_SOFTWARE returned by adapted ld64 after an internal assertion unwinds.
#define OM_LINKER_ASSERTION_STATUS 70

/// Outcome of one captured linker invocation.
typedef struct {
    int  exitStatus;    ///< value returned by the linker entry point
    BOOL internalError; ///< the entry point unwound instead of returning
} OMLinkerRun;

/// Runs `invoke` with fd 1/2 captured and folds the result into the text slots.
///
/// ld64 reports every failure with `fprintf(stderr, ...)` and a non-zero return,
/// but fd 2 inside the app is not something the caller can read back -- a failed
/// link arrived as "ld64 exited with status 1" with no reason attached. Moving
/// the descriptor for the duration of the call is the only way to see the real
/// message. A line written by another thread during those few milliseconds can
/// land in the capture; that is a better trade than never seeing the reason.
///
/// `*outText` and `*errText` are always assigned. Placed outside the
/// OM_TOOLCHAIN_ENABLED switch on purpose (see above), so `maybe_unused` keeps
/// the disabled configuration warning-free.
[[maybe_unused]] static inline OMLinkerRun OMRunLinkerCapturing(int (^invoke)(void),
                                                               NSString **outText,
                                                               NSString **errText) {
    OMLinkerRun run = { 0, NO };
    if (outText) *outText = @"";
    if (errText) *errText = @"";

    OMStdioCapture capture;
    OMStdioCaptureInit(&capture);

    std::vector<char> capturedOut(OM_LINKER_CAPTURE_BYTES);
    std::vector<char> capturedErr(OM_LINKER_CAPTURE_BYTES);
    capturedOut[0] = '\0';
    capturedErr[0] = '\0';
    const BOOL capturing = OMStdioCaptureBegin(&capture,
                                               NSTemporaryDirectory().UTF8String) == 1;

    @try {
        run.exitStatus = invoke();
    } @catch (NSException *e) {
        // fd 1/2 have to go back even when the call unwinds, or the host's own
        // stderr stays redirected for the rest of the process.
        OMStdioCaptureEnd(&capture, NULL, 0, NULL, 0);
        run.internalError = YES;
        if (errText) {
            *errText = [NSString stringWithFormat:@"OMToolchain: ObjC exception %@: %@\n",
                        e.name, e.reason];
        }
        return run;
    } @catch (...) {
        OMStdioCaptureEnd(&capture, NULL, 0, NULL, 0);
        run.internalError = YES;
        if (errText) *errText = @"OMToolchain: unknown exception in linker\n";
        return run;
    }

    OMStdioCaptureEnd(&capture, capturedOut.data(), capturedOut.size(),
                      capturedErr.data(), capturedErr.size());

    if (outText) *outText = [NSString stringWithUTF8String:capturedOut.data()] ?: @"";
    NSMutableString *reported = [NSMutableString string];
    if (run.exitStatus != 0) {
        [reported appendFormat:@"OMToolchain: ld64 exited with status %d\n", run.exitStatus];
    }
    if (capturedErr[0] != '\0') {
        [reported appendString:[NSString stringWithUTF8String:capturedErr.data()] ?: @""];
    }
    if (!capturing) {
        [reported appendString:@"OMToolchain: linker output could not be captured\n"];
    }
    if (errText) *errText = reported;
    return run;
}

// The normal app can build and expose accurate capability status before the
// matching LLVM archives and development headers are supplied. Enabling this
// switch requires real compiler/linker libraries; it never loads a library
// dynamically or falls back to a different architecture.
#ifndef OM_TOOLCHAIN_ENABLED
#define OM_TOOLCHAIN_ENABLED 0
#endif
// Separate opt-ins: old LLVM/ld64 kits must not acquire new static references.
#ifndef OM_TOOLCHAIN_COMPILER_DRIVER_ENABLED
#define OM_TOOLCHAIN_COMPILER_DRIVER_ENABLED 0
#endif
#ifndef OM_TOOLCHAIN_LLD_ENABLED
#define OM_TOOLCHAIN_LLD_ENABLED 0
#endif
// Disposable experimental builds only: allows the provider to run without the
// full fixed-runtime evidence suite. Never set this in a production target.
#ifndef OM_TOOLCHAIN_EXPERIMENTAL_BUILD
#define OM_TOOLCHAIN_EXPERIMENTAL_BUILD 0
#endif
#if (OM_TOOLCHAIN_COMPILER_DRIVER_ENABLED || OM_TOOLCHAIN_LLD_ENABLED) && !OM_TOOLCHAIN_ENABLED
#error "New bridge APIs require OM_TOOLCHAIN_ENABLED and a matching statically linked kit"
#endif

#if OM_TOOLCHAIN_COMPILER_DRIVER_ENABLED
#include "clang/Driver/Action.h"
#include "clang/Driver/Compilation.h"
#include "clang/Driver/Driver.h"
#include "clang/Driver/Job.h"
#include "clang/Driver/Tool.h"
#include "clang/FrontendTool/Utils.h"
#endif
#if OM_TOOLCHAIN_LLD_ENABLED
#include "lld/Common/Driver.h"
#include "llvm/Support/CrashRecoveryContext.h"
LLD_HAS_DRIVER(macho)
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

/// Guards every LLVM/ld64/LLD entry point. Never synchronously re-enter a runtime.
static char OMQueueKey;
dispatch_queue_t OMQueue() {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("com.openminis.toolchain", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(q, &OMQueueKey, &OMQueueKey, nullptr);
    });
    return q;
}

// Re-entry is rejected, not executed inline: LLVM/LLD are not recursively safe.
// The Driver executes its cc1 job directly on OMQueue, never by calling runCC1.
bool OMOnRuntimeQueue() {
    (void)OMQueue();
    return dispatch_get_specific(&OMQueueKey) != nullptr;
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

#if OM_TOOLCHAIN_COMPILER_DRIVER_ENABLED || OM_TOOLCHAIN_LLD_ENABLED
// Bounded, lossless UTF-8 argv only. Never let NUL truncate a validated option.
bool OMValidArguments(NSArray<NSString *> *args) {
    if (![args isKindOfClass:[NSArray class]] || args.count == 0 || args.count > 4096) return false;
    size_t bytes = 0;
    for (id value in args) {
        if (![value isKindOfClass:[NSString class]]) return false;
        NSString *s = value;
        const char *p = s.UTF8String;
        if (!p || !*p || strlen(p) != [s lengthOfBytesUsingEncoding:NSUTF8StringEncoding]) return false;
        bytes += strlen(p);
        // Response files are rejected, but dyld rpath placeholders are legal
        // values and are admitted only in that exact form.
        BOOL dyldPlaceholder = [s hasPrefix:@"@rpath/"] ||
            [s hasPrefix:@"@loader_path/"] || [s hasPrefix:@"@executable_path/"];
        if (bytes > 1024 * 1024 || ([s hasPrefix:@"@"] && !dyldPlaceholder) ||
            [s rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location != NSNotFound) return false;
    }
    return true;
}

bool OMAbsolutePath(NSString *s) {
    return [s hasPrefix:@"/"] && ![s hasPrefix:@"/dev/"] && ![s isEqualToString:@"/dev"];
}
#endif

#if OM_TOOLCHAIN_COMPILER_DRIVER_ENABLED
// Fail closed before BuildCompilation can load configs/expand hidden options.
// This is a shape guard, not a workspace authorization or filesystem sandbox.
bool OMValidateDriver(NSArray<NSString *> *args) {
    if (!OMValidArguments(args)) return false;
    NSSet *flags = [NSSet setWithArray:@[@"-c", @"-fobjc-arc", @"-fno-objc-arc",
        @"-fobjc-weak", @"-fno-objc-weak", @"-fblocks", @"-fno-blocks", @"-fPIC", @"-fpic",
        @"-fno-common", @"-fexceptions", @"-fno-exceptions", @"-fcxx-exceptions",
        @"-fno-rtti", @"-frtti", @"-fvisibility=hidden", @"-fvisibility=default",
        @"-fvisibility-inlines-hidden", @"-fomit-frame-pointer", @"-fno-omit-frame-pointer",
        @"-fno-stack-protector", @"-fstack-protector-strong", @"-ffunction-sections",
        @"-fdata-sections", @"-fno-strict-aliasing", @"-fstrict-aliasing",
        @"-O0", @"-O1", @"-O2", @"-O3", @"-Os", @"-Oz", @"-g", @"-g0",
        @"-Wall", @"-Wextra", @"-Werror", @"-w", @"-nostdinc", @"-nostdinc++"]];
    NSSet *pathOptions = [NSSet setWithArray:@[@"-o", @"-isysroot", @"-resource-dir",
        @"-I", @"-F", @"-isystem", @"-iquote", @"-include", @"-iframework"]];
    NSUInteger inputs = 0, outputs = 0, compile = 0, targets = 0, sysroots = 0, resources = 0;
    for (NSUInteger i = 0; i < args.count; ++i) {
        NSString *s = args[i];
        if ([flags containsObject:s]) { if ([s isEqualToString:@"-c"]) ++compile; continue; }
        if ([pathOptions containsObject:s]) {
            if (++i >= args.count || !OMAbsolutePath(args[i])) return false;
            if ([s isEqualToString:@"-o"]) { ++outputs; if (![args[i] hasSuffix:@".o"]) return false; }
            if ([s isEqualToString:@"-isysroot"]) ++sysroots;
            if ([s isEqualToString:@"-resource-dir"]) ++resources;
            continue;
        }
        if ([s isEqualToString:@"-target"] || [s isEqualToString:@"--target"]) {
            if (++i >= args.count) return false;
            NSString *t = args[i];
            if (![t hasPrefix:@"arm64-apple-ios"] && ![t hasPrefix:@"arm64e-apple-ios"]) return false;
            if ([t containsString:@"simulator"] || [t containsString:@"macabi"]) return false;
            ++targets; continue;
        }
        if ([s isEqualToString:@"-x"]) {
            if (++i >= args.count || ![@[@"c", @"c++", @"objective-c", @"objective-c++"] containsObject:args[i]]) return false;
            continue;
        }
        if (([s hasPrefix:@"-D"] || [s hasPrefix:@"-U"]) && s.length > 2) continue;
        if ([s isEqualToString:@"-D"] || [s isEqualToString:@"-U"]) { if (++i >= args.count) return false; continue; }
        if (([s hasPrefix:@"-I"] || [s hasPrefix:@"-F"]) && s.length > 2 && OMAbsolutePath([s substringFromIndex:2])) continue;
        if ([s hasPrefix:@"-std="] || [s hasPrefix:@"-miphoneos-version-min="]) continue;
        if ([s isEqualToString:@"-Xclang"]) {
            // No generic frontend pass-through: only reviewed, non-loading switches.
            if (++i >= args.count || ![@[@"-fdebug-compilation-dir=."] containsObject:args[i]]) return false;
            continue;
        }
        if ([s hasPrefix:@"-"] || !OMAbsolutePath(s)) return false;
        if (![@[@"c", @"cc", @"cpp", @"cxx", @"m", @"mm"] containsObject:s.pathExtension.lowercaseString]) return false;
        ++inputs;
    }
    return inputs == 1 && outputs == 1 && compile == 1 && targets == 1 && sysroots == 1 && resources == 1;
}
#endif

#if OM_TOOLCHAIN_LLD_ENABLED
// Shared LLVM state may be damaged by a failed LLD recovery. Fence all runtimes.
static bool OMRuntimePoisoned = false;

// lldMain needs recovery enabled: otherwise fatal() can terminate the host even
// with exitEarly=false. Probe without changing policy; restore only if we own it.
// Upstream Enable/Disable save/restore POSIX dispositions. Host policy changes
// outside OMQueue during this scope are unsupported (LLVM exposes no refcount).
class OMScopedLLDRecovery {
    bool owns = false;
public:
    OMScopedLLDRecovery() {
        bool enabled = false;
        llvm::CrashRecoveryContext probe;
        probe.RunSafely([&] { enabled = llvm::CrashRecoveryContext::GetCurrent() != nullptr; });
        owns = !enabled;
        if (owns) llvm::CrashRecoveryContext::Enable();
    }
    ~OMScopedLLDRecovery() { if (owns) llvm::CrashRecoveryContext::Disable(); }
};
#endif

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
    BOOL experimental = OM_TOOLCHAIN_EXPERIMENTAL_BUILD != 0;
    NSString *arch = @"unknown";
#if defined(__arm64e__)
    arch = @"arm64e";
#elif defined(__arm64__)
    arch = @"arm64";
#elif defined(__x86_64__)
    arch = @"x86_64";
#endif
    return @{@"compiler_linked": linked ? @"yes" : @"no",
             // Macro=1 causes direct strong symbol references, so a missing
             // archive fails static linking instead of claiming availability.
             @"compiler_driver_linked": OM_TOOLCHAIN_COMPILER_DRIVER_ENABLED ? @"yes" : @"no",
             @"lld_linked": OM_TOOLCHAIN_LLD_ENABLED ? @"yes" : @"no",
             @"linker_backend": OM_TOOLCHAIN_LLD_ENABLED ? @"lld-macho+ld64" : (linked ? @"ld64" : @"unavailable"),
             @"verification": verified ? @"passed" : @"missing",
             @"experimental_build": experimental ? @"yes" : @"no",
             @"state": linked && (verified || experimental) && headersReady && sdkReady ? @"ready" : @"unavailable",
             @"host_architecture": arch,
             @"resource_headers": headersReady ? @"present" : @"missing",
             @"resource_dir": resource ?: @"",
             @"sdk": sdkReady ? @"present" : @"missing",
             @"sysroot": sdk ?: @"",
             @"reason": !linked ? @"此构建未链接 LLVM/ld64；准备好资源不代表已启用编译。"
                         : !verified && !experimental ? @"已链接 LLVM/ld64，但尚未通过启用桥接编译与静态链接门禁。"
                         : experimental ? @"实验构建：运行时证据未完成；产物未验证，仅用于一次性测试。"
                         : !headersReady ? @"缺少与 LLVM 版本匹配的 Clang builtin headers。"
                         : !sdkReady ? @"缺少可用的 iOS SDK。"
                         : @"固定 fixture 运行时验证已通过；BuildProvider 仍需独立的安全执行适配器。"};
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
    if (OMOnRuntimeQueue()) {
        HandOut(@"", outText);
        HandOut(@"OMToolchain: recursive runtime entry is not supported\n", errText);
        return OMToolchainStatusInternalError;
    }
    [self initializeRuntimes];

    __block OMToolchainStatus status = OMToolchainStatusInternalError;
    __block NSString *outString = @"";
    __block NSString *errString = @"";

    dispatch_sync(OMQueue(), ^{
        @try {
#if OM_TOOLCHAIN_LLD_ENABLED
            if (OMRuntimePoisoned) { errString = @"OMToolchain: runtime poisoned by LLD; restart the app\n"; return; }
#endif
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
    if (OMOnRuntimeQueue()) {
        HandOut(@"", outText);
        HandOut(@"OMToolchain: recursive runtime entry is not supported\n", errText);
        return OMToolchainStatusInternalError;
    }
    [self initializeRuntimes];

    __block OMToolchainStatus status = OMToolchainStatusInternalError;
    __block NSString *outString = @"";
    __block NSString *errString = @"";
    // An internal linker assertion unwinds safely, but it still means an
    // invariant failed after mutating process-lifetime state. OMQueue serializes
    // access; after status 70 only an app restart may enable linking again.
    static BOOL linkerPoisoned = NO;

    dispatch_sync(OMQueue(), ^{
        if (linkerPoisoned
#if OM_TOOLCHAIN_LLD_ENABLED
            || OMRuntimePoisoned
#endif
        ) {
            errString = @"OMToolchain: linker disabled after an internal assertion; restart the app before linking again\n";
            return;
        }
        ArgvStorage argv(ld64Arguments, /*prependProgramName=*/true);
        // The block below captures its surroundings by value, and a captured
        // copy is const -- which would turn argv.argv.data() into a
        // `const char *const *` that the linker entry point cannot take.
        // Reaching it through a pointer keeps the pointee mutable.
        // toolchain-build/scripts/probe-linker-block-capture.mm compiles
        // exactly this shape, because nothing on a machine without the LLVM
        // archives can check it any other way.
        ArgvStorage *argvPointer = &argv;
        __block NSString *capturedOut = @"";
        __block NSString *capturedErr = @"";

        const OMLinkerRun run = OMRunLinkerCapturing(^int {
            // ld64 is not reentrant; the vendored build provides explicit reset
            // hooks for its singletons. They run inside the captured call, so a
            // throw from them is reported like any other linker failure.
            om_ld64_reset_options();
            om_ld64_reset_state();
            om_ld64_reset_branches();
            om_ld64_reset_threads();
            return om_ld64_main(static_cast<int>(argvPointer->owned.size()),
                                argvPointer->argv.data());
        }, &capturedOut, &capturedErr);

        outString = capturedOut;
        errString = capturedErr;
        const BOOL assertionFailed = run.exitStatus == OM_LINKER_ASSERTION_STATUS;
        if (assertionFailed) {
            linkerPoisoned = YES;
            errString = [errString stringByAppendingString:
                @"OMToolchain: linker disabled after an internal assertion; restart the app before linking again\n"];
        }
        if (run.internalError || assertionFailed) {
            status = OMToolchainStatusInternalError;
        } else {
            status = (run.exitStatus == 0) ? OMToolchainStatusOK : OMToolchainStatusDiagnostics;
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

#pragma mark - Opt-in compiler driver

+ (OMToolchainStatus)runCompilerDriver:(NSArray<NSString *> *)driverArguments
                              stdout:(NSString *_Nullable *_Nullable)outText
                              stderr:(NSString *_Nullable *_Nullable)errText {
    if (outText) *outText = @"";
    if (errText) *errText = @"";
#if OM_TOOLCHAIN_COMPILER_DRIVER_ENABLED
    if (OMOnRuntimeQueue()) {
        HandOut(@"OMToolchain: recursive runtime entry is not supported\n", errText);
        return OMToolchainStatusInternalError;
    }
    // Snapshot before validating, so NSMutableArray cannot change job shape.
    NSArray<NSString *> *arguments = [driverArguments copy];
    if (!OMValidateDriver(arguments)) {
        HandOut(@"OMToolchain: expected one trusted -c input, absolute .o/sysroot/resource paths and an iOS arm64 target; unsupported option or job shape\n", errText);
        return OMToolchainStatusBadArguments;
    }
    __block OMToolchainStatus status = OMToolchainStatusInternalError;
    __block NSString *reported = @"";
    dispatch_sync(OMQueue(), ^{
#if OM_TOOLCHAIN_LLD_ENABLED
        if (OMRuntimePoisoned) { reported = @"OMToolchain: runtime poisoned by LLD; restart the app\n"; return; }
#endif
        [self initializeRuntimes];
        std::string diagnostics;
        llvm::raw_string_ostream errors(diagnostics);
        @try {
            try {
                clang::DiagnosticOptions diagOpts;
                auto ids = clang::DiagnosticIDs::create();
                clang::DiagnosticsEngine diags(ids, diagOpts,
                    new clang::TextDiagnosticPrinter(errors, diagOpts), true);
                clang::driver::Driver driver("clang", "arm64-apple-ios15.4", diags);
                driver.setCheckInputsExist(true);
                // Disable implicit .cfg loading, but keep all actual target and
                // codegen option derivation in Clang's driver (no cc1 flag emulation).
                NSMutableArray<NSString *> *safeArgs = [NSMutableArray arrayWithObject:@"--no-default-config"];
                [safeArgs addObjectsFromArray:arguments];
                ArgvStorage argv(safeArgs, true);
                std::unique_ptr<clang::driver::Compilation> compilation(driver.BuildCompilation(argv.arrayRef()));
                if (!compilation || diags.hasErrorOccurred()) {
                    status = OMToolchainStatusDiagnostics;
                } else if (compilation->getJobs().size() != 1) {
                    errors << "OMToolchain: driver must produce exactly one cc1 object job\n";
                    status = OMToolchainStatusBadArguments;
                } else {
                    const clang::driver::Command &job = *compilation->getJobs().begin();
                    const auto &cc1 = job.getArguments();
                    bool safe = !job.getCreator().isLinkJob() &&
                        llvm::StringRef(job.getCreator().getName()) == "clang" &&
                        job.getSource().getKind() == clang::driver::Action::AssembleJobClass &&
                        !cc1.empty() && llvm::StringRef(cc1.front()) == "-cc1";
                    for (const char *a : cc1) {
                        llvm::StringRef option(a);
                        if (option.starts_with("@") || option == "-load" || option == "-plugin" ||
                            option == "-add-plugin" || option == "-mllvm" || option == "-cc1as") safe = false;
                    }
                    if (!safe) {
                        errors << "OMToolchain: refused non-integrated, plugin or external driver job\n";
                        status = OMToolchainStatusBadArguments;
                    } else {
                        auto invocation = std::make_shared<clang::CompilerInvocation>();
                        bool parsed = clang::CompilerInvocation::CreateFromArgs(*invocation,
                            llvm::ArrayRef<const char *>(cc1.data() + 1, cc1.size() - 1), diags, "clang");
                        const auto &frontend = invocation->getFrontendOpts();
                        bool objectOnly = frontend.ProgramAction == clang::frontend::EmitObj &&
                            frontend.Inputs.size() == 1 && frontend.Inputs.front().isFile() &&
                            !frontend.OutputFile.empty() && frontend.OutputFile != "-" &&
                            frontend.Plugins.empty() && frontend.AddPluginActions.empty() &&
                            frontend.PluginArgs.empty();
                        if (!parsed) status = OMToolchainStatusDiagnostics;
                        else if (!objectOnly) {
                            errors << "OMToolchain: refused unsafe frontend invocation\n";
                            status = OMToolchainStatusBadArguments;
                        } else {
                            clang::CompilerInstance instance(invocation);
                            instance.createVirtualFileSystem(llvm::vfs::getRealFileSystem());
                            instance.createDiagnostics(new clang::TextDiagnosticPrinter(errors, diagOpts), true);
                            const bool success = clang::ExecuteCompilerInvocation(&instance);
                            status = success ? OMToolchainStatusOK : OMToolchainStatusDiagnostics;
                        }
                    }
                }
            } catch (const std::exception &e) {
                errors << "OMToolchain: compiler driver exception: " << e.what() << "\n";
            } catch (...) { errors << "OMToolchain: compiler driver unknown exception\n"; }
        } @catch (NSException *e) {
            errors << "OMToolchain: compiler driver ObjC exception: " << ToStdString(e.reason) << "\n";
        }
        errors.flush();
        reported = ToNSString(diagnostics);
    });
    HandOut(reported, errText);
    return status;
#else
    (void)driverArguments;
    if (errText) *errText = @"OMToolchain: compiler driver is not enabled/linked in this build\n";
    return OMToolchainStatusUnavailable;
#endif
}

#pragma mark - Opt-in LLD Mach-O

+ (OMToolchainStatus)runLLD:(NSArray<NSString *> *)lldArguments
                    stdout:(NSString *_Nullable *_Nullable)outText
                    stderr:(NSString *_Nullable *_Nullable)errText {
    if (outText) *outText = @"";
    if (errText) *errText = @"";
#if OM_TOOLCHAIN_LLD_ENABLED
    if (OMOnRuntimeQueue()) {
        HandOut(@"OMToolchain: recursive runtime entry is not supported\n", errText);
        return OMToolchainStatusInternalError;
    }
    NSArray<NSString *> *arguments = [lldArguments copy];
    bool valid = OMValidArguments(arguments);
    NSSet *flags = [NSSet setWithArray:@[@"-dylib", @"-bundle", @"-dead_strip", @"-no_dead_strip_inits_and_terms",
        @"-no_adhoc_codesign", @"-adhoc_codesign", @"-fixup_chains", @"-no_fixup_chains",
        @"-fatal_warnings", @"-ObjC", @"-all_load", @"-no_uuid", @"-no_function_starts",
        @"-no_data_in_code_info", @"-application_extension", @"-no_warn_inits"]];
    NSSet *paths = [NSSet setWithArray:@[@"-o", @"-syslibroot", @"-L", @"-F", @"-force_load", @"-install_name", @"-rpath"]];
    NSSet *values = [NSSet setWithArray:@[@"-arch", @"-framework", @"-weak_framework", @"-undefined",
        @"-compatibility_version", @"-current_version", @"-exported_symbol", @"-u"]];
    NSUInteger outputs = 0, inputs = 0, archs = 0, platforms = 0;
    bool versionOnly = arguments.count == 1 && [arguments.firstObject isEqualToString:@"--version"];
    if (!versionOnly) for (NSUInteger i = 0; valid && i < arguments.count; ++i) {
        NSString *s = arguments[i];
        if ([flags containsObject:s]) continue;
        if ([paths containsObject:s]) {
            if (++i >= arguments.count) { valid = false; break; }
            NSString *value = arguments[i];
            // dylib rpaths may legitimately use dyld placeholders; every other
            // path-valued option remains absolute-only.
            BOOL rpathPlaceholder = ([s isEqualToString:@"-rpath"] ||
                [s isEqualToString:@"-install_name"]) &&
                ([value hasPrefix:@"@rpath/"] || [value hasPrefix:@"@loader_path/"] ||
                 [value hasPrefix:@"@executable_path/"]);
            valid = OMAbsolutePath(value) || rpathPlaceholder;
            if ([s isEqualToString:@"-o"]) ++outputs;
            if ([s isEqualToString:@"-force_load"]) ++inputs;
            continue;
        }
        if ([values containsObject:s]) {
            valid = ++i < arguments.count && ![arguments[i] hasPrefix:@"-"];
            if (valid && [s isEqualToString:@"-arch"]) {
                ++archs; valid = [@[@"arm64", @"arm64e"] containsObject:arguments[i]];
            }
            continue;
        }
        if ([s isEqualToString:@"-platform_version"]) {
            valid = i + 3 < arguments.count && [arguments[i + 1] isEqualToString:@"ios"];
            i += 3; ++platforms; continue;
        }
        if (([s hasPrefix:@"-L"] || [s hasPrefix:@"-F"]) && s.length > 2 && OMAbsolutePath([s substringFromIndex:2])) continue;
        if ([s hasPrefix:@"-l"] && s.length > 2 &&
            ![s hasPrefix:@"-lto"] && ![s hasPrefix:@"-load"] && ![s hasPrefix:@"-lazy"] &&
            ![s containsString:@"_"] && ![s containsString:@"/"] &&
            ![s containsString:@"="] && ![s containsString:@","]) { ++inputs; continue; }
        valid = OMAbsolutePath(s) && [@[@"o", @"a", @"dylib", @"tbd"] containsObject:s.pathExtension.lowercaseString];
        if (valid) ++inputs;
    }
    if (!valid || (!versionOnly && (outputs != 1 || inputs == 0 || archs != 1 || platforms != 1))) {
        HandOut(@"OMToolchain: unsupported LLD option/job; response files, plugins, filelists and arbitrary LLVM forwarding are forbidden\n", errText);
        return OMToolchainStatusBadArguments;
    }
    __block OMToolchainStatus status = OMToolchainStatusInternalError;
    __block NSString *output = @"", *reported = @"";
    dispatch_sync(OMQueue(), ^{
        if (OMRuntimePoisoned) { reported = @"OMToolchain: runtime poisoned by LLD; restart the app\n"; return; }
        std::string stdoutBuffer, stderrBuffer;
        llvm::raw_string_ostream stdoutStream(stdoutBuffer), stderrStream(stderrBuffer);
        @try {
            try {
                OMScopedLLDRecovery recovery;
                // Program name selects Darwin without exposing -flavor. Only
                // Mach-O is linked/registered; never register all LLD drivers.
                NSMutableArray<NSString *> *safeArgs = [NSMutableArray arrayWithObjects:@"ld64.lld", @"--threads=1", nil];
                [safeArgs addObjectsFromArray:arguments];
                ArgvStorage argv(safeArgs, false);
                const lld::DriverDef drivers[] = {{lld::Darwin, &lld::macho::link}};
                // Public library entry calls the driver with exitEarly=false,
                // performs CommonLinkerContext::destroy() and guarded cleanup.
                const lld::Result result = lld::lldMain(argv.arrayRef(), stdoutStream, stderrStream, drivers);
                if (!result.canRunAgain) {
                    OMRuntimePoisoned = true;
                    stderrStream << "OMToolchain: LLD recovery/cleanup failed; runtime poisoned, restart the app\n";
                } else status = result.retCode == 0 ? OMToolchainStatusOK : OMToolchainStatusDiagnostics;
            } catch (const std::exception &e) {
                OMRuntimePoisoned = true;
                stderrStream << "OMToolchain: LLD exception; runtime poisoned: " << e.what() << "\n";
            } catch (...) {
                OMRuntimePoisoned = true;
                stderrStream << "OMToolchain: unknown LLD exception; runtime poisoned\n";
            }
        } @catch (NSException *e) {
            OMRuntimePoisoned = true;
            stderrStream << "OMToolchain: LLD ObjC exception; runtime poisoned: " << ToStdString(e.reason) << "\n";
        }
        stdoutStream.flush(); stderrStream.flush();
        output = ToNSString(stdoutBuffer); reported = ToNSString(stderrBuffer);
    });
    HandOut(output, outText); HandOut(reported, errText);
    return status;
#else
    (void)lldArguments;
    if (errText) *errText = @"OMToolchain: LLD Mach-O is not enabled/linked in this build\n";
    return OMToolchainStatusUnavailable;
#endif
}

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

/// True when `path` looks like a materialised SDK this process can actually
/// read: headers plus a real libSystem stub.
///
/// The size floor is not cosmetic. An SDK installed inside the iSH rootfs has
/// 58 symlinks under usr/lib, and iSH keeps a link's target in its own metadata
/// while the host file is a tiny placeholder holding the target's *name* --
/// `libSystem.tbd` is 15 bytes of text. A native process must use
/// `libSystem.B.tbd`, the real stub, and this check rejects the placeholder
/// rather than letting the linker fail later with a confusing parse error.
+ (BOOL)isUsableSDKAtPath:(NSString *)path {
    if (path.length == 0) return NO;
    NSFileManager *fm = [NSFileManager defaultManager];
    BOOL isDirectory = NO;
    if (![fm fileExistsAtPath:[path stringByAppendingPathComponent:@"usr/include"]
                  isDirectory:&isDirectory] || !isDirectory) {
        return NO;
    }
    NSString *stub = [[path stringByAppendingPathComponent:@"usr/lib"]
        stringByAppendingPathComponent:@"libSystem.B.tbd"];
    NSDictionary *attributes = [fm attributesOfItemAtPath:stub error:NULL];
    return attributes.fileSize >= 1024;
}

/// Orders two iPhoneOS<version>.sdk file names by their numeric components.
+ (NSComparisonResult)compareVersionName:(NSString *)lhs with:(NSString *)rhs {
    NSString *left = [[lhs stringByDeletingPathExtension] stringByReplacingOccurrencesOfString:@"iPhoneOS" withString:@""];
    NSString *right = [[rhs stringByDeletingPathExtension] stringByReplacingOccurrencesOfString:@"iPhoneOS" withString:@""];
    return [left compare:right options:NSNumericSearch];
}

/// Highest usable iPhoneOS<version>.sdk inside `directory`, or nil.
+ (NSString *)highestSDKInDirectory:(NSString *)directory {
    if (directory.length == 0) return nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *entries = [fm contentsOfDirectoryAtPath:directory error:NULL];
    NSString *best = nil;
    for (NSString *name in entries) {
        if (![name hasPrefix:@"iPhoneOS"] || ![name hasSuffix:@".sdk"]) continue;
        NSString *candidate = [directory stringByAppendingPathComponent:name];
        if (![self isUsableSDKAtPath:candidate]) continue;
        if (best == nil || [self compareVersionName:name with:[best lastPathComponent]] == NSOrderedDescending) {
            best = candidate;
        }
    }
    return best;
}

/// The app-owned SDK library, populated by 管理 iPhoneSDK. Kept outside the iSH
/// rootfs on purpose: a rootfs reset or reinstall deletes that tree, and the
/// SDK has to outlive it.
+ (NSString *)appOwnedSDKPath {
    NSArray<NSString *> *support = NSSearchPathForDirectoriesInDomains(
        NSApplicationSupportDirectory, NSUserDomainMask, YES);
    if (support.count == 0) return nil;
    NSString *store = [[support firstObject]
        stringByAppendingPathComponent:@"MinisToolchain/SDKs"];

    NSString *selected = [[NSUserDefaults standardUserDefaults]
        stringForKey:@"toolchain.selectedSDKVersion"];
    if (selected.length > 0) {
        NSString *candidate = [store stringByAppendingPathComponent:
            [NSString stringWithFormat:@"iPhoneOS%@.sdk", selected]];
        if ([self isUsableSDKAtPath:candidate]) return candidate;
    }
    return [self highestSDKInDirectory:store];
}

+ (void)resolveDefaultPathsForSysroot:(NSString *_Nullable *_Nullable)sysroot
                          resourceDir:(NSString *_Nullable *_Nullable)resourceDir {
    NSBundle *bundle = [NSBundle mainBundle];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (sysroot && *sysroot == nil) {
        // Preference order: an SDK imported into the app-owned library, then one
        // bundled with the app. The copy inside the iSH rootfs is deliberately
        // NOT consulted: a rootfs reset deletes it, and its 72 symlinks are
        // placeholder files for a native process -- the linker would read a
        // 10-byte text file where it expects a 370 KB stub. The build settings
        // page copies the whole SDK here instead.
        NSString *candidate = [self appOwnedSDKPath];
        if (candidate == nil) {
            NSString *bundled = [bundle.resourcePath stringByAppendingPathComponent:@"SDKs/iPhoneOS.sdk"];
            if ([self isUsableSDKAtPath:bundled]) candidate = bundled;
        }
        if (candidate != nil) *sysroot = candidate;
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
    [args addObject:@"-fdefine-target-os-macros"];
    [args addObject:@"-target-cpu"];
    [args addObject:[archName isEqualToString:@"arm64e"] ? @"apple-a12" : @"apple-a7"];
    // Upstream clang does not turn on pointer authentication for an arm64e
    // triple the way Apple's clang does, so an arm64e slice built without
    // these flags is plain arm64 code with an arm64e cputype. dyld then loads
    // it under the arm64e ABI, the system authenticates function pointers it
    // receives (pthread start routines, block invokes, objc dispatch) and the
    // process dies with a pointer-authentication fault. Keep both flags.
    if ([archName isEqualToString:@"arm64e"]) {
        [args addObject:@"-fptrauth-returns"];
        [args addObject:@"-fptrauth-calls"];
    }
    [args addObject:@"-fgnuc-version=4.2.1"];
    [args addObject:@"-D__GCC_HAVE_DWARF2_CFI_ASM=1"];
    [args addObject:@"-resource-dir"];
    [args addObject:res ?: @""];
    if (sdk) {
        [args addObject:@"-isysroot"];
        [args addObject:sdk];
        [args addObject:@"-internal-isystem"];
        [args addObject:[sdk stringByAppendingPathComponent:@"usr/local/include"]];
        if (res.length > 0) {
            [args addObject:@"-internal-isystem"];
            [args addObject:[res stringByAppendingPathComponent:@"include"]];
        }
        [args addObject:@"-internal-externc-isystem"];
        [args addObject:[sdk stringByAppendingPathComponent:@"usr/include"]];
        [args addObject:@"-iframework"];
        [args addObject:[sdk stringByAppendingPathComponent:@"System/Library/Frameworks"]];
    }
    [args addObject:@"-fblocks"];
    [args addObject:@"-fencode-extended-block-signature"];
    [args addObject:@"-fregister-global-dtors-with-atexit"];
    [args addObject:@"-fskip-odr-check-in-gmf"];
    [args addObject:@"-fmax-type-align=16"];

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
        [args addObject:@"-fobjc-exceptions"];
        [args addObject:@"-fexceptions"];
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
