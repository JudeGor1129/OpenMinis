import Foundation

// BuildModels, ProgrammingBuildTools and all extracted declarations are actual
// production source. Only registry, SQLite, detector and verifier are spies.
private struct ContractFailure: Error, CustomStringConvertible { let description: String }
@MainActor
private enum Spy {
    static var events: [String] = []
    static var workspace: URL?
    static var selected: BuildProviderID = .embeddedTheos
    static var fail = false
    static let artifactPath = "/var/minis/workspace/smoke/build/minis-embedded/fixture.deb"
    static func reset(_ id: BuildProviderID, _ root: URL?) {
        events = []; selected = id; workspace = root; fail = false
    }
    static func validate(_ context: BuildProviderContext) throws {
        guard context.nativeWorkspaceRoot == workspace, context.nativeWorkspaceRoot != nil else {
            throw EmbeddedAdapterError.rejected("native workspace URL was lost or missing")
        }
        let kind: ProjectBuildKind = selected == .embeddedTheos ? .theos : .embeddedTweak
        let manifests = selected == .embeddedTheos ? ["./Makefile", "./control"] : ["./MinisTweak.json"]
        guard context.inspection.kind == kind, context.inspection.manifests == manifests,
              context.inspection.suggestedProviders == [selected] else {
            throw ContractFailure(description: "native descriptor changed kind/provider/manifests")
        }
    }
}
@MainActor
private struct SpyProvider: BuildProvider {
    let id: BuildProviderID
    func availability(for context: BuildProviderContext) async -> BuildProviderAvailability {
        Spy.events.append("probe:\(id.rawValue)")
        do {
            try Spy.validate(context)
            return .init(provider: id, state: .available, reason: "spy only", missingConfiguration: [], capabilities: [])
        } catch {
            return .init(provider: id, state: .unavailable, reason: error.localizedDescription,
                         missingConfiguration: ["workspace"], capabilities: [])
        }
    }
    func resolvedToolchain(for context: BuildProviderContext) async -> String {
        Spy.events.append("toolchain:\(id.rawValue)")
        do { try Spy.validate(context) } catch { return error.localizedDescription }
        return "spy-toolchain"
    }
    func build(context: BuildProviderContext, runID: String) async -> BuildProviderExecution {
        Spy.events.append("build:\(id.rawValue)")
        do { try Spy.validate(context) } catch {
            return .unavailable(.init(provider: id, state: .unavailable, reason: error.localizedDescription,
                                      missingConfiguration: [], capabilities: []))
        }
        let execution = BuildCommandExecution(command: "spy, NOT native compilation", exitCode: Spy.fail ? 1 : 0,
            durationSeconds: 0, stdoutSummary: "fixture", stderrSummary: "", fullLogPath: "", diagnosticExcerpt: "",
            remoteMetadata: [:], remoteJobs: [], remoteArtifacts: [])
        // No file exists: this synthetic evidence only exercises the artifact
        // branch. No real build, compiler, hash, publication or delivery is claimed.
        let artifact = ArtifactVerificationResult(path: Spy.artifactPath, kind: .deb, state: .available, exists: true,
            sizeBytes: 1, sha256: "spy-only", archiveEntries: [], archiveEntryCount: 0, architectures: [],
            encryption: nil, signature: nil, debControl: [:], rootlessPaths: nil, rootlessViolations: [],
            capabilities: [], errors: [])
        return .completedWithArtifacts(execution, [artifact])
    }
    func test(context: BuildProviderContext, runID: String) async -> BuildProviderExecution {
        Spy.events.append("tests:\(id.rawValue)")
        do { try Spy.validate(context) } catch {
            return .unavailable(.init(provider: id, state: .unavailable, reason: error.localizedDescription,
                                      missingConfiguration: [], capabilities: []))
        }
        return .unavailable(.init(provider: id, state: .unavailable, reason: "no generated-code execution",
                                  missingConfiguration: [], capabilities: []))
    }
}
@MainActor
enum BuildProviderRegistry {
    static var providers: [any BuildProvider] { BuildProviderID.allCases.map { SpyProvider(id: $0) } }
    static func provider(_ id: BuildProviderID) -> (any BuildProvider)? { SpyProvider(id: id) }
}
@MainActor
enum BuildProjectDetector {
    static func inspect(path: String, executor: @escaping BuildShellExecutor) async throws -> BuildProjectInspection {
        Spy.events.append("shell-inspection")
        _ = try await executor("unexpected-shell-inspection", 1)
        throw ContractFailure(description: "native request fell through to shell inspection")
    }
}
@MainActor
enum ArtifactVerifier {
    static func verify(path: String, requestedKind: ArtifactKind?, executor: @escaping BuildShellExecutor) async -> ArtifactVerificationResult {
        Spy.events.append("shell-artifact-verification")
        return .init(path: path, kind: .deb, state: .invalid, exists: false, sizeBytes: nil, sha256: nil,
            archiveEntries: [], archiveEntryCount: 0, architectures: [], encryption: nil, signature: nil,
            debControl: [:], rootlessPaths: nil, rootlessViolations: [], capabilities: [], errors: ["unexpected verifier"])
    }
}
enum BuildLogAnalyzer {
    static func analyze(_ text: String) -> BuildLogAnalysis {
        .init(diagnostics: [], firstError: nil, errorCount: 0, warningCount: 0, truncated: false)
    }
}
actor BuildRunStore {
    static let shared = BuildRunStore()
    func insert(_ row: PersistedBuildRun) throws {
        guard let json = row.resultJSON.data(using: .utf8) else { throw ContractFailure(description: "result missing") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        _ = try decoder.decode(BuildToolResult.self, from: json)
    }
    func cachedSuccess(fingerprint: String, provider: BuildProviderID) throws -> CachedBuildRun? {
        throw ContractFailure(description: "native request consulted command cache")
    }
}
@main
@MainActor
struct NativeEntryContracts {
    private static var checks = 0
    private static func require(_ condition: Bool, _ message: String) throws {
        checks += 1
        if !condition { throw ContractFailure(description: message) }
    }
    private static func request(_ id: BuildProviderID) -> BuildRequest {
        .init(projectPath: "/var/minis/workspace/smoke", provider: id, configuration: "Release", toolchain: "auto",
            command: nil, testCommand: nil, artifactPaths: [Spy.artifactPath], timeoutSeconds: 30,
            cachePolicy: .use, attempt: 1, maxAttempts: 3, workflow: nil, workflowInputs: [:])
    }
    private static let noShell: BuildShellExecutor = { _, _ in
        Spy.events.append("shell-execution")
        throw ContractFailure(description: "native request invoked shell")
    }
    static func main() async throws {
        try testTargetAndParser()
        try testLocalizedErrors()
        try await testNativeWorkspaceRouting()
        print("PASS: \(checks) actual entry/target/parser/error contracts (spies only; no LLVM/publication/output execution)")
    }
    private static func testNativeWorkspaceRouting() async throws {
        let workspace = URL(fileURLWithPath: "/tmp/native-entry-workspace", isDirectory: true)
        for id in [BuildProviderID.embeddedTheos, .embeddedToolchain] {
            Spy.reset(id, workspace)
            let build = try await ProgrammingBuildTools.shared.build(request: request(id), executor: noShell,
                                                                      nativeWorkspaceRoot: workspace)
            try require(build.buildState == .success, "spy build failed: \(id)")
            try require(build.persistenceError == nil, "encoded result did not persist")
            try require(build.selectedProvider == id && build.providerAvailability.count == 1, "probed unrelated providers")
            try require(build.artifacts.count == 1 && build.artifacts[0].path == Spy.artifactPath,
                        "native artifact replaced by shell verification")
            try require(!build.cacheHit, "native build reused command cache")
            try require(Spy.events == ["probe:\(id.rawValue)", "toolchain:\(id.rawValue)", "build:\(id.rawValue)"],
                        "workspace or provider route mismatch: \(Spy.events)")
            Spy.reset(id, workspace)
            let tests = try await ProgrammingBuildTools.shared.runTests(request: request(id), executor: noShell,
                                                                        nativeWorkspaceRoot: workspace)
            try require(tests.state == .unavailable && tests.execution == nil, "native tests must not claim passed")
            try require(Spy.events == ["probe:\(id.rawValue)", "tests:\(id.rawValue)"], "tests lost native workspace")
            Spy.reset(id, nil)
            let missing = try await ProgrammingBuildTools.shared.build(request: request(id), executor: noShell)
            try require(missing.buildState == .unavailable && missing.build == nil && missing.artifacts.isEmpty,
                        "missing workspace treated as success")
            try require(missing.checkpoint.nextActions.joined().contains("native workspace URL was lost or missing"),
                        "localized workspace error lost its detail")
            try require(Spy.events == ["probe:\(id.rawValue)"], "missing workspace triggered shell fallback")
            Spy.reset(id, workspace)
            Spy.fail = true
            let failed = try await ProgrammingBuildTools.shared.build(request: request(id), executor: noShell,
                                                                       nativeWorkspaceRoot: workspace)
            try require(failed.buildState == .failed && failed.build?.exitCode == 1, "nonzero exit reported success")
        }
        try require(BuildProviderID.allCases.filter(\.isNativeEmbedded) == [.embeddedToolchain, .embeddedTheos],
                    "native provider classification drifted")
    }
    private static func target(_ installName: String?, kind: EmbeddedTheosTargetKind = .tweak,
                               name: String = "MinisSmoke", source: String = "Smoke.m") -> EmbeddedTheosTarget {
        .init(name: name, kind: kind, sourcePaths: [source], headerPaths: ["Shared.h"], frameworks: ["Foundation"],
              installPath: kind == .tweak ? "Library/MobileSubstrate/DynamicLibraries/MinisSmoke.dylib" : "usr/libexec/MinisSmoke",
              installName: installName, filterPlistPath: kind == .tweak ? "MinisSmoke.plist" : nil,
              entitlementsPath: nil, architectures: [.arm64, .arm64e])
    }
    private static func rejects(_ candidate: EmbeddedTheosTarget) throws {
        do { try candidate.validate() } catch { try require(true, "rejected target"); return }
        try require(false, "invalid target accepted: \(candidate.installName ?? "nil")")
    }
    private static func testTargetAndParser() throws {
        try target("@rpath/MinisSmoke.dylib").validate()
        try require(true, "normal dylib install name must validate")
        for name in [nil, "@rpath/MinisSmoke", "@rpath/Other.dylib", "@rpath/../MinisSmoke.dylib",
                     "@rpath//MinisSmoke.dylib", "/tmp/MinisSmoke.dylib", "@loader_path/MinisSmoke.dylib",
                     "@rpath/MinisSmoke.dylib\n", "@rpath/MinisSmoke.dylib\0"] as [String?] {
            try rejects(target(name))
        }
        try target(nil, kind: .daemon).validate()
        try require(true, "daemon validates without LC_ID_DYLIB")
        try rejects(target("@rpath/MinisSmoke.dylib", kind: .daemon))
        try rejects(target("@rpath/MinisSmoke.dylib", name: "MinisSmoke\n"))
        for source in ["../Smoke.m", "src//Smoke.m", "src/./Smoke.m", "src/Smoke.m/", "Smoke.m\0", "\\Smoke.m"] {
            try rejects(target("@rpath/MinisSmoke.dylib", source: source))
        }
        let makefile = """
        ARCHS = arm64 arm64e
        THEOS_PACKAGE_SCHEME = rootless
        TWEAK_NAME = MinisSmoke
        MinisSmoke_FILES = Smoke.m Helper.c Shared.h
        MinisSmoke_FRAMEWORKS = Foundation
        include $(THEOS)/makefiles/common.mk
        include $(THEOS_MAKE_PATH)/tweak.mk
        """
        let graph = try EmbeddedTheosManifestParser.inspect(makefile: makefile)
        try require(graph.targets.count == 1 && graph.targets[0].kind == .tweak, "smoke parser failed")
        try require(graph.targets[0].sourcePaths == ["Smoke.m", "Helper.c"] && graph.targets[0].headerPaths == ["Shared.h"],
                    "parser lost smoke files")
        try require(graph.targets[0].installName == "@rpath/MinisSmoke.dylib", "parser changed installation name")
        try require(graph.ignoredRecipes.isEmpty, "smoke unexpectedly contains recipes")
        let architectureCases: [(String, [EmbeddedToolchainArchitecture])] = [
            ("arm64", [.arm64]), ("arm64e", [.arm64e]),
            ("arm64 arm64e", [.arm64, .arm64e]), ("arm64e arm64", [.arm64, .arm64e])
        ]
        for (declaration, expected) in architectureCases {
            let input = makefile.replacingOccurrences(of: "ARCHS = arm64 arm64e", with: "ARCHS = " + declaration)
            let result = try EmbeddedTheosManifestParser.inspect(makefile: input)
            try require(result.targets[0].architectures == expected, "parser lost ARCHS: " + declaration)
            try result.targets[0].validate()
        }
        let defaultGraph = try EmbeddedTheosManifestParser.inspect(makefile:
            makefile.replacingOccurrences(of: "ARCHS = arm64 arm64e", with: ""))
        try require(defaultGraph.targets[0].architectures == [.arm64, .arm64e], "missing ARCHS changed legacy default")
        let overrideGraph = try EmbeddedTheosManifestParser.inspect(makefile: makefile + "\nMinisSmoke_ARCHS = arm64e\n")
        try require(overrideGraph.targets[0].architectures == [.arm64e], "target ARCHS did not override global ARCHS")
        for declaration in ["", "armv7", "arm64 armv7", "arm64 arm64", "arm64e arm64e", "$(ARCHS)"] {
            let input = makefile.replacingOccurrences(of: "ARCHS = arm64 arm64e", with: "ARCHS = " + declaration)
            do {
                _ = try EmbeddedTheosManifestParser.inspect(makefile: input)
            } catch is EmbeddedTheosManifestError {
                try require(true, "invalid ARCHS rejected")
                continue
            }
            try require(false, "invalid ARCHS accepted: " + declaration)
        }
    }
    private static func testLocalizedErrors() throws {
        for error in [EmbeddedAdapterError.rejected("no native workspace"), .poisoned("Mach-O signature mismatch")] {
            let detail = error.errorDescription ?? ""
            try require(!detail.isEmpty && error.localizedDescription == detail, "localized error lost associated message")
            try require((error as NSError).localizedDescription == detail, "NSError bridge erased detail")
        }
    }
}
