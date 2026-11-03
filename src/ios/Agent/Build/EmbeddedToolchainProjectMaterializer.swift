import Foundation
import CryptoKit

/// Converts a validated immutable project snapshot into the adapter's first
/// operation shape. It never reads files, invokes a toolchain, or creates a
/// caller-visible output path. Header text is materialized into each entry
/// source in include order, preserving every unguarded repeated include.
struct EmbeddedToolchainMaterializedSource: Equatable, Sendable {
    let sourcePath: String
    let contents: String
    let sha256: String
}

struct EmbeddedToolchainMaterializedPlan: Equatable, Sendable {
    let sources: [String: String]
    let operations: [EmbeddedToolchainOperation]
    let sourceFingerprints: [String: String]
    let snapshotFingerprint: String
    let outputName: String
}

enum EmbeddedToolchainProjectMaterializerError: Error, Equatable, LocalizedError, Sendable {
    case missingEntry(String)
    case missingDependency(String)
    case duplicateEntry(String)
    case materializedSourceTooLarge(String)
    case sourceNameCollision(String)
    case noOperations

    var errorDescription: String? {
        switch self {
        case .missingEntry(let path): return "materializer entry source is missing: \(path)"
        case .missingDependency(let path): return "materializer dependency is missing: \(path)"
        case .duplicateEntry(let path): return "materializer received duplicate entry source: \(path)"
        case .materializedSourceTooLarge(let path): return "materialized source exceeds the adapter budget: \(path)"
        case .sourceNameCollision(let path): return "materialized source name collision: \(path)"
        case .noOperations: return "materializer produced no compile operations"
        }
    }
}

enum EmbeddedToolchainProjectMaterializer {
    static let maxMaterializedSourceBytes = EmbeddedToolchainProjectSnapshotBuilder.maxSourceBytes

    static func plan(snapshot: EmbeddedToolchainProjectSnapshot,
                     outputName: String = "project.dylib") throws -> EmbeddedToolchainMaterializedPlan {
        guard !snapshot.entrySources.isEmpty else { throw EmbeddedToolchainProjectMaterializerError.noOperations }
        let files = Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.path, $0) })
        var materialized: [String: String] = [:]
        var fingerprints: [String: String] = [:]

        for (index, entry) in snapshot.entrySources.sorted().enumerated() {
            guard let entryFile = files[entry] else {
                throw EmbeddedToolchainProjectMaterializerError.missingEntry(entry)
            }
            var parts: [String] = []
            var materializedBytes = 0
            try append(file: entryFile, files: files, parts: &parts,
                       materializedBytes: &materializedBytes)
            let text = parts.joined(separator: "\n")
            guard let data = text.data(using: .ascii), data.count <= maxMaterializedSourceBytes else {
                throw EmbeddedToolchainProjectMaterializerError.materializedSourceTooLarge(entry)
            }
            let output = "unit\(index)" + (entry.hasSuffix(".m") ? ".m" : ".c")
            guard materialized[output] == nil else {
                throw EmbeddedToolchainProjectMaterializerError.sourceNameCollision(output)
            }
            materialized[output] = text
            fingerprints[output] = digest(data)
        }

        let outputs = materialized.keys.sorted()
        var operations: [EmbeddedToolchainOperation] = []
        var objects: [String] = []
        for output in outputs {
            let language: EmbeddedToolchainLanguage = output.hasSuffix(".m") ? .objectiveC : .c
            let object = output.replacingExtension(with: ".o")
            operations.append(.compile(source: output, output: object, language: language))
            objects.append(object)
        }
        guard !operations.isEmpty, outputName.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}\\.dylib$", options: .regularExpression) != nil else {
            throw EmbeddedToolchainProjectMaterializerError.noOperations
        }
        operations.append(.link(objects: objects, output: outputName, installName: "@rpath/" + outputName))
        return EmbeddedToolchainMaterializedPlan(
            sources: materialized,
            operations: operations,
            sourceFingerprints: fingerprints,
            snapshotFingerprint: snapshot.fingerprint,
            outputName: outputName
        )
    }

    private static func append(file: EmbeddedToolchainProjectFile,
                               files: [String: EmbeddedToolchainProjectFile],
                               parts: inout [String], materializedBytes: inout Int) throws {
        for token in file.tokens {
            switch token {
            case .include(let dependency):
                guard let includedFile = files[dependency] else {
                    throw EmbeddedToolchainProjectMaterializerError.missingDependency(dependency)
                }
                try append(file: includedFile, files: files, parts: &parts,
                           materializedBytes: &materializedBytes)
            case .code(let text):
                materializedBytes += text.utf8.count + 1
                guard materializedBytes <= maxMaterializedSourceBytes else {
                    throw EmbeddedToolchainProjectMaterializerError.materializedSourceTooLarge(file.path)
                }
                parts.append(text)
            }
        }
    }

    private static func materializedName(_ path: String) -> String {
        let base = path.replacingOccurrences(of: "/", with: "_")
        return base.hasSuffix(".m") ? base : base.replacingExtension(with: ".c")
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private extension String {
    func replacingExtension(with extensionName: String) -> String {
        let url = URL(fileURLWithPath: self)
        return url.deletingPathExtension().lastPathComponent + extensionName
    }
}
