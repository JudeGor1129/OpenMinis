import Foundation
import UIKit

// MARK: - Safe system-file access

enum SystemAccessMode: String, CaseIterable, Identifiable {
    case readonly
    case limited
    case expert
    var id: String { rawValue }
    var title: String {
        switch self { case .readonly: return "只读"; case .limited: return "有限写入"; case .expert: return "专家写入" }
    }
}

enum SystemAccessSettings {
    static let enabledKey = "system.access.enabled"
    static let modeKey = "system.access.mode"
    static var enabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    static var mode: SystemAccessMode {
        SystemAccessMode(rawValue: UserDefaults.standard.string(forKey: modeKey) ?? "readonly") ?? .readonly
    }
}

struct SystemAccessEnvelope {
    let value: [String: Any]
    var ok: Bool { value["ok"] as? Bool == true }
    var error: String? { value["error"] as? String }
    var code: String? { value["code"] as? String }

    var diagnosticSummary: String {
        var lines: [String] = []
        if let code { lines.append("错误代码：\(code)") }
        if let stage = value["stage"] as? String { lines.append("执行阶段：\(stage)") }
        let ids = ["uid", "euid", "gid", "egid"].map { key in
            "\(key)=\((value[key] as? NSNumber)?.stringValue ?? "未返回")"
        }.joined(separator: " ")
        lines.append("helper \(ids)")
        if let exitCode = value["exit_code"] as? NSNumber { lines.append("退出码：\(exitCode)") }
        return lines.joined(separator: "\n")
    }
}

@MainActor
enum SystemHelperClient {
    static func run(action: String, payload: [String: Any]) async -> SystemAccessEnvelope {
        guard SystemAccessSettings.enabled else {
            return SystemAccessEnvelope(value: ["ok": false, "code": "disabled", "error": "系统目录访问未在设置中开启。"]) 
        }
        // Backup/audit state is needed only by write and rollback. Request
        // bodies travel over the helper's FD 3 channel, so identity and read
        // never depend on this directory existing.
        if action == "write" || action == "rollback" {
            do {
                try FileManager.default.createDirectory(at: stateDirectory, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: stateDirectory.path)
            } catch {
                return SystemAccessEnvelope(value: ["ok": false, "code": "state_directory_failed", "error": error.localizedDescription])
            }
        }
        var body = payload
        body["mode"] = SystemAccessSettings.mode.rawValue
        let request = OpenMinisPrivilegedRequest(action: action, payload: body)
        // Task cancellation revokes the helper lease. A request cancelled before
        // it starts is refused by the bridge's authorization check.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.run { [request] text in
                    _ = request
                    let object: [String: Any]
                    if let data = text.data(using: .utf8),
                       let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                        object = parsed
                    } else {
                        object = ["ok": false, "code": "invalid_bridge_output", "error": text]
                    }
                    continuation.resume(returning: SystemAccessEnvelope(value: object))
                }
            }
        } onCancel: {
            request.cancel()
        }
    }

    /// Xina's root persona receives uid 0 but gets EPERM inside the app data
    /// container, so helper state lives in the rootless bootstrap temp area.
    /// The helper resolves this path itself and rejects symlinks/loose modes.
    static var stateDirectory: URL {
        URL(fileURLWithPath: "/var/jb/var/tmp/MinisSystemAccess", isDirectory: true)
    }
}

@MainActor
final class SystemWriteConfirmer {
    static let shared = SystemWriteConfirmer()
    private var pending = false

    func confirm(title: String, message: String, confirmButtonTitle: String) async -> Bool {
        guard !pending, UIApplication.shared.applicationState == .active else { return false }
        pending = true
        defer { pending = false }
        guard var presenter = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene }).flatMap(\.windows)
            .first(where: \.isKeyWindow)?.rootViewController else { return false }
        while let shown = presenter.presentedViewController { presenter = shown }
        return await withCheckedContinuation { continuation in
            let alert = UIAlertController(title: title, message: message, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "取消", style: .cancel) { _ in continuation.resume(returning: false) })
            alert.addAction(UIAlertAction(title: confirmButtonTitle, style: .destructive) { _ in continuation.resume(returning: true) })
            presenter.present(alert, animated: true)
        }
    }
}

@MainActor
enum SystemAccessAudit {
    static var fileURL: URL { SystemHelperClient.stateDirectory.appendingPathComponent("Audit/system-access.jsonl") }
    static func entries(limit: Int = 100) -> [[String: Any]] {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(max(1, min(500, limit))).reversed().compactMap {
            guard let data = String($0).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let dictionary = object as? [String: Any] else { return nil }
            return dictionary
        }
    }
}

extension AIChatViewModel {
    private func systemToolJSON(_ object: [String: Any], success: Bool) -> FileToolResult {
        let safe = Self.systemJSONSafe(object)
        let data = try? JSONSerialization.data(withJSONObject: safe, options: [.prettyPrinted, .sortedKeys])
        let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? "{\"ok\":false}"
        return FileToolResult(output: EnvVarRedactor.redactIfEnabled(text).0, success: success)
    }

    nonisolated private static func systemJSONSafe(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] { return dictionary.mapValues { systemJSONSafe($0) } }
        if let array = value as? [Any] { return array.map { systemJSONSafe($0) } }
        if value is NSNull || value is String || value is NSNumber || value is Bool || value is Int || value is Double { return value }
        return String(describing: value)
    }

    func executeSystemAccessTool(name: String, args: [String: Any]) async -> FileToolResult {
        guard SystemAccessSettings.enabled else {
            return FileToolResult(output: "系统目录访问已关闭。请在设置 → Agent Tools → 系统目录访问中开启。", success: false)
        }
        switch name {
        case "system_access_status":
            let result = await SystemHelperClient.run(action: "identity", payload: [:])
            return systemToolJSON(result.value, success: result.ok)
        case "system_file_read":
            guard let path = args["path"] as? String else { return FileToolResult(output: "缺少 path。", success: false) }
            let maxBytes = max(1, min(262_144, (args["max_bytes"] as? Int) ?? 65_536))
            let result = await SystemHelperClient.run(action: "read", payload: ["path": path, "max_bytes": maxBytes])
            return systemToolJSON(result.value, success: result.ok)
        case "system_file_write":
            return await executeConfirmedSystemWrite(args)
        case "system_file_rollback":
            return await executeConfirmedSystemRollback(args)
        case "system_access_audit":
            let limit = max(1, min(500, (args["limit"] as? Int) ?? 100))
            return systemToolJSON(["ok": true, "entries": SystemAccessAudit.entries(limit: limit)], success: true)
        default:
            return FileToolResult(output: "未知系统访问操作。", success: false)
        }
    }

    private func executeConfirmedSystemWrite(_ args: [String: Any]) async -> FileToolResult {
        guard SystemAccessSettings.mode != .readonly else {
            return FileToolResult(output: "当前为只读模式；请在设置中切换为有限写入或专家写入。", success: false)
        }
        guard let path = args["path"] as? String, let content = args["content"] as? String else {
            return FileToolResult(output: "system_file_write 需要 path 和 content。", success: false)
        }
        guard content.utf8.count <= 1_048_576 else {
            return FileToolResult(output: "拒绝：写入内容超过 1 MiB。", success: false)
        }
        let read = await SystemHelperClient.run(action: "read", payload: ["path": path, "max_bytes": 262_144])
        let existed = read.ok
        let old = read.value["content"] as? String ?? ""
        let expected = (read.value["sha256"] as? String) ?? "missing"
        if !read.ok, read.code != "target_missing", read.code != "open_failed" {
            return systemToolJSON(read.value, success: false)
        }
        let preview = Self.boundedSystemDiff(old: old, new: content)
        let message = "路径：\(path)\n模式：\(SystemAccessSettings.mode.title)\n原大小：\(old.utf8.count) B\n新大小：\(content.utf8.count) B\n\n\(preview)\n\n继续后将先备份，再进行原子替换。"
        guard await SystemWriteConfirmer.shared.confirm(title: existed ? "确认修改系统文件" : "确认创建系统文件", message: message, confirmButtonTitle: "写入") else {
            return FileToolResult(output: "用户已取消系统文件写入。", success: false)
        }
        let auditID = UUID().uuidString
        let result = await SystemHelperClient.run(action: "write", payload: [
            "path": path, "content": content, "expected_sha256": expected, "audit_id": auditID
        ])
        return systemToolJSON(result.value, success: result.ok)
    }

    private func executeConfirmedSystemRollback(_ args: [String: Any]) async -> FileToolResult {
        guard SystemAccessSettings.mode != .readonly else {
            return FileToolResult(output: "当前为只读模式，无法回滚系统文件。", success: false)
        }
        guard let sourceID = args["audit_id"] as? String,
              let entry = SystemAccessAudit.entries(limit: 500).first(where: { ($0["audit_id"] as? String) == sourceID }),
              let path = entry["path"] as? String else {
            return FileToolResult(output: "未找到可回滚的 audit_id。", success: false)
        }
        guard await SystemWriteConfirmer.shared.confirm(
            title: "确认回滚系统文件",
            message: "路径：\(path)\n审计记录：\(sourceID)\n\n仅当当前文件仍与该次写入的哈希一致时才会回滚。",
            confirmButtonTitle: "回滚") else {
            return FileToolResult(output: "用户已取消系统文件回滚。", success: false)
        }
        let result = await SystemHelperClient.run(action: "rollback", payload: [
            "rollback_audit_id": sourceID, "audit_id": UUID().uuidString
        ])
        return systemToolJSON(result.value, success: result.ok)
    }

    nonisolated static func boundedSystemDiff(old: String, new: String) -> String {
        if old == new { return "内容没有变化。" }
        let oldLines = old.components(separatedBy: .newlines)
        let newLines = new.components(separatedBy: .newlines)
        let count = max(oldLines.count, newLines.count)
        var output: [String] = []
        for index in 0..<count where output.count < 8 {
            let before = index < oldLines.count ? oldLines[index] : nil
            let after = index < newLines.count ? newLines[index] : nil
            if before == after { continue }
            if let before { output.append("- \(String(before.prefix(240)))") }
            if let after { output.append("+ \(String(after.prefix(240)))") }
        }
        if output.isEmpty { output.append("文本字节发生变化。") }
        if count > 8 { output.append("… diff 已限制为前 8 行变化") }
        return output.joined(separator: "\n")
    }
}


extension AIChatViewModel {
    func systemAccessToolDefinitions() -> [AgentToolDefinition] {
        let title = AgentToolParam(type: .string, description: "简短说明本次系统访问操作。")
        return [
            AgentToolDefinition(name: "system_access_status",
                description: "检查独立系统文件 helper 是否已打包并真实获得 uid/euid 0。不会修改文件。",
                parameters: ["tool_title": title], required: ["tool_title"], propertyOrdering: ["tool_title"]),
            AgentToolDefinition(name: "system_file_read",
                description: "通过短生命周期 root helper 读取受审查目录中的小型 UTF-8 文本文件。永久拒绝钥匙串、设备节点、trust/dyld 缓存、原始 preboot 和系统根目录。",
                parameters: [
                    "tool_title": title,
                    "path": AgentToolParam(type: .string, description: "绝对 iOS 路径。只读范围由 helper 白名单决定。"),
                    "max_bytes": AgentToolParam(type: .integer, description: "最大读取字节数，1...262144。")],
                required: ["tool_title", "path"], propertyOrdering: ["tool_title", "path", "max_bytes"]),
            AgentToolDefinition(name: "system_file_write",
                description: "修改受审查的 rootless 越狱文本文件。调用会先读取旧内容、显示有限 diff 并要求用户前台确认；helper 校验旧哈希、自动备份、fsync 并原子替换。只读模式不可用。",
                parameters: ["tool_title": title,
                    "path": AgentToolParam(type: .string, description: "受允许层级中的绝对路径。"),
                    "content": AgentToolParam(type: .string, description: "完整 UTF-8 新内容，最多 1 MiB。")],
                required: ["tool_title", "path", "content"], propertyOrdering: ["tool_title", "path", "content"]),
            AgentToolDefinition(name: "system_file_rollback",
                description: "按审计记录回滚一次系统文件写入。只有当前文件仍匹配被审计写入的哈希时才执行，并再次要求用户确认。",
                parameters: ["tool_title": title,
                    "audit_id": AgentToolParam(type: .string, description: "system_access_audit 返回的 UUID。")],
                required: ["tool_title", "audit_id"], propertyOrdering: ["tool_title", "audit_id"]),
            AgentToolDefinition(name: "system_access_audit",
                description: "列出系统文件写入和回滚审计元数据。记录路径、时间、动作、哈希和结果，不包含文件正文或凭证。",
                parameters: ["tool_title": title,
                    "limit": AgentToolParam(type: .integer, description: "返回最近记录数，1...500。")],
                required: ["tool_title"], propertyOrdering: ["tool_title", "limit"]),
        ]
    }
}
