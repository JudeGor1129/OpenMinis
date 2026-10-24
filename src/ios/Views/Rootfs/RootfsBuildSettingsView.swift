import Foundation
import SwiftUI

/// Build settings for the Alpine/Theos environment. The selected SDK is
/// persisted, while the actual build remains an explicit terminal action.
struct RootfsBuildSettingsView: View {
    @StateObject private var model = RootfsBuildSettingsViewModel()

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: model.toolchainSymbol)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(model.toolchainColor)
                        .frame(width: 32, height: 32)
                        .background(model.toolchainColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("编译环境")
                            .font(.headline)
                        Text(model.toolchainSummary)
                            .font(.subheadline)
                            .foregroundStyle(model.toolchainColor)
                    }
                    Spacer()
                    if model.isChecking { ProgressView() }
                }

                NavigationLink {
                    ToolchainStatusView()
                } label: {
                    Label("查看全部工具状态", systemImage: "list.bullet.rectangle")
                }

                Button {
                    model.refresh()
                } label: {
                    Label("刷新编译工具状态", systemImage: "arrow.clockwise")
                }
                .disabled(model.isChecking)
            } header: {
                Text("编译工具")
            } footer: {
                Text("状态来自内置 Alpine 环境中的实际命令检测，不代表每个工程的依赖都已安装。")
            }

            Section {
                if model.sdks.isEmpty {
                    HStack {
                        Text("SDK")
                        Spacer()
                        Text(model.isChecking ? "检测中…" : "未发现")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    NavigationLink {
                        IOSDKSelectionView(model: model)
                    } label: {
                        HStack {
                            Label("构建使用的 SDK", systemImage: "shippingbox")
                            Spacer()
                            Text(model.selectedSDK?.displayName ?? "未选择")
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                HStack {
                    Text("最低部署版本")
                    Spacer()
                    Text("iOS 15.0")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("架构")
                    Spacer()
                    Text("arm64 · arm64e")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("构建模式")
                    Spacer()
                    Text("Release · -O")
                        .foregroundStyle(.green)
                }
            } header: {
                Text("iPhoneOS SDK")
            } footer: {
                Text("SDK 版本与最低部署版本是两个独立设置。选择 SDK 只影响后续终端构建命令，不会修改 RootFS。")
            }

            Section {
                HStack {
                    Text("项目路径")
                    Spacer()
                    Text(model.projectPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                NavigationLink {
                    ISHTerminalView(showCloseButton: true, initCommand: model.buildCommand)
                } label: {
                    Label("打开 Release 构建终端", systemImage: "hammer.fill")
                }
                .disabled(model.selectedSDK == nil || !model.isToolchainReady)
            } header: {
                Text("构建")
            } footer: {
                Text("打开终端后会预填命令，确认路径和 SDK 后按回车执行。构建不会自动安装或覆盖系统文件。")
            }

            if let notice = model.notice {
                Section {
                    Text(notice)
                        .font(.callout)
                        .foregroundStyle(model.noticeIsError ? .orange : .secondary)
                }
            }
        }
        .navigationTitle("编译环境")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.refreshIfNeeded() }
    }
}

struct IOSDKInfo: Identifiable, Hashable {
    let id: String
    let version: String
    let path: String
    let sizeKB: Int64

    var displayName: String { "iPhoneOS \(version)" }
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeKB * 1024, countStyle: .file)
    }
}

struct IOSDKSelectionView: View {
    @ObservedObject var model: RootfsBuildSettingsViewModel

    var body: some View {
        List {
            Section("已发现的 SDK") {
                ForEach(model.sdks) { sdk in
                    Button {
                        model.select(sdk)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: model.selectedSDK?.id == sdk.id
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(model.selectedSDK?.id == sdk.id ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(sdk.displayName)
                                    .foregroundStyle(.primary)
                                Text("\(sdk.formattedSize) · \(sdk.path)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(model.selectedSDK?.id == sdk.id ? .isSelected : [])
                }
            }

            Section {
                Button {
                    model.refresh()
                } label: {
                    Label("重新扫描 SDK", systemImage: "arrow.clockwise")
                }
                .disabled(model.isChecking)
            } footer: {
                Text("当前实现扫描 /opt/theos/sdks 下的 iPhoneOS*.sdk。ZIP 导入和多版本清理可在后续版本加入，不会影响当前构建流程。")
            }
        }
        .navigationTitle("选择 iPhoneOS SDK")
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
@MainActor
final class RootfsBuildSettingsViewModel: ObservableObject {
    enum ToolchainState { case checking, ready, partial, unavailable }

    @Published private(set) var sdks: [IOSDKInfo] = []
    @Published private(set) var selectedSDK: IOSDKInfo?
    @Published private(set) var toolchainState: ToolchainState = .unavailable
    @Published private(set) var toolchainVersion = ""
    @Published private(set) var isChecking = false
    @Published var notice: String?
    @Published var noticeIsError = false

    private static let selectedSDKKey = "rootfs.selectedIPhoneOSSDK"
    private var didRefresh = false

    var projectPath: String { "/var/minis/workspace/MinisSource" }
    var isToolchainReady: Bool { toolchainState == .ready }

    var toolchainSummary: String {
        switch toolchainState {
        case .checking: return "检测中…"
        case .ready: return toolchainVersion.isEmpty ? "编译环境就绪" : "编译环境就绪 · \(toolchainVersion)"
        case .partial: return "部分工具可用"
        case .unavailable: return "等待 Alpine 环境"
        }
    }

    var toolchainSymbol: String {
        switch toolchainState {
        case .ready: return "checkmark.seal.fill"
        case .partial: return "exclamationmark.triangle.fill"
        case .checking: return "arrow.triangle.2.circlepath"
        case .unavailable: return "xmark.seal.fill"
        }
    }

    var toolchainColor: Color {
        switch toolchainState {
        case .ready: return .green
        case .partial: return .orange
        case .checking: return .blue
        case .unavailable: return .secondary
        }
    }

    var buildCommand: String {
        let sdkPath = selectedSDK?.path ?? "/opt/theos/sdks/iPhoneOS16.5.sdk"
        let sdkVersion = selectedSDK?.version ?? "16.5"
        return """
        cd \(shellQuote(projectPath))
        export THEOS=/opt/theos
        export PATH=/opt/theos/toolchain/linux/iphone/bin:$PATH
        export SDKROOT=\(shellQuote(sdkPath))
        export SDKVERSION=\(shellQuote(sdkVersion))
        export THEOS_PLATFORM_SDK=\(shellQuote(sdkVersion))
        echo '使用 SDK: \(sdkVersion) · 最低系统: iOS 15.0 · 架构: arm64 arm64e'
        make package FINALPACKAGE=1 ARCHS='arm64 arm64e'
        """
    }

    func refreshIfNeeded() {
        guard !didRefresh else { return }
        didRefresh = true
        refresh()
    }

    func select(_ sdk: IOSDKInfo) {
        selectedSDK = sdk
        UserDefaults.standard.set(sdk.path, forKey: Self.selectedSDKKey)
        notice = "已选择 \(sdk.displayName)"
        noticeIsError = false
    }

    func refresh() {
        guard !isChecking else { return }
        guard ISHKernel.shared.isBooted else {
            toolchainState = .unavailable
            notice = "请先打开内置终端启动 Alpine 环境。"
            noticeIsError = false
            return
        }
        isChecking = true
        toolchainState = .checking
        notice = nil
        noticeIsError = false

        DispatchQueue.global(qos: .utility).async { [weak self] in
            let script = """
            for d in /opt/theos/sdks/iPhoneOS*.sdk; do [ -d \"$d\" ] || continue; v=\"${d##*iPhoneOS}\"; v=\"${v%.sdk}\"; z=$(du -sk \"$d\" 2>/dev/null | awk '{print $1}'); printf 'SDK|%s|%s|%s\\n' \"$v\" \"$d\" \"${z:-0}\"; done
            printf 'TOOL|theos|'; test -d /opt/theos && echo ready || echo missing
            printf 'TOOL|clang|'; clang --version 2>/dev/null | head -1 || true
            printf 'TOOL|ld64|'; ld64.lld --version 2>/dev/null | head -1 || true
            printf 'TOOL|ldid|'; test -x /usr/local/bin/ldid && echo ready || echo missing
            printf 'TOOL|lipo|'; llvm-lipo --version 2>/dev/null | head -1 || true
            """
            let result = ISHShellExecutor.executeCommandSync(script, timeout: 30, lineCallback: nil)
            let parsed = Self.parse(result.output)
            let timedOut = result.exitCode == -1
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.isChecking = false
                self.sdks = parsed.sdks.sorted { $0.version.compare($1.version, options: .numeric) == .orderedDescending }
                let selectedPath = UserDefaults.standard.string(forKey: Self.selectedSDKKey)
                self.selectedSDK = self.sdks.first(where: { $0.path == selectedPath }) ?? self.sdks.first
                if let selected = self.selectedSDK {
                    UserDefaults.standard.set(selected.path, forKey: Self.selectedSDKKey)
                }
                let required = ["theos", "clang", "ld64", "ldid", "lipo"]
                let readyCount = required.filter { parsed.tools[$0] == true }.count
                self.toolchainVersion = parsed.clangVersion
                self.toolchainState = readyCount == required.count ? .ready : (readyCount == 0 ? .unavailable : .partial)
                if timedOut {
                    self.notice = "检测超时"
                    self.noticeIsError = true
                } else if self.sdks.isEmpty {
                    self.notice = "未发现 iPhoneOS SDK"
                    self.noticeIsError = true
                } else {
                    self.notice = "已检测 \(self.sdks.count) 个 SDK，工具 \(readyCount)/\(required.count) 可用"
                    self.noticeIsError = false
                }
            }
        }
    }

    private static func parse(_ output: String) -> (sdks: [IOSDKInfo], tools: [String: Bool], clangVersion: String) {
        var sdks: [IOSDKInfo] = []
        var tools: [String: Bool] = [:]
        var clang = ""
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3 else { continue }
            if parts[0] == "SDK", parts.count >= 4, let kb = Int64(parts[3]) {
                sdks.append(IOSDKInfo(id: parts[1], version: parts[1], path: parts[2], sizeKB: kb))
            } else if parts[0] == "TOOL" {
                let value = parts.dropFirst(2).joined(separator: "|")
                tools[parts[1]] = !value.isEmpty && value != "missing"
                if parts[1] == "clang" { clang = value.split(separator: " ").prefix(2).joined(separator: " ") }
            }
        }
        return (sdks, tools, clang)
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
