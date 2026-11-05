import XCTest
import Foundation
import CryptoKit
@testable import Minis

@MainActor
final class ProgrammingBuildToolsTests: XCTestCase {
    func testDiagnosticsParseClangSwiftAndMakeLocations() {
        let log = """
        /tmp/App.swift:12:7: error: cannot find 'thing' in scope
        Sources/native.c:4:2: warning: unused variable 'x'
        error: emit-module command failed with exit code 1
        make[2]: *** [obj/tweak.o] Error 1
        """
        let result = BuildLogAnalyzer.analyze(log)
        XCTAssertEqual(result.firstError?.file, "/tmp/App.swift")
        XCTAssertEqual(result.firstError?.line, 12)
        XCTAssertEqual(result.firstError?.column, 7)
        XCTAssertEqual(result.firstError?.severity, .error)
        XCTAssertEqual(result.diagnostics.first?.tool, "swift")
        XCTAssertGreaterThanOrEqual(result.errorCount, 3)
        XCTAssertEqual(result.warningCount, 1)
    }

    func testArtifactKindInference() {
        XCTAssertEqual(ArtifactVerifier.inferKind("/tmp/App.ipa"), .ipa)
        XCTAssertEqual(ArtifactVerifier.inferKind("/tmp/tweak.deb"), .deb)
        XCTAssertEqual(ArtifactVerifier.inferKind("/tmp/libHook.dylib"), .macho)
        XCTAssertEqual(ArtifactVerifier.inferKind("/tmp/tool"), .binary)
    }

    func testProjectClassificationDoesNotTreatVendoredMakefileAsRootBuild() {
        XCTAssertEqual(BuildProjectDetector.classify(manifests: ["./deps/vendor/Makefile"]), .unknown)
        XCTAssertEqual(BuildProjectDetector.classify(manifests: ["./Makefile"], isTheos: true), .theos)
        XCTAssertEqual(BuildProjectDetector.classify(manifests: ["./App.xcodeproj"]), .xcode)
        XCTAssertEqual(BuildProjectDetector.classify(manifests: ["./App.xcodeproj", "./android/gradlew"]), .mixed)
    }

    func testCredentialCommandRedaction() {
        let value = CredentialLogPolicy.redact("curl https://abc@example.com token=hunter2 --password secret")
        XCTAssertFalse(value.contains("hunter2"))
        XCTAssertFalse(value.contains("abc@"))
        XCTAssertFalse(value.contains(" secret"))
        XCTAssertTrue(value.contains("[REDACTED]"))
    }

    func testProviderRosterContainsAllRealAdapters() {
        XCTAssertEqual(Set(BuildProviderID.allCases), Set([.localISH, .theos, .remoteGitHubActions, .macSSH, .embeddedToolchain, .embeddedTheos]))
        XCTAssertEqual(Set(BuildProviderRegistry.providers.map { $0.id }), Set(BuildProviderID.allCases))
    }

    func testTheosProjectsPreferEmbeddedTheosProviderWithoutExecutingMakefile() {
        XCTAssertEqual(BuildProjectDetector.classify(manifests: ["./Makefile"], isTheos: true), .theos)
        XCTAssertEqual(BuildProjectDetector.classify(manifests: ["./Makefile"], isTheos: false), .make)
    }

    func testEmbeddedTheosPlanRequiresSafeDualTargetGraph() throws {
        let daemon = EmbeddedTheosTarget(name: "ictrld", kind: .daemon,
            sourcePaths: ["daemon/main.m"], headerPaths: ["daemon/ICNAuth.h"],
            frameworks: ["Foundation", "Security"], installPath: "usr/libexec/ictrld",
            installName: nil, filterPlistPath: nil, entitlementsPath: "daemon/entitlements.plist",
            architectures: [.arm64, .arm64e])
        let tweak = EmbeddedTheosTarget(name: "iCTRLBridge", kind: .tweak,
            sourcePaths: ["bridge/ICNBridge.m"], headerPaths: ["shared/ICNProtocol.h"],
            frameworks: ["Foundation", "UIKit", "CoreFoundation"],
            installPath: "Library/MobileSubstrate/DynamicLibraries/iCTRLBridge.dylib",
            installName: "@rpath/iCTRLBridge.dylib", filterPlistPath: "iCTRLBridge.plist",
            entitlementsPath: nil, architectures: [.arm64, .arm64e])
        let plan = EmbeddedTheosProjectPlan(schema: 1, packageID: "com.example.ictrl",
            version: "1.0", name: "iCTRL", maintainer: "Test", description: "Native test",
            bundleIDs: ["com.apple.springboard"], targets: [daemon, tweak])
        XCTAssertNoThrow(try plan.validate())

        let unsafe = EmbeddedTheosTarget(name: "bad", kind: .tweak,
            sourcePaths: ["../escape.m"], headerPaths: [], frameworks: [],
            installPath: "Library/Tweak.dylib", installName: "@rpath/Tweak.dylib",
            filterPlistPath: nil, entitlementsPath: nil, architectures: [.arm64, .arm64e])
        XCTAssertThrowsError(try unsafe.validate())

        let singleTarget = EmbeddedTheosProjectPlan(schema: 1, packageID: "com.example.ictrl",
            version: "1.0", name: "iCTRL", maintainer: "Test", description: "Native test",
            bundleIDs: ["com.apple.springboard"], targets: [daemon])
        XCTAssertThrowsError(try singleTarget.validate())
    }

    func testEmbeddedTheosManifestParserBuildsDualTargetGraphAndRejectsShell() throws {
        let metadata = EmbeddedDebMetadata(packageID: "com.judegor.ictrl-native",
            name: "iCTRL Native", version: "0.1.2", maintainer: "JudeGor",
            description: "Local-only native bridge", tweakName: "iCTRLBridge",
            bundleIDs: ["com.apple.springboard"])
        let makefile = """
        THEOS_PACKAGE_SCHEME = rootless
        TOOL_NAME = ictrld
        ictrld_FILES = daemon/main.m daemon/ICNAuth.m shared/ICNProtocol.m vendor/ictrl/util.c
        ictrld_FRAMEWORKS = Foundation Security
        ictrld_INSTALL_PATH = /usr/libexec
        ictrld_CODESIGN_FLAGS = -Sdaemon/entitlements.plist
        TWEAK_NAME = iCTRLBridge
        iCTRLBridge_FILES = bridge/ICNBridge.m shared/ICNProtocol.m
        iCTRLBridge_FRAMEWORKS = Foundation UIKit CoreFoundation
        include $(THEOS)/makefiles/common.mk
        before-package::
        \tchmod 0755 $(THEOS_STAGING_DIR)/DEBIAN/postinst
        """
        let plan = try EmbeddedTheosManifestParser.parse(makefile: makefile, metadata: metadata)
        XCTAssertEqual(plan.targets.count, 2)
        let daemon = try XCTUnwrap(plan.targets.first { $0.kind == .daemon })
        XCTAssertEqual(daemon.name, "ictrld")
        XCTAssertEqual(daemon.installPath, "usr/libexec/ictrld")
        XCTAssertEqual(daemon.entitlementsPath, "daemon/entitlements.plist")
        XCTAssertTrue(daemon.frameworks.contains("Security"))
        XCTAssertEqual(daemon.architectures, [.arm64, .arm64e])
        let tweak = try XCTUnwrap(plan.targets.first { $0.kind == .tweak })
        XCTAssertEqual(tweak.installPath, "Library/MobileSubstrate/DynamicLibraries/iCTRLBridge.dylib")
        XCTAssertEqual(tweak.installName, "@rpath/iCTRLBridge.dylib")
        XCTAssertFalse(EmbeddedTheosManifestParser.ignoredRecipes(in: makefile).isEmpty)

        let shellMakefile = """
        THEOS_PACKAGE_SCHEME = rootless
        TOOL_NAME = ictrld
        ictrld_FILES = daemon/main.m
        BAD = $(shell rm -rf /)
        """
        XCTAssertThrowsError(try EmbeddedTheosManifestParser.parse(makefile: shellMakefile, metadata: metadata))
    }

    func testEmbeddedTheosCompilePlannerBuildsPerTargetActions() throws {
        let daemon = EmbeddedTheosTarget(name: "ictrld", kind: .daemon,
            sourcePaths: ["daemon/main.m", "vendor/util.c"], headerPaths: ["daemon/include/Shared.h"],
            frameworks: ["Foundation"], installPath: "usr/libexec/ictrld",
            installName: nil, filterPlistPath: nil, entitlementsPath: "daemon/entitlements.plist",
            architectures: [.arm64, .arm64e])
        let tweak = EmbeddedTheosTarget(name: "iCTRLBridge", kind: .tweak,
            sourcePaths: ["bridge/ICNBridge.m"], headerPaths: [],
            frameworks: ["UIKit"],
            installPath: "Library/MobileSubstrate/DynamicLibraries/iCTRLBridge.dylib",
            installName: "@rpath/iCTRLBridge.dylib", filterPlistPath: "iCTRLBridge.plist",
            entitlementsPath: nil, architectures: [.arm64, .arm64e])
        let project = EmbeddedTheosProjectPlan(schema: 1, packageID: "com.example.ictrl",
            version: "1.0", name: "iCTRL", maintainer: "Test", description: "Native test",
            bundleIDs: ["com.apple.springboard"], targets: [daemon, tweak])
        let contents = [
            "daemon/main.m": "int main(void) { return 0; }\n",
            "vendor/util.c": "int util(void) { return 1; }\n",
            "daemon/include/Shared.h": "#define SHARED_VALUE 7\n",
            "daemon/entitlements.plist": "<plist><dict><key>com.apple.private.example</key><true/></dict></plist>",
            "bridge/ICNBridge.m": "@interface X @end\n"
        ]
        let plans = try EmbeddedTheosCompilePlanner.plan(project: project, fileContents: contents)
        XCTAssertEqual(plans.count, 2)
        let daemonPlan = try XCTUnwrap(plans.first { $0.target.kind == .daemon })
        XCTAssertEqual(daemonPlan.sources.count, 2)
        XCTAssertEqual(daemonPlan.headers.count, 1)
        XCTAssertEqual(daemonPlan.headers.first?.path, "daemon/include/Shared.h")
        XCTAssertNotNil(daemonPlan.entitlements)
        XCTAssertTrue(daemonPlan.entitlements.flatMap { String(data: $0, encoding: .utf8) }?
            .contains("com.apple.private.example") == true)
        XCTAssertEqual(daemonPlan.architectures, [.arm64, .arm64e])
        XCTAssertEqual(Set(daemonPlan.objectNames).count, 2)
        XCTAssertEqual(daemonPlan.sources.first { $0.path == "vendor/util.c" }?.language, .c)
        XCTAssertEqual(daemonPlan.sources.first { $0.path == "daemon/main.m" }?.language, .objectiveC)
        XCTAssertTrue(daemonPlan.sources.allSatisfy { $0.sha256.count == 64 })
        let tweakPlan = try XCTUnwrap(plans.first { $0.target.kind == .tweak })
        XCTAssertEqual(tweakPlan.sources.first?.language, .objectiveC)

        XCTAssertThrowsError(try EmbeddedTheosCompilePlanner.plan(project: project,
            fileContents: ["daemon/main.m": "int x;\n"]))
        XCTAssertThrowsError(try EmbeddedTheosCompilePlanner.plan(project: project,
            fileContents: ["daemon/main.m": "int main(void) { return 0; }\n",
                           "vendor/util.c": "int util(void) { return 1; }\n",
                           "daemon/entitlements.plist": "<plist><dict><key>x</key><true/></dict></plist>",
                           "bridge/ICNBridge.m": "@interface X @end\n"]))
    }

    func testEmbeddedTheosDebPackageBuildsRootlessMultiTargetDeb() throws {
        let control = try EmbeddedTheosDebPackage.control(packageID: "com.judegor.ictrl-native",
            name: "iCTRL Native", version: "0.1.2", maintainer: "JudeGor",
            description: "Local-only native bridge",
            depends: "firmware (>= 15.4), mobilesubstrate")
        let files = [
            EmbeddedTheosDebEntry(path: "var/jb/usr/libexec/ictrld",
                                  bytes: Data("daemon".utf8), mode: 0o755),
            EmbeddedTheosDebEntry(path: "var/jb/Library/MobileSubstrate/DynamicLibraries/iCTRLBridge.dylib",
                                  bytes: Data("dylib".utf8), mode: 0o755),
            EmbeddedTheosDebEntry(path: "var/jb/Library/MobileSubstrate/DynamicLibraries/iCTRLBridge.plist",
                                  bytes: Data("<plist/>".utf8), mode: 0o644),
            EmbeddedTheosDebEntry(path: "var/jb/Library/LaunchDaemons/com.judegor.ictrl-native.plist",
                                  bytes: Data("<daemon/>".utf8), mode: 0o644)
        ]
        let deb = try EmbeddedTheosDebPackage.build(files: files, controlText: control,
            maintainerScripts: ["postinst": "#!/bin/sh\nexit 0\n"])
        let paths = try EmbeddedTheosDebPackage.inspect(deb)
        XCTAssertTrue(paths.contains("var/jb/usr/libexec/ictrld"))
        XCTAssertTrue(paths.contains("var/jb/Library/MobileSubstrate/DynamicLibraries/iCTRLBridge.dylib"))
        XCTAssertTrue(paths.allSatisfy { $0.hasPrefix("var/jb/") })

        XCTAssertThrowsError(try EmbeddedTheosDebPackage.build(
            files: [EmbeddedTheosDebEntry(path: "Library/Tweak.dylib", bytes: Data("x".utf8), mode: 0o755)],
            controlText: control))
        XCTAssertThrowsError(try EmbeddedTheosDebPackage.build(files: files, controlText: control,
            maintainerScripts: ["postrm": "#!/bin/sh\n"]))
        XCTAssertThrowsError(try EmbeddedTheosDebPackage.control(packageID: "Bad ID",
            name: "n", version: "1.0", maintainer: "m", description: "d", depends: "mobilesubstrate"))
    }

    func testEmbeddedAdHocSignatureVerifierCoversPagesAndEntitlements() throws {
        func little(_ value: UInt32) -> Data {
            Data([UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8),
                  UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 24)])
        }
        func big(_ value: UInt32) -> Data {
            Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16),
                  UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
        }
        func put(_ bytes: Data, at offset: Int, in data: inout Data) {
            data.replaceSubrange(offset..<(offset + bytes.count), with: bytes)
        }

        let entitlements = Data("<plist><dict><key>platform-application</key><true/></dict></plist>".utf8)
        var entitlementBlob = big(EmbeddedCodeSignature.magicEntitlements)
        entitlementBlob.append(big(UInt32(8 + entitlements.count)))
        entitlementBlob.append(entitlements)

        let identifier = Data("fixture\0".utf8)
        let fixedHeader = 0x58
        let entitlementHashOffset = fixedHeader + identifier.count
        let hashOffset = entitlementHashOffset + 5 * 32
        let codeDirectoryLength = hashOffset + 32
        let codeDirectoryOffset = 28
        let entitlementOffset = codeDirectoryOffset + codeDirectoryLength
        let superBlobLength = entitlementOffset + entitlementBlob.count
        let signatureSize = (superBlobLength + 7) & ~7
        let codeLimit = 4096

        var image = Data(repeating: 0, count: codeLimit)
        put(little(0xfeedfacf), at: 0, in: &image)
        put(little(0x0100000c), at: 4, in: &image)
        put(little(2), at: 12, in: &image)
        put(little(1), at: 16, in: &image)
        put(little(16), at: 20, in: &image)
        put(little(0x1d), at: 32, in: &image)
        put(little(16), at: 36, in: &image)
        put(little(UInt32(codeLimit)), at: 40, in: &image)
        put(little(UInt32(signatureSize)), at: 44, in: &image)

        var codeDirectory = Data(repeating: 0, count: codeDirectoryLength)
        put(big(EmbeddedCodeSignature.magicCodeDirectory), at: 0, in: &codeDirectory)
        put(big(UInt32(codeDirectoryLength)), at: 4, in: &codeDirectory)
        put(big(0x20400), at: 8, in: &codeDirectory)
        put(big(0x2), at: 12, in: &codeDirectory)
        put(big(UInt32(hashOffset)), at: 16, in: &codeDirectory)
        put(big(UInt32(fixedHeader)), at: 20, in: &codeDirectory)
        put(big(5), at: 24, in: &codeDirectory)
        put(big(1), at: 28, in: &codeDirectory)
        put(big(UInt32(codeLimit)), at: 32, in: &codeDirectory)
        codeDirectory[36] = 32
        codeDirectory[37] = 2
        codeDirectory[39] = 12
        put(identifier, at: fixedHeader, in: &codeDirectory)
        put(Data(SHA256.hash(data: entitlementBlob)), at: entitlementHashOffset, in: &codeDirectory)
        put(Data(SHA256.hash(data: image)), at: hashOffset, in: &codeDirectory)

        var superBlob = big(EmbeddedCodeSignature.magicEmbeddedSignature)
        superBlob.append(big(UInt32(superBlobLength)))
        superBlob.append(big(2))
        superBlob.append(big(EmbeddedCodeSignature.slotCodeDirectory))
        superBlob.append(big(UInt32(codeDirectoryOffset)))
        superBlob.append(big(EmbeddedCodeSignature.slotEntitlements))
        superBlob.append(big(UInt32(entitlementOffset)))
        superBlob.append(codeDirectory)
        superBlob.append(entitlementBlob)
        superBlob.append(Data(repeating: 0, count: signatureSize - superBlob.count))
        image.append(superBlob)

        let report = try EmbeddedCodeSignature.verify(image, expectedEntitlements: entitlements)
        XCTAssertTrue(report.adHoc)
        XCTAssertTrue(report.entitlementsPresent)
        XCTAssertEqual(report.entitlementsBytes, entitlements.count)
        XCTAssertEqual(report.codeSlots, 1)

        var changedCode = image
        changedCode[100] ^= 0x01
        XCTAssertThrowsError(try EmbeddedCodeSignature.verify(changedCode,
            expectedEntitlements: entitlements))
        XCTAssertThrowsError(try EmbeddedCodeSignature.verify(image,
            expectedEntitlements: Data("different".utf8)))

        var duplicateBlobType = image
        put(big(EmbeddedCodeSignature.slotCodeDirectory), at: codeLimit + 20, in: &duplicateBlobType)
        XCTAssertThrowsError(try EmbeddedCodeSignature.verify(duplicateBlobType,
            expectedEntitlements: entitlements))

        var overlappingBlobs = image
        put(big(UInt32(codeDirectoryOffset)), at: codeLimit + 24, in: &overlappingBlobs)
        XCTAssertThrowsError(try EmbeddedCodeSignature.verify(overlappingBlobs,
            expectedEntitlements: entitlements))

        var trailingUnsignedByte = image
        trailingUnsignedByte.append(0)
        XCTAssertThrowsError(try EmbeddedCodeSignature.verify(trailingUnsignedByte,
            expectedEntitlements: entitlements))

        var changedEntitlementBlob = image
        changedEntitlementBlob[codeLimit + entitlementOffset + 9] ^= 0x01
        XCTAssertThrowsError(try EmbeddedCodeSignature.verify(changedEntitlementBlob,
            expectedEntitlements: entitlements))
    }

    func testEmbeddedProviderRequiresNativeWorkspaceAndNeverRunsShell() async {
        final class CallCounter { var value = 0 }
        let shellCalls = CallCounter()
        let inspection = BuildProjectInspection(
            canonicalPath: "/var/minis/workspace/missing", kind: .embeddedTweak,
            manifests: ["./MinisTweak.json"], languageStack: ["C", "Objective-C"],
            gitBranch: nil, gitCommit: nil, gitIsDirty: true, gitRemote: nil,
            suggestedProviders: [.embeddedToolchain], suggestedCommands: [])
        let request = BuildRequest(
            projectPath: "/var/minis/workspace/missing", provider: .embeddedToolchain, configuration: "Debug",
            toolchain: "auto", command: nil, testCommand: nil, artifactPaths: [], timeoutSeconds: 60,
            cachePolicy: .ignore, attempt: 1, maxAttempts: 3, workflow: nil, workflowInputs: [:])
        let context = BuildProviderContext(inspection: inspection, request: request) { _, _ in
            shellCalls.value += 1
            return BuildShellResult(output: "", exitCode: 0)
        }
        let provider = EmbeddedToolchainBuildProvider()
        let availability = await provider.availability(for: context)
        XCTAssertEqual(availability.state, .unavailable)
        XCTAssertTrue(availability.missingConfiguration.contains("session workspace project with valid MinisTweak.json"))
        guard case .unavailable = await provider.build(context: context, runID: "probe") else {
            return XCTFail("Missing native workspace must not build.")
        }
        XCTAssertEqual(shellCalls.value, 0)
    }

    func testEmbeddedFailurePreservesFirstCompilerErrorAndRealSamples() {
        var result = EmbeddedAdapterResult()
        result.state = "diagnostics"
        result.reason = "compiler/linker rejected the bounded input"
        result.residentSamplesBytes = [100, 140, 110]
        result.processLinkCount = 1
        result.steps = [EmbeddedAdapterStep(operation: "unit0.o", status: 1, stdout: "",
            stderr: "source.c:4:2: error: expected ';'\n" + String(repeating: "a warning line\n", count: 300))]
        let provider = EmbeddedToolchainBuildProvider()
        guard case .completed(let execution) = provider.failedExecution(result.reason, runID: "test",
                                                                        started: Date(), reports: [result]) else {
            return XCTFail("native compiler failure must not return an available artifact")
        }
        XCTAssertEqual(execution.exitCode, 1)
        XCTAssertEqual(execution.remoteMetadata["resident_samples_by_architecture"], "arm64=100,140,110")
        XCTAssertEqual(execution.remoteMetadata["peak_observed_resident_bytes"], "140")
        XCTAssertEqual(execution.remoteMetadata["arm64_observed_growth_from_first_sample_bytes"], "40")
        XCTAssertEqual(execution.remoteMetadata["process_link_count"], "1")
        XCTAssertEqual(execution.fullLogPath, "")
        let first = BuildLogAnalyzer.analyze(execution.diagnosticExcerpt).firstError
        XCTAssertEqual(first?.file, "source.c")
        XCTAssertEqual(first?.line, 4)
        XCTAssertEqual(first?.column, 2)
        XCTAssertTrue(first?.message.contains("expected") == true)
    }

    func testEmbeddedOperationRejectsUnsafeInputs() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("int probe(void) { return 1; }\n".utf8).write(to: root.appendingPathComponent("probe.c"))
        var objectHeader = [UInt8](repeating: 0, count: 104)
        objectHeader[0] = 0xcf; objectHeader[1] = 0xfa; objectHeader[2] = 0xed; objectHeader[3] = 0xfe
        objectHeader[4] = 0x0c; objectHeader[7] = 0x01; objectHeader[12] = 0x01
        objectHeader[16] = 0x01; objectHeader[20] = 0x48
        objectHeader[32] = 0x19; objectHeader[36] = 0x48
        try Data(objectHeader).write(to: root.appendingPathComponent("probe.o"))

        let compile = EmbeddedToolchainOperation.compile(source: "probe.c", output: "out.o", language: .c)
        XCTAssertNil(compile.validationError(root: root))
        let linkedRoot = root.deletingLastPathComponent().appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: linkedRoot) }
        try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: root)
        XCTAssertNotNil(compile.validationError(root: linkedRoot))
        XCTAssertNotNil(EmbeddedToolchainOperation.compile(source: "../escape.c", output: "out.o", language: .c).validationError(root: root))
        XCTAssertNotNil(EmbeddedToolchainOperation.compile(source: "probe\0.c", output: "out.o", language: .c).validationError(root: root))
        XCTAssertNotNil(EmbeddedToolchainOperation.compile(source: "probe.c", output: "out.dylib", language: .c).validationError(root: root))
        XCTAssertNotNil(EmbeddedToolchainOperation.compile(source: "probe.c", output: "out.o", language: .objectiveC).validationError(root: root))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("directory.c"), withIntermediateDirectories: false)
        XCTAssertNotNil(EmbeddedToolchainOperation.compile(source: "directory.c", output: "dir.o", language: .c).validationError(root: root))

        let link = EmbeddedToolchainOperation.link(objects: ["probe.o"], output: "out.dylib", installName: "@rpath/out.dylib")
        XCTAssertNil(link.validationError(root: root))
        var malformedHeader = [UInt8](repeating: 0, count: 32)
        malformedHeader[0] = 0xcf; malformedHeader[1] = 0xfa; malformedHeader[2] = 0xed; malformedHeader[3] = 0xfe
        malformedHeader[4] = 0x0c; malformedHeader[7] = 0x01; malformedHeader[12] = 0x01
        malformedHeader[16] = 0x01; malformedHeader[20] = 0x48
        try Data(malformedHeader).write(to: root.appendingPathComponent("malformed.o"))
        XCTAssertNotNil(EmbeddedToolchainOperation.link(objects: ["malformed.o"], output: "bad.dylib", installName: "@rpath/bad.dylib").validationError(root: root))
        XCTAssertNotNil(EmbeddedToolchainOperation.link(objects: ["probe.o"], output: "out.dylib", installName: "/tmp/out.dylib").validationError(root: root))
        XCTAssertNotNil(EmbeddedToolchainOperation.link(objects: ["probe.o"], output: "out.dylib", installName: "@rpath/sub/out.dylib").validationError(root: root))
        XCTAssertNotNil(EmbeddedToolchainOperation.link(objects: Array(repeating: "probe.o", count: 33), output: "out.dylib", installName: "@rpath/out.dylib").validationError(root: root))
        XCTAssertNotNil(EmbeddedToolchainOperation.link(objects: ["missing.o"], output: "out.dylib", installName: "@rpath/out.dylib").validationError(root: root))

        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("link.c"), withDestinationURL: root.appendingPathComponent("probe.c"))
        XCTAssertNotNil(EmbeddedToolchainOperation.compile(source: "link.c", output: "out.o", language: .c).validationError(root: root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("linked-dir"), withDestinationURL: root)
        XCTAssertNotNil(EmbeddedToolchainOperation.compile(source: "linked-dir/probe.c", output: "nested.o", language: .c).validationError(root: root))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("out.o"), withDestinationURL: root.appendingPathComponent("probe.o"))
        XCTAssertNotNil(EmbeddedToolchainOperation.compile(source: "probe.c", output: "out.o", language: .c).validationError(root: root))
    }

    func testBuildRunMigrationIsIdempotent() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = directory.appendingPathComponent("build.sqlite3")
        let store = BuildRunStore(databaseURL: url)
        try await store.migrate()
        try await store.migrate()
        let count = try await store.count()
        XCTAssertEqual(count, 0)
        try? FileManager.default.removeItem(at: directory)
    }

    func testBuildSuccessAndTestPassStatesAreExitCodeBacked() {
        func buildState(exit: Int) -> BuildState { exit == 0 ? .success : .failed }
        func testState(exit: Int) -> TestState { exit == 0 ? .passed : .failed }
        XCTAssertEqual(buildState(exit: 0), .success)
        XCTAssertEqual(buildState(exit: 65), .failed)
        XCTAssertEqual(testState(exit: 0), .passed)
        XCTAssertEqual(testState(exit: 1), .failed)
    }

    func testCommandRunnerUsesCapturedExitCodeNotSuccessText() async {
        let b64: (String) -> String = { Data($0.utf8).base64EncodedString() }
        let output = """
        __MINIS_BUILD_EXIT__=65
        __MINIS_BUILD_DURATION__=2
        __MINIS_BUILD_STDOUT__=\(b64("** BUILD SUCCEEDED **"))
        __MINIS_BUILD_STDERR__=\(b64("compiler failed"))
        __MINIS_BUILD_DIAGNOSTICS__=\(b64("App.swift:1:1: error: broken"))
        __MINIS_BUILD_LOG__=/tmp/build.log
        __MINIS_REMOTE__run_id=400 run_number=12 status=completed conclusion=failure run_url=https://example/run run_logs_url=https://api.example/logs jobs_url=https://api.example/jobs artifacts_url=https://api.example/artifacts repository=Owner/Repo head_sha=abc
        __MINIS_JOB__id=501 name=Compile App status=completed conclusion=failure html_url=https://example/job api_url=https://api.example/job
        __MINIS_ARTIFACT__id=601 name=Build Logs size=1234 expired=false url=https://api.example/artifact
        """
        let execution = await BuildCommandRunner.run(projectPath: "/tmp", command: "false", displayCommand: "false", runID: "test", phase: "build", timeout: 30) { _, _ in
            BuildShellResult(output: output, exitCode: 0)
        }
        let record: BuildCommandExecution
        switch execution {
        case .completed(let value): record = value
        case .completedWithArtifacts(let value, _): record = value
        case .unavailable: return XCTFail("expected completed result")
        }
        XCTAssertEqual(record.exitCode, 65)
        XCTAssertEqual(record.fullLogPath, "/tmp/build.log")
        XCTAssertTrue(record.stdoutSummary.contains("BUILD SUCCEEDED"))
        XCTAssertEqual(record.remoteMetadata["run_id"], "400")
        XCTAssertEqual(record.remoteMetadata["run_number"], "12")
        XCTAssertEqual(record.remoteJobs.first?.jobID, 501)
        XCTAssertEqual(record.remoteJobs.first?.name, "Compile App")
        XCTAssertEqual(record.remoteJobs.first?.logCommand, "gh run view --job 501 --log --repo 'Owner/Repo'")
        XCTAssertEqual(record.remoteArtifacts.first?.artifactID, 601)
        XCTAssertEqual(record.remoteArtifacts.first?.name, "Build Logs")
    }

    func testArtifactRequiresHashAndStructuralVerification() async {
        let b64: (String) -> String = { Data($0.utf8).base64EncodedString() }
        let tagged = [
            "EXISTS=" + b64("1"),
            "SIZE=" + b64("123"),
            "SHA256=" + b64(String(repeating: "a", count: 64)),
            "ENTRY_COUNT=" + b64("2"),
            "ENTRY=" + b64("Payload/App.app/Info.plist"),
            "ENTRY=" + b64("Payload/App.app/App"),
            "FILE_INFO=" + b64("App: Mach-O 64-bit executable arm64"),
            "CAP=" + b64("archive|verified|unzip"),
        ].joined(separator: "\n")
        let result = await ArtifactVerifier.verify(path: "/tmp/App.ipa", requestedKind: .ipa) { _, _ in
            BuildShellResult(output: tagged, exitCode: 0)
        }
        XCTAssertEqual(result.state, .available)
        XCTAssertEqual(result.architectures, ["arm64"])
        XCTAssertEqual(result.archiveEntryCount, 2)
    }

    func testEmbeddedProjectSnapshotBuildsDeterministicallyAndScansLocalHeaders() throws {
        let files = [
            "src/main.c": "#include \"value.h\"\nint main_value(void) { return 7; }\n",
            "src/value.h": "#include \"nested.h\"\nint value(void);\n",
            "src/nested.h": "int nested(void);\n"
        ]
        let snapshot = try EmbeddedToolchainProjectSnapshotBuilder.build(files: files, entrySources: ["src/main.c"])
        XCTAssertEqual(snapshot.schema, 1)
        XCTAssertEqual(snapshot.entrySources, ["src/main.c"])
        XCTAssertEqual(snapshot.dependencies["src/main.c"], ["src/value.h"])
        XCTAssertEqual(snapshot.dependencies["src/value.h"], ["src/nested.h"])
        XCTAssertEqual(snapshot.files.map(\.path), ["src/main.c", "src/nested.h", "src/value.h"])
        XCTAssertEqual(snapshot.totalBytes, files.values.reduce(0) { $0 + $1.utf8.count })
        XCTAssertEqual(EmbeddedToolchainProjectSnapshotBuilder.materializedFiles(snapshot), files)
        let reversed = try EmbeddedToolchainProjectSnapshotBuilder.build(
            files: Dictionary(uniqueKeysWithValues: files.reversed()), entrySources: ["src/main.c"])
        XCTAssertEqual(snapshot, reversed)
        XCTAssertEqual(snapshot.fingerprint, reversed.fingerprint)
    }

    func testEmbeddedProjectSnapshotRejectsUnsafeOrUnsupportedInputs() throws {
        let valid = ["main.c": "#include \"value.h\"\nint main_value(void) { return 1; }\n",
                     "value.h": "int value(void);\n"]
        for (name, files) in [
            ("absolute", ["/main.c": "int x;" ]),
            ("traversal", ["../main.c": "int x;" ]),
            ("symlink-like", ["dir//main.c": "int x;" ]),
            ("uppercase-extension", ["main.C": "int x;" ]),
            ("unsupported-extension", ["main.cpp": "int x;" ]),
            ("non-ASCII", ["main.c": "int café;" ]),
            ("escaped-include", ["main.c": "#include \"../value.h\"\nint x;", "value.h": "int x;" ]),
            ("system-include", ["main.c": "#include <stdio.h>\nint x;" ]),
            ("conditional", ["main.c": "#ifdef X\nint x;\n#endif\n"]),
            ("assembly", ["main.c": "__asm__(\"nop\");" ]),
            ("missing-header", ["main.c": "#include \"missing.h\"\nint x;" ])
        ] {
            XCTAssertThrowsError(try EmbeddedToolchainProjectSnapshotBuilder.build(files: files), name)
        }
        XCTAssertNoThrow(try EmbeddedToolchainProjectSnapshotBuilder.build(files: valid))
        XCTAssertThrowsError(try EmbeddedToolchainProjectSnapshotBuilder.build(files: valid, entrySources: ["value.h"]))
    }

    func testEmbeddedProjectSnapshotRejectsCyclesAndDepth() throws {
        let cycle = ["main.c": "#include \"a.h\"\nint x;", "a.h": "#include \"b.h\"\n", "b.h": "#include \"a.h\"\n"]
        XCTAssertThrowsError(try EmbeddedToolchainProjectSnapshotBuilder.build(files: cycle))
        var deep: [String: String] = ["main.c": "#include \"d0.h\"\nint x;"]
        for index in 0...EmbeddedToolchainProjectSnapshotBuilder.maxDependencyDepth {
            deep["d\(index).h"] = index == EmbeddedToolchainProjectSnapshotBuilder.maxDependencyDepth
                ? "int leaf;" : "#include \"d\(index + 1).h\"\n"
        }
        XCTAssertThrowsError(try EmbeddedToolchainProjectSnapshotBuilder.build(files: deep))
    }
}
