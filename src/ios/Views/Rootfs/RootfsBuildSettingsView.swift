import Foundation
import SwiftUI
import UIKit

/// Theos 与 SDK 设置页。
///
/// 原生编译完全在 App 进程内完成（Clang 资源与 ld64 内置），因此这里不再检测
/// iSH 里的 clang / ld64 / ldid / make，也不提供“在终端里 make package”的入口。
/// 页面只负责：展示内置编译器状态、选择 iPhoneOS SDK、进入 SDK 管理（导入/下载）。
struct RootfsBuildSettingsView: View {
    @ObservedObject private var library = ToolchainSDKLibrary.shared
    @State private var embeddedStatus: [String: String] = [:]

    private var compilerReady: Bool { embeddedStatus["compiler_linked"] == "yes" }

    var body: some View {
        List {
            Section {
                HStack {
                    Text("编译环境")
                    Spacer()
                    Text(compilerReady ? "就绪（编译器内置）" : "未启用")
                        .foregroundStyle(compilerReady ? .green : .secondary)
                }
                HStack {
                    Text("App 架构")
                    Spacer()
                    Text(embeddedStatus["host_architecture"] ?? "unknown")
                        .foregroundStyle(.secondary)
                }
                NavigationLink {
                    IOSDKManagerView()
                } label: {
                    HStack {
                        Label("构建使用的 SDK", systemImage: "shippingbox")
                        Spacer()
                        Text(library.selectedSDK?.displayName ?? "未配置")
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text("最低部署版本")
                    Spacer()
                    Text("iOS 15.0").foregroundStyle(.secondary)
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
                    Text("Release · -O").foregroundStyle(.green)
                }
            } header: {
                Text("Theos 与 SDK")
            } footer: {
                Text("编译在 App 进程内完成，不经过 iSH，也不需要 iSH 里的 clang / ld64 / ldid / make。SDK 由「构建使用的 SDK」导入或下载。")
            }

            Section {
                NavigationLink {
                    EmbeddedProjectBuildView()
                } label: {
                    Label("编译受限 C / Objective-C 工程", systemImage: "hammer")
                }
                .disabled(embeddedStatus["verification"] != "passed" || embeddedStatus["sdk"] != "present")
                Text(embeddedStatus["reason"] ?? "正在检查内置资源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("会话 workspace 的 Theos / C / Objective-C 工程走聊天 build_project 的原生双架构 DEB 链路；构建日志在会话右上角菜单的「编译器」。产物不会自动执行、安装或签名。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } header: {
                Text("工程编译")
            }
        }
        .navigationTitle("Theos 与 SDK")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            embeddedStatus = OMToolchain.capabilityStatus()
            library.refresh()
        }
    }
}


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

        let destination = Self.storeDirectory.appendingPathComponent(source.lastPathComponent)

        switch result {
        case .success(let (_, stats)):
            if let installed = Self.importedSDKPath() {
                installedPath = installed.path
                var summary = "已导入 \(installed.lastPathComponent)：\(stats.files) 个文件，展开 \(stats.symlinks) 个符号链接"
                if stats.skipped > 0 { summary += "，跳过 \(stats.skipped) 个悬空条目" }
                phase = .finished(summary)
                return
            }
            // Copying finished but the result is not a usable SDK. Report what was
            // actually written rather than a generic "stub missing": the two very
            // different causes are "nothing was enumerated at all" and "files were
            // written but the stub is not one of them", and guessing between them
            // from a device screenshot costs a build cycle each time.
            let written = stats.files + stats.symlinks
            let stub = Self.stubBytes(destination)
            var reason = "拷贝结束但不可用：写入 \(written) 项（\(stats.files) 文件 / \(stats.symlinks) 链接）"
            if written == 0 {
                reason += "；没有枚举到任何条目，源目录不可读或为空"
            } else if stub < 1024 {
                reason += "；libSystem.B.tbd 为 \(stub) 字节"
            } else {
                reason += "；缺少 usr/include"
            }
            phase = .failed(reason)
        case .failure(let error):
            // Keep the partial tree: it is the evidence, and the next attempt
            // replaces it automatically.
            phase = .failed("导入失败：\(error.localizedDescription)（已写入 \(Self.entryCount(destination)) 项）")
        }
    }

    /// Number of entries currently under `url`, for failure reporting only.
    nonisolated static func entryCount(_ url: URL) -> Int {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil) else { return 0 }
        var n = 0
        while e.nextObject() != nil { n += 1 }
        return n
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

    /// Copies the complete SDK tree. The traversal carries relative paths from
    /// each directory's child names, rather than trying to derive them from
    /// absolute URLs: Foundation may report /private/var/... for a /var/... URL,
    /// which made prefix-stripping silently write the source's whole path into
    /// the destination. A stack also lets us recognize iSH's link placeholders
    /// before deciding whether to recurse into a directory.
    nonisolated static func copySDK(from source: URL,
                                    progress: @escaping (Int, Int) -> Void) throws -> ImportStats {
        let fm = FileManager.default
        let destination = storeDirectory.appendingPathComponent(source.lastPathComponent)
        try fm.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            if isUsable(destination) { throw ImportError.destinationExists }
            try? fm.removeItem(at: destination)
        }
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var entries: [(source: URL, relative: String, isDirectory: Bool)] = []
        var directories: [(url: URL, relative: String)] = [(source, "")]
        while let current = directories.popLast() {
            try Task.checkCancellation()
            let children = try fm.contentsOfDirectory(at: current.url,
                                                       includingPropertiesForKeys: [.isDirectoryKey],
                                                       options: [])
            for child in children {
                let name = child.lastPathComponent
                let relative = current.relative.isEmpty ? name : current.relative + "/" + name
                if symlinkTargetIfPlaceholder(child) != nil {
                    entries.append((child, relative, false))
                    continue
                }
                let values = try? child.resourceValues(forKeys: [.isDirectoryKey])
                let isDirectory = values?.isDirectory == true
                entries.append((child, relative, isDirectory))
                if isDirectory { directories.append((child, relative)) }
            }
        }

        var stats = ImportStats()
        let total = max(entries.count, 1)
        for (index, entry) in entries.enumerated() {
            try Task.checkCancellation()
            let target = destination.appendingPathComponent(entry.relative)
            if let linkTarget = symlinkTargetIfPlaceholder(entry.source) {
                // Keep the relative destination exactly as it was in the SDK.
                // The target may itself be another placeholder link; both links
                // are recreated, so the native filesystem resolves the chain.
                try fm.createSymbolicLink(atPath: target.path, withDestinationPath: linkTarget)
                stats.symlinks += 1
            } else if entry.isDirectory {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try fm.copyItem(at: entry.source, to: target)
                stats.files += 1
            }
            progress(index + 1, total)
        }
        return stats
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
