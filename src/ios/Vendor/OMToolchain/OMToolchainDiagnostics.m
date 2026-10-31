#import "OMToolchainDiagnostics.h"
#import "OMToolchain.h"

#import <mach/mach.h>
#import <mach-o/fat.h>
#import <mach-o/loader.h>

static const uint32_t kOMPACIBSP = 0xD503237Fu;
static const uint32_t kOMAUTIBSP = 0xD50323FFu;
static const uint32_t kOMRETAB = 0xD65F0FFFu;
static const uint32_t kOMPACIASP = 0xD503233Fu;
static const uint32_t kOMRETAA = 0xD65F0BFFu;
static const uint32_t kOMShiftPACIAA = 0xDAC103FEu;

static NSString *OMStatusName(OMToolchainStatus status) {
    switch (status) {
        case OMToolchainStatusOK: return @"ok";
        case OMToolchainStatusBadArguments: return @"bad_arguments";
        case OMToolchainStatusDiagnostics: return @"diagnostics";
        case OMToolchainStatusInternalError: return @"internal_error";
        case OMToolchainStatusUnavailable: return @"unavailable";
    }
    return @"unknown";
}

static NSString *OMBoundedText(NSString *text) {
    if (!text) return @"";
    static const NSUInteger limit = 4096;
    if (text.length <= limit) return text;
    return [[text substringToIndex:limit] stringByAppendingString:@"\n…[truncated]"];
}

static uint64_t OMResidentBytes(void) {
    mach_task_basic_info_data_t info = {0};
    mach_msg_type_number_t count = MACH_TASK_BASIC_INFO_COUNT;
    kern_return_t result = task_info(mach_task_self(), MACH_TASK_BASIC_INFO,
                                     (task_info_t)&info, &count);
    return result == KERN_SUCCESS ? (uint64_t)info.resident_size : 0;
}

static uint64_t OMFileBytes(NSString *path) {
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
    return [attributes[NSFileSize] unsignedLongLongValue];
}

static NSDictionary<NSString *, id> *OMInspectMachO(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:NULL];
    if (data.length < sizeof(struct mach_header_64)) return @{@"valid": @NO};

    const uint8_t *base = data.bytes;
    struct mach_header_64 header;
    memcpy(&header, base, sizeof(header));
    if (header.magic != MH_MAGIC_64 || header.cputype != CPU_TYPE_ARM64) {
        return @{@"valid": @NO};
    }

    uint32_t pacibsp = 0, autibsp = 0, retab = 0;
    uint32_t paciasp = 0, retaa = 0, otherPacia = 0;
    uint64_t textBytes = 0;
    size_t cursor = sizeof(struct mach_header_64);
    for (uint32_t index = 0; index < header.ncmds; index++) {
        if (cursor + sizeof(struct load_command) > data.length) return @{@"valid": @NO};
        const struct load_command *command = (const struct load_command *)(base + cursor);
        if (command->cmdsize < sizeof(struct load_command) ||
            cursor + command->cmdsize > data.length) return @{@"valid": @NO};
        if (command->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *segment = (const struct segment_command_64 *)command;
            uint64_t sectionTableBytes = (uint64_t)segment->nsects * sizeof(struct section_64);
            if (sizeof(struct segment_command_64) + sectionTableBytes > command->cmdsize) {
                return @{@"valid": @NO};
            }
            const struct section_64 *sections = (const struct section_64 *)
                ((const uint8_t *)segment + sizeof(struct segment_command_64));
            for (uint32_t sectionIndex = 0; sectionIndex < segment->nsects; sectionIndex++) {
                const struct section_64 section = sections[sectionIndex];
                if (strncmp(section.sectname, "__text", sizeof(section.sectname)) != 0) continue;
                if (section.offset > data.length || section.size > data.length - section.offset) {
                    return @{@"valid": @NO};
                }
                const uint8_t *code = base + section.offset;
                textBytes += section.size;
                for (uint64_t word = 0; word + 4 <= section.size; word += 4) {
                    uint32_t instruction = 0;
                    memcpy(&instruction, code + word, sizeof(instruction));
                    switch (instruction) {
                        case kOMPACIBSP: pacibsp++; break;
                        case kOMAUTIBSP: autibsp++; break;
                        case kOMRETAB: retab++; break;
                        case kOMPACIASP: paciasp++; break;
                        case kOMRETAA: retaa++; break;
                        case kOMShiftPACIAA: otherPacia++; break;
                        default: break;
                    }
                }
            }
        }
        cursor += command->cmdsize;
    }

    OMOutputArch outputArch = [OMToolchain architectureOfMachOAtPath:path];
    NSString *architecture = outputArch == OMOutputArchArm64e ? @"arm64e" :
        (outputArch == OMOutputArchArm64 ? @"arm64" : @"unknown");
    BOOL bKeyReturnSigning = pacibsp > 0 && (autibsp > 0 || retab > 0) &&
        paciasp == 0 && retaa == 0 && otherPacia == 0;
    return @{
        @"valid": @YES,
        @"architecture": architecture,
        @"filetype": @(header.filetype),
        @"cpusubtype": @((uint32_t)header.cpusubtype),
        @"text_bytes": @(textBytes),
        @"pacibsp": @(pacibsp),
        @"autibsp": @(autibsp),
        @"retab": @(retab),
        @"paciasp": @(paciasp),
        @"retaa": @(retaa),
        @"other_pacia": @(otherPacia),
        @"b_key_return_signing": @(bKeyReturnSigning),
    };
}

static OMToolchainStatus OMCompile(NSString *source, NSString *output, NSString *architecture,
                                   BOOL requirePointerAuthentication,
                                   NSString **stdoutText, NSString **stderrText) {
    NSMutableArray<NSString *> *arguments = [[OMToolchain
        cc1ArgumentsForSource:source outputPath:output sysroot:nil resourceDir:nil
        archName:architecture minimumIOS:@"15.0"] mutableCopy];
    if (requirePointerAuthentication && arguments.count > 1) {
        [arguments insertObject:@"-fptrauth-returns" atIndex:1];
    }
    return [OMToolchain runCC1:arguments stdout:stdoutText stderr:stderrText];
}

/// The exact argv for the acceptance dylib link, so the report can show what
/// actually ran instead of leaving the reader to infer it.
static NSArray<NSString *> *OMDylibLinkArguments(NSString *object, NSString *output,
                                                 NSString *architecture) {
    return @[
        @"-arch", architecture,
        @"-dylib",
        @"-platform_version", @"ios", @"15.0", @"16.5",
        @"-o", output,
        @"-install_name", [NSString stringWithFormat:@"@rpath/om-runtime-%@.dylib", architecture],
        object,
    ];
}

static OMToolchainStatus OMLink(NSString *object, NSString *output, NSString *architecture,
                                NSString **stdoutText, NSString **stderrText) {
    return [OMToolchain runLinker:OMDylibLinkArguments(object, output, architecture)
                           stdout:stdoutText stderr:stderrText];
}

static NSDictionary<NSString *, id> *OMStep(NSString *name, OMToolchainStatus status,
                                             BOOL passed, NSTimeInterval duration,
                                             NSString *stdoutText, NSString *stderrText,
                                             NSDictionary<NSString *, id> *details) {
    NSMutableDictionary<NSString *, id> *result = [@{
        @"name": name,
        @"status": OMStatusName(status),
        @"passed": @(passed),
        @"duration_ms": @(duration * 1000.0),
        @"stdout": OMBoundedText(stdoutText),
        @"stderr": OMBoundedText(stderrText),
    } mutableCopy];
    if (details) [result addEntriesFromDictionary:details];
    return result;
}

@implementation OMToolchainDiagnostics

+ (NSDictionary<NSString *, id> *)runSuiteWithIterations:(NSUInteger)iterations {
    @try {
        @autoreleasepool {
        NSUInteger rounds = MAX((NSUInteger)1, MIN(iterations, (NSUInteger)3));
        NSDictionary<NSString *, NSString *> *capability = [OMToolchain capabilityStatus];
        NSMutableDictionary<NSString *, id> *report = [@{
            @"schema": @1,
            @"suite": @"fixed in-process Clang/ld64 runtime diagnostics",
            @"requested_iterations": @(iterations),
            @"bounded_iterations": @(rounds),
            @"capability": capability,
            @"provider_executable": @NO,
            @"runtime_verification_gate": @"not_granted",
            @"output_execution_attempted": @NO,
            @"limitations": @[
                @"Only fixed built-in freestanding C/Objective-C fixtures are accepted.",
                @"Generated Mach-O files are inspected but never loaded or executed.",
                @"A passing report does not define OM_TOOLCHAIN_VERIFIED or unlock BuildProvider.",
                @"Foundation/SDK compilation is not covered when no bundled iPhoneOS SDK is present.",
            ],
        } mutableCopy];
        BOOL linked = [capability[@"compiler_linked"] isEqualToString:@"yes"];
        BOOL resourcesReady = [capability[@"resource_headers"] isEqualToString:@"present"];
        if (!linked || !resourcesReady) {
            report[@"passed"] = @NO;
            report[@"reason"] = !linked ? @"compiler archives are not linked" :
                @"locked Clang resource headers are missing";
            report[@"steps"] = @[];
            return report;
        }

        NSString *identifier = [NSString stringWithFormat:@"om-runtime-%@", NSUUID.UUID.UUIDString];
        NSURL *root = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
            URLByAppendingPathComponent:identifier isDirectory:YES];
        NSError *fileError = nil;
        if (![[NSFileManager defaultManager] createDirectoryAtURL:root
                                      withIntermediateDirectories:YES
                                                       attributes:nil
                                                            error:&fileError]) {
            report[@"passed"] = @NO;
            report[@"reason"] = fileError.localizedDescription ?: @"cannot create temporary directory";
            report[@"steps"] = @[];
            return report;
        }

        NSString *cFixture =
            @"__attribute__((noinline)) static int om_helper(int x) { return x * 3 + 1; }\n"
             "__attribute__((noinline, visibility(\"default\"))) int om_probe(int x) {\n"
             "    return om_helper(x) + 7;\n"
             "}\n";
        NSString *objcFixture =
            @"__attribute__((objc_root_class)) @interface OMRuntimeProbe\n"
             "+ (int)value:(int)x;\n"
             "@end\n"
             "@implementation OMRuntimeProbe\n"
             "+ (int)value:(int)x { return x + 1; }\n"
             "@end\n"
             "int om_objc_entry(int x) { return [OMRuntimeProbe value:x]; }\n";
        NSString *badFixture = @"int om_broken( { return 0; }\n";
        NSURL *cSource = [root URLByAppendingPathComponent:@"probe.c"];
        NSURL *objcSource = [root URLByAppendingPathComponent:@"probe.m"];
        NSURL *badSource = [root URLByAppendingPathComponent:@"broken.c"];
        BOOL wrote = [cFixture writeToURL:cSource atomically:YES encoding:NSUTF8StringEncoding error:&fileError] &&
            [objcFixture writeToURL:objcSource atomically:YES encoding:NSUTF8StringEncoding error:&fileError] &&
            [badFixture writeToURL:badSource atomically:YES encoding:NSUTF8StringEncoding error:&fileError];
        if (!wrote) {
            report[@"passed"] = @NO;
            report[@"reason"] = fileError.localizedDescription ?: @"cannot write fixed fixtures";
            report[@"steps"] = @[];
            [[NSFileManager defaultManager] removeItemAtURL:root error:NULL];
            return report;
        }

        [OMToolchain initializeRuntimes];
        NSMutableArray<NSDictionary<NSString *, id> *> *steps = [NSMutableArray array];
        NSMutableArray<NSNumber *> *residentSamples = [NSMutableArray arrayWithObject:@(OMResidentBytes())];
        BOOL allPassed = YES;
        NSFileManager *fm = [NSFileManager defaultManager];

        for (NSString *architecture in @[@"arm64", @"arm64e"]) {
            BOOL needsPAC = [architecture isEqualToString:@"arm64e"];
            NSString *object = [[root URLByAppendingPathComponent:
                [NSString stringWithFormat:@"baseline-%@.o", architecture]] path];
            NSString *dylib = [[root URLByAppendingPathComponent:
                [NSString stringWithFormat:@"baseline-%@.dylib", architecture]] path];
            NSString *stdoutText = nil, *stderrText = nil;
            NSDate *started = [NSDate date];
            OMToolchainStatus status = OMCompile(cSource.path, object, architecture, needsPAC,
                                                 &stdoutText, &stderrText);
            NSTimeInterval duration = -started.timeIntervalSinceNow;
            NSDictionary *inspection = OMInspectMachO(object);
            BOOL passed = status == OMToolchainStatusOK && OMFileBytes(object) > 0 &&
                [inspection[@"valid"] boolValue] &&
                [inspection[@"filetype"] unsignedIntValue] == MH_OBJECT &&
                [inspection[@"architecture"] isEqualToString:architecture] &&
                (!needsPAC || [inspection[@"b_key_return_signing"] boolValue]);
            allPassed = allPassed && passed;
            [steps addObject:OMStep([NSString stringWithFormat:@"compile_%@_c", architecture],
                                    status, passed, duration, stdoutText, stderrText,
                                    @{@"output_bytes": @(OMFileBytes(object)),
                                      @"macho": inspection})];

            stdoutText = nil; stderrText = nil; started = [NSDate date];
            status = passed ? OMLink(object, dylib, architecture, &stdoutText, &stderrText)
                            : OMToolchainStatusUnavailable;
            duration = -started.timeIntervalSinceNow;
            inspection = OMInspectMachO(dylib);
            passed = status == OMToolchainStatusOK && OMFileBytes(dylib) > 0 &&
                [inspection[@"valid"] boolValue] &&
                [inspection[@"filetype"] unsignedIntValue] == MH_DYLIB &&
                [inspection[@"architecture"] isEqualToString:architecture] &&
                (!needsPAC || [inspection[@"b_key_return_signing"] boolValue]);
            allPassed = allPassed && passed;
            [steps addObject:OMStep([NSString stringWithFormat:@"link_%@_dylib", architecture],
                                    status, passed, duration, stdoutText, stderrText,
                                    @{@"output_bytes": @(OMFileBytes(dylib)),
                                      @"arguments": OMDylibLinkArguments(object, dylib, architecture),
                                      @"macho": inspection})];
            [residentSamples addObject:@(OMResidentBytes())];
        }

        // --- Linker argument ladder -----------------------------------------
        //
        // build185 reported every link as "ld64 exited with status 1" and
        // nothing more, because ld64's own message went to fd 2 and the host
        // could not read it back. Once that message is captured, the remaining
        // question is *which* part of the argument set ld64 rejects. Each probe
        // answers one such question, so a single device report locates the
        // failing flag instead of one build cycle per guess.
        //
        // Fixtures are the same object file compiled above, written into the
        // same temporary directory, and inspected but never executed. Probes do
        // not feed `allPassed`: the acceptance criterion stays the real
        // link_<arch>_dylib step, and link_probe_full_dylib exists precisely to
        // confirm the ladder reproduces that step's outcome.
        NSString *probeObject = [[root URLByAppendingPathComponent:@"baseline-arm64.o"] path];
        if (OMFileBytes(probeObject) > 0) {
            NSArray<NSDictionary<NSString *, id> *> *probes = @[
                @{@"name": @"link_probe_minimal_dylib",
                  @"flags": @[@"-arch", @"arm64", @"-dylib"],
                  @"filetype": @(MH_DYLIB)},
                @{@"name": @"link_probe_platform_version",
                  @"flags": @[@"-arch", @"arm64", @"-dylib",
                              @"-platform_version", @"ios", @"15.0", @"16.5"],
                  @"filetype": @(MH_DYLIB)},
                @{@"name": @"link_probe_install_name",
                  @"flags": @[@"-arch", @"arm64", @"-dylib",
                              @"-install_name", @"@rpath/om-probe.dylib"],
                  @"filetype": @(MH_DYLIB)},
                @{@"name": @"link_probe_full_dylib",
                  @"flags": @[@"-arch", @"arm64", @"-dylib",
                              @"-platform_version", @"ios", @"15.0", @"16.5",
                              @"-install_name", @"@rpath/om-probe.dylib"],
                  @"filetype": @(MH_DYLIB)},
                @{@"name": @"link_probe_executable",
                  @"flags": @[@"-arch", @"arm64",
                              @"-platform_version", @"ios", @"15.0", @"16.5"],
                  @"filetype": @(MH_EXECUTE)},
            ];
            for (NSDictionary<NSString *, id> *probe in probes) {
                NSString *probeName = probe[@"name"];
                NSString *probeOutput = [[root URLByAppendingPathComponent:
                    [NSString stringWithFormat:@"%@.out", probeName]] path];
                NSMutableArray<NSString *> *probeArguments =
                    [NSMutableArray arrayWithArray:probe[@"flags"]];
                [probeArguments addObjectsFromArray:@[@"-o", probeOutput, probeObject]];
                NSString *probeStdout = nil, *probeStderr = nil;
                NSDate *probeStarted = [NSDate date];
                OMToolchainStatus probeStatus = [OMToolchain runLinker:probeArguments
                                                                stdout:&probeStdout
                                                                stderr:&probeStderr];
                NSTimeInterval probeDuration = -probeStarted.timeIntervalSinceNow;
                NSDictionary *probeInspection = OMInspectMachO(probeOutput);
                unsigned int expectedFiletype = [probe[@"filetype"] unsignedIntValue];
                BOOL produced = probeStatus == OMToolchainStatusOK &&
                    OMFileBytes(probeOutput) > 0 &&
                    [probeInspection[@"valid"] boolValue] &&
                    [probeInspection[@"architecture"] isEqualToString:@"arm64"] &&
                    [probeInspection[@"filetype"] unsignedIntValue] == expectedFiletype;
                [steps addObject:OMStep(probeName, probeStatus, produced, probeDuration,
                                        probeStdout, probeStderr,
                                        @{@"arguments": probeArguments,
                                          @"output_bytes": @(OMFileBytes(probeOutput)),
                                          @"expected_filetype": @(expectedFiletype),
                                          @"macho": probeInspection})];
                [residentSamples addObject:@(OMResidentBytes())];
            }
        }

        NSString *objcObject = [[root URLByAppendingPathComponent:@"objective-c-arm64.o"] path];
        NSString *stdoutText = nil, *stderrText = nil;
        NSDate *started = [NSDate date];
        OMToolchainStatus status = OMCompile(objcSource.path, objcObject, @"arm64", NO,
                                             &stdoutText, &stderrText);
        NSTimeInterval duration = -started.timeIntervalSinceNow;
        NSDictionary *inspection = OMInspectMachO(objcObject);
        BOOL passed = status == OMToolchainStatusOK && OMFileBytes(objcObject) > 0 &&
            [inspection[@"valid"] boolValue] &&
            [inspection[@"filetype"] unsignedIntValue] == MH_OBJECT &&
            [inspection[@"architecture"] isEqualToString:@"arm64"];
        allPassed = allPassed && passed;
        [steps addObject:OMStep(@"compile_arm64_objective_c", status, passed, duration,
                                stdoutText, stderrText,
                                @{@"output_bytes": @(OMFileBytes(objcObject)),
                                  @"macho": inspection})];

        NSString *badObject = [[root URLByAppendingPathComponent:@"broken.o"] path];
        stdoutText = nil; stderrText = nil; started = [NSDate date];
        status = OMCompile(badSource.path, badObject, @"arm64", NO, &stdoutText, &stderrText);
        duration = -started.timeIntervalSinceNow;
        passed = status == OMToolchainStatusDiagnostics && stderrText.length > 0;
        allPassed = allPassed && passed;
        [steps addObject:OMStep(@"expected_clang_failure", status, passed, duration,
                                stdoutText, stderrText,
                                @{@"output_exists": @([fm fileExistsAtPath:badObject])})];

        NSString *recoveryObject = [[root URLByAppendingPathComponent:@"recovery.o"] path];
        stdoutText = nil; stderrText = nil; started = [NSDate date];
        status = OMCompile(cSource.path, recoveryObject, @"arm64", NO, &stdoutText, &stderrText);
        duration = -started.timeIntervalSinceNow;
        inspection = OMInspectMachO(recoveryObject);
        passed = status == OMToolchainStatusOK &&
            [inspection[@"filetype"] unsignedIntValue] == MH_OBJECT &&
            [inspection[@"architecture"] isEqualToString:@"arm64"];
        allPassed = allPassed && passed;
        [steps addObject:OMStep(@"clang_recovery_after_failure", status, passed, duration,
                                stdoutText, stderrText, @{@"macho": inspection})];

        NSString *missingObject = [[root URLByAppendingPathComponent:@"missing-input.o"] path];
        NSString *failedDylib = [[root URLByAppendingPathComponent:@"expected-link-failure.dylib"] path];
        stdoutText = nil; stderrText = nil; started = [NSDate date];
        status = OMLink(missingObject, failedDylib, @"arm64", &stdoutText, &stderrText);
        duration = -started.timeIntervalSinceNow;
        passed = status != OMToolchainStatusOK;
        allPassed = allPassed && passed;
        [steps addObject:OMStep(@"expected_linker_failure", status, passed, duration,
                                stdoutText, stderrText,
                                @{@"output_exists": @([fm fileExistsAtPath:failedDylib])})];

        NSString *recoveryDylib = [[root URLByAppendingPathComponent:@"recovery.dylib"] path];
        stdoutText = nil; stderrText = nil; started = [NSDate date];
        status = OMLink(recoveryObject, recoveryDylib, @"arm64", &stdoutText, &stderrText);
        duration = -started.timeIntervalSinceNow;
        inspection = OMInspectMachO(recoveryDylib);
        passed = status == OMToolchainStatusOK &&
            [inspection[@"filetype"] unsignedIntValue] == MH_DYLIB &&
            [inspection[@"architecture"] isEqualToString:@"arm64"];
        allPassed = allPassed && passed;
        [steps addObject:OMStep(@"linker_recovery_after_failure", status, passed, duration,
                                stdoutText, stderrText, @{@"macho": inspection})];
        [residentSamples addObject:@(OMResidentBytes())];

        for (NSUInteger index = 0; index < rounds; index++) {
            @autoreleasepool {
                NSString *object = [[root URLByAppendingPathComponent:
                    [NSString stringWithFormat:@"repeat-%lu.o", (unsigned long)index]] path];
                NSString *dylib = [[root URLByAppendingPathComponent:
                    [NSString stringWithFormat:@"repeat-%lu.dylib", (unsigned long)index]] path];
                NSString *repeatOut = nil, *repeatErr = nil;
                NSDate *repeatStart = [NSDate date];
                OMToolchainStatus compileStatus = OMCompile(cSource.path, object, @"arm64", NO,
                                                             &repeatOut, &repeatErr);
                OMToolchainStatus linkStatus = compileStatus == OMToolchainStatusOK
                    ? OMLink(object, dylib, @"arm64", &repeatOut, &repeatErr)
                    : OMToolchainStatusUnavailable;
                NSDictionary *repeatInspection = OMInspectMachO(dylib);
                BOOL repeatPassed = compileStatus == OMToolchainStatusOK &&
                    linkStatus == OMToolchainStatusOK &&
                    [repeatInspection[@"filetype"] unsignedIntValue] == MH_DYLIB &&
                    [repeatInspection[@"architecture"] isEqualToString:@"arm64"];
                allPassed = allPassed && repeatPassed;
                [residentSamples addObject:@(OMResidentBytes())];
                [steps addObject:OMStep([NSString stringWithFormat:@"repeat_compile_link_%lu",
                                         (unsigned long)(index + 1)],
                                        linkStatus, repeatPassed,
                                        -repeatStart.timeIntervalSinceNow,
                                        repeatOut, repeatErr,
                                        @{@"compile_status": OMStatusName(compileStatus),
                                          @"macho": repeatInspection,
                                          @"resident_bytes": residentSamples.lastObject})];
            }
        }

        uint64_t residentBefore = residentSamples.firstObject.unsignedLongLongValue;
        uint64_t residentAfter = OMResidentBytes();
        [residentSamples addObject:@(residentAfter)];
        uint64_t observedPeak = 0;
        for (NSNumber *sample in residentSamples) observedPeak = MAX(observedPeak, sample.unsignedLongLongValue);
        report[@"steps"] = steps;
        report[@"resident_samples_bytes"] = residentSamples;
        report[@"resident_before_bytes"] = @(residentBefore);
        report[@"resident_after_bytes"] = @(residentAfter);
        report[@"resident_delta_bytes"] = @((int64_t)residentAfter - (int64_t)residentBefore);
        report[@"peak_observed_resident_bytes"] = @(observedPeak);
        NSError *cleanupError = nil;
        BOOL removed = [[NSFileManager defaultManager] removeItemAtURL:root error:&cleanupError];
        report[@"temporary_outputs_removed"] = @(removed);
        if (!removed) {
            allPassed = NO;
            report[@"cleanup_error"] = cleanupError.localizedDescription ?: @"unknown cleanup error";
        }
        report[@"passed"] = @(allPassed);
        return report;
        }
    } @catch (NSException *exception) {
        return @{
            @"schema": @1,
            @"suite": @"fixed in-process Clang/ld64 runtime diagnostics",
            @"passed": @NO,
            @"provider_executable": @NO,
            @"runtime_verification_gate": @"not_granted",
            @"output_execution_attempted": @NO,
            @"exception_name": exception.name ?: @"unknown",
            @"exception_reason": exception.reason ?: @"unknown",
            @"steps": @[],
        };
    }
}

@end
