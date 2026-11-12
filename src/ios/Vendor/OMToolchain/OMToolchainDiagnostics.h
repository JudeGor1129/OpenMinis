#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Fixed-fixture runtime diagnostics for the linked in-process compiler.
/// This surface accepts no source text, linker flags or output path from callers.
/// A passing report is evidence only and never unlocks BuildProvider execution.
@interface OMToolchainDiagnostics : NSObject

+ (NSDictionary<NSString *, id> *)runSuiteWithIterations:(NSUInteger)iterations
    NS_SWIFT_NAME(run(iterations:));

/// Fixed-source Clang Driver and LLD Mach-O compile/link diagnostics.
/// No caller source, flags, input paths, or output paths are accepted.
/// This never executes generated code and never authorizes BuildProvider execution.
+ (NSDictionary<NSString *, id> *)runDriverLLDSuite
    NS_SWIFT_NAME(runDriverLLD());

@end

NS_ASSUME_NONNULL_END
