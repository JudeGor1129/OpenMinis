import Foundation
import CryptoKit

// MARK: - Structured programming tool policy

/// Roles are an opt-in workflow policy layered on top of the existing Sub Agent
/// roster. They do not replace, rename, or mutate user-configured agents.
enum ProgrammingWorkflowRole: String, CaseIterable, Codable {
    case repositoryExplorer = "RepositoryExplorer"
    case planner = "Planner"
    case implementer = "Implementer"
    case builder = "Builder"
    case debugger = "Debugger"
    case reviewer = "Reviewer"
    case releaseVerifier = "ReleaseVerifier"

    static func parse(_ value: Any?) -> ProgrammingWorkflowRole? {
        guard let raw = value as? String, !raw.isEmpty else { return nil }
        return allCases.first { $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame }
    }

    var summary: String {
        switch self {
        case .repositoryExplorer: return "Read-only project discovery and evidence-backed code search."
        case .planner: return "Read-only planning from indexed project facts; no source mutation."
        case .implementer: return "Hash-checked, locked patch application and focused verification."
        case .builder: return "Build, lint, and test execution; no source mutation."
        case .debugger: return "Evidence gathering, minimal hash-checked fixes, and targeted tests."
        case .reviewer: return "Read-only diff, risk, lint, and test review."
        case .releaseVerifier: return "Read-only release checks from clean status, diffs, and tests."
        }
    }
}

enum ProgrammingRolePolicy {
    private static let readTools: Set<String> = [
        "inspect_project", "search_code", "project_read_file", "git_status", "git_diff"
    ]

    static func permits(role: ProgrammingWorkflowRole?, tool: String) -> Bool {
        guard let role else { return true } // Backwards-compatible unroled calls.
        if readTools.contains(tool) { return true }
        switch tool {
        case "apply_patch":
            return role == .implementer || role == .debugger
        case "run_lint":
            return [.implementer, .builder, .debugger, .reviewer, .releaseVerifier].contains(role)
        default:
            return false
        }
    }

    static var descriptors: [[String: Any]] {
        ProgrammingWorkflowRole.allCases.map { role in
            ["name": role.rawValue, "policy": role.summary]
        }
    }
}

// MARK: - Incremental symbol index and semantic seam

struct CodeSymbolRecord: Codable, Hashable, Sendable {
    let name: String
    let kind: String
    let line: Int
    let signature: String
}

struct IndexedCodeFile: Codable, Sendable {
    let relativePath: String
    let hash: String
    let byteCount: Int
    let symbols: [CodeSymbolRecord]
}

struct CodeIndexSnapshot: Codable, Sendable {
    let schemaVersion: Int
    let projectPath: String
    let commit: String
    let generatedAt: Date
    let files: [String: IndexedCodeFile]
}

struct CodeSearchHit: Codable, Sendable {
    let path: String
    let line: Int
    let endLine: Int
    let kind: String
    let symbol: String?
    let score: Double
    let snippet: String
    let commit: String
    let fileHash: String
}

/// Optional adapter seam for a future on-device or remote embedding provider.
/// The default adapter is deliberately unavailable; callers receive an explicit
/// BM25/symbol/keyword fallback instead of a fabricated "semantic" result.
protocol CodeSemanticSearchProviding: Sendable {
    var providerName: String { get }
    var isAvailable: Bool { get }
    func search(query: String, projectPath: String, limit: Int) async throws -> [CodeSearchHit]
}

struct UnavailableCodeSemanticSearchProvider: CodeSemanticSearchProviding {
    let providerName = "none"
    let isAvailable = false
    func search(query: String, projectPath: String, limit: Int) async throws -> [CodeSearchHit] { [] }
}

enum CodeSymbolExtractor {
    private struct Pattern {
        let expression: NSRegularExpression
        let kindGroup: Int
        let nameGroup: Int
    }

    private static func pattern(_ value: String, kind: Int, name: Int) -> Pattern {
        Pattern(expression: try! NSRegularExpression(pattern: value, options: []),
                kindGroup: kind, nameGroup: name)
    }

    static func extract(text: String, extension ext: String) -> [CodeSymbolRecord] {
        let patterns: [Pattern]
        switch ext.lowercased() {
        case "swift":
            patterns = [pattern(#"^\s*(?:(?:public|open|internal|private|fileprivate|final|static|class|mutating|nonmutating|override|required|convenience|indirect|distributed)\s+)*(class|struct|enum|protocol|actor|extension|func|init|subscript|typealias)\s*([A-Za-z_][A-Za-z0-9_\.]*)?"#, kind: 1, name: 2)]
        case "m", "mm", "h", "c", "cc", "cpp", "cxx", "hpp":
            patterns = [
                pattern(#"^\s*@(?:interface|implementation|protocol)\s+([A-Za-z_][A-Za-z0-9_]*)"#, kind: 0, name: 1),
                pattern(#"^\s*[-+]\s*\([^)]*\)\s*([A-Za-z_][A-Za-z0-9_]*)"#, kind: 0, name: 1),
                pattern(#"^\s*[A-Za-z_][A-Za-z0-9_\s\*:<>,]*\s+([A-Za-z_][A-Za-z0-9_]*)\s*\([^;]*\)\s*(?:\{|$)"#, kind: 0, name: 1)
            ]
        case "rs":
            patterns = [pattern(#"^\s*(?:pub(?:\([^)]*\))?\s+)?(fn|struct|enum|trait|impl|mod|type)\s+([A-Za-z_][A-Za-z0-9_]*)"#, kind: 1, name: 2)]
        case "py":
            patterns = [pattern(#"^\s*(?:async\s+)?(def|class)\s+([A-Za-z_][A-Za-z0-9_]*)"#, kind: 1, name: 2)]
        case "js", "jsx", "ts", "tsx", "java", "kt", "kts":
            patterns = [pattern(#"^\s*(?:export\s+|public\s+|private\s+|protected\s+|abstract\s+|final\s+|static\s+)*(class|interface|enum|type|function|fun)\s+([A-Za-z_$][A-Za-z0-9_$]*)"#, kind: 1, name: 2)]
        default:
            patterns = []
        }

        var result: [CodeSymbolRecord] = []
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = String(rawLine.prefix(500))
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            for p in patterns {
                guard let match = p.expression.firstMatch(in: line, range: range) else { continue }
                func group(_ index: Int) -> String? {
                    guard index > 0, index < match.numberOfRanges,
                          let r = Range(match.range(at: index), in: line) else { return nil }
                    return String(line[r])
                }
                let rawKind = group(p.kindGroup) ?? inferredKind(line: line, extension: ext)
                let name = group(p.nameGroup) ?? (rawKind == "init" ? "init" : inferredName(line: line))
                guard !name.isEmpty else { continue }
                result.append(CodeSymbolRecord(name: name, kind: normalizeKind(rawKind),
                                               line: offset + 1,
                                               signature: line.trimmingCharacters(in: .whitespaces)))
                break
            }
        }
        return result
    }

    private static func inferredKind(line: String, extension ext: String) -> String {
        if line.contains("@interface") { return "type" }
        if line.contains("@protocol") { return "protocol" }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("-") || line.trimmingCharacters(in: .whitespaces).hasPrefix("+") { return "function" }
        return ["m", "mm", "c", "cc", "cpp", "cxx"].contains(ext.lowercased()) ? "function" : "symbol"
    }

    private static func inferredName(line: String) -> String {
        let pieces = line.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
        return pieces.last.map(String.init) ?? ""
    }

    static func normalizeKind(_ raw: String) -> String {
        let lower = raw.lowercased()
        if ["func", "fn", "def", "function", "fun", "init", "subscript"].contains(lower) { return "function" }
        if ["class", "struct", "enum", "protocol", "trait", "interface", "actor", "type", "typealias"].contains(lower) { return "type" }
        if lower == "extension" || lower == "impl" { return "extension" }
        if lower == "mod" { return "module" }
        return lower.isEmpty ? "symbol" : lower
    }
}

enum ProgrammingPathPolicy {
    /// Normalize a project-relative path without allowing `..` to escape the
    /// project. Absolute paths are accepted only when they are strict children
    /// of the canonical project root.
    static func projectRelativePath(_ input: String, projectRoot: String) throws -> String {
        guard !input.isEmpty, !input.contains("\0") else {
            throw ProgrammingToolError("invalid file path")
        }
        if input.hasPrefix("/") {
            let root = URL(fileURLWithPath: projectRoot).standardizedFileURL.path
            let candidate = URL(fileURLWithPath: input).standardizedFileURL.path
            let rootPrefix = root.hasSuffix("/") ? root : root + "/"
            guard candidate.hasPrefix(rootPrefix), candidate.count > rootPrefix.count else {
                throw ProgrammingToolError("file path escapes the project root")
            }
            return String(candidate.dropFirst(rootPrefix.count))
        }
        var components: [Substring] = []
        for component in input.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." {
                guard !components.isEmpty else {
                    throw ProgrammingToolError("file path escapes the project root")
                }
                components.removeLast()
            } else {
                components.append(component)
            }
        }
        guard !components.isEmpty else { throw ProgrammingToolError("invalid file path") }
        return components.joined(separator: "/")
    }
}

// MARK: - Structured programming tool execution

extension AIChatViewModel {
    private static let programmingOutputLimit = 14_000
    private static let programmingSearchExtensions: Set<String> = [
        "swift", "m", "mm", "h", "c", "cc", "cpp", "cxx", "hpp", "rs", "py",
        "js", "jsx", "ts", "tsx", "java", "kt", "kts", "sh", "rb", "go"
    ]
    private static let semanticSearchProvider: any CodeSemanticSearchProviding = UnavailableCodeSemanticSearchProvider()

    actor ProjectWriteLockRegistry {
        static let shared = ProjectWriteLockRegistry()
        private var locked: Set<String> = []
        private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

        func withLock<T: Sendable>(project: String,
                                   operation: @MainActor @Sendable () async throws -> T) async rethrows -> T {
            if locked.contains(project) {
                await withCheckedContinuation { continuation in
                    waiters[project, default: []].append(continuation)
                }
            } else {
                locked.insert(project)
            }
            defer {
                if var queued = waiters[project], !queued.isEmpty {
                    let next = queued.removeFirst()
                    waiters[project] = queued
                    next.resume()
                } else {
                    waiters[project] = nil
                    locked.remove(project)
                }
            }
            return try await operation()
        }
    }

    func executeProgrammingTool(name: String, args: [String: Any]) async -> FileToolResult {
        let role = ProgrammingWorkflowRole.parse(args["role"])
        guard ProgrammingRolePolicy.permits(role: role, tool: name) else {
            return programmingJSON([
                "ok": false, "tool": name, "error": "role_policy_denied",
                "role": role?.rawValue ?? "unknown",
                "detail": "This role is read-only or is not permitted to invoke this tool."
            ], success: false)
        }
        do {
            switch name {
            case "inspect_project": return try await inspectProject(args)
            case "search_code": return try await searchCode(args)
            case "project_read_file": return try await readProgrammingFile(args)
            case "apply_patch": return try await applyProgrammingPatch(args)
            case "git_status": return try await runGitStatus(args)
            case "git_diff": return try await runGitDiff(args)
            case "run_lint": return try await runProjectCommand(args, kind: "lint")
            default:
                return programmingJSON(["ok": false, "error": "unknown_programming_tool"], success: false)
            }
        } catch {
            return programmingJSON([
                "ok": false, "tool": name, "error": "execution_failed",
                "detail": error.localizedDescription
            ], success: false)
        }
    }

    // MARK: Project discovery

    private struct ProjectContext: Sendable {
        let root: String
        let hostRoot: URL
        let commit: String
        let branch: String
        let remote: String?
    }

    private func inspectProject(_ args: [String: Any]) async throws -> FileToolResult {
        let context = try await projectContext(from: args)
        let fm = FileManager.default
        let rootURL = context.hostRoot
        let maxDepth = max(1, min(8, integer(args["max_depth"], default: 4)))
        var manifests: [String] = []
        var languages: [String: Int] = [:]
        var modules: Set<String> = []
        var dependencies: Set<String> = []
        var isTheos = false

        for url in projectFiles(rootURL: rootURL, maxDepth: maxDepth, includeHidden: false, maxFiles: 12_000) {
            let rel = relative(url, to: rootURL)
            let name = url.lastPathComponent
            let ext = url.pathExtension.lowercased()
            if Self.programmingSearchExtensions.contains(ext) {
                languages[languageName(ext), default: 0] += 1
            }
            if ["Package.swift", "project.yml", "Podfile", "Makefile", "Cargo.toml"].contains(name)
                || name == "project.pbxproj" || url.pathExtension == "xcodeproj" {
                manifests.append(rel)
            }
            if name == "control" && rel.contains("DEBIAN") || name == "Tweak.xm" || name == "NIC.pl" {
                isTheos = true
            }
            if ["Package.swift", "Cargo.toml", "Podfile", "project.yml", "Makefile", "project.pbxproj"].contains(name),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                modules.formUnion(parseModules(text: text, name: name))
                dependencies.formUnion(parseDependencies(text: text, name: name))
                if text.localizedCaseInsensitiveContains("theos") || text.contains("include $(THEOS)") { isTheos = true }
            }
            if url.pathExtension == "xcodeproj" { modules.insert(url.deletingPathExtension().lastPathComponent) }
        }

        let commands = candidateCommands(manifests: manifests, theos: isTheos)
        let index = try await refreshCodeIndex(context: context, force: (args["refresh_index"] as? Bool) ?? false)
        let symbolCount = index.files.values.reduce(0) { $0 + $1.symbols.count }
        return programmingJSON([
            "ok": true,
            "project": [
                "canonical_path": context.root,
                "language_stack": languages.sorted { $0.value > $1.value }.map { ["language": $0.key, "files": $0.value] },
                "modules": Array(modules).sorted(),
                "dependencies": Array(dependencies).sorted(),
                "manifests": manifests.sorted(),
                "theos": isTheos,
                "git": ["remote": context.remote as Any, "branch": context.branch, "commit": context.commit],
                "candidate_commands": commands
            ],
            "index": [
                "incremental": true, "commit": index.commit,
                "files": index.files.count, "symbols": symbolCount,
                "indexed_bytes": index.files.values.reduce(0) { $0 + $1.byteCount },
                "max_indexed_bytes": 48 * 1_024 * 1_024,
                "workflow_roles": ProgrammingRolePolicy.descriptors,
                "semantic_provider": Self.semanticSearchProvider.providerName,
                "semantic_available": Self.semanticSearchProvider.isAvailable,
                "fallback": "BM25-like lexical ranking + exact symbol + keyword"
            ]
        ], success: true)
    }

    private func projectContext(from args: [String: Any]) async throws -> ProjectContext {
        let requested = ((args["path"] as? String) ?? (args["project_path"] as? String) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard requested.hasPrefix("/"), !requested.contains("\0") else {
            throw ProgrammingToolError("path must be an absolute Linux path")
        }
        let quoted = shellQuote(requested)
        let command = "p=\(quoted); if [ -f \"$p\" ]; then p=$(dirname \"$p\"); fi; git -C \"$p\" rev-parse --show-toplevel 2>/dev/null || realpath \"$p\""
        let rootResult = try await executeCommand(command, timeout: 20) { _ in }
        guard rootResult.exitCode == 0,
              let root = rootResult.output.split(separator: "\n").last.map(String.init),
              root.hasPrefix("/") else {
            throw ProgrammingToolError("project path does not exist or cannot be canonicalized")
        }
        let git = try await executeCommand("git -C \(shellQuote(root)) rev-parse HEAD 2>/dev/null; git -C \(shellQuote(root)) branch --show-current 2>/dev/null; git -C \(shellQuote(root)) config --get remote.origin.url 2>/dev/null || true", timeout: 20) { _ in }
        let rows = git.output.components(separatedBy: .newlines)
        let commit = rows.indices.contains(0) && rows[0].count >= 7 ? rows[0] : "unversioned"
        let branch = rows.indices.contains(1) && !rows[1].isEmpty ? rows[1] : "detached-or-unversioned"
        let remote = rows.indices.contains(2) && !rows[2].isEmpty ? rows[2] : nil
        guard let hostRoot = await resolvePathForDirectRead(root) else {
            throw ProgrammingToolError("canonical project path cannot be resolved in the active workspace")
        }
        return ProjectContext(root: root, hostRoot: hostRoot, commit: commit, branch: branch, remote: remote)
    }

    private func parseModules(text: String, name: String) -> Set<String> {
        var values: Set<String> = []
        let patterns: [String]
        switch name {
        case "Package.swift": patterns = [#"\.target\s*\(\s*name\s*:\s*\"([^\"]+)\""#, #"\.testTarget\s*\(\s*name\s*:\s*\"([^\"]+)\""#]
        case "Cargo.toml": patterns = [#"(?m)^name\s*=\s*\"([^\"]+)\""#]
        case "Podfile": patterns = [#"target\s+['\"]([^'\"]+)['\"]"#]
        case "project.yml": patterns = [#"(?m)^\s{0,4}([A-Za-z0-9_.-]+):\s*$"#]
        case "project.pbxproj": patterns = [#"productName = ([^;]+);"#]
        default: patterns = []
        }
        for p in patterns { values.formUnion(regexCaptures(p, in: text, limit: 200)) }
        return values
    }

    private func parseDependencies(text: String, name: String) -> Set<String> {
        var values: Set<String> = []
        let patterns: [String]
        switch name {
        case "Package.swift": patterns = [#"https?://[^\"']+/([^/\"']+?)(?:\.git)?[\"']"#, #"\.product\s*\(\s*name\s*:\s*\"([^\"]+)\""#]
        case "Cargo.toml": patterns = [#"(?m)^([A-Za-z0-9_-]+)\s*=\s*(?:\"|\{)"#]
        case "Podfile": patterns = [#"pod\s+['\"]([^'\"]+)['\"]"#]
        case "project.yml": patterns = [#"(?m)^\s*url:\s*.*?/([^/]+?)(?:\.git)?\s*$"#]
        case "project.pbxproj": patterns = [#"productName = ([^;]+);"#, #"repositoryURL = \"?([^;\"]+)"#]
        default: patterns = []
        }
        for p in patterns { values.formUnion(regexCaptures(p, in: text, limit: 300)) }
        return values
    }

    private func candidateCommands(manifests: [String], theos: Bool) -> [String: [String]] {
        var build: [String] = [], tests: [String] = [], lint: [String] = []
        if manifests.contains(where: { $0.hasSuffix("Package.swift") }) {
            build.append("swift build"); tests.append("swift test"); lint.append("swiftlint")
        }
        if manifests.contains(where: { $0.hasSuffix("project.pbxproj") || $0.hasSuffix(".xcodeproj") }) {
            build.append("xcodebuild -project <project>.xcodeproj -scheme <scheme> build")
            tests.append("xcodebuild -project <project>.xcodeproj -scheme <scheme> test")
        }
        if manifests.contains(where: { $0.hasSuffix("project.yml") }) { build.append("xcodegen generate") }
        if manifests.contains(where: { $0.hasSuffix("Podfile") }) { build.append("pod install") }
        if manifests.contains(where: { $0.hasSuffix("Cargo.toml") }) {
            build.append("cargo build"); tests.append("cargo test"); lint.append("cargo clippy --all-targets --all-features")
        }
        if manifests.contains(where: { $0.hasSuffix("Makefile") }) {
            build.append("make"); tests.append("make test"); lint.append("make lint")
        }
        if theos { build.append("make package"); tests.append("make test") }
        return ["build": Array(Set(build)).sorted(), "test": Array(Set(tests)).sorted(), "lint": Array(Set(lint)).sorted()]
    }

    // MARK: Incremental indexing and bounded search

    private func refreshCodeIndex(context: ProjectContext, force: Bool) async throws -> CodeIndexSnapshot {
        let fm = FileManager.default
        let rootURL = context.hostRoot
        let indexURL = indexFileURL(project: context.root)
        let old: CodeIndexSnapshot? = force ? nil : (try? Data(contentsOf: indexURL)).flatMap {
            try? JSONDecoder().decode(CodeIndexSnapshot.self, from: $0)
        }
        var files: [String: IndexedCodeFile] = [:]
        var indexedBytes = 0
        let maximumIndexedBytes = 48 * 1_024 * 1_024
        for url in projectFiles(rootURL: rootURL, maxDepth: 20, includeHidden: false, maxFiles: 12_000) {
            guard Self.programmingSearchExtensions.contains(url.pathExtension.lowercased()),
                  let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) <= 2_000_000 else { continue }
            let fileSize = values.fileSize ?? 0
            guard indexedBytes + fileSize <= maximumIndexedBytes else { continue }
            guard let data = try? Data(contentsOf: url), !data.contains(0),
                  let text = String(data: data, encoding: .utf8) else { continue }
            let rel = relative(url, to: rootURL)
            indexedBytes += data.count
            let hash = sha256(data)
            if let cached = old?.files[rel], cached.hash == hash {
                files[rel] = cached
            } else {
                files[rel] = IndexedCodeFile(relativePath: rel, hash: hash,
                                             byteCount: data.count,
                                             symbols: CodeSymbolExtractor.extract(text: text, extension: url.pathExtension))
            }
        }
        let snapshot = CodeIndexSnapshot(schemaVersion: 1, projectPath: context.root,
                                         commit: context.commit, generatedAt: Date(), files: files)
        try fm.createDirectory(at: indexURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoded = try JSONEncoder().encode(snapshot)
        try encoded.write(to: indexURL, options: .atomic)
        return snapshot
    }

    private func searchCode(_ args: [String: Any]) async throws -> FileToolResult {
        let context = try await projectContext(from: args)
        let query = ((args["query"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty, query.count <= 500 else { throw ProgrammingToolError("query must be 1...500 characters") }
        let limit = max(1, min(50, integer(args["limit"], default: 20)))
        let contextLines = max(0, min(4, integer(args["context_lines"], default: 2)))
        let requestedMode = ((args["mode"] as? String) ?? "auto").lowercased()
        let index = try await refreshCodeIndex(context: context, force: false)

        if requestedMode == "semantic", Self.semanticSearchProvider.isAvailable {
            let hits = try await Self.semanticSearchProvider.search(query: query, projectPath: context.root, limit: limit)
            return programmingJSON(["ok": true, "mode_used": "semantic", "provider": Self.semanticSearchProvider.providerName,
                                    "fallback": false, "hits": try jsonObject(hits)], success: true)
        }

        let terms = tokenize(query)
        let queryLower = query.lowercased()
        let rootURL = context.hostRoot
        var documentFrequency: [String: Int] = [:]
        var searchable: [(IndexedCodeFile, String, [String])] = []
        for entry in index.files.values {
            let url = rootURL.appendingPathComponent(entry.relativePath)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let symbolCandidate = entry.symbols.contains {
                $0.name.caseInsensitiveCompare(query) == .orderedSame
                    || $0.name.range(of: query, options: .caseInsensitive) != nil
            }
            let lexicalCandidate = text.range(of: query, options: .caseInsensitive) != nil
                || terms.contains { text.range(of: $0, options: .caseInsensitive) != nil }
            guard symbolCandidate || lexicalCandidate else { continue }
            let tokens = tokenize(text)
            for term in Set(tokens).intersection(terms) { documentFrequency[term, default: 0] += 1 }
            searchable.append((entry, text, tokens))
        }
        let n = Double(max(1, searchable.count))
        var hits: [CodeSearchHit] = []
        for (entry, text, tokens) in searchable {
            let lines = text.components(separatedBy: .newlines)
            let tokenCounts = Dictionary(grouping: tokens, by: { $0 }).mapValues(\.count)
            var baseScore = 0.0
            for term in terms {
                let tf = Double(tokenCounts[term] ?? 0)
                let df = Double(documentFrequency[term] ?? 0)
                baseScore += (tf / (tf + 1.2)) * log(1.0 + (n - df + 0.5) / (df + 0.5))
            }
            let matchingSymbols = entry.symbols.filter {
                $0.name.lowercased() == queryLower || $0.name.lowercased().contains(queryLower)
            }
            for symbol in matchingSymbols {
                let exactBonus = symbol.name.lowercased() == queryLower ? 100.0 : 35.0
                hits.append(makeHit(entry: entry, lines: lines, line: symbol.line,
                                    contextLines: contextLines, kind: symbol.kind, symbol: symbol.name,
                                    score: exactBonus + baseScore, commit: index.commit))
            }
            if matchingSymbols.isEmpty || requestedMode == "keyword" || requestedMode == "auto" || requestedMode == "semantic" {
                for (lineOffset, line) in lines.enumerated() where line.lowercased().contains(queryLower) {
                    hits.append(makeHit(entry: entry, lines: lines, line: lineOffset + 1,
                                        contextLines: contextLines, kind: "text", symbol: nil,
                                        score: 10.0 + baseScore, commit: index.commit))
                    if hits.count > limit * 8 { break }
                }
            }
        }
        let sorted = hits.sorted { lhs, rhs in
            lhs.score == rhs.score ? (lhs.path, lhs.line) < (rhs.path, rhs.line) : lhs.score > rhs.score
        }
        var deduped: [CodeSearchHit] = []
        var seen: Set<String> = []
        for hit in sorted where deduped.count < limit {
            let key = "\(hit.path):\(hit.line):\(hit.symbol ?? "")"
            if seen.insert(key).inserted { deduped.append(hit) }
        }
        let semanticRequested = requestedMode == "semantic"
        return programmingJSON([
            "ok": true,
            "mode_requested": requestedMode,
            "mode_used": "symbol+bm25+keyword",
            "semantic_provider": Self.semanticSearchProvider.providerName,
            "semantic_available": Self.semanticSearchProvider.isAvailable,
            "fallback": semanticRequested,
            "fallback_reason": semanticRequested ? "No embedding provider is configured or available on this device." : NSNull(),
            "commit": index.commit,
            "result_count": deduped.count,
            "context_lines": contextLines,
            "hits": try jsonObject(deduped)
        ], success: true)
    }

    private func makeHit(entry: IndexedCodeFile, lines: [String], line: Int, contextLines: Int,
                         kind: String, symbol: String?, score: Double, commit: String) -> CodeSearchHit {
        let start = max(1, line - contextLines)
        let end = min(lines.count, line + contextLines)
        let snippet = (start...max(start, end)).compactMap { number -> String? in
            guard number > 0, number <= lines.count else { return nil }
            return "\(number): \(String(lines[number - 1].prefix(500)))"
        }.joined(separator: "\n")
        return CodeSearchHit(path: entry.relativePath, line: line, endLine: end,
                             kind: kind, symbol: symbol, score: score,
                             snippet: String(snippet.prefix(3000)), commit: commit, fileHash: entry.hash)
    }

    private func readProgrammingFile(_ args: [String: Any]) async throws -> FileToolResult {
        let context = try await projectContext(from: args)
        guard let path = args["file"] as? String else { throw ProgrammingToolError("file is required") }
        let relativePath = try projectRelativePath(path, projectRoot: context.root)
        let url = try confinedFile(relativePath, projectRoot: context.hostRoot, mustExist: true)
        let maxBytes = max(256, min(64_000, integer(args["max_bytes"], default: 16_000)))
        let startLine = max(1, integer(args["start_line"], default: 1))
        let maxLines = max(1, min(1000, integer(args["max_lines"], default: 200)))
        let data = try Data(contentsOf: url)
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else {
            throw ProgrammingToolError("file is binary or not UTF-8")
        }
        let all = text.components(separatedBy: .newlines)
        let end = min(all.count, startLine + maxLines - 1)
        var content = startLine <= all.count
            ? (startLine...max(startLine, end)).map { "\($0): \(all[$0 - 1])" }.joined(separator: "\n")
            : ""
        var truncated = end < all.count
        if content.utf8.count > maxBytes {
            content = String(content.prefix(maxBytes)); truncated = true
        }
        let rel = relative(url, to: context.hostRoot)
        return programmingJSON([
            "ok": true, "path": rel, "canonical_path": url.path,
            "commit": context.commit, "file_hash": sha256(data),
            "start_line": startLine, "end_line": end, "total_lines": all.count,
            "truncated": truncated, "content": content
        ], success: true)
    }

    // MARK: Safe mutation, Git, lint, and tests

    private func applyProgrammingPatch(_ args: [String: Any]) async throws -> FileToolResult {
        let context = try await projectContext(from: args)
        guard let file = args["file"] as? String,
              let expectedHash = args["expected_hash"] as? String,
              let oldText = args["old_text"] as? String,
              let newText = args["new_text"] as? String,
              !file.isEmpty, !expectedHash.isEmpty, !oldText.isEmpty else {
            throw ProgrammingToolError("file, expected_hash, non-empty old_text, and new_text are required")
        }
        if let refusal = Self.offloadPlaceholderRefusal(field: "new_text", value: newText, path: file) {
            return refusal
        }
        let allowDirty = (args["allow_dirty"] as? Bool) ?? false
        let replaceAll = (args["replace_all"] as? Bool) ?? false
        return try await ProjectWriteLockRegistry.shared.withLock(project: context.root) { [self] in
            let relativeFile = try projectRelativePath(file, projectRoot: context.root)
            let hostURL = try confinedFile(relativeFile, projectRoot: context.hostRoot, mustExist: true)
            let linuxFile = context.root + "/" + relativeFile
            if MountedFolderCoordinator.isLinuxPathUnderReadOnlyMount(linuxFile)
                || MountedFolderCoordinator.isUnderReadOnlyMount(hostURL) {
                throw ProgrammingToolError("target is inside a read-only mounted folder")
            }
            let originalData = try Data(contentsOf: hostURL)
            guard let original = String(data: originalData, encoding: .utf8) else {
                throw ProgrammingToolError("target is not UTF-8 text")
            }
            let currentHash = sha256(originalData)
            guard currentHash.caseInsensitiveCompare(expectedHash) == .orderedSame else {
                throw ProgrammingToolError("hash_mismatch: expected \(expectedHash), current \(currentHash); re-read before patching")
            }
            let status = try await executeCommand("git -C \(shellQuote(context.root)) status --porcelain=v1 --untracked-files=all -- \(shellQuote(relativeFile))", timeout: 20) { _ in }
            guard status.exitCode == 0 else {
                throw ProgrammingToolError("git_status_failed: refusing to patch without a reliable dirty-file check (exit \(status.exitCode))")
            }
            let dirty = !status.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            guard allowDirty || !dirty else {
                throw ProgrammingToolError("uncommitted_changes: target file is already modified; pass allow_dirty=true only after reviewing and preserving them")
            }
            let matches = original.components(separatedBy: oldText).count - 1
            guard matches > 0 else { throw ProgrammingToolError("old_text not found; no file was changed") }
            guard replaceAll || matches == 1 else {
                throw ProgrammingToolError("old_text matches \(matches) locations; add context or set replace_all=true")
            }
            let updated: String
            if replaceAll {
                updated = original.replacingOccurrences(of: oldText, with: newText)
            } else if let range = original.range(of: oldText) {
                var copy = original
                copy.replaceSubrange(range, with: newText)
                updated = copy
            } else {
                throw ProgrammingToolError("old_text not found; no file was changed")
            }
            guard let updatedData = updated.data(using: .utf8) else {
                throw ProgrammingToolError("updated file is not valid UTF-8")
            }
            let tempURL = hostURL.deletingLastPathComponent()
                .appendingPathComponent(".\(hostURL.lastPathComponent).minis-\(UUID().uuidString).tmp")
            do {
                try updatedData.write(to: tempURL, options: [.atomic])
                let verify = try Data(contentsOf: tempURL)
                guard verify == updatedData else { throw ProgrammingToolError("temporary file verification failed") }
                let preWriteData = try Data(contentsOf: hostURL)
                let preWriteHash = sha256(preWriteData)
                guard preWriteHash.caseInsensitiveCompare(expectedHash) == .orderedSame,
                      preWriteData == originalData else {
                    throw ProgrammingToolError("hash_mismatch: target changed while the patch was being prepared; re-read before patching")
                }
                _ = try FileManager.default.replaceItemAt(hostURL, withItemAt: tempURL,
                                                          backupItemName: nil, options: [])
            } catch {
                try? FileManager.default.removeItem(at: tempURL)
                throw error
            }
            let landed = try Data(contentsOf: hostURL)
            guard landed == updatedData else { throw ProgrammingToolError("post-write verification failed") }
            ensureFakefsMetadata(for: linuxFile, isDirectory: false)
            let diff = try await executeCommand("git -C \(shellQuote(context.root)) diff --no-ext-diff -- \(shellQuote(relativeFile))", timeout: 30) { _ in }
            return programmingJSON([
                "ok": true, "project": context.root, "path": file,
                "previous_hash": currentHash, "file_hash": sha256(landed),
                "preexisting_uncommitted_changes": dirty, "replacements": replaceAll ? matches : 1,
                "atomic": true, "lock": "project_serial",
                "diff": diff.output, "diff_exit_code": diff.exitCode
            ], success: diff.exitCode == 0)
        }
    }

    private func runGitStatus(_ args: [String: Any]) async throws -> FileToolResult {
        let context = try await projectContext(from: args)
        let result = try await executeCommand("git -C \(shellQuote(context.root)) status --short --branch", timeout: 30) { _ in }
        let lines = result.output.components(separatedBy: .newlines).filter { !$0.isEmpty }
        return programmingJSON([
            "ok": result.exitCode == 0, "project": context.root,
            "branch": context.branch, "commit": context.commit,
            "exit_code": result.exitCode, "clean": lines.dropFirst().isEmpty,
            "status": result.output
        ], success: result.exitCode == 0)
    }

    private func runGitDiff(_ args: [String: Any]) async throws -> FileToolResult {
        let context = try await projectContext(from: args)
        let staged = (args["staged"] as? Bool) ?? false
        let statOnly = (args["stat_only"] as? Bool) ?? false
        var command = "git -C \(shellQuote(context.root)) diff --no-ext-diff"
        if staged { command += " --cached" }
        if statOnly { command += " --stat" }
        if let file = args["file"] as? String, !file.isEmpty {
            let relativeFile = try projectRelativePath(file, projectRoot: context.root)
            _ = try confinedFile(relativeFile, projectRoot: context.hostRoot, mustExist: false)
            command += " -- \(shellQuote(relativeFile))"
        }
        let result = try await executeCommand(command, timeout: 45) { _ in }
        return programmingJSON([
            "ok": result.exitCode == 0, "project": context.root,
            "commit": context.commit, "staged": staged, "stat_only": statOnly,
            "exit_code": result.exitCode, "diff": result.output
        ], success: result.exitCode == 0)
    }

    private func runProjectCommand(_ args: [String: Any], kind: String) async throws -> FileToolResult {
        let context = try await projectContext(from: args)
        let requested = ((args["command"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = candidateCommandsForProject(context: context, kind: kind)
        let command = requested.isEmpty ? candidates.first ?? "" : requested
        guard !command.isEmpty else { throw ProgrammingToolError("no \(kind) command was supplied or detected") }
        guard command.count <= 1000, !command.contains("\0") else { throw ProgrammingToolError("command is invalid or too long") }
        let timeout = max(1, min(7200, integer(args["timeout"], default: kind == "tests" ? 1800 : 900)))
        let fullLogPath = "/var/minis/offloads/programming-\(kind)-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).log"
        let fmLogURL = await writableHostURL(for: fullLogPath)
        var logHandle: FileHandle?
        if let fmLogURL {
            try? FileManager.default.createDirectory(at: fmLogURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: fmLogURL.path, contents: nil)
            logHandle = try? FileHandle(forWritingTo: fmLogURL)
        }
        defer { try? logHandle?.close() }
        let started = Date()
        let result = try await executeCommand("cd \(shellQuote(context.root)) && \(command)", timeout: TimeInterval(timeout)) { line in
            if let bytes = (line + "\n").data(using: .utf8) { try? logHandle?.write(contentsOf: bytes) }
        }
        if let tail = result.output.data(using: .utf8) { try? logHandle?.write(contentsOf: tail) }
        if fmLogURL != nil { ensureParentDirsInMetaDB(for: fullLogPath); ensureFakefsMetadata(for: fullLogPath, isDirectory: false) }
        let summary = String(result.output.suffix(8000))
        return programmingJSON([
            "ok": result.exitCode == 0, "kind": kind, "project": context.root,
            "command": command, "candidate_commands": candidates,
            "commit": context.commit, "exit_code": result.exitCode,
            "duration_seconds": Date().timeIntervalSince(started),
            "summary_tail": summary,
            "full_output_path": fmLogURL == nil ? NSNull() : fullLogPath,
            "output_externalized": fmLogURL != nil
        ], success: result.exitCode == 0)
    }

    private func candidateCommandsForProject(context: ProjectContext, kind: String) -> [String] {
        let root = context.hostRoot
        let exists: (String) -> Bool = { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        var output: [String] = []
        if exists("Package.swift") { output.append(kind == "tests" ? "swift test" : "swiftlint") }
        if exists("Cargo.toml") { output.append(kind == "tests" ? "cargo test" : "cargo clippy --all-targets --all-features") }
        if exists("Makefile") { output.append(kind == "tests" ? "make test" : "make lint") }
        if exists("Podfile") && kind == "lint" { output.append("pod lib lint") }
        return output
    }

    private func writableHostURL(for linuxPath: String) async -> URL? {
        if let url = await resolvePathForDirectRead(linuxPath) { return url }
        return resolveHostPath(linuxPath)
    }

    // MARK: Shared helpers

    private func programmingJSON(_ object: [String: Any], success: Bool) -> FileToolResult {
        let normalized = Self.jsonSafe(object)
        let data = try? JSONSerialization.data(withJSONObject: normalized, options: [.prettyPrinted, .sortedKeys])
        var output = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"ok\":false,\"error\":\"serialization_failed\"}"
        // High-level commands may print environment-backed credentials just like
        // shell_execute. Redact before either returning or externalizing so a
        // long result cannot persist an unmasked secret in offloads.
        output = EnvVarRedactor.redactIfEnabled(output).0
        if output.count > Self.programmingOutputLimit {
            let original = output
            if let sid = fsSessionId {
                let name = "programming-tool-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json"
                let url = Self.minisOffloadsPersistentDir(for: sid).appendingPathComponent(name)
                try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? original.data(using: .utf8)?.write(to: url, options: .atomic)
                output = "{\n  \"ok\": \(success),\n  \"externalized\": true,\n  \"summary\": \"Structured result exceeded \(Self.programmingOutputLimit) characters; read the externalized JSON for full output.\",\n  \"path\": \"\(Self.minisOffloadsLinuxDir)/\(name)\",\n  \"characters\": \(original.count)\n}"
            } else {
                output = String(original.prefix(Self.programmingOutputLimit)) + "\n[TRUNCATED: no session offload path available]"
            }
        }
        return FileToolResult(output: output, success: success)
    }

    nonisolated private static func jsonSafe(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            return dict.mapValues { jsonSafe($0) }
        }
        if let array = value as? [Any] { return array.map { jsonSafe($0) } }
        if value is NSNull || value is String || value is NSNumber || value is Bool || value is Int || value is Double { return value }
        return String(describing: value)
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> Any {
        let data = try JSONEncoder().encode(value)
        return try JSONSerialization.jsonObject(with: data)
    }

    private func projectRelativePath(_ input: String, projectRoot: String) throws -> String {
        try ProgrammingPathPolicy.projectRelativePath(input, projectRoot: projectRoot)
    }

    private func confinedFile(_ input: String, projectRoot: URL, mustExist: Bool) throws -> URL {
        guard !input.isEmpty, !input.hasPrefix("/"), !input.contains("\0") else {
            throw ProgrammingToolError("invalid project-relative file path")
        }
        let root = projectRoot.standardizedFileURL.resolvingSymlinksInPath()
        let candidate = root.appendingPathComponent(input).standardizedFileURL
        let exists = FileManager.default.fileExists(atPath: candidate.path)
        let resolved = exists
            ? candidate.resolvingSymlinksInPath()
            : candidate.deletingLastPathComponent().resolvingSymlinksInPath()
                .appendingPathComponent(candidate.lastPathComponent)
        let rootPrefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard resolved.path != root.path, resolved.path.hasPrefix(rootPrefix) else {
            throw ProgrammingToolError("file path escapes the project root")
        }
        if mustExist && !exists {
            throw ProgrammingToolError("file does not exist")
        }
        return resolved
    }

    private func indexFileURL(project: String) -> URL {
        let digest = sha256(Data(project.utf8))
        let base: URL
        if let sid = fsSessionId {
            base = Self.minisOffloadsPersistentDir(for: sid)
        } else {
            base = FileManager.default.temporaryDirectory
        }
        return base.appendingPathComponent("code-index", isDirectory: true)
            .appendingPathComponent("\(digest).json")
    }

    private func projectFiles(rootURL: URL, maxDepth: Int, includeHidden: Bool, maxFiles: Int) -> [URL] {
        let fm = FileManager.default
        let rootComponents = rootURL.standardizedFileURL.pathComponents.count
        let skipNames: Set<String> = [".git", ".build", "DerivedData", "Pods", "node_modules", "vendor", "build", "dist", ".theos"]
        guard let enumerator = fm.enumerator(at: rootURL,
                                             includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey],
                                             options: includeHidden ? [] : [.skipsHiddenFiles]) else { return [] }
        var result: [URL] = []
        while let url = enumerator.nextObject() as? URL, result.count < maxFiles {
            let depth = url.standardizedFileURL.pathComponents.count - rootComponents
            if depth > maxDepth { enumerator.skipDescendants(); continue }
            if skipNames.contains(url.lastPathComponent) { enumerator.skipDescendants(); continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true { enumerator.skipDescendants(); continue }
            if values?.isRegularFile == true { result.append(url) }
        }
        return result
    }

    private func relative(_ url: URL, to root: URL) -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
    }

    private func regexCaptures(_ pattern: String, in text: String, limit: Int) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).prefix(limit).compactMap { match in
            guard match.numberOfRanges > 1, let capture = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[capture]).trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    private func tokenize(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .map(String.init).filter { $0.count > 1 }.prefix(200_000).map { $0 }
    }

    private func languageName(_ ext: String) -> String {
        switch ext {
        case "swift": return "Swift"
        case "m", "mm", "h": return "Objective-C/C++"
        case "c", "cc", "cpp", "cxx", "hpp": return "C/C++"
        case "rs": return "Rust"
        case "py": return "Python"
        case "js", "jsx": return "JavaScript"
        case "ts", "tsx": return "TypeScript"
        case "java": return "Java"
        case "kt", "kts": return "Kotlin"
        case "sh": return "Shell"
        case "rb": return "Ruby"
        case "go": return "Go"
        default: return ext
        }
    }

    private func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private func integer(_ value: Any?, default fallback: Int) -> Int {
        (value as? Int) ?? (value as? Double).map(Int.init) ?? fallback
    }
}

private struct ProgrammingToolError: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
