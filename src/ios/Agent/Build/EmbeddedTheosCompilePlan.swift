import Foundation
import CryptoKit

/// Errors raised while turning a validated Theos target graph plus a source
/// snapshot into typed compile actions. No shell text or user flags are involved.
enum EmbeddedTheosCompilePlanError: Error, Equatable, LocalizedError, Sendable {
    case missingSource(String)
    case unsupportedLanguage(String)
    case sourceTooLarge(String)
    case totalSizeExceeded
    case unsafePath(String)
    case nonASCII(String)

    var errorDescription: String? {
        switch self {
        case .missingSource(let path): return "Theos source is missing from the snapshot: \(path)"
        case .unsupportedLanguage(let path): return "unsupported Theos source language: \(path)"
        case .sourceTooLarge(let path): return "Theos source exceeds its byte budget: \(path)"
        case .totalSizeExceeded: return "Theos project source snapshot exceeds the total byte budget"
        case .unsafePath(let path): return "Theos source path is not a safe relative path: \(path)"
        case .nonASCII(let path): return "Theos source must be bounded ASCII: \(path)"
        }
    }
}

/// One source file that has already been read, bounded and hashed.
struct EmbeddedTheosMaterializedSource: Equatable, Sendable {
    let path: String
    let contents: String
    let language: EmbeddedToolchainLanguage
    let sha256: String
}

/// Typed compile actions for a single Theos target. The adapter - not the caller -
/// owns target triple, minimum iOS, SDK, framework and PAC policy.
struct EmbeddedTheosTargetPlan: Equatable, Sendable {
    let target: EmbeddedTheosTarget
    let sources: [EmbeddedTheosMaterializedSource]
    let architectures: [EmbeddedToolchainArchitecture]

    var objectNames: [String] {
        sources.map { EmbeddedTheosTargetPlan.objectName(for: $0.path) }
    }

    /// Flat, collision-free object names for a private per-run directory.
    static func objectName(for sourcePath: String) -> String {
        let base = sourcePath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        return base + ".o"
    }
}

/// Pure planner: it validates paths and languages and computes hashes, but it never
/// invokes a compiler, linker, Makefile or package hook.
enum EmbeddedTheosCompilePlanner {
    static let maxSourcesPerTarget = 64
    static let maxSourceBytes = 1024 * 1024
    static let maxTotalBytes = 8 * 1024 * 1024

    static func plan(project: EmbeddedTheosProjectPlan,
                     fileContents: [String: String]) throws -> [EmbeddedTheosTargetPlan] {
        try project.validate()
        var total = 0
        var plans: [EmbeddedTheosTargetPlan] = []
        for target in project.targets {
            guard target.sourcePaths.count <= maxSourcesPerTarget else {
                throw EmbeddedTheosCompilePlanError.totalSizeExceeded
            }
            let sources = try target.sourcePaths.map { path -> EmbeddedTheosMaterializedSource in
                guard isSafeRelative(path) else { throw EmbeddedTheosCompilePlanError.unsafePath(path) }
                guard let text = fileContents[path] else { throw EmbeddedTheosCompilePlanError.missingSource(path) }
                guard let data = text.data(using: .ascii) else { throw EmbeddedTheosCompilePlanError.nonASCII(path) }
                guard data.count > 0, data.count <= maxSourceBytes else {
                    throw EmbeddedTheosCompilePlanError.sourceTooLarge(path)
                }
                guard total <= maxTotalBytes - data.count else {
                    throw EmbeddedTheosCompilePlanError.totalSizeExceeded
                }
                total += data.count
                return EmbeddedTheosMaterializedSource(path: path, contents: text,
                                                       language: try language(for: path),
                                                       sha256: digest(data))
            }
            plans.append(EmbeddedTheosTargetPlan(target: target, sources: sources,
                                                 architectures: [.arm64, .arm64e]))
        }
        return plans
    }

    private static func language(for path: String) throws -> EmbeddedToolchainLanguage {
        switch (path as NSString).pathExtension.lowercased() {
        case "c": return .c
        case "m": return .objectiveC
        default: throw EmbeddedTheosCompilePlanError.unsupportedLanguage(path)
        }
    }

    private static func isSafeRelative(_ value: String) -> Bool {
        guard !value.isEmpty, !value.hasPrefix("/"), !value.contains("\\"), !value.contains("\0") else { return false }
        let parts = value.split(separator: "/")
        guard !parts.isEmpty else { return false }
        return parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
