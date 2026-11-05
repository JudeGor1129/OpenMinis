import Foundation

// MARK: - Programming build domain

enum BuildProviderID: String, Codable, CaseIterable, Sendable {
    case localISH = "local_ish"
    case theos = "theos"
    case remoteGitHubActions = "remote_github_actions"
    case macSSH = "mac_ssh"
    case embeddedToolchain = "embedded_toolchain"
    case embeddedTheos = "embedded_theos"
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

    func validate() throws {
        func safeName(_ value: String) -> Bool {
            value.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil
        }
        func safeRelative(_ value: String) -> Bool {
            !value.isEmpty && !value.hasPrefix("/") && !value.contains("\\") &&
                !value.split(separator: "/").contains("..") &&
                value.split(separator: "/").allSatisfy { !$0.isEmpty && $0 != "." }
        }
        guard safeName(name), !sourcePaths.isEmpty, sourcePaths.count <= 128,
              headerPaths.count <= 256, frameworks.count <= 32,
              sourcePaths.allSatisfy(safeRelative), headerPaths.allSatisfy(safeRelative),
              frameworks.allSatisfy(safeName), safeRelative(installPath),
              architectures == [.arm64, .arm64e] else {
            throw EmbeddedTheosPlanError.invalidTarget(name)
        }
        if let installName {
            guard installName.hasPrefix("@rpath/"), safeName(String(installName.dropFirst(7))) else {
                throw EmbeddedTheosPlanError.invalidInstallName(name)
            }
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
              !bundleIDs.isEmpty, bundleIDs.count <= 20,
              bundleIDs.allSatisfy({ $0.range(of: "^[A-Za-z0-9][A-Za-z0-9.-]{0,254}$", options: .regularExpression) != nil }),
              Set(targets.map(\.name)).count == targets.count else {
            throw EmbeddedTheosPlanError.invalidPackage
        }
        for target in targets { try target.validate() }
        guard targets.contains(where: { $0.kind == .daemon }), targets.contains(where: { $0.kind == .tweak }) else {
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
        case .missingTargetKind: return "Theos plan must contain both daemon and tweak targets"
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
