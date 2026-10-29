import SwiftUI

struct SystemAccessSettingsView: View {
    @AppStorage(SystemAccessSettings.enabledKey) private var enabled = false
    @AppStorage(SystemAccessSettings.modeKey) private var modeRaw = SystemAccessMode.readonly.rawValue
    @State private var status = "尚未验证 helper 身份"
    @State private var identityDetails = ""
    @State private var isVerifyingIdentity = false
    @State private var auditEntries: [[String: Any]] = []
    @State private var rollbackResult: String?
    private var helperPackaged: Bool { OpenMinisPrivilegedHelperPackaged() }

    private var mode: Binding<SystemAccessMode> {
        Binding(get: { SystemAccessMode(rawValue: modeRaw) ?? .readonly },
                set: { modeRaw = $0.rawValue })
    }

    var body: some View {
        List {
            Section {
                Toggle("启用系统目录访问", isOn: $enabled)
                    .disabled(!helperPackaged)
                    .onChange(of: enabled) { value in
                        if !value { OpenMinisCancelPrivilegedRequests() }
                    }
                Picker("访问模式", selection: mode) {
                    ForEach(SystemAccessMode.allCases) { item in Text(item.title).tag(item) }
                }
                .disabled(!enabled)
            } footer: {
                Text(helperPackaged
                     ? "默认关闭。GUI 不会变成 root；每次操作由短生命周期独立 helper 执行。写入需要前台确认、旧哈希校验、备份、审计和原子替换。"
                     : "当前安装包不包含系统 helper。请安装专用 TrollStore 构建；普通签名版本不会获得系统访问能力。")
            }

            Section("能力状态") {
                Button("验证 root helper 身份") { verifyIdentity() }
                    .disabled(!enabled || isVerifyingIdentity)
                if isVerifyingIdentity {
                    HStack { ProgressView(); Text("正在验证 helper 身份…") }
                }
                Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                if !identityDetails.isEmpty {
                    Text(identityDetails).font(.caption.monospaced()).textSelection(.enabled)
                }
                Text(OpenMinisNativeIdentity()).font(.caption2).textSelection(.enabled)
            }

            Section("路径范围") {
                Text("只读：系统日志、越狱日志、dpkg 元数据、PreferenceLoader、PreferenceBundles、MobileSubstrate 配置与 APT 配置中的小型 UTF-8 文本。")
                Text("有限写入：rootless 临时目录、PreferenceLoader、PreferenceBundles、MobileSubstrate 动态库与 rootless 移动偏好。")
                Text("专家写入：额外开放 /var/jb/etc、/var/jb/usr/local、/var/jb/Library/LaunchDaemons。")
                Text("始终禁止：Keychain、设备节点、trust/dyld 缓存、/System、系统 /usr、/bin、/sbin、原始 preboot 和 /private/var/db。")
                    .foregroundStyle(.red)
            }

            if mode.wrappedValue == .expert {
                Section {
                    Label("专家模式可能破坏越狱启动环境。它仍不允许任意命令、递归删除、chmod/chown 或 launchctl。", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
            }

            Section {
                if auditEntries.isEmpty {
                    Text("暂无系统文件写入记录").foregroundStyle(.secondary)
                }
                ForEach(Array(auditEntries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 5) {
                        Text((entry["path"] as? String) ?? "未知路径").font(.subheadline)
                        Text("动作：\((entry["action"] as? String) ?? "unknown")")
                            .font(.caption).foregroundStyle(.secondary)
                        if let auditID = entry["audit_id"] as? String {
                            Text(auditID).font(.caption2.monospaced()).textSelection(.enabled)
                            if entry["backup_available"] as? Bool == true {
                                Button("回滚此修改", role: .destructive) { rollback(auditID, path: entry["path"] as? String) }
                                    .disabled(!enabled || mode.wrappedValue == .readonly)
                            }
                        }
                    }
                }
                Button("刷新审计记录") { reloadAudit() }
            } header: {
                Text("审计与回滚")
            } footer: {
                Text("审计只保存路径、动作、时间、字节数和前后哈希，不保存文件正文或凭证。")
            }

            if let rollbackResult {
                Section("最近结果") { Text(rollbackResult).font(.caption).textSelection(.enabled) }
            }
        }
        .navigationTitle("系统目录访问")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadAudit)
    }

    private func verifyIdentity() {
        guard !isVerifyingIdentity else { return }
        isVerifyingIdentity = true
        Task { @MainActor in
            defer { isVerifyingIdentity = false }
            let response = await SystemHelperClient.run(action: "identity", payload: [:])
            status = response.ok
                ? "身份已验证：helper 的 uid/euid/gid/egid 均为 0。文件读写能力仍需单独验证。"
                : "验证失败：\(response.error ?? response.code ?? "未知错误")"
            identityDetails = response.diagnosticSummary
        }
    }

    private func reloadAudit() { auditEntries = SystemAccessAudit.entries(limit: 100) }

    private func rollback(_ auditID: String, path: String?) {
        Task {
            guard await SystemWriteConfirmer.shared.confirm(
                title: "确认回滚系统文件",
                message: "路径：\(path ?? "未知")\n审计记录：\(auditID)\n\n只有当前文件哈希仍匹配时才会回滚。",
                confirmButtonTitle: "回滚") else { return }
            let response = await SystemHelperClient.run(action: "rollback", payload: [
                "rollback_audit_id": auditID, "audit_id": UUID().uuidString
            ])
            rollbackResult = response.ok ? "回滚成功" : "回滚失败：\(response.error ?? "未知错误")"
            reloadAudit()
        }
    }
}
