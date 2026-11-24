import Foundation

// BEGIN ResponseIdleTimeoutSetting
/// Device-local response idle timeout, not a total generation deadline.
/// Official 1.15 (6eda5523): absent/default values leave existing instances at 120 s.
enum ResponseIdleTimeoutSetting {
    static let defaultSeconds = 120
    static let minSeconds = 30
    static let maxSeconds = 3600
    static let presets = [120, 300, 600, 1800, 3600]

    static func clamp(_ seconds: Int) -> Int { min(max(seconds, minSeconds), maxSeconds) }
    static func key(forInstanceId id: String) -> String { "provider.responseIdleTimeout.\(id)" }

    static func seconds(forInstanceId id: String?, defaults: UserDefaults = .standard) -> Int {
        guard let id, !id.isEmpty, let stored = defaults.object(forKey: key(forInstanceId: id)) as? Int else {
            return defaultSeconds
        }
        return clamp(stored)
    }

    static func set(_ seconds: Int?, forInstanceId id: String, defaults: UserDefaults = .standard) {
        guard !id.isEmpty else { return }
        guard let seconds, clamp(seconds) != defaultSeconds else {
            defaults.removeObject(forKey: key(forInstanceId: id))
            return
        }
        defaults.set(clamp(seconds), forKey: key(forInstanceId: id))
    }

    static func requestTimeout(forIdleSeconds idle: Int, sessionDefault: Int = 600) -> TimeInterval? {
        idle > sessionDefault ? TimeInterval(idle + 30) : nil
    }
}
// END ResponseIdleTimeoutSetting

/// Never add the setting to AgentProvider's protocol in this iOS 15 backport:
/// the SSE consumer explicitly selects OpenAIAgentProvider's Chat Completions path.
extension ResponseIdleTimeoutSetting {
    static func supports(_ instance: ProviderInstance) -> Bool {
        switch instance.providerType {
        case .openAI:
            // OAuth sign-in is Codex. A pasted bearer uses the compatible Chat API.
            return instance.credentialType == .apiKey
                || ProviderKeychainHelper.loadOAuthString(instanceId: instance.id, account: "manual-oauth-token") != nil
        case .openRouter, .xAI, .kimiCode, .githubCopilot:
            return true
        case .openAIResponses, .anthropic, .gemini, .antigravity, .unsupported:
            return false
        }
    }

    static func stalled(_ seconds: Int) -> LLMError {
        // Preserve the existing transient-error recovery and StopRetry behavior.
        .transientError(message: "No response from the server for \(seconds) seconds — the stream stalled mid-generation")
    }

    /// Starts only when dispatching HTTP, not during OAuth refresh or serialization.
    /// URLSession's await is cancellation-aware; the losing request/timer is cancelled.
    static func awaitFirstResponse<Value>(seconds: Int,
        operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
        try await withThrowingTaskGroup(of: ResponseIdleResult<Value>.self) { group in
            group.addTask { ResponseIdleResult(try await operation()) }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                try Task.checkCancellation()
                throw stalled(seconds)
            }
            defer { group.cancelAll() }
            return try await group.next()!.value
        }
    }
}

private final class ResponseIdleResult<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

// BEGIN ResponseIdleActivity
/// Lock-protected monotonic clock shared by the raw SSE pump and the agent watchdog.
/// Reasoning hidden by the UI is still activity. Comments/role-only frames are not.
final class ResponseIdleActivity: @unchecked Sendable {
    private let lock = NSLock()
    private var lastActivity = ProcessInfo.processInfo.systemUptime

    func reset(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        lastActivity = uptime
    }

    func record(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) { reset(at: uptime) }

    func elapsed(since waitStarted: TimeInterval? = nil,
                 now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        lock.lock(); defer { lock.unlock() }
        return max(0, now - max(lastActivity, waitStarted ?? lastActivity))
    }
}
// END ResponseIdleActivity

// BEGIN ChatCompletionsIdleActivity
/// Classifies the actual reply, without fabricating text/thinking/usage events.
enum ChatCompletionsIdleActivity {
    static func carriesActivity(_ line: String, interleavedField: String? = nil) -> Bool {
        guard line.hasPrefix("data:") else { return false }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespacesAndNewlines)
        if payload == "[DONE]" { return true }
        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        if event["usage"] is [String: Any] || event["error"] != nil { return true }
        guard let choices = event["choices"] as? [[String: Any]] else { return false }
        return choices.contains { choice in
            if let finish = choice["finish_reason"] as? String, !finish.isEmpty { return true }
            guard let delta = choice["delta"] as? [String: Any] else { return false }
            if let text = delta["content"] as? String, !text.isEmpty { return true }
            if let calls = delta["tool_calls"] as? [[String: Any]], !calls.isEmpty { return true }
            if let call = delta["function_call"] as? [String: Any], !call.isEmpty { return true }
            for field in ["reasoning_content", "reasoning", "reasoning_text"] + (interleavedField.map { [$0] } ?? []) {
                if let text = delta[field] as? String, !text.isEmpty { return true }
            }
            if let details = delta["reasoning_details"] as? [[String: Any]] {
                for item in details {
                    let field: String
                    switch item["type"] as? String {
                    case "reasoning.text": field = "text"
                    case "reasoning.summary": field = "summary"
                    case "reasoning.encrypted": field = "data"
                    default: continue
                    }
                    if let value = item[field] as? String, !value.isEmpty { return true }
                }
            }
            return false
        }
    }
}
// END ChatCompletionsIdleActivity
