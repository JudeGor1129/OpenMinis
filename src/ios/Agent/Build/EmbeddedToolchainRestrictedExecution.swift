import Foundation

/// Verification-only execution seam for a validated immutable request.
/// It returns adapter evidence and deliberately has no output publication verb.
struct EmbeddedToolchainRestrictedExecutionReport: Sendable {
    let requestFingerprint: String
    let adapter: EmbeddedAdapterResult
    let outputFilesPublished: Bool
    let outputExecutionAttempted: Bool
    let providerExecutable: Bool
    let dylibCaptureRequested: Bool
    let dylibData: Data?
    let verifiedArtifact: EmbeddedAdapterArtifact?

    var passed: Bool {
        let captureVerified = !dylibCaptureRequested || (dylibData != nil && verifiedArtifact != nil)
        return adapter.passed && !outputFilesPublished && !outputExecutionAttempted &&
            !providerExecutable && captureVerified
    }
}

enum EmbeddedToolchainRestrictedExecutionError: Error, Equatable, LocalizedError, Sendable {
    case publicationNotSupported
    case invalidRequest(String)

    var errorDescription: String? {
        switch self {
        case .publicationNotSupported: return "restricted verification never publishes generated files"
        case .invalidRequest(let detail): return "restricted request is invalid: \(detail)"
        }
    }
}

/// This type is intentionally not a BuildProvider. Its only output is a
/// structured, cleanup-backed validation report. A later reviewed product
/// delivery layer may consume that report, but it must not bypass this seam.
final class EmbeddedToolchainRestrictedExecutor: @unchecked Sendable {
    static let shared = EmbeddedToolchainRestrictedExecutor()
    private let adapter: EmbeddedToolchainExecutionAdapter

    init(adapter: EmbeddedToolchainExecutionAdapter = .shared) {
        self.adapter = adapter
    }

    func execute(_ request: EmbeddedToolchainRestrictedRequest,
                 captureVerifiedDylib: Bool = false,
                 cancellation: EmbeddedAdapterCancellation = EmbeddedAdapterCancellation()) async
        -> EmbeddedToolchainRestrictedExecutionReport {
        let result = await adapter.execute(sources: request.sources,
                                           operations: request.operations,
                                           captureDylib: captureVerifiedDylib,
                                           cancellation: cancellation)
        return EmbeddedToolchainRestrictedExecutionReport(
            requestFingerprint: request.snapshotFingerprint,
            adapter: result,
            outputFilesPublished: false,
            outputExecutionAttempted: result.outputExecutionAttempted,
            providerExecutable: result.providerExecutable,
            dylibCaptureRequested: captureVerifiedDylib,
            dylibData: result.capturedDylibData,
            verifiedArtifact: captureVerifiedDylib ? result.artifacts.first(where: {
                $0.filetype == 6 && $0.name == request.outputName &&
                $0.bytes == result.capturedDylibData?.count &&
                $0.sha256 == result.capturedDylibData.map(EmbeddedAdapterArtifact.digest)
            }) : nil
        )
    }
}
