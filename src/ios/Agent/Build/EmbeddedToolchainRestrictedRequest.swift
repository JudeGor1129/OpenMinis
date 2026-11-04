import Foundation
import CryptoKit

/// The only request shape the future project adapter may receive. It contains
/// immutable source bytes and typed operations, never a root path or raw argv.
struct EmbeddedToolchainRestrictedRequest: Equatable, Sendable {
    let snapshotFingerprint: String
    let sources: [String: String]
    let operations: [EmbeddedToolchainOperation]
    let sourceFingerprints: [String: String]
    let outputName: String
    /// Immutable target metadata bound to the validated project plan. The
    /// dual-target order is canonical: arm64 first, then arm64e.
    let targetArchitectures: [EmbeddedToolchainArchitecture]

    fileprivate init(snapshotFingerprint: String, sources: [String: String],
                     operations: [EmbeddedToolchainOperation], sourceFingerprints: [String: String],
                     outputName: String, targetArchitectures: [EmbeddedToolchainArchitecture]) {
        self.snapshotFingerprint = snapshotFingerprint
        self.sources = sources
        self.operations = operations
        self.sourceFingerprints = sourceFingerprints
        self.outputName = outputName
        self.targetArchitectures = targetArchitectures
    }
}

enum EmbeddedToolchainRestrictedRequestError: Error, Equatable, LocalizedError, Sendable {
    case emptySources
    case sourceCountExceeded
    case sourceNameMismatch(String)
    case sourceFingerprintMismatch(String)
    case snapshotMismatch
    case duplicateOutput(String)
    case invalidOperation(String)
    case invalidOutputName
    case invalidTargetArchitectures
    case linkMustBeLast
    case linkObjectMismatch

    var errorDescription: String? {
        switch self {
        case .emptySources: return "restricted request has no materialized sources"
        case .sourceCountExceeded: return "restricted request source count exceeds the adapter budget"
        case .sourceNameMismatch(let name): return "operation names a source not present in the request: \(name)"
        case .sourceFingerprintMismatch(let name): return "materialized source fingerprint mismatch: \(name)"
        case .snapshotMismatch: return "materialized plan does not match its validated snapshot"
        case .duplicateOutput(let name): return "restricted request reuses an output name: \(name)"
        case .invalidOperation(let detail): return "invalid restricted operation: \(detail)"
        case .invalidOutputName: return "restricted request output name is unsafe"
        case .invalidTargetArchitectures: return "restricted request target architectures are not canonical"
        case .linkMustBeLast: return "link operation must be the final operation"
        case .linkObjectMismatch: return "link objects do not match preceding compile outputs"
        }
    }
}

enum EmbeddedToolchainRestrictedRequestBuilder {
    static let maxSources = 4
    static let maxOperations = 6

    static func make(snapshot: EmbeddedToolchainProjectSnapshot,
                     plan: EmbeddedToolchainMaterializedPlan,
                     targetArchitectures: [EmbeddedToolchainArchitecture] = [.arm64]) throws -> EmbeddedToolchainRestrictedRequest {
        let request = try validate(plan, targetArchitectures: targetArchitectures)
        guard try EmbeddedToolchainProjectMaterializer.plan(snapshot: snapshot, outputName: plan.outputName) == plan else {
            throw EmbeddedToolchainRestrictedRequestError.snapshotMismatch
        }
        return request
    }

    /// Only make(snapshot:plan:) may create a request. A self-signed plan or
    /// decoded diagnostic cannot replace the validated immutable snapshot.
    private static func validate(_ plan: EmbeddedToolchainMaterializedPlan,
                                 targetArchitectures: [EmbeddedToolchainArchitecture]) throws -> EmbeddedToolchainRestrictedRequest {
        guard targetArchitectures == [.arm64] || targetArchitectures == [.arm64, .arm64e] else {
            throw EmbeddedToolchainRestrictedRequestError.invalidTargetArchitectures
        }
        let sources = plan.sources
        guard !sources.isEmpty else { throw EmbeddedToolchainRestrictedRequestError.emptySources }
        guard sources.count <= maxSources else { throw EmbeddedToolchainRestrictedRequestError.sourceCountExceeded }
        guard plan.operations.count <= maxOperations else { throw EmbeddedToolchainRestrictedRequestError.invalidOperation("operation count") }
        guard safeDylibName(plan.outputName) else { throw EmbeddedToolchainRestrictedRequestError.invalidOutputName }
        guard Set(plan.sourceFingerprints.keys) == Set(sources.keys),
              plan.snapshotFingerprint.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else {
            throw EmbeddedToolchainRestrictedRequestError.sourceFingerprintMismatch("snapshot")
        }

        for (name, contents) in sources {
            guard safeSourceName(name),
                  name.hasSuffix(".c") || name.hasSuffix(".m") else {
                throw EmbeddedToolchainRestrictedRequestError.sourceNameMismatch(name)
            }
            guard let data = contents.data(using: .ascii), data.count > 0,
                  data.count <= EmbeddedToolchainProjectMaterializer.maxMaterializedSourceBytes,
                  plan.sourceFingerprints[name] == digest(data) else {
                throw EmbeddedToolchainRestrictedRequestError.sourceFingerprintMismatch(name)
            }
        }

        var compiled: [String] = []
        var compiledSources: Set<String> = []
        var outputs: Set<String> = []
        for (index, operation) in plan.operations.enumerated() {
            switch operation {
            case let .compile(source, output, language):
                guard index < plan.operations.count - 1 || plan.operations.count == 1 else {
                    throw EmbeddedToolchainRestrictedRequestError.linkMustBeLast
                }
                guard sources[source] != nil,
                      source.hasSuffix(language == .c ? ".c" : ".m"),
                      output.hasSuffix(".o"), safeObjectName(output),
                      compiledSources.insert(source).inserted, !outputs.contains(output) else {
                    throw EmbeddedToolchainRestrictedRequestError.invalidOperation("compile input/output")
                }
                outputs.insert(output); compiled.append(output)
            case let .link(objects, output, installName):
                guard index == plan.operations.count - 1 else { throw EmbeddedToolchainRestrictedRequestError.linkMustBeLast }
                guard objects == compiled, output == plan.outputName,
                      installName == "@rpath/" + output,
                      safeDylibName(output) else {
                    throw EmbeddedToolchainRestrictedRequestError.linkObjectMismatch
                }
                outputs.insert(output)
            }
        }
        guard compiledSources == Set(sources.keys),
              plan.operations.contains(where: { if case .link = $0 { return true }; return false }) else {
            throw EmbeddedToolchainRestrictedRequestError.invalidOperation("missing link or unmatched source")
        }
        return EmbeddedToolchainRestrictedRequest(
            snapshotFingerprint: plan.snapshotFingerprint,
            sources: sources,
            operations: plan.operations,
            sourceFingerprints: plan.sourceFingerprints,
            outputName: plan.outputName,
            targetArchitectures: targetArchitectures
        )
    }

    private static func safeSourceName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\\.(c|m)$", options: .regularExpression) != nil
    }

    private static func safeObjectName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\\.o$", options: .regularExpression) != nil
    }

    private static func safeDylibName(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\\.dylib$", options: .regularExpression) != nil
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
