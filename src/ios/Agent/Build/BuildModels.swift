import Foundation

// MARK: - Programming build domain

enum BuildProviderID: String, Codable, CaseIterable, Sendable {
    case localISH = "local_ish"
    case theos = "theos"
    case remoteGitHubActions = "remote_github_actions"
    case macSSH = "mac_ssh"
    case embeddedToolchain = "embedded_toolchain"
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
}

enum BuildProviderExecution {
    case completed(BuildCommandExecution)
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
