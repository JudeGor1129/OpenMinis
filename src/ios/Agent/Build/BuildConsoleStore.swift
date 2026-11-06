import Foundation
import SwiftUI

/// Lifecycle state shown in the chat's build console ("编译器").
enum BuildConsoleStatus: Equatable {
    case idle
    case running
    case succeeded
    case failed
    case cancelled

    var title: String {
        switch self {
        case .idle: return "未构建"
        case .running: return "构建中"
        case .succeeded: return "构建成功"
        case .failed: return "构建失败"
        case .cancelled: return "已取消"
        }
    }

    var symbol: String {
        switch self {
        case .idle: return "hammer"
        case .running: return "hammer.fill"
        case .succeeded: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        case .cancelled: return "slash.circle.fill"
        }
    }
}

/// One captured console line. `id` is a monotonically increasing sequence
/// number rather than a UUID so appending stays cheap and the order is stable.
struct BuildConsoleLine: Identifiable, Equatable {
    let id: Int
    let text: String
}

/// Per-session console buffer for the in-app compiler.
///
/// The build tools themselves stay pure (they return a `BuildToolResult`);
/// this store only mirrors what already happened so the console page can show
/// it without re-running anything. State is keyed by chat session id so
/// switching chats never shows another session's build output.
@MainActor
final class BuildConsoleStore: ObservableObject {
    static let shared = BuildConsoleStore()

    struct State: Equatable {
        var status: BuildConsoleStatus = .idle
        var lines: [BuildConsoleLine] = []
        var title: String = ""
        var projectPath: String = ""
        var startedAt: Date?
        var finishedAt: Date?
        var artifactPath: String?

        var duration: TimeInterval? {
            guard let startedAt, let finishedAt else { return nil }
            return max(0, finishedAt.timeIntervalSince(startedAt))
        }
    }

    /// Guards against a runaway provider dumping tens of thousands of lines
    /// into a SwiftUI list (and into the app's memory).
    private static let maxLines = 2_000

    @Published private(set) var states: [String: State] = [:]

    private var nextLineID = 1

    private init() {}

    func state(for sessionID: String?) -> State {
        states[Self.key(sessionID)] ?? State()
    }

    /// Reset the buffer and mark a new build as running.
    func begin(sessionID: String?, title: String, projectPath: String) {
        let key = Self.key(sessionID)
        var state = State()
        state.status = .running
        state.title = title
        state.projectPath = projectPath
        state.startedAt = Date()
        states[key] = state
        append("$ build_project · \(title)", sessionID: sessionID)
        append("project: \(projectPath)", sessionID: sessionID)
    }

    func append(_ text: String, sessionID: String?) {
        let key = Self.key(sessionID)
        var state = states[key] ?? State()
        let incoming = text.isEmpty ? [""] : text.components(separatedBy: "\n")
        for line in incoming {
            state.lines.append(BuildConsoleLine(id: nextLineID, text: line))
            nextLineID &+= 1
        }
        if state.lines.count > Self.maxLines {
            state.lines.removeFirst(state.lines.count - Self.maxLines)
        }
        states[key] = state
    }

    func finish(sessionID: String?, status: BuildConsoleStatus, artifactPath: String? = nil) {
        let key = Self.key(sessionID)
        var state = states[key] ?? State()
        state.status = status
        state.finishedAt = Date()
        if let artifactPath, !artifactPath.isEmpty { state.artifactPath = artifactPath }
        states[key] = state
        if let duration = state.duration {
            append("\(status.title) · \(String(format: "%.2f", duration))s", sessionID: sessionID)
        } else {
            append(status.title, sessionID: sessionID)
        }
    }

    func clear(sessionID: String?) {
        states[Self.key(sessionID)] = State()
    }

    /// Flatten a finished build into console lines. Only values the provider
    /// actually reported are printed — nothing is inferred or re-verified here.
    static func summary(of result: BuildToolResult) -> String {
        var lines: [String] = []
        if let provider = result.selectedProvider {
            lines.append("provider: \(provider.rawValue)")
        }
        lines.append("state: \(result.buildState.rawValue) · tests: \(result.testsState.rawValue)")
        if result.cacheHit {
            lines.append("cache: hit (复用 \(result.sourceRunID ?? "-") 的结果)")
        }
        if let build = result.build {
            lines.append("command: \(build.command)")
            lines.append("exit: \(build.exitCode) · \(String(format: "%.2f", build.durationSeconds))s")
            if !build.stdoutSummary.isEmpty { lines.append(build.stdoutSummary) }
            if !build.stderrSummary.isEmpty { lines.append(build.stderrSummary) }
            if !build.fullLogPath.isEmpty { lines.append("log: \(build.fullLogPath)") }
            for (key, value) in build.remoteMetadata.sorted(by: { $0.key < $1.key }) {
                lines.append("meta.\(key): \(value)")
            }
        } else {
            lines.append("command: (provider 未返回命令输出)")
        }
        for artifact in result.artifacts {
            let archs = artifact.architectures.isEmpty ? "" : " · \(artifact.architectures.joined(separator: "+"))"
            lines.append("artifact: \(artifact.path) · \(artifact.kind.rawValue) · \(artifact.state.rawValue)\(archs)")
        }
        if result.diagnostics.errorCount > 0 || result.diagnostics.warningCount > 0 {
            lines.append("diagnostics: errors=\(result.diagnostics.errorCount) warnings=\(result.diagnostics.warningCount)")
        }
        if let firstError = result.diagnostics.firstError {
            let location = [firstError.file, firstError.line.map(String.init)]
                .compactMap { $0 }
                .joined(separator: ":")
            lines.append("first error: \(location.isEmpty ? "" : location + " ")\(firstError.message)")
        }
        if let error = result.persistenceError, !error.isEmpty {
            lines.append("persistence: \(error)")
        }
        return lines.joined(separator: "\n")
    }

    private static func key(_ sessionID: String?) -> String {
        guard let sessionID, !sessionID.isEmpty else { return "draft" }
        return sessionID
    }
}
