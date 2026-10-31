import Foundation
import SwiftUI
import UIKit

/// Build settings for the Alpine/Theos environment. The selected SDK is
/// persisted, while the actual build remains an explicit terminal action.
struct RootfsBuildSettingsView: View {
    @StateObject private var model = RootfsBuildSettingsViewModel()
    @State private var embeddedStatus: [String: String] = [:]

    var body: some View {
        List {
            Section("原生内置工具链（不经过 iSH）") {
                HStack {
                    Text("编译器链接状态")
                    Spacer()
                    Text(embeddedStatus["compiler_linked"] == "yes" ? "已链接" : "未启用")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("App 架构")
                    Spacer()
                    Text(embeddedStatus["host_architecture"] ?? "unknown")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Clang 基础头文件")
                    Spacer()
                    Text(embeddedStatus["resource_headers"] == "present" ? "已准备" : "缺失")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("原生 iOS SDK")
                    Spacer()
                    Text(embeddedStatus["sdk"] == "present" ? "已准备" : "未配置")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("BuildProvider")
                    Spacer()
                    Text("保持禁用")
                        .foregroundStyle(.orange)
                }
                NavigationLink {
                    EmbeddedToolchainDiagnosticsView()
                } label: {
                    Label("运行受限真机诊断", systemImage: "stethoscope")
                }
                .disabled(embeddedStatus["compiler_linked"] != "yes" ||
                          embeddedStatus["resource_headers"] != "present")
                Text(embeddedStatus["reason"] ?? "正在检查内置资源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("诊断只使用固定 C/Objective-C 夹具，最多重复 3 轮；产物不会执行，通过也不会开放 BuildProvider。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

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

                // 原生工具链只使用 App 自己目录里的 SDK。这一行把 iSH 环境里那份
                // 整份拷过来（含 72 个符号链接的就地展开），拷完之后 rootfs 被重置
                // 或重装都不再影响构建。
                ToolchainSDKImportRow()

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
        .onAppear {
            embeddedStatus = OMToolchain.capabilityStatus()
            model.refreshIfNeeded()
        }
    }
}

private struct EmbeddedToolchainDiagnosticsView: View {
    @State private var status: [String: String] = [:]
    @State private var iterations = 1
    @State private var isRunning = false
    @State private var reportText = ""
    @State private var reportPassed: Bool?
    @State private var copyNotice = ""

    private var canRun: Bool {
        status["compiler_linked"] == "yes" && status["resource_headers"] == "present"
    }

    var body: some View {
        List {
            Section("运行门禁") {
                diagnosticRow("编译器", value: status["compiler_linked"] == "yes" ? "已链接" : "未链接")
                diagnosticRow("Clang 资源", value: status["resource_headers"] == "present" ? "已锁定" : "缺失")
                diagnosticRow("iOS SDK", value: status["sdk"] == "present" ? "可用" : "未配置（仅测无 SDK 夹具）")
                diagnosticRow("BuildProvider", value: "保持禁用", color: .orange)
                diagnosticRow("产物执行", value: "不会执行", color: .secondary)
            }

            Section {
                Stepper("重复编译/链接：\(iterations) 轮", value: $iterations, in: 1...3)
                    .disabled(isRunning)
                Button {
                    runDiagnostics()
                } label: {
                    HStack {
                        Label("开始固定夹具诊断", systemImage: "waveform.path.ecg")
                        Spacer()
                        if isRunning { ProgressView() }
                    }
                }
                .disabled(!canRun || isRunning)

                if let reportPassed {
                    Label(reportPassed ? "诊断步骤全部通过" : "诊断发现失败",
                          systemImage: reportPassed ? "checkmark.seal.fill" : "xmark.octagon.fill")
                        .foregroundStyle(reportPassed ? .green : .orange)
                }
            } header: {
                Text("受限运行时测试")
            } footer: {
                Text("固定夹具覆盖 arm64/arm64e C、无 SDK Objective-C、B-key PAC、Mach-O 架构、预期编译/链接失败后的恢复、重复任务和常驻内存采样。最多 3 轮，避免 ld64 已知的进程内常驻分配无限增长。")
            }

            if !reportText.isEmpty {
                Section {
                    ScrollView(.horizontal, showsIndicators: true) {
                        Text(reportText)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                    Button {
                        UIPasteboard.general.string = reportText
                        copyNotice = "已复制诊断 JSON"
                    } label: {
                        Label("复制诊断 JSON", systemImage: "doc.on.doc")
                    }
                    if !copyNotice.isEmpty {
                        Text(copyNotice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("结构化报告")
                } footer: {
                    Text("报告中的 passed 只表示本次固定夹具通过；不会写入运行时验证宏，也不会开放 BuildProvider。")
                }
            }
        }
        .navigationTitle("内置工具链诊断")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { status = OMToolchain.capabilityStatus() }
    }

    @ViewBuilder
    private func diagnosticRow(_ title: String, value: String, color: Color = .secondary) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .font(.caption)
                .foregroundStyle(color)
                .multilineTextAlignment(.trailing)
        }
    }

    private func runDiagnostics() {
        guard canRun, !isRunning else { return }
        isRunning = true
        reportPassed = nil
        reportText = ""
        copyNotice = ""
        let selectedIterations = iterations
        Task {
            let rendered = await Task.detached(priority: .userInitiated) { () -> (String, Bool) in
                let report = OMToolchainDiagnostics.run(iterations: UInt(selectedIterations))
                let passed = (report["passed"] as? NSNumber)?.boolValue ?? false
                let data = try? JSONSerialization.data(withJSONObject: report,
                                                       options: [.prettyPrinted, .sortedKeys])
                let text = data.flatMap { String(data: $0, encoding: .utf8) }
                    ?? "{\"passed\":false,\"reason\":\"JSON serialization failed\"}"
                return (text, passed)
            }.value
            reportText = rendered.0
            reportPassed = rendered.1
            status = OMToolchain.capabilityStatus()
            isRunning = false
        }
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


// MARK: - iPhoneOS SDK 整份导入
//
// 把 iSH rootfs 里的 iPhoneOS SDK 整份拷进 App 自己的目录。
//
// 为什么不直接读 rootfs 里的那份：iSH 把符号链接的目标存在自己的元数据里，
// 宿主文件系统上留下的是一个「内容=目标名」的小文件。SDK 里这样的条目有 72 个
// （58 个在 usr/lib，6 个头文件，8 个 framework），其中就包括链接必备的
// libSystem.tbd —— 原生 ld64 打开它只会读到 15 字节文本，而不是 370 KB 的库桩。
// 所以拷贝时必须就地展开它们，否则拷出来照样不能用。
//
// 另外 rootfs 会被「重置 rootfs / 重装 App」删掉，SDK 放在 App 自己目录才能活下去。

/// 导入进度与结果。
@MainActor
final class ToolchainSDKImporter: ObservableObject {
    enum Phase: Equatable {
        case idle
        case scanning
        case copying(done: Int, total: Int)
        case finished(String)
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var installedPath: String?

    /// App 自有的 SDK 库。与 OMToolchain 的解析顺序保持一致。
    ///
    /// `nonisolated`：类本身是 @MainActor（要驱动 UI 进度），但查找与拷贝都跑在
    /// 后台任务里，而这个路径只是由 ContainerLocator 算出来的，不需要主线程。
    nonisolated static var storeDirectory: URL {
        ContainerLocator.applicationSupportDirectory
            .appendingPathComponent("MinisToolchain/SDKs", isDirectory: true)
    }

    /// iSH rootfs 中可用的 SDK（宿主路径）。
    nonisolated static func rootfsSDKPath() -> URL? {
        let guestRoot = ContainerLocator.documentsDirectory
            .appendingPathComponent("alpine-rootfs/data", isDirectory: true)
        let selected = UserDefaults.standard.string(forKey: "rootfs.selectedIPhoneOSSDK") ?? ""
        if selected.hasPrefix("/") {
            let candidate = guestRoot.appendingPathComponent(selected)
            if isUsable(candidate) { return candidate }
        }
        let sdksDirectory = guestRoot.appendingPathComponent("opt/theos/sdks", isDirectory: true)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: sdksDirectory, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.lastPathComponent.hasPrefix("iPhoneOS") }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .first { isUsable($0) }
    }

    /// 已导入且可用的 SDK。
    nonisolated static func importedSDKPath() -> URL? {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: storeDirectory, includingPropertiesForKeys: nil)) ?? []
        return entries
            .filter { $0.lastPathComponent.hasPrefix("iPhoneOS") }
            .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
            .first { isUsable($0) }
    }

    /// 可用 = 有头文件，且 libSystem 库桩是真文件而不是占位符。
    nonisolated static func isUsable(_ sdk: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: sdk.appendingPathComponent("usr/include").path, isDirectory: &isDirectory),
            isDirectory.boolValue else { return false }
        return stubBytes(sdk) >= 1024
    }

    /// `usr/lib/libSystem.B.tbd` 的字节数，0 表示不存在。
    nonisolated static func stubBytes(_ sdk: URL) -> Int {
        let stub = sdk.appendingPathComponent("usr/lib/libSystem.B.tbd")
        let attributes = try? FileManager.default.attributesOfItem(atPath: stub.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    func start() {
        guard case .idle = phase else { return }
        phase = .scanning
        Task { await self.runImport() }
    }

    /// Clears a finished or failed state so the row can offer another attempt.
    func reset() {
        if case .copying = phase { return }
        phase = .idle
    }

    /// Removes the imported SDK, freeing its space. The row used to tell the
    /// user to delete the directory without providing any way to; this is it.
    func removeImported() {
        guard case .idle = phase else { return }
        if let path = Self.importedSDKPath() {
            try? FileManager.default.removeItem(at: path)
        }
        installedPath = nil
    }

    private func runImport() async {
        let source = await Task.detached { Self.rootfsSDKPath() }.value
        guard let source else {
            phase = .failed("没有找到可用的 iPhoneOS SDK。请先在 iSH 环境里安装 Theos 的 SDK。")
            return
        }

        let result = await Task.detached { () -> Result<(URL, ImportStats), Error> in
            do {
                let stats = try Self.copySDK(from: source, progress: { done, total in
                    Task { @MainActor in self.phase = .copying(done: done, total: total) }
                })
                return .success((source, stats))
            } catch {
                return .failure(error)
            }
        }.value

        switch result {
        case .success(let (_, stats)):
            guard let installed = Self.importedSDKPath() else {
                phase = .failed("拷贝完成但导入的 SDK 不可用（libSystem 库桩缺失）。")
                return
            }
            installedPath = installed.path
            var summary = "已导入 \(installed.lastPathComponent)：\(stats.files) 个文件，展开 \(stats.symlinks) 个符号链接"
            if stats.skipped > 0 { summary += "，跳过 \(stats.skipped) 个悬空条目" }
            phase = .finished(summary)
        case .failure(let error):
            // Leave nothing half-copied behind: the next attempt starts clean.
            try? FileManager.default.removeItem(
                at: Self.storeDirectory.appendingPathComponent(source.lastPathComponent))
            phase = .failed(error.localizedDescription)
        }
    }

    struct ImportStats {
        var files = 0
        var symlinks = 0
        var skipped = 0
    }

    enum ImportError: LocalizedError {
        case destinationExists
        var errorDescription: String? {
            "目标目录已存在，请先删除后再导入。"
        }
    }

    /// 逐项拷贝，按需把符号链接占位文件还原成真正的符号链接。
    nonisolated static func copySDK(from source: URL,
                                    progress: @escaping (Int, Int) -> Void) throws -> ImportStats {
        let fm = FileManager.default
        let destination = storeDirectory.appendingPathComponent(source.lastPathComponent)
        try fm.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        // A previous attempt can be interrupted -- this copy is 222 MB, and the
        // app can be suspended while it runs -- so a partial tree is likely.
        // Refusing to continue would strand the user with nothing to tap: the
        // message used to say "delete it first" without offering a way to. Only
        // an SDK that is already usable is left alone.
        if fm.fileExists(atPath: destination.path) {
            if isUsable(destination) { throw ImportError.destinationExists }
            try? fm.removeItem(at: destination)
        }

        var stats = ImportStats()
        guard let enumerator = fm.enumerator(at: source,
                                             includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey],
                                             options: []) else {
            throw CocoaError(.fileReadUnknown)
        }

        var pending: [URL] = []
        while let entry = enumerator.nextObject() as? URL { pending.append(entry) }
        let total = max(pending.count, 1)

        // Compare components of the *resolved* source: NSDirectoryEnumerator
        // reports /private/var/... for a /var/... URL (iOS keeps /var as a
        // symlink to /private/var), and a plain string prefix test then fails --
        // which silently wrote the entire absolute path into the copy.
        let baseComponents = source.resolvingSymlinksInPath().standardizedFileURL.pathComponents

        for url in pending {
            try Task.checkCancellation()
            let relative = relativePath(of: url, under: source, base: baseComponents)
            guard let relative else { continue }
            let target = destination.appendingPathComponent(relative)
            guard !fm.fileExists(atPath: target.path) else { continue }

            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else if let linkTarget = symlinkTargetIfPlaceholder(url) {
                let resolved = url.deletingLastPathComponent()
                    .appendingPathComponent(linkTarget).standardizedFileURL
                if fm.fileExists(atPath: resolved.path) {
                    try fm.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
                    stats.symlinks += 1
                } else {
                    stats.skipped += 1   // 悬空链接：原样拷过去只会是一个假的文本文件
                }
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: url, to: target)
                stats.files += 1
            }
            progress(stats.files + stats.symlinks + stats.skipped, total)
        }
        return stats
    }

    /// `url`'s path relative to the resolved `source`, or nil when it is not
    /// underneath it. Components are compared, not strings: the enumerator
    /// resolves symlinks (/private/var/...) while the source URL may not (/var),
    /// and a string prefix test against the wrong form drops the whole path.
    nonisolated static func relativePath(of url: URL, under source: URL,
                                        base: [String]) -> String? {
        let components = url.pathComponents
        guard components.count > base.count,
              Array(components.prefix(base.count)) == base else { return nil }
        return components.dropFirst(base.count).joined(separator: "/")
    }

    /// iSH 的符号链接在这个进程看来是一个「内容=目标相对路径」的小文件。
    ///
    /// 判据用真 SDK 标定过：必须很小、单行、不含空格与 `#`/`<`/引号，不是绝对
    /// 路径，且目标确实存在于同一目录树下。**不能要求目标里带点号** ——
    /// `IOKit.framework/Versions/Current -> A` 与 `Headers -> Versions/Current/Headers`
    /// 都不带点号，加了这条就会漏掉它们，拷贝后 IOKit 的头文件会变成文本文件。
    /// 去掉点号要求后，iPhoneOS16.5.sdk 里 72/72 个链接全部命中，8859 个真实文件零误判。
    nonisolated static func symlinkTargetIfPlaceholder(_ url: URL) -> String? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey]),
              values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size < 512,
              let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }

        let target = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, target == text.trimmingCharacters(in: .newlines) else { return nil }
        for rejected in [" ", "\t", "#", "<", "\"", "\n"] where target.contains(rejected) { return nil }
        guard !target.hasPrefix("/") else { return nil }

        let resolved = url.deletingLastPathComponent()
            .appendingPathComponent(target).standardizedFileURL
        return FileManager.default.fileExists(atPath: resolved.path) ? target : nil
    }
}

/// 编译环境页里的「整份拷贝」入口。
struct ToolchainSDKImportRow: View {
    @StateObject private var importer = ToolchainSDKImporter()
    @State private var installed: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch importer.phase {
            case .idle:
                if let installed {
                    HStack {
                        Label("已导入 \(installed)", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("删除", role: .destructive) {
                            importer.removeImported()
                            self.installed = nil
                        }
                        .buttonStyle(.borderless)
                    }
                } else {
                    Button {
                        importer.start()
                    } label: {
                        Label("把整份 iPhoneOS SDK 拷贝到本机", systemImage: "square.and.arrow.down")
                    }
                }
            case .scanning:
                HStack { ProgressView(); Text("正在查找 SDK…").foregroundStyle(.secondary) }
            case .copying(let done, let total):
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(done), total: Double(total))
                    Text("已拷贝 \(done)/\(total) 项")
                        .font(.caption).foregroundStyle(.secondary)
                }
            case .finished(let summary):
                Label(summary, systemImage: "checkmark.seal")
                    .font(.footnote).foregroundStyle(.secondary)
            case .failed(let reason):
                VStack(alignment: .leading, spacing: 6) {
                    Label(reason, systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                    Button("重试") { importer.reset() }
                        .buttonStyle(.borderless)
                }
            }
        }
        .onAppear {
            installed = ToolchainSDKImporter.importedSDKPath()?.lastPathComponent
        }
    }
}
