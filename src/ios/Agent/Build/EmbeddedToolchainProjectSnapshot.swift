import Foundation
import CryptoKit

/// An immutable, in-memory project view for the first restricted project gate.
/// It never reads a filesystem and never creates compiler/linker arguments.
/// A future filesystem reader must establish the path/symlink policy before
/// constructing this value.
struct EmbeddedToolchainProjectFile: Equatable, Sendable {
    enum Kind: String, Sendable {
        case cSource = "c"
        case objectiveCSource = "objective-c"
        case header = "header"
    }

    let path: String
    let kind: Kind
    let contents: String
    let byteCount: Int
    let sha256: String

    fileprivate init(path: String, kind: Kind, contents: String, byteCount: Int, sha256: String) {
        self.path = path; self.kind = kind; self.contents = contents
        self.byteCount = byteCount; self.sha256 = sha256
    }
}

/// Deliberately not Decodable: a serialized value cannot bypass the builder's
/// validation or claim a forged content hash. Value members are immutable.
struct EmbeddedToolchainProjectSnapshot: Equatable, Sendable {
    let schema: Int
    let files: [EmbeddedToolchainProjectFile]
    let entrySources: [String]
    let dependencies: [String: [String]]
    let totalBytes: Int
    let fingerprint: String

    fileprivate init(schema: Int, files: [EmbeddedToolchainProjectFile], entrySources: [String],
                     dependencies: [String: [String]], totalBytes: Int, fingerprint: String) {
        self.schema = schema; self.files = files; self.entrySources = entrySources
        self.dependencies = dependencies; self.totalBytes = totalBytes; self.fingerprint = fingerprint
    }
}

enum EmbeddedToolchainProjectSnapshotError: Error, Equatable, LocalizedError, Sendable {
    case emptyProject
    case tooManyFiles
    case tooManySources
    case unsupportedPath(String)
    case unsupportedExtension(String)
    case nonASCII(String)
    case fileTooLarge(String)
    case totalSizeExceeded
    case invalidEntrySource(String)
    case invalidDirective(String)
    case includePathEscapes(String)
    case missingHeader(String, from: String)
    case dependencyDepthExceeded(String)
    case dependencyCountExceeded
    case dependencyCycle(String)

    var errorDescription: String? {
        switch self {
        case .emptyProject: return "project snapshot must contain at least one source"
        case .tooManyFiles: return "project snapshot contains too many files"
        case .tooManySources: return "project snapshot contains too many entry sources"
        case .unsupportedPath(let path): return "unsupported project path: \(path)"
        case .unsupportedExtension(let path): return "unsupported project file extension: \(path)"
        case .nonASCII(let path): return "project file must be bounded ASCII: \(path)"
        case .fileTooLarge(let path): return "project file exceeds its byte budget: \(path)"
        case .totalSizeExceeded: return "project snapshot exceeds the total byte budget"
        case .invalidEntrySource(let path): return "entry source is not a supplied C/Objective-C source: \(path)"
        case .invalidDirective(let path): return "unsupported preprocessing directive in \(path)"
        case .includePathEscapes(let path): return "quoted include escapes its source directory: \(path)"
        case .missingHeader(let header, let source): return "missing local header \(header) included by \(source)"
        case .dependencyDepthExceeded(let path): return "local header dependency depth exceeded at \(path)"
        case .dependencyCountExceeded: return "local header dependency edge budget exceeded"
        case .dependencyCycle(let path): return "local header dependency cycle at \(path)"
        }
    }
}

/// Deterministic scanner for a deliberately narrow first project class.
///
/// Supported input is a caller-created immutable dictionary containing flat or
/// nested `.c`, `.m`, and `.h` files. Only quoted local includes are scanned;
/// angle-bracket includes, macros, conditionals, imports, pragmas, continuations
/// and all other preprocessor directives are rejected. This is a dependency
/// snapshot, not yet an execution or virtual-filesystem authorization.
enum EmbeddedToolchainProjectSnapshotBuilder {
    static let maxFiles = 20
    static let maxSources = 4
    static let maxSourceBytes = 128 * 1024
    static let maxHeaderBytes = 64 * 1024
    static let maxTotalBytes = 512 * 1024
    static let maxDependencyDepth = 8
    static let maxDependencyEdges = 48

    static func build(files: [String: String], entrySources: [String] = []) throws -> EmbeddedToolchainProjectSnapshot {
        guard !files.isEmpty else { throw EmbeddedToolchainProjectSnapshotError.emptyProject }
        guard files.count <= maxFiles else { throw EmbeddedToolchainProjectSnapshotError.tooManyFiles }

        var totalBytes = 0
        var records: [EmbeddedToolchainProjectFile] = []
        var sourcePaths: [String] = []
        var headerPaths: Set<String> = []

        for path in files.keys.sorted() {
            try validatePath(path)
            let contents = files[path] ?? ""
            guard let data = contents.data(using: .utf8),
                  data.allSatisfy({ $0 == 9 || $0 == 10 || $0 == 13 || (32...126).contains($0) }) else {
                throw EmbeddedToolchainProjectSnapshotError.nonASCII(path)
            }
            let rawExtension = URL(fileURLWithPath: path).pathExtension
            guard !rawExtension.isEmpty, rawExtension == rawExtension.lowercased() else {
                throw EmbeddedToolchainProjectSnapshotError.unsupportedPath(path)
            }
            let ext = rawExtension
            let kind: EmbeddedToolchainProjectFile.Kind
            switch ext {
            case "c":
                kind = .cSource; sourcePaths.append(path)
            case "m":
                kind = .objectiveCSource; sourcePaths.append(path)
            case "h":
                kind = .header; headerPaths.insert(path)
            default:
                throw EmbeddedToolchainProjectSnapshotError.unsupportedExtension(path)
            }
            let limit = kind == .header ? maxHeaderBytes : maxSourceBytes
            guard data.count > 0, data.count <= limit else {
                throw EmbeddedToolchainProjectSnapshotError.fileTooLarge(path)
            }
            totalBytes += data.count
            guard totalBytes <= maxTotalBytes else {
                throw EmbeddedToolchainProjectSnapshotError.totalSizeExceeded
            }
            records.append(EmbeddedToolchainProjectFile(
                path: path,
                kind: kind,
                contents: contents,
                byteCount: data.count,
                sha256: digest(data)
            ))
        }

        guard !sourcePaths.isEmpty else { throw EmbeddedToolchainProjectSnapshotError.emptyProject }
        guard sourcePaths.count <= maxSources else { throw EmbeddedToolchainProjectSnapshotError.tooManySources }
        let entries = entrySources.isEmpty ? sourcePaths : entrySources
        guard entries.count <= maxSources, Set(entries).count == entries.count else {
            throw EmbeddedToolchainProjectSnapshotError.tooManySources
        }
        for entry in entries {
            guard sourcePaths.contains(entry) else {
                throw EmbeddedToolchainProjectSnapshotError.invalidEntrySource(entry)
            }
        }

        var dependencies: [String: [String]] = [:]
        var edgeCount = 0
        for path in sourcePaths.sorted() {
            dependencies[path] = try directIncludes(in: files[path] ?? "", from: path)
            edgeCount += dependencies[path]?.count ?? 0
        }
        for path in headerPaths.sorted() {
            dependencies[path] = try directIncludes(in: files[path] ?? "", from: path)
            edgeCount += dependencies[path]?.count ?? 0
        }
        guard edgeCount <= maxDependencyEdges else {
            throw EmbeddedToolchainProjectSnapshotError.dependencyCountExceeded
        }

        // Inspect every supplied file, including headers not reachable from an
        // entry point. Do not let cached shallow visits hide a later deep path.
        for path in files.keys.sorted() {
            var visiting: Set<String> = []
            try walk(path, files: files, dependencies: dependencies, depth: 0,
                     visiting: &visiting)
        }

        let sortedRecords = records.sorted { $0.path < $1.path }
        let sortedEntries = entries.sorted()
        let sortedDependencies = dependencies.keys.sorted().map { key in
            key + "\0" + (dependencies[key] ?? []).sorted().joined(separator: "\0") + "\0"
        }.joined()
        // Length-prefixed records avoid ambiguity if future path/name rules grow.
        let fingerprintInput = "schema=1\0files=\(sortedRecords.count)\0" +
            sortedRecords.map { "\($0.path.utf8.count):\($0.path)\($0.kind.rawValue.utf8.count):\($0.kind.rawValue)\($0.sha256)\0" }.joined() +
            "entries=\(sortedEntries.count)\0" + sortedEntries.joined(separator: "\0") +
            "\0deps=\(sortedDependencies.utf8.count)\0" + sortedDependencies
        return EmbeddedToolchainProjectSnapshot(
            schema: 1,
            files: sortedRecords,
            entrySources: sortedEntries,
            dependencies: dependencies.mapValues { $0.sorted() },
            totalBytes: totalBytes,
            fingerprint: digest(Data(fingerprintInput.utf8))
        )
    }

    static func materializedFiles(_ snapshot: EmbeddedToolchainProjectSnapshot) -> [String: String] {
        Dictionary(uniqueKeysWithValues: snapshot.files.map { ($0.path, $0.contents) })
    }

    private static func validatePath(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count <= 192, !path.hasPrefix("/"),
              !path.hasSuffix("/"), !path.contains("\0"), !path.contains("\\"),
              !path.contains("//") else {
            throw EmbeddedToolchainProjectSnapshotError.unsupportedPath(path)
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.count <= 8, components.allSatisfy({ component in
            component != "." && component != ".." &&
            component.range(of: "^[A-Za-z0-9_-][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil
        }) else {
            throw EmbeddedToolchainProjectSnapshotError.unsupportedPath(path)
        }
    }

    private static func directIncludes(in contents: String, from source: String) throws -> [String] {
        guard !contents.contains("\\"), !contents.contains("\r") else {
            throw EmbeddedToolchainProjectSnapshotError.invalidDirective(source)
        }
        let forbiddenTokens = ["#if", "#ifdef", "#ifndef", "#elif", "#else", "#endif",
                               "#define", "#undef", "#error", "#warning", "#pragma", "#import",
                               "_Pragma", "@import"]
        let forbiddenSourceTokens = ["__asm__", "__attribute__", "asm(", "asm "]
        for token in forbiddenTokens where contents.contains(token) {
            throw EmbeddedToolchainProjectSnapshotError.invalidDirective(source)
        }
        for token in forbiddenSourceTokens where contents.contains(token) {
            throw EmbeddedToolchainProjectSnapshotError.invalidDirective(source)
        }
        var includes: [String] = []
        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            guard line.hasPrefix("#") else { continue }
            guard line.hasPrefix("#include \"") && line.last == "\"" else {
                throw EmbeddedToolchainProjectSnapshotError.invalidDirective(source)
            }
            let value = String(line.dropFirst(10).dropLast())
            guard !value.isEmpty, value.utf8.count <= 192, !value.hasPrefix("/"),
                  !value.contains("\\"), !value.split(separator: "/").contains(".."),
                  !value.contains("//"),
                  value.range(of: "^[A-Za-z0-9_-][A-Za-z0-9._/-]{0,191}$", options: .regularExpression) != nil else {
                throw EmbeddedToolchainProjectSnapshotError.includePathEscapes(value)
            }
            includes.append(try resolve(value, from: source))
        }
        return Array(Set(includes)).sorted()
    }

    private static func resolve(_ include: String, from source: String) throws -> String {
        let components = source.split(separator: "/", omittingEmptySubsequences: true)
        let directory = components.dropLast().map(String.init)
        let includeComponents = include.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let candidate = (directory + includeComponents).joined(separator: "/")
        try validatePath(candidate)
        return candidate
    }

    private static func walk(_ path: String, files: [String: String],
                             dependencies: [String: [String]], depth: Int,
                             visiting: inout Set<String>) throws {
        guard depth <= maxDependencyDepth else {
            throw EmbeddedToolchainProjectSnapshotError.dependencyDepthExceeded(path)
        }
        if visiting.contains(path) { throw EmbeddedToolchainProjectSnapshotError.dependencyCycle(path) }
        visiting.insert(path)
        defer { visiting.remove(path) }
        for dependency in dependencies[path] ?? [] {
            guard files[dependency] != nil, dependency.hasSuffix(".h") else {
                throw EmbeddedToolchainProjectSnapshotError.missingHeader(dependency, from: path)
            }
            try walk(dependency, files: files, dependencies: dependencies, depth: depth + 1,
                     visiting: &visiting)
        }
    }

    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
