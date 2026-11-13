import Foundation

// MARK: - Programming build domain

enum BuildProviderID: String, Codable, CaseIterable, Sendable {
    case localISH = "local_ish"
    case theos = "theos"
    case remoteGitHubActions = "remote_github_actions"
    case macSSH = "mac_ssh"
    case embeddedToolchain = "embedded_toolchain"
    case embeddedTheos = "embedded_theos"

    /// Both native providers require a session URL and must bypass shell probes,
    /// shell artifact verification, and command-build cache reuse.
    var isNativeEmbedded: Bool {
        self == .embeddedToolchain || self == .embeddedTheos
    }
}

enum BuildAvailabilityState: String, Codable, Sendable {
    case available
    case unavailable
}

struct BuildProviderAvailability: Codable, Equatable, Sendable {
    let provider: BuildProviderID
    let state: BuildAvailabilityState
    let reason: String
    let missingConfiguration: [String]
    let capabilities: [String]

    var isAvailable: Bool { state == .available }
}

enum ProjectBuildKind: String, Codable, Sendable {
    case xcode
    case swiftPackage = "swift_package"
    case theos
    case embeddedTweak = "embedded_tweak"
    case gradle
    case cargo
    case cmake
    case make
    case node
    case mixed
    case unknown
}

struct SuggestedBuildCommand: Codable, Equatable, Sendable {
    let provider: BuildProviderID
    let purpose: String
    let command: String
}

struct BuildProjectInspection: Codable, Equatable, Sendable {
    let canonicalPath: String
    let kind: ProjectBuildKind
    let manifests: [String]
    let languageStack: [String]
    let gitBranch: String?
    let gitCommit: String?
    let gitIsDirty: Bool
    let gitRemote: String?
    let suggestedProviders: [BuildProviderID]
    let suggestedCommands: [SuggestedBuildCommand]
}

// Declarative target graph accepted by the future Twork-level in-process Theos adapter.
// It carries no shell recipes and never represents executable package hooks.
enum EmbeddedTheosTargetKind: String, Codable, Equatable, Sendable {
    case daemon
    case tweak
}

struct EmbeddedTheosTarget: Codable, Equatable, Sendable {
    let name: String
    let kind: EmbeddedTheosTargetKind
    let sourcePaths: [String]
    let headerPaths: [String]
    let frameworks: [String]
    let installPath: String
    let installName: String?
    let filterPlistPath: String?
    let entitlementsPath: String?
    let architectures: [EmbeddedToolchainArchitecture]

    var rootlessInstallName: String? {
        kind == .tweak ? "/var/jb/" + installPath : nil
    }

    func validate() throws {
        func safeName(_ value: String) -> Bool {
            guard let range = value.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) else { return false }
            return range == value.startIndex..<value.endIndex
        }
        func safeRelative(_ value: String) -> Bool {
            !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") && !value.contains("\0") &&
                value.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
                    !$0.isEmpty && $0 != "." && $0 != ".."
                }
        }
        guard safeName(name), !sourcePaths.isEmpty, sourcePaths.count <= 128,
              headerPaths.count <= 256, frameworks.count <= 32,
              sourcePaths.allSatisfy(safeRelative), headerPaths.allSatisfy(safeRelative),
              frameworks.allSatisfy(safeName), safeRelative(installPath),
              (architectures == [.arm64] || architectures == [.arm64e] ||
               architectures == [.arm64, .arm64e]) else {
            throw EmbeddedTheosPlanError.invalidTarget(name)
        }
        // Keep the dylib ID bound to the exact safe relative payload path.
        if kind == .tweak {
            let installParts = installPath.split(separator: "/", omittingEmptySubsequences: false)
            let safeDirectories = installParts.dropLast().allSatisfy { part in
                let component = String(part)
                guard let range = component.range(of: "^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$",
                                                  options: .regularExpression) else { return false }
                return range == component.startIndex..<component.endIndex
            }
            let safeInstallPath = installPath.utf8.count <= 192 &&
                installParts.count <= 8 && safeDirectories &&
                (installPath == "\(name).dylib" || installPath.hasSuffix("/\(name).dylib"))
            guard safeInstallPath, installName == rootlessInstallName else {
                throw EmbeddedTheosPlanError.invalidInstallName(name)
            }
        } else if installName != nil {
            throw EmbeddedTheosPlanError.invalidInstallName(name)
        }
        for optionalPath in [filterPlistPath, entitlementsPath].compactMap({ $0 }) {
            guard safeRelative(optionalPath) else { throw EmbeddedTheosPlanError.invalidTarget(name) }
        }
    }
}

struct EmbeddedTheosProjectPlan: Codable, Equatable, Sendable {
    let schema: Int
    let packageID: String
    let version: String
    let name: String
    let maintainer: String
    let description: String
    let bundleIDs: [String]
    let targets: [EmbeddedTheosTarget]

    func validate() throws {
        guard schema == 1, targets.count > 0, targets.count <= 8,
              packageID.range(of: "^[a-z0-9][a-z0-9+.-]{1,127}$", options: .regularExpression) != nil,
              version.range(of: "^[0-9][A-Za-z0-9.+~_-]{0,63}$", options: .regularExpression) != nil,
              !name.isEmpty, name.utf8.count <= 256,
              !maintainer.isEmpty, maintainer.utf8.count <= 256,
              !description.isEmpty, description.utf8.count <= 512,
              // Bundle filters only make sense for a SpringBoard tweak; a daemon-only
              // project legitimately declares none. A tweak project must declare them.
              bundleIDs.count <= 20,
              (!targets.contains { $0.kind == .tweak } || !bundleIDs.isEmpty),
              bundleIDs.allSatisfy({ $0.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$", options: .regularExpression) != nil }),
              Set(targets.map(\.name)).count == targets.count else {
            throw EmbeddedTheosPlanError.invalidPackage
        }
        for target in targets { try target.validate() }
        // A Theos project may ship only a tweak, only a daemon, or both. Requiring
        // both kinds used to reject every ordinary single-tweak tweak project.
        guard targets.contains(where: { $0.kind == .tweak }) ||
              targets.contains(where: { $0.kind == .daemon }) else {
            throw EmbeddedTheosPlanError.missingTargetKind
        }
    }
}

enum EmbeddedTheosPlanError: Error, Equatable, LocalizedError, Sendable {
    case invalidPackage
    case invalidTarget(String)
    case invalidInstallName(String)
    case missingTargetKind

    var errorDescription: String? {
        switch self {
        case .invalidPackage: return "Theos plan package metadata or target count is invalid"
        case .invalidTarget(let name): return "Theos target is invalid or outside the bounded policy: \(name)"
        case .invalidInstallName(let name): return "Theos target has an unsafe install name: \(name)"
        case .missingTargetKind: return "Theos plan must contain at least one daemon or tweak target"
        }
    }
}

enum EmbeddedTheosManifestParser {
    static let maxBytes = 128 * 1024
    static let maxLines = 4096

    struct Inspection: Equatable, Sendable {
        let targets: [EmbeddedTheosTarget]
        let ignoredRecipes: [String]
        var isComplete: Bool {
            targets.contains { $0.kind == .daemon } && targets.contains { $0.kind == .tweak }
        }
    }

    /// Declarative-only inspection: needs no package metadata and never executes
    /// the Makefile. It reports the exact target graph plus every recipe that was
    /// deliberately skipped, so a caller can list precise blockers.
    static func inspect(makefile: String) throws -> Inspection {
        guard makefile.utf8.count <= maxBytes else { throw EmbeddedTheosManifestError.unsafeDirective("Makefile exceeds byte budget") }
        var assignments: [String: String] = [:]
        var targetNames: [String] = []
        var toolName: String?
        var tweakName: String?
        var rootless = false
        let lines = makefile.components(separatedBy: .newlines)
        guard lines.count <= maxLines else { throw EmbeddedTheosManifestError.unsafeDirective("line budget") }

        for raw in lines {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            if line.hasPrefix("\t") || trimmed.hasSuffix("::") || trimmed.hasPrefix("before-") || trimmed.hasPrefix("after-") {
                // Recipes and package hooks are never executed. They are reported by
                // ignoredRecipes(in:) so the native packager must reimplement any
                // required staging (modes, ownership, plists) declaratively.
                continue
            }
            if trimmed.hasPrefix("include ") || trimmed.hasPrefix("-include ") {
                let include = trimmed.drop { $0 != " " }.trimmingCharacters(in: .whitespaces)
                let allowed = include.contains("$(THEOS)/makefiles/") || include.contains("$(THEOS_MAKE_PATH)/")
                guard allowed else { throw EmbeddedTheosManifestError.unsafeDirective(trimmed) }
                continue
            }
            if trimmed.hasPrefix("ifeq") || trimmed.hasPrefix("ifneq") || trimmed == "else" || trimmed == "endif" {
                continue
            }
            if trimmed.contains("$(shell") || trimmed.contains("`") || trimmed.contains("eval ") || trimmed.contains("\u{0}") {
                throw EmbeddedTheosManifestError.unsafeDirective(trimmed)
            }
            guard let equals = trimmed.firstIndex(of: "=") else {
                throw EmbeddedTheosManifestError.unsafeDirective(trimmed)
            }
            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: equals)...]).trimmingCharacters(in: .whitespaces)
            guard key.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil else {
                throw EmbeddedTheosManifestError.unsafeDirective(trimmed)
            }
            assignments[key] = value
            if key == "TOOL_NAME" { toolName = value }
            if key == "TWEAK_NAME" { tweakName = value }
            if key == "THEOS_PACKAGE_SCHEME" { rootless = value == "rootless" }
            if key.hasSuffix("_FILES") {
                let name = String(key.dropLast("_FILES".count))
                if !name.isEmpty && !targetNames.contains(name) { targetNames.append(name) }
            }
        }

        guard !targetNames.isEmpty else { throw EmbeddedTheosManifestError.noTargets }
        guard rootless else { throw EmbeddedTheosManifestError.unsafeDirective("THEOS_PACKAGE_SCHEME must be rootless") }
        var targets: [EmbeddedTheosTarget] = []
        for name in targetNames.sorted() {
            let requested = split(assignments[name + "_ARCHS"] ?? assignments["ARCHS"] ?? "arm64 arm64e")
            guard !requested.isEmpty, Set(requested).count == requested.count,
                  requested.allSatisfy({ $0 == "arm64" || $0 == "arm64e" }) else {
                throw EmbeddedTheosManifestError.unsafeDirective("unsupported or duplicate ARCHS for \(name)")
            }
            let architectures: [EmbeddedToolchainArchitecture] = [.arm64, .arm64e].filter {
                requested.contains($0.rawValue)
            }
            let files = split(assignments[name + "_FILES"] ?? "")
            let frameworks = split(assignments[name + "_FRAMEWORKS"] ?? "")
            let installPath = assignments[name + "_INSTALL_PATH"] ?? ""
            let kind: EmbeddedTheosTargetKind = (name == tweakName || installPath.contains("DynamicLibraries") || frameworks.contains("UIKit")) ? .tweak : .daemon
            let baseInstall = installPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let install: String
            if baseInstall.isEmpty {
                install = kind == .daemon ? "usr/libexec/\(name)" : "Library/MobileSubstrate/DynamicLibraries/\(name).dylib"
            } else if kind == .tweak {
                install = baseInstall.hasSuffix(".dylib") ? baseInstall : baseInstall + "/\(name).dylib"
            } else {
                install = baseInstall.hasSuffix("/\(name)") ? baseInstall : baseInstall + "/\(name)"
            }
            let codeSign = split(assignments[name + "_CODESIGN_FLAGS"] ?? "")
            let entitlements = codeSign.first(where: { $0.hasPrefix("-S") }).map { token in
                let path = String(token.dropFirst(2))
                return path.isEmpty ? "daemon/entitlements.plist" : path
            }
            let target = EmbeddedTheosTarget(name: name, kind: kind,
                sourcePaths: files.filter { !["h", "hh", "hpp"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) },
                headerPaths: files.filter { ["h", "hh", "hpp"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) },
                frameworks: frameworks, installPath: install,
                installName: kind == .tweak ? "/var/jb/\(install)" : nil,
                filterPlistPath: kind == .tweak ? "\(name).plist" : nil,
                entitlementsPath: entitlements, architectures: architectures)
            do { try target.validate() } catch { throw EmbeddedTheosManifestError.invalidTarget(name) }
            targets.append(target)
        }
        guard toolName != nil || tweakName != nil else { throw EmbeddedTheosManifestError.noTargets }
        return Inspection(targets: targets, ignoredRecipes: ignoredRecipes(in: makefile))
    }

    static func parse(makefile: String, metadata: EmbeddedDebMetadata) throws -> EmbeddedTheosProjectPlan {
        let inspection = try inspect(makefile: makefile)
        let plan = EmbeddedTheosProjectPlan(schema: 1, packageID: metadata.packageID,
            version: metadata.version, name: metadata.name, maintainer: metadata.maintainer,
            description: metadata.description, bundleIDs: metadata.bundleIDs, targets: inspection.targets)
        try plan.validate()
        return plan
    }

    private static func split(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
    }

    /// Recipe/staging lines that were deliberately not executed. The native
    /// packager must reimplement each one declaratively (file modes, ownership,
    /// plist placement) or report the package as unverified.
    static func ignoredRecipes(in makefile: String) -> [String] {
        makefile.components(separatedBy: .newlines).compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isRecipe = line.hasPrefix("\t")
            let isHook = trimmed.hasPrefix("before-") || trimmed.hasPrefix("after-") ||
                (trimmed.hasSuffix("::") && !trimmed.contains("="))
            guard isRecipe || isHook else { return nil }
            return trimmed.isEmpty ? nil : trimmed
        }
    }
}

enum EmbeddedTheosManifestError: Error, Equatable, LocalizedError, Sendable {
    case unsafeDirective(String)
    case unsupportedRecipe(String)
    case noTargets
    case invalidTarget(String)

    var errorDescription: String? {
        switch self {
        case .unsafeDirective(let detail): return "Theos manifest contains an unsafe directive: \(detail)"
        case .unsupportedRecipe(let detail): return "Theos package recipe is not allowed: \(detail)"
        case .noTargets: return "Theos manifest contains no supported targets"
        case .invalidTarget(let name): return "Theos target is invalid: \(name)"
        }
    }
}

enum BuildDiagnosticSeverity: String, Codable, Sendable {
    case note
    case warning
    case error
    case fatal
}

struct BuildDiagnostic: Codable, Hashable, Sendable {
    let file: String?
    let line: Int?
    let column: Int?
    let severity: BuildDiagnosticSeverity
    let message: String
    let tool: String
    let raw: String
}

struct BuildLogAnalysis: Codable, Sendable {
    let diagnostics: [BuildDiagnostic]
    let firstError: BuildDiagnostic?
    let errorCount: Int
    let warningCount: Int
    let truncated: Bool
}

enum ArtifactKind: String, Codable, CaseIterable, Sendable {
    case ipa
    case deb
    case macho
    case binary
    case unknown
}

enum ArtifactState: String, Codable, Sendable {
    /// Only emitted after existence, size, SHA-256 and kind-specific structural checks pass.
    case available
    case invalid
    case missing
}

enum VerificationCapabilityState: String, Codable, Sendable {
    case verified
    case failed
    case unavailable
    case notApplicable = "not_applicable"
}

struct VerificationCapability: Codable, Equatable, Sendable {
    let name: String
    let state: VerificationCapabilityState
    let detail: String
}

struct ArtifactVerificationResult: Codable, Equatable, Sendable {
    let path: String
    let kind: ArtifactKind
    let state: ArtifactState
    let exists: Bool
    let sizeBytes: Int64?
    let sha256: String?
    let archiveEntries: [String]
    let archiveEntryCount: Int
    let architectures: [String]
    let encryption: String?
    let signature: String?
    let debControl: [String: String]
    let rootlessPaths: Bool?
    let rootlessViolations: [String]
    let capabilities: [VerificationCapability]
    let errors: [String]
}

enum BuildState: String, Codable, Sendable {
    case success
    case failed
    case unavailable
    /// A remote dispatch is not a successful build until the remote job completes with exit 0.
    case queued
    case notRun = "not_run"
}

enum TestState: String, Codable, Sendable {
    case passed
    case failed
    case unavailable
    case notRun = "not_run"
}

enum BuildCachePolicy: String, Codable, Sendable {
    case use
    case refresh
    case ignore
}

struct RemoteArtifactMetadata: Codable, Equatable, Sendable {
    let artifactID: Int64
    let name: String
    let sizeBytes: Int64
    let expired: Bool
    let archiveDownloadURL: String
}

struct RemoteJobMetadata: Codable, Equatable, Sendable {
    let jobID: Int64
    let name: String
    let status: String
    let conclusion: String?
    let htmlURL: String
    let apiURL: String
    /// A command, not a guessed URL. Job logs are fetched only on explicit request.
    let logCommand: String
}

struct BuildCommandExecution: Codable, Equatable, Sendable {
    let command: String
    let exitCode: Int
    let durationSeconds: Double
    let stdoutSummary: String
    let stderrSummary: String
    let fullLogPath: String
    let diagnosticExcerpt: String
    let remoteMetadata: [String: String]
    let remoteJobs: [RemoteJobMetadata]
    let remoteArtifacts: [RemoteArtifactMetadata]
}

struct BuildRequest: Codable, Sendable {
    let projectPath: String
    let provider: BuildProviderID?
    let configuration: String
    let toolchain: String
    let command: String?
    let testCommand: String?
    let artifactPaths: [String]
    let timeoutSeconds: Int
    let cachePolicy: BuildCachePolicy
    let attempt: Int
    let maxAttempts: Int
    let workflow: String?
    let workflowInputs: [String: String]
}

struct BuildWorkflowCheckpoint: Codable, Sendable {
    let attempt: Int
    let maxAttempts: Int
    let stage: String
    let firstError: BuildDiagnostic?
    let nextActions: [String]
    let stopReason: String?
}

struct BuildToolResult: Codable, Sendable {
    let runID: String
    let project: BuildProjectInspection
    let providerAvailability: [BuildProviderAvailability]
    let selectedProvider: BuildProviderID?
    let cacheFingerprint: String
    let cacheHit: Bool
    let sourceRunID: String?
    let buildState: BuildState
    let testsState: TestState
    let build: BuildCommandExecution?
    let tests: BuildCommandExecution?
    let diagnostics: BuildLogAnalysis
    let artifacts: [ArtifactVerificationResult]
    let checkpoint: BuildWorkflowCheckpoint
    let persistenceError: String?
    let createdAt: Date
}

struct RunTestsResult: Codable, Sendable {
    let runID: String
    let project: BuildProjectInspection
    let providerAvailability: BuildProviderAvailability
    let state: TestState
    let execution: BuildCommandExecution?
    let diagnostics: BuildLogAnalysis
    let createdAt: Date
}

struct BuildShellResult: Sendable {
    let output: String
    let exitCode: Int
}

typealias BuildShellExecutor = @MainActor (_ command: String, _ timeout: TimeInterval) async throws -> BuildShellResult

struct BuildProviderContext {
    let inspection: BuildProjectInspection
    let request: BuildRequest
    let executor: BuildShellExecutor
    /// An App Group URL resolved from the active session workspace. It is never
    /// derived by the provider from an arbitrary guest path.
    let nativeWorkspaceRoot: URL?

    init(inspection: BuildProjectInspection, request: BuildRequest,
         executor: @escaping BuildShellExecutor, nativeWorkspaceRoot: URL? = nil) {
        self.inspection = inspection
        self.request = request
        self.executor = executor
        self.nativeWorkspaceRoot = nativeWorkspaceRoot
    }
}

enum BuildProviderExecution {
    case completed(BuildCommandExecution)
    case completedWithArtifacts(BuildCommandExecution, [ArtifactVerificationResult])
    case unavailable(BuildProviderAvailability)
}

extension JSONEncoder {
    static func programmingToolsEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
