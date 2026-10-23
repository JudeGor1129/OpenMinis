//
//  RootfsManagementView.swift
//  MinisApp
//
//  UI for managing rootfs (reset, backup, restore)
//

import SwiftUI

struct RootfsManagementView: View {
    @StateObject private var viewModel = RootfsManagementViewModel()
    @State private var showFileBrowser = false

    var body: some View {
        List {
            Section("Status") {
                HStack {
                    // The label used to be a hardcoded Text("Installed"), which
                    // read as a claim rather than a field name: with no rootfs
                    // present the row said "Installed ❌", contradicting both the
                    // icon and the "Install Rootfs" action right below it. Use a
                    // neutral field name and put the state in the value.
                    Text("Status")
                    Spacer()
                    Text(viewModel.isInstalled ? "Installed" : "Not Installed")
                        .foregroundStyle(.secondary)
                    Image(systemName: viewModel.isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(viewModel.isInstalled ? .green : .red)
                }

                if viewModel.isInstalled {
                    HStack {
                        Text("Size")
                        Spacer()
                        if viewModel.rootfsSize > 0 {
                            Text(viewModel.formattedSize)
                                .foregroundColor(.secondary)
                        } else {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }

                    HStack {
                        Text("Path")
                        Spacer()
                        Text(viewModel.rootfsPath)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            if viewModel.isInstalled {
                Section("Browse") {
                    Button(action: { showFileBrowser = true }) {
                        Label {
                            Text("Browse Files")
                        } icon: {
                            Image(systemName: "folder.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.blue, in: Circle())
                        }
                    }
                }

                MirrorsSectionView()
                MinisEnvironmentPresetsSection()
                Section("外部文件") {
                    NavigationLink(destination: MountedFoldersSettingsView()) {
                        Label("挂载外部文件夹", systemImage: "folder.badge.plus")
                    }
                }
            }

            Section("Actions") {
                if !viewModel.isInstalled {
                    Button(action: { viewModel.install() }) {
                        Label {
                            Text("Install Rootfs")
                        } icon: {
                            Image(systemName: "arrow.down.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.green, in: Circle())
                        }
                    }
                    .disabled(viewModel.isProcessing)
                } else {
                    Button(action: { viewModel.showResetConfirmation = true }) {
                        Label {
                            Text("Reset Rootfs")
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.orange, in: Circle())
                        }
                    }
                    .disabled(viewModel.isProcessing)

                    Button(action: { viewModel.showResetWithBackupConfirmation = true }) {
                        Label {
                            Text("Reset & Backup User Data")
                        } icon: {
                            Image(systemName: "archivebox.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.indigo, in: Circle())
                        }
                    }
                    .disabled(viewModel.isProcessing)
                }

                if viewModel.hasBackup {
                    Button(action: { viewModel.restoreBackup() }) {
                        Label {
                            Text("Restore User Data")
                        } icon: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(.white)
                                .frame(width: 21, height: 21)
                                .background(.teal, in: Circle())
                        }
                    }
                    .disabled(viewModel.isProcessing || !viewModel.isInstalled)
                }
            }

            if viewModel.isProcessing {
                Section {
                    HStack {
                        ProgressView()
                        Text(viewModel.statusMessage)
                            .foregroundColor(.secondary)
                    }
                }
            }

            if let message = viewModel.resultMessage {
                Section {
                    Text(message)
                        .font(.callout)
                        .foregroundColor(viewModel.lastOperationSuccess ? .green : .red)
                }
            }

            // [T-ios-toolchain-status] Show iSH toolchain status for all installed tools
            ToolchainStatusView()

            Section("Info") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("About Rootfs")
                        .font(.headline)

                    Text("The rootfs contains the Alpine Linux filesystem. Resetting will delete all data and restore to factory state.")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Text("• Reset: Delete everything\n• Backup: Save /root directory\n• Restore: Recover saved data")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .navigationTitle("Rootfs Management")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            viewModel.refresh()
        }
        .alert("Reset Rootfs?", isPresented: $viewModel.showResetConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset", role: .destructive) {
                viewModel.resetRootfs(keepUserData: false)
            }
        } message: {
            Text("This will delete the entire rootfs. All data will be lost. The app will need to restart to reinstall.")
        }
        .alert("Reset with Backup?", isPresented: $viewModel.showResetWithBackupConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Reset & Backup", role: .destructive) {
                viewModel.resetRootfs(keepUserData: true)
            }
        } message: {
            Text("This will backup your /root directory, then reset the rootfs. You can restore the backup later.")
        }
        .sheet(isPresented: $showFileBrowser) {
            MinisNavigationContainer {
                FileBrowserView(rootPath: RootfsManager.shared.dataPath, rootLabel: "/")
            }
        }
    }
}

class RootfsManagementViewModel: ObservableObject {
    @Published var isInstalled = false
    @Published var isProcessing = false
    @Published var statusMessage = ""
    @Published var resultMessage: String?
    @Published var lastOperationSuccess = false
    @Published var rootfsSize: Int64 = 0
    @Published var hasBackup = false
    @Published var showResetConfirmation = false
    @Published var showResetWithBackupConfirmation = false

    private var backupURL: URL?

    var rootfsPath: String {
        RootfsManager.shared.rootfsPath.path
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: rootfsSize, countStyle: .file)
    }

    func refresh() {
        isInstalled = RootfsManager.shared.isInstalled

        if isInstalled {
            DispatchQueue.global(qos: .utility).async {
                do {
                    let size = try RootfsManager.shared.getRootfsSize()
                    DispatchQueue.main.async {
                        self.rootfsSize = size
                    }
                } catch {
                    print("Failed to get rootfs size: \(error)")
                }
            }
        }
    }

    func install() {
        isProcessing = true
        statusMessage = "Installing rootfs..."
        resultMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try RootfsManager.shared.installIfNeeded()

                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.lastOperationSuccess = true
                    self.resultMessage = "✅ Rootfs installed successfully"
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.lastOperationSuccess = false
                    self.resultMessage = "❌ Installation failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func resetRootfs(keepUserData: Bool) {
        isProcessing = true
        statusMessage = keepUserData ? "Backing up and resetting..." : "Resetting rootfs..."
        resultMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let backup = try RootfsManager.shared.reset(keepUserData: keepUserData)

                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.lastOperationSuccess = true
                    self.backupURL = backup
                    self.hasBackup = backup != nil

                    if keepUserData {
                        self.resultMessage = "✅ Rootfs reset with backup created"
                    } else {
                        self.resultMessage = "✅ Rootfs reset complete. Restart app to reinstall."
                    }

                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.lastOperationSuccess = false
                    self.resultMessage = "❌ Reset failed: \(error.localizedDescription)"
                }
            }
        }
    }

    func restoreBackup() {
        guard let backupURL = backupURL else {
            resultMessage = "❌ No backup available"
            return
        }

        isProcessing = true
        statusMessage = "Restoring user data..."
        resultMessage = nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try RootfsManager.shared.restoreUserData(from: backupURL)

                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.lastOperationSuccess = true
                    self.resultMessage = "✅ User data restored successfully"
                    self.refresh()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.lastOperationSuccess = false
                    self.resultMessage = "❌ Restore failed: \(error.localizedDescription)"
                }
            }
        }
    }
}

#Preview {
    MinisNavigationContainer {
        RootfsManagementView()
    }
}

// Presets use the existing Alpine guest and terminal, never the iOS host.
private struct MinisEnvironmentPreset: Identifiable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let commands: [String]
    let packages: String
    let versionCommand: String

    static let all: [Self] = [
        .init(id: "python", title: "Python", detail: "Python、pip 和虚拟环境", symbol: "chevron.left.forwardslash.chevron.right", commands: ["python3", "pip3"], packages: "python3 py3-pip", versionCommand: "python3 --version; pip3 --version; python3 -m venv --help"),
        .init(id: "node", title: "Node.js", detail: "Node.js 和 npm", symbol: "shippingbox", commands: ["node", "npm"], packages: "nodejs npm", versionCommand: "node --version; npm --version"),
        .init(id: "git", title: "Git", detail: "克隆仓库与版本管理", symbol: "point.topleft.down.curvedto.point.bottomright.up", commands: ["git"], packages: "git", versionCommand: "git --version"),
        .init(id: "ssh", title: "SSH", detail: "SSH、SCP、SFTP 与密钥生成", symbol: "key", commands: ["ssh", "scp", "sftp", "ssh-keygen"], packages: "openssh-client openssh-keygen", versionCommand: "ssh -V; command -v scp sftp ssh-keygen"),
        .init(id: "network", title: "网络工具", detail: "curl · wget", symbol: "network", commands: ["curl", "wget"], packages: "curl wget", versionCommand: "curl --version; wget --help"),
        .init(id: "archive", title: "压缩工具", detail: "zip · unzip", symbol: "archivebox", commands: ["zip", "unzip"], packages: "zip unzip", versionCommand: "zip -v; unzip -v")
    ]
}

private struct MinisEnvironmentPresetsSection: View {
    @State private var statuses: [String: String] = [:]
    @State private var checking = false
    @State private var notice: String?

    var body: some View {
        Section {
            ForEach(MinisEnvironmentPreset.all) { preset in
                NavigationLink {
                    MinisEnvironmentPresetDetail(preset: preset)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: preset.symbol).frame(width: 24)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.title)
                            Text(preset.detail).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(statuses[preset.id] ?? "未检测")
                            .font(.caption).foregroundColor(.secondary)
                    }
                }
            }
            Button(action: refresh) {
                HStack {
                    Label("刷新工具状态", systemImage: "arrow.clockwise")
                    if checking { Spacer(); ProgressView() }
                }
            }.disabled(checking)
            if let notice { Text(notice).font(.caption).foregroundColor(.secondary) }
        } header: {
            Text("环境预设")
        } footer: {
            Text("工具运行在 App 内的 Alpine 环境中。状态仅表示命令入口存在，不保证所有依赖或项目兼容。安装需要网络；进入详情后确认执行。")
        }
        .onAppear { if statuses.isEmpty { refresh() } }
    }

    private func refresh() {
        guard !checking else { return }
        guard ISHKernel.shared.isBooted else {
            notice = "请先打开内置终端启动环境，再返回刷新。"
            return
        }
        guard !RootfsManager.shared.didResetWhileBooted else {
            notice = "环境已重置，请退出并重新打开 App 后检测。"
            return
        }
        checking = true
        notice = nil
        // Fixed command names only. One bounded guest process, no host shell,
        // no install side effects, and no shell execution on the main queue.
        let checks = MinisEnvironmentPreset.all.map { preset in
            let tests = preset.commands.map { "command -v \($0) >/dev/null 2>&1" }.joined(separator: " && ")
            return "if \(tests); then echo '\(preset.id)=present'; else echo '\(preset.id)=missing'; fi"
        }.joined(separator: "; ")
        DispatchQueue.global(qos: .utility).async {
            let result = ISHShellExecutor.executeCommandSync(checks, timeout: 15, lineCallback: nil)
            let output = result.output
            let success = result.exitCode == 0 && result.error.rawValue == 0
            DispatchQueue.main.async {
                checking = false
                guard success else {
                    statuses = [:]
                    notice = "检测失败或超时，请检查内置终端是否正常运行后重试。"
                    return
                }
                var updated: [String: String] = [:]
                for line in output.components(separatedBy: .newlines) {
                    let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "=", maxSplits: 1)
                    guard parts.count == 2 else { continue }
                    updated[String(parts[0])] = parts[1] == "present" ? "已安装" : "未完整安装"
                }
                statuses = updated
                if updated.count != MinisEnvironmentPreset.all.count { notice = "部分工具未返回检测结果，请重试。" }
            }
        }
    }
}

private struct MinisEnvironmentPresetDetail: View {
    let preset: MinisEnvironmentPreset
    @State private var terminalCommand: String?
    @State private var showingTerminal = false
    @State private var confirmingInstall = false

    var body: some View {
        List {
            Section("用途") { Text(preset.detail) }
            Section("操作") {
                Button("安装／补齐工具") { confirmingInstall = true }
                Button("检查版本与可用性") { openTerminal(preset.versionCommand) }
            }
            Section("安装命令") {
                Text("apk add --no-cache \(preset.packages)")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                Text("会打开内置终端并预填命令，按回车后才执行。不会安装到 iOS 系统，也不会自动升级整个环境。")
                    .font(.caption).foregroundColor(.secondary)
            }
            if preset.id == "python" {
                Section("虚拟环境示例") {
                    Text("python3 -m venv .venv\n. .venv/bin/activate")
                        .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                }
            }
        }
        .navigationTitle(preset.title)
        .alert("安装 \(preset.title)？", isPresented: $confirmingInstall) {
            Button("打开终端") { openTerminal("apk add --no-cache \(preset.packages)") }
            Button("取消", role: .cancel) {}
        } message: { Text("从当前 Alpine 镜像下载并安装，可能消耗流量和存储空间。请在终端检查输出；完成后返回刷新工具状态。") }
        .fullScreenCover(isPresented: $showingTerminal) {
            MinisNavigationContainer {
                ISHTerminalView(showCloseButton: true, initCommand: terminalCommand)
            }
        }
    }

    private func openTerminal(_ command: String) {
        terminalCommand = command
        showingTerminal = true
    }
}
