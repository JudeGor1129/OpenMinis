import SwiftUI

/// No UI-process Frida initialization and no unbounded root shell.
@MainActor
enum PrivilegedHelperClient {
    private final class RequestBox: @unchecked Sendable {
        let request: OpenMinisPrivilegedRequest
        init(_ action: String) { request = OpenMinisPrivilegedRequest(action: action) }
    }
    static func run(_ action: String) async -> String {
        let box = RequestBox(action)
        return await withTaskCancellationHandler(operation: {
            if Task.isCancelled { box.request.cancel() }
            return await withCheckedContinuation { continuation in
                box.request.run(completion: { text in continuation.resume(returning: text) })
            }
        }, onCancel: { box.request.cancel() })
    }
}

@MainActor
struct PrivilegedToolsSection: View {
    @AppStorage(AgentToolSwitch.rootHelper.key) private var rootEnabled = false
    @AppStorage(AgentToolSwitch.fridaProcesses.key) private var processesEnabled = false
    @AppStorage("agent.tools.fridaProcesses.risk.v1") private var riskAccepted = false
    @State private var askRoot = false
    @State private var askFrida = false
    @State private var busy = false
    @State private var report = "尚未运行助手；本机身份："
    @State private var task: Task<Void, Never>?
    private var packaged: Bool { OpenMinisPrivilegedHelperPackaged() }
    var body: some View {
        Section {
            Toggle("允许受限 root 助手", isOn: Binding(
                get: { rootEnabled },
                set: { value in
                    if value { askRoot = true }
                    else { disableAll() }
                }))
                .disabled(!packaged)
            Text(packaged
                 ? "仅 TrollStore 专用包可用。GUI 不切换为 root；独立助手尝试实际 UID 0，并校验结果。不是为 iSH 或任意命令开启真实 root。"
                 : "此安装包未包含签名助手。请安装专用 TrollStore 构建；不能靠打开开关获得 root。")
                .font(.caption).foregroundStyle(.secondary)
            Button("验证助手的真实 root 身份") { execute("identity") }
                .disabled(!rootEnabled || busy || !packaged)
            Toggle("实验性 Frida 进程列表", isOn: Binding(
                get: { processesEnabled && riskAccepted },
                set: { value in
                    if value { askFrida = true }
                    else {
                        processesEnabled = false; riskAccepted = false
                        OpenMinisCancelPrivilegedRequests(); task?.cancel()
                    }
                }))
                .disabled(!rootEnabled || !packaged)
            Text("只连接本机 127.0.0.1:27042，固定 socket-only 后端，要求安装包版本为 Frida 17.9.10。不启动服务，不附加、不生成进程、不执行脚本；安装版本记录不能证明监听者身份。此前设备曾重启，隔离助手仍不能排除内核或服务端风险。")
                .font(.caption).foregroundStyle(.secondary)
            Button("查询本机 Frida 进程列表") { execute("frida-processes") }
                .disabled(!processesEnabled || !riskAccepted || !rootEnabled || busy || !packaged)
            if busy {
                HStack {
                    ProgressView()
                    Text("助手执行中（最多约十四秒）").font(.caption)
                    Spacer()
                    Button("取消") { task?.cancel() }
                }
            }
            Text(report).font(.caption.monospaced()).textSelection(.enabled)
            Text("权限提示：专用 GUI 签名也包含 persona 管理与解沙箱权限，开关并不能撤销二进制的签名权限；只应在本人设备和已授权目标上使用。服务端/内核崩溃可能仍导致设备重启。")
                .font(.caption).foregroundStyle(.secondary)
        } header: { Text("越狱 / 高权限诊断") }
        .onAppear { report = OpenMinisNativeIdentity() }
        .onDisappear { task?.cancel() }
        .alert("允许高权限助手？", isPresented: $askRoot) {
            Button("取消", role: .cancel) {}
            Button("允许受限操作") { rootEnabled = true }
        } message: {
            Text("此包具备高权限签名。只允许身份验证和经另行确认的 Frida 列表；不提供任意 root shell。只有助手返回实际 UID/EUID 0 才能确认成功。")
        }
        .alert("接受 Frida 实验性风险？", isPresented: $askFrida) {
            Button("取消", role: .cancel) {}
            Button("知悉风险并开启", role: .destructive) { riskAccepted = true; processesEnabled = true }
        } message: {
            Text("以前的 Frida 探测曾引发设备重启。独立助手避免 GUI 内初始化，但不能保证设备不会重启。确认开启后只执行本机只读进程列表。")
        }
    }
    private func disableAll() {
        rootEnabled = false; processesEnabled = false; riskAccepted = false
        OpenMinisCancelPrivilegedRequests()
        task?.cancel()
    }
    private func execute(_ action: String) {
        guard !busy else { return }
        busy = true
        task = Task { @MainActor in
            let text = await PrivilegedHelperClient.run(action)
            report = text
            busy = false
            task = nil
        }
    }
}
