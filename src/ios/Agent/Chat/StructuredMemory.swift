import Foundation

// MARK: - Structured memory domain

struct ProjectRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var canonicalPath: String
    var gitRemote: String?
    var currentBranch: String?
    var lastCommit: String?
    var languageStack: [String]
    var toolchainProfile: [String]
    var buildCommands: [String]
    var createdAt: Date
    var updatedAt: Date
}

struct StructuredMemoryRecord: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var scope: String
    var type: String
    var projectId: String?
    var key: String?
    var content: String
    var sourceSessionId: String?
    var sourceMessageId: String?
    var sourceRefs: [String]
    var confidence: Double
    var importance: Double
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var expiresAt: Date?
    var supersedesId: String?
    var sensitivity: String
    var status: String
    var isPinned: Bool
}

struct TaskCheckpoint: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var sessionId: String
    var projectId: String?
    var goal: String
    var acceptanceCriteria: [String]
    var factsAndConstraints: [String]
    var completedSteps: [String]
    var changedFiles: [String]
    var commandsRun: [String]
    var testResults: [String]
    var failuresAndBlockers: [String]
    var nextAction: String
    var sourceMarkerId: String?
    var previousCheckpointId: String?
    var status: String
    var createdAt: Date
    var updatedAt: Date
}

struct TokenBudgetSnapshot: Sendable, Equatable {
    var modelId: String
    var contextWindow: Int
    var systemAndTools: Int
    var checkpointAndMemory: Int
    var recentMessages: Int
    var codeAndLogs: Int
    var outputReserve: Int
    var estimatedInput: Int {
        systemAndTools + checkpointAndMemory + recentMessages + codeAndLogs
    }
}

enum TokenBudgetManager {
    /// Category caps, not extra context. System/tool cost is measured, the
    /// remaining input is split between durable state and live conversation,
    /// and output is reserved before either can consume the whole window.
    static func allocation(contextWindow: Int, modelId: String) -> TokenBudgetSnapshot {
        let window = max(contextWindow, 16_000)
        let output = min(32_000, max(2_048, Int(Double(window) * 0.15)))
        let input = max(0, window - output)
        return TokenBudgetSnapshot(
            modelId: modelId,
            contextWindow: contextWindow,
            systemAndTools: Int(Double(input) * 0.18),
            checkpointAndMemory: Int(Double(input) * 0.24),
            recentMessages: Int(Double(input) * 0.38),
            codeAndLogs: Int(Double(input) * 0.20),
            outputReserve: output
        )
    }

    static func snapshot(modelId: String, contextWindow: Int, fixedTokens: Int,
                         checkpointMemoryTokens: Int, history: [AgentMessage]) -> TokenBudgetSnapshot {
        var recent = 0
        var codeLogs = 0
        let recentStart = max(0, history.count - 12)
        for (index, message) in history.enumerated() {
            let tokens = ContextSizeMeter.estimateTokens(message: message)
            let hasTool = message.parts.contains { part in
                switch part {
                case .toolUse, .toolResult: return true
                default: return false
                }
            }
            if hasTool || index < recentStart { codeLogs += tokens }
            else { recent += tokens }
        }
        return TokenBudgetSnapshot(
            modelId: modelId,
            contextWindow: contextWindow,
            systemAndTools: max(0, fixedTokens - checkpointMemoryTokens),
            checkpointAndMemory: checkpointMemoryTokens,
            recentMessages: recent,
            codeAndLogs: codeLogs,
            outputReserve: allocation(contextWindow: contextWindow, modelId: modelId).outputReserve
        )
    }
}

// MARK: - Admission and redaction

enum MemoryCredentialGuard {
    struct Finding: Equatable, Sendable { let kind: String }

    /// Deliberately conservative. Memory is long-lived and searchable, so an
    /// uncertain credential-like value is rejected rather than redacted and
    /// partially retained. Paths, commit hashes, and ordinary UUIDs are allowed.
    static func finding(in text: String) -> Finding? {
        let patterns: [(String, String)] = [
            ("private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
            ("authorization header", #"(?i)authorization\s*:\s*(bearer|basic)\s+[^\s]+"#),
            ("API token", #"(?i)\b(sk-[A-Za-z0-9_-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|xox[baprs]-[A-Za-z0-9-]{20,})\b"#),
            ("credential assignment", #"(?i)\b(api[_-]?key|access[_-]?token|refresh[_-]?token|client[_-]?secret|password|passwd)\b\s*[:=]\s*[^\s,;]{8,}"#),
            ("URL credential", #"(?i)https?://[^/@:\s]+:[^/@\s]+@"#)
        ]
        for (kind, pattern) in patterns where text.range(of: pattern, options: .regularExpression) != nil {
            return Finding(kind: kind)
        }
        return nil
    }

    static func admits(_ content: String) -> Bool {
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && finding(in: content) == nil
    }
}

enum AutoMemoryAdmission {
    enum Origin: Sendable { case explicitUser, projectTool, ordinaryConversation }

    static func admits(content: String, origin: Origin, autoMemoryEnabled: Bool) -> Bool {
        guard MemoryCredentialGuard.admits(content) else { return false }
        switch origin {
        case .explicitUser: return true
        case .projectTool: return autoMemoryEnabled
        case .ordinaryConversation: return false
        }
    }
}

// MARK: - Checkpoint markdown codec

enum StructuredCheckpointCodec {
    static let headings = [
        "Goal", "Acceptance Criteria", "Facts & Constraints", "Completed Steps",
        "Changed Files", "Commands Run", "Test Results", "Failures & Blockers", "Next Action"
    ]

    static func parse(_ markdown: String, sessionId: String, projectId: String?,
                      sourceMarkerId: String?, previousCheckpointId: String? = nil,
                      now: Date = Date()) -> TaskCheckpoint {
        var sections: [String: [String]] = [:]
        var current: String?
        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let normalized = line.replacingOccurrences(of: #"^#{1,6}\s*"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: CharacterSet(charactersIn: ":： "))
            if let heading = headings.first(where: { $0.caseInsensitiveCompare(normalized) == .orderedSame }) {
                current = heading
                continue
            }
            guard let current, !line.isEmpty else { continue }
            let value = line.replacingOccurrences(of: #"^[-*]\s+"#, with: "", options: .regularExpression)
            sections[current, default: []].append(value)
        }
        func list(_ name: String) -> [String] {
            (sections[name] ?? []).filter { $0.lowercased() != "none" && $0 != "无" }
        }
        let goal = list("Goal").joined(separator: "\n")
        let next = list("Next Action").joined(separator: "\n")
        return TaskCheckpoint(
            id: UUID().uuidString, sessionId: sessionId, projectId: projectId,
            goal: goal.isEmpty ? "Conversation continuity" : goal,
            acceptanceCriteria: list("Acceptance Criteria"),
            factsAndConstraints: list("Facts & Constraints"), completedSteps: list("Completed Steps"),
            changedFiles: list("Changed Files"), commandsRun: list("Commands Run"),
            testResults: list("Test Results"), failuresAndBlockers: list("Failures & Blockers"),
            nextAction: next, sourceMarkerId: sourceMarkerId,
            previousCheckpointId: previousCheckpointId,
            status: next.isEmpty ? "completed" : "active", createdAt: now, updatedAt: now
        )
    }

    static func render(_ checkpoint: TaskCheckpoint) -> String {
        func section(_ title: String, _ values: [String]) -> String {
            "## \(title)\n" + (values.isEmpty ? "- None" : values.map { "- \($0)" }.joined(separator: "\n"))
        }
        return [
            "## Goal\n\(checkpoint.goal)",
            section("Acceptance Criteria", checkpoint.acceptanceCriteria),
            section("Facts & Constraints", checkpoint.factsAndConstraints),
            section("Completed Steps", checkpoint.completedSteps),
            section("Changed Files", checkpoint.changedFiles),
            section("Commands Run", checkpoint.commandsRun),
            section("Test Results", checkpoint.testResults),
            section("Failures & Blockers", checkpoint.failuresAndBlockers),
            "## Next Action\n\(checkpoint.nextAction.isEmpty ? "None" : checkpoint.nextAction)"
        ].joined(separator: "\n\n")
    }
}

// MARK: - Project evidence extraction

struct ProjectEvidence: Sendable {
    var canonicalPath: String
    var remote: String?
    var branch: String?
    var commit: String?
    var buildCommands: [String]
    var stack: [String]
    var toolchain: [String]
}

enum ProjectScopeDetector {
    static func detect(command: String, output: String) -> ProjectEvidence? {
        let cd = firstMatch(#"(?:^|[;&|]\s*)cd\s+(?:--\s+)?(?:'([^']+)'|\"([^\"]+)\"|([^;&|\n]+))"#, in: command)
        let explicit = [cd?.first.map(String.init),
                        firstMatch(#"(?m)^(/var/minis/(?:workspace|mounts|shared)/[^\s]+)"#, in: output)?.first.map(String.init)]
            .compactMap { $0 }.first
        guard let path = explicit?.trimmingCharacters(in: .whitespacesAndNewlines), path.hasPrefix("/") else { return nil }
        let canonical = URL(fileURLWithPath: path).standardizedFileURL.path
        let remote = firstMatch(#"(?:https?://|ssh://|git@)[^\s]+"#, in: output)?.first.map(String.init)
        let branch = firstMatch(#"(?m)^(?:##|On branch)\s+([^.\s]+)"#, in: output)?.first.map(String.init)
        let commit = command.contains("git ") ? firstMatch(#"\b[0-9a-f]{7,40}\b"#, in: output)?.first.map(String.init) : nil
        let buildLines = command.components(separatedBy: .newlines).filter {
            let s = $0.lowercased()
            return ["xcodebuild", "swift build", "swift test", "make", "npm test", "gradle", "cargo test", "pytest"].contains { s.contains($0) }
        }
        let lower = command.lowercased() + "\n" + output.lowercased()
        let stack = [("Package.swift", "Swift"), (".xcodeproj", "iOS/Xcode"), ("Cargo.toml", "Rust"),
                     ("package.json", "JavaScript"), ("Makefile", "Make")].compactMap { lower.contains($0.0.lowercased()) ? $0.1 : nil }
        let tools = ["xcodebuild", "swift", "theos", "make", "cargo", "npm", "gradle", "pytest"].filter { lower.contains($0) }
        return ProjectEvidence(canonicalPath: canonical, remote: remote, branch: branch,
                               commit: commit, buildCommands: buildLines, stack: stack, toolchain: tools)
    }

    private static func firstMatch(_ pattern: String, in text: String) -> [Substring]? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (1..<match.numberOfRanges).compactMap { index in
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return text[range]
        }.isEmpty ? Range(match.range, in: text).map { [text[$0]] } :
            (1..<match.numberOfRanges).compactMap { Range(match.range(at: $0), in: text).map { text[$0] } }
    }
}
