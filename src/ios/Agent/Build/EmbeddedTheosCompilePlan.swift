import Foundation
import CryptoKit

/// Errors raised while turning a validated Theos target graph plus a source
/// snapshot into typed compile actions. No shell text or user flags are involved.
enum EmbeddedTheosCompilePlanError: Error, Equatable, LocalizedError, Sendable {
    case missingSource(String)
    case missingHeader(String)
    case unsupportedLanguage(String)
    case sourceTooLarge(String)
    case headerTooLarge(String)
    case totalSizeExceeded
    case unsafePath(String)
    case nonASCII(String)
    case invalidEntitlements(String)

    var errorDescription: String? {
        switch self {
        case .missingSource(let path): return "Theos source is missing from the snapshot: \(path)"
        case .missingHeader(let path): return "Theos header is missing from the snapshot: \(path)"
        case .unsupportedLanguage(let path): return "unsupported Theos source language: \(path)"
        case .sourceTooLarge(let path): return "Theos source exceeds its byte budget: \(path)"
        case .headerTooLarge(let path): return "Theos header exceeds its byte budget: \(path)"
        case .totalSizeExceeded: return "Theos project source/header snapshot exceeds the total byte budget"
        case .unsafePath(let path): return "Theos source or header path is not a safe relative path: \(path)"
        case .nonASCII(let path): return "Theos source or header must be bounded ASCII: \(path)"
        case .invalidEntitlements(let path): return "Theos entitlements plist is invalid or unbounded: \(path)"
        }
    }
}

/// One source or header already read, bounded and hashed before compilation.
struct EmbeddedTheosMaterializedSource: Equatable, Sendable {
    let path: String
    let contents: String
    let language: EmbeddedToolchainLanguage
    let sha256: String
}

struct EmbeddedTheosMaterializedHeader: Equatable, Sendable {
    let path: String
    let contents: String
    let sha256: String
}

/// Typed compile actions for a single Theos target. The adapter - not the caller -
/// owns target triple, minimum iOS, SDK, framework and PAC policy.
struct EmbeddedTheosTargetPlan: Equatable, Sendable {
    let target: EmbeddedTheosTarget
    let sources: [EmbeddedTheosMaterializedSource]
    let headers: [EmbeddedTheosMaterializedHeader]
    let entitlements: Data?
    let architectures: [EmbeddedToolchainArchitecture]

    var objectNames: [String] {
        sources.map { EmbeddedTheosTargetPlan.objectName(for: $0.path) }
    }

    static func objectName(for sourcePath: String) -> String {
        let base = sourcePath
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: ".", with: "_")
        let suffix = String(EmbeddedAdapterArtifact.digest(Data(sourcePath.utf8)).prefix(12))
        return "\(base)-\(suffix).o"
    }
}

/// Pure planner: it validates paths and languages and computes hashes, but it never
/// invokes a compiler, linker, Makefile or package hook.
enum EmbeddedTheosCompilePlanner {
    static let maxSourcesPerTarget = 64
    static let maxHeadersPerTarget = 256
    static let maxSourceBytes = 1024 * 1024
    static let maxHeaderBytes = 256 * 1024
    static let maxTotalBytes = 8 * 1024 * 1024

    static func plan(project: EmbeddedTheosProjectPlan,
                     fileContents: [String: String]) throws -> [EmbeddedTheosTargetPlan] {
        try project.validate()
        var total = 0
        var plans: [EmbeddedTheosTargetPlan] = []
        for target in project.targets {
            let declaredPaths = target.sourcePaths + target.headerPaths + (target.entitlementsPath.map { [$0] } ?? [])
            guard target.sourcePaths.count <= maxSourcesPerTarget,
                  target.headerPaths.count <= maxHeadersPerTarget,
                  Set(declaredPaths).count == declaredPaths.count else {
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
            let headers = try target.headerPaths.map { path -> EmbeddedTheosMaterializedHeader in
                guard isSafeRelative(path) else { throw EmbeddedTheosCompilePlanError.unsafePath(path) }
                guard ["h", "hh", "hpp"].contains((path as NSString).pathExtension.lowercased()) else {
                    throw EmbeddedTheosCompilePlanError.unsupportedLanguage(path)
                }
                guard let text = fileContents[path] else { throw EmbeddedTheosCompilePlanError.missingHeader(path) }
                guard let data = text.data(using: .ascii) else { throw EmbeddedTheosCompilePlanError.nonASCII(path) }
                guard data.count > 0, data.count <= maxHeaderBytes else {
                    throw EmbeddedTheosCompilePlanError.headerTooLarge(path)
                }
                guard total <= maxTotalBytes - data.count else {
                    throw EmbeddedTheosCompilePlanError.totalSizeExceeded
                }
                total += data.count
                return EmbeddedTheosMaterializedHeader(path: path, contents: text, sha256: digest(data))
            }
            let entitlements: Data?
            if let path = target.entitlementsPath {
                guard let text = fileContents[path], let data = text.data(using: .utf8),
                      !data.isEmpty, data.count <= 16 * 1024 else {
                    throw EmbeddedTheosCompilePlanError.invalidEntitlements(path)
                }
                guard total <= maxTotalBytes - data.count else {
                    throw EmbeddedTheosCompilePlanError.totalSizeExceeded
                }
                let object: Any
                do {
                    object = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
                } catch {
                    throw EmbeddedTheosCompilePlanError.invalidEntitlements(path)
                }
                guard let dictionary = object as? [String: Any], !dictionary.isEmpty else {
                    throw EmbeddedTheosCompilePlanError.invalidEntitlements(path)
                }
                do {
                    let canonical = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
                    guard data.count <= maxTotalBytes - total,
                          canonical.count <= maxTotalBytes - total - data.count else {
                        throw EmbeddedTheosCompilePlanError.totalSizeExceeded
                    }
                    total += data.count + canonical.count
                    entitlements = canonical
                } catch let error as EmbeddedTheosCompilePlanError {
                    throw error
                } catch {
                    throw EmbeddedTheosCompilePlanError.invalidEntitlements(path)
                }
            } else {
                entitlements = nil
            }
            plans.append(EmbeddedTheosTargetPlan(target: target, sources: sources, headers: headers,
                                                 entitlements: entitlements, architectures: target.architectures))
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
        guard !value.isEmpty, value.utf8.count <= 192, !value.hasPrefix("/"),
              !value.hasSuffix("/"), !value.contains("//"),
              !value.contains("\\"), !value.contains("\0") else { return false }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        return parts.count <= 8 && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." &&
            $0.range(of: "^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
