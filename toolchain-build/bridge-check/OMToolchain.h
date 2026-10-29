//
//  OMToolchain.h
//  In-process Clang + Mach-O linker runtime for the OpenMinis host process.
//
//  Design note
//  -----------
//  Twork statically links clang/LLVM/lld into its *main executable* and exposes
//  them through internal entry points. A main executable cannot be dlopen()ed
//  on iOS ("cannot dlopen a main executable"), so that arrangement is not
//  copyable. Instead this module builds the same upstream components into a
//  real static library and links them into the host, with our own thin bridge
//  standing in for clang's `cc1_main` (which lives in clangFrontendTool).
//
//  Everything here runs in-process. No subprocess is spawned, which is what
//  makes in-process compile work on a non-jailbroken device.
//
//  Threading: LLVM and ld64 both keep process-global state. All entry points
//  serialize on one queue; do not call them concurrently.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, OMToolchainStatus) {
    OMToolchainStatusOK = 0,
    OMToolchainStatusBadArguments = 1,
    OMToolchainStatusDiagnostics = 2,   // clang/ld64 reported errors
    OMToolchainStatusInternalError = 3, // exception, missing output, etc.
    OMToolchainStatusUnavailable = 4,   // compiler not linked in this build
};

typedef NS_ENUM(NSInteger, OMOutputArch) {
    OMOutputArchUnknown = 0,
    OMOutputArchArm64,   // cpusubtype 0
    OMOutputArchArm64e,  // cpusubtype 0x80000002 (ptrauth version 0)
};

@interface OMToolchain : NSObject

/// Reports linked capability separately from bundled resources. Does not run
/// LLVM or allocate linker state. "ready" is configuration readiness, not a
/// claim that a compilation, installation or runtime test has succeeded.
+ (NSDictionary<NSString *, NSString *> *)capabilityStatus NS_SWIFT_NAME(capabilityStatus());

/// Idempotent. Registers LLVM targets/asm printers and resets linker state.
+ (void)initializeRuntimes;

/// Runs the clang front end in-process — the equivalent of `clang -cc1 ...`.
///
/// @param cc1Arguments Arguments *after* `-cc1` (kernel args such as `-triple`,
///        `-isysroot`, `-resource-dir`, `-emit-obj`, `-o`, `-x` are expected).
///        The array is passed through verbatim; no driver-level expansion is
///        performed, matching how the toolchain driver already invokes cc1.
/// @param outText Receives clang stdout (usually empty).
/// @param errText Receives diagnostics. Non-empty on status Diagnostics.
+ (OMToolchainStatus)runCC1:(NSArray<NSString *> *)cc1Arguments
                     stdout:(NSString *_Nullable *_Nullable)outText
                     stderr:(NSString *_Nullable *_Nullable)errText;

/// Runs the in-process Mach-O linker.
///
/// The linker is a serialized build of Apple's ld64 (via cctools-port) whose
/// CLI `main` was converted into a reentrant entry point: no exit(), no atexit,
/// and the free-function statics that cache the previous run are reset between
/// runs by om_ld64_reset_* hooks appended to the translation units that own
/// them.
///
/// Note on allocations: ld64 deliberately leaks its heap objects for linking
/// performance (<rdar://problem/55031993>), and this build does not intercept
/// them -- the CLI never needed to reclaim them, and a host that wants
/// allocator isolation would have to redirect new/malloc/free in every ld64
/// translation unit. So each run's linker-local allocations stay resident.
/// Bounded repetition is fine; unbounded repetition in one process grows.
///
/// @param ld64Arguments The argument vector ld64 would normally receive,
///        excluding argv[0].
+ (OMToolchainStatus)runLinker:(NSArray<NSString *> *)ld64Arguments
                        stdout:(NSString *_Nullable *_Nullable)outText
                        stderr:(NSString *_Nullable *_Nullable)errText;

/// Infers the architecture of a Mach-O produced by the calls above.
/// Reads cputype/cpusubtype only; it does not validate code signatures.
+ (OMOutputArch)architectureOfMachOAtPath:(NSString *)path;

/// Convenience: assembles the cc1 argument list for one translation unit.
/// Mirrors what the Theos-facing driver passes, including the arm64e sysroot
/// and resource-dir wiring needed for pointer-authenticated output.
+ (NSArray<NSString *> *)cc1ArgumentsForSource:(NSString *)sourcePath
                                    outputPath:(NSString *)objectPath
                                       sysroot:(nullable NSString *)sysroot
                                  resourceDir:(nullable NSString *)resourceDir
                                     archName:(NSString *)archName
                                minimumIOS:(nullable NSString *)minimumIOS;

/// Fills sysroot/resourceDir defaults from the host bundle when nil.
+ (void)resolveDefaultPathsForSysroot:(NSString *_Nullable *_Nullable)sysroot
                          resourceDir:(NSString *_Nullable *_Nullable)resourceDir;

@end

NS_ASSUME_NONNULL_END
