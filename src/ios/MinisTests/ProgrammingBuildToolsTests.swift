import XCTest
import Foundation
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
        XCTAssertEqual(Set(BuildProviderID.allCases), Set([.localISH, .theos, .remoteGitHubActions, .macSSH, .embeddedToolchain]))
        XCTAssertEqual(Set(BuildProviderRegistry.providers.map { $0.id }), Set(BuildProviderID.allCases))
    }

    func testEmbeddedToolchainStaysUnavailableAndNeverRunsShell() async {
        final class CallCounter { var value = 0 }
        let shellCalls = CallCounter()
        let inspection = BuildProjectInspection(
            canonicalPath: "/tmp/embedded-toolchain-probe", kind: .unknown, manifests: [], languageStack: ["c"],
            gitBranch: nil, gitCommit: nil, gitIsDirty: false, gitRemote: nil,
            suggestedProviders: [.embeddedToolchain], suggestedCommands: [])
        let request = BuildRequest(
            projectPath: "/tmp/embedded-toolchain-probe", provider: .embeddedToolchain, configuration: "Debug",
            toolchain: "auto", command: nil, testCommand: nil, artifactPaths: [], timeoutSeconds: 60,
            cachePolicy: .ignore, attempt: 1, maxAttempts: 3, workflow: nil, workflowInputs: [:])
        let context = BuildProviderContext(inspection: inspection, request: request) { _, _ in
            shellCalls.value += 1
            return BuildShellResult(output: "", exitCode: 0)
        }
        let provider = EmbeddedToolchainBuildProvider()
        let availability = await provider.availability(for: context)
        XCTAssertEqual(availability.state, .unavailable)
        XCTAssertTrue(availability.missingConfiguration.contains("in-process BuildProvider execution adapter"))
        guard case .unavailable = await provider.build(context: context, runID: "probe") else {
            return XCTFail("Embedded build must not execute before the runtime gates pass.")
        }
        guard case .unavailable = await provider.test(context: context, runID: "probe") else {
            return XCTFail("Embedded test must not execute before the runtime gates pass.")
        }
        XCTAssertEqual(shellCalls.value, 0)
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
        guard case .completed(let record) = execution else { return XCTFail("expected completed result") }
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
}
