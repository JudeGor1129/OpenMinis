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

/// The product-delivery seam remains separate from the generic BuildProvider:
/// it exposes only verified in-memory FAT/DEB bytes and never writes them.
struct EmbeddedToolchainUniversalDeliveryReport: Sendable {
    let requestFingerprint: String
    let adapterReports: [EmbeddedAdapterResult]
    let universalArtifact: EmbeddedUniversalArtifact?
    let debArtifact: EmbeddedDebArtifact?
    let universalData: Data?
    let debData: Data?
    let outputFilesPublished: Bool
    let outputExecutionAttempted: Bool
    let providerExecutable: Bool
    let reason: String

    var passed: Bool {
        adapterReports.count == 2 && adapterReports.allSatisfy(\.passed) &&
            universalArtifact != nil && universalData != nil &&
            debArtifact != nil && debData != nil &&
            !outputFilesPublished && !outputExecutionAttempted && !providerExecutable
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
        guard request.targetArchitectures == [.arm64] else {
            var result = EmbeddedAdapterResult()
            result.state = "rejected"
            result.reason = "single-target execution requires [arm64]"
            return EmbeddedToolchainRestrictedExecutionReport(
                requestFingerprint: request.snapshotFingerprint, adapter: result,
                outputFilesPublished: false, outputExecutionAttempted: false,
                providerExecutable: false, dylibCaptureRequested: captureVerifiedDylib,
                dylibData: nil, verifiedArtifact: nil)
        }
        let result = await adapter.execute(sources: request.sources,
                                           operations: request.operations,
                                           architecture: .arm64,
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
                $0.architecture == EmbeddedToolchainArchitecture.arm64.rawValue &&
                $0.bytes == result.capturedDylibData?.count &&
                $0.sha256 == result.capturedDylibData.map(EmbeddedAdapterArtifact.digest)
            }) : nil
        )
    }

    func executeUniversal(_ request: EmbeddedToolchainRestrictedRequest,
                          metadata: EmbeddedDebMetadata,
                          cancellation: EmbeddedAdapterCancellation = EmbeddedAdapterCancellation()) async
        -> EmbeddedToolchainUniversalDeliveryReport {
        func failed(_ reason: String, reports: [EmbeddedAdapterResult] = []) -> EmbeddedToolchainUniversalDeliveryReport {
            EmbeddedToolchainUniversalDeliveryReport(
                requestFingerprint: request.snapshotFingerprint, adapterReports: reports,
                universalArtifact: nil, debArtifact: nil, universalData: nil, debData: nil,
                outputFilesPublished: false, outputExecutionAttempted: false,
                providerExecutable: false, reason: reason)
        }
        guard request.targetArchitectures == [.arm64, .arm64e] else {
            return failed("universal execution requires canonical [arm64, arm64e] request metadata")
        }
        guard metadata.dylibName == request.outputName else {
            return failed("DEB tweak name must match the request output name")
        }
        do { try metadata.validate() }
        catch { return failed("invalid DEB metadata: \(error.localizedDescription)") }
        let result = await adapter.executeUniversal(sources: request.sources,
                                                    operations: request.operations,
                                                    cancellation: cancellation)
        guard result.passed, let universalData = result.data,
              let universalArtifact = result.artifact else {
            return failed(result.reason.isEmpty ? "universal adapter failed" : result.reason,
                          reports: result.reports)
        }
        do {
            let debData = try EmbeddedToolchainDebPackage.build(dylib: universalData,
                                                                metadata: metadata,
                                                                cancellation: cancellation)
            let debArtifact = try EmbeddedToolchainDebPackage.inspect(debData, metadata: metadata)
            return EmbeddedToolchainUniversalDeliveryReport(
                requestFingerprint: request.snapshotFingerprint,
                adapterReports: result.reports,
                universalArtifact: universalArtifact, debArtifact: debArtifact,
                universalData: universalData, debData: debData,
                outputFilesPublished: false, outputExecutionAttempted: false,
                providerExecutable: false, reason: "")
        } catch {
            return failed("DEB packaging failed: \(error.localizedDescription)", reports: result.reports)
        }
    }
}
