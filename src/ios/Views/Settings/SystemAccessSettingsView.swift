import SwiftUI

struct SystemAccessSettingsView: View {
    @State private var status = "尚未验证 helper 身份"
    @State private var identityDetails = ""
    @State private var isVerifyingIdentity = false
    @State private var auditEntries: [[String: Any]] = []
    private var helperPackaged: Bool { OpenMinisPrivilegedHelperPackaged() }

    var body: some View {
        List {
            Section {
                Label("系统目录权限按会话控制", systemImage: "lock.shield")
                Text("默认关闭。请进入目标会话，在消息页右上角 More 菜单中打开“本会话权限”。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if !helperPackaged {
                    Label("当前安装包不包含系统 helper。", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } footer: {
                Text("权限不会从一个会话继承到另一个会话。写入和回滚仍需要前台确认、旧哈希校验、备份、审计和原子替换。")
            }

            Section("能力状态") {
                Button("验证 root helper 身份") { verifyIdentity() }
                    .disabled(!helperPackaged || isVerifyingIdentity)
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
                        }
                    }
                }
                Button("刷新审计记录") { reloadAudit() }
            } header: {
                Text("审计与回滚")
            } footer: {
                Text("审计只保存路径、动作、时间、字节数和前后哈希，不保存文件正文或凭证。")
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

}
