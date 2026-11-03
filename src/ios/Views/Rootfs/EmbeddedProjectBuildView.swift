import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct EmbeddedProjectBuildReport: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case schema, suite, projectFingerprint, entrySources, compiledSourceCount
        case expectedOutputPath, outputBytes, outputSHA256, operations
        case residentSamplesBytes, processLinkCount, temporaryOutputsRemoved
        case outputPublished, outputExecutionAttempted, providerExecutable, passed
    }
    let schema = 1
    let suite = "restricted_project_build"
    let projectFingerprint: String
    let entrySources: [String]
    let compiledSourceCount: Int
    let expectedOutputPath: String
    let outputBytes: Int
    let outputSHA256: String
    let operations: [EmbeddedAdapterStep]
    let residentSamplesBytes: [UInt64]
    let processLinkCount: Int
    let temporaryOutputsRemoved: Bool
    let outputPublished: Bool
    let outputExecutionAttempted = false
    let providerExecutable = false
    let passed: Bool
}

@MainActor
struct EmbeddedProjectBuildView: View {
    @State private var toolchain: [String: String] = [:]
    @State private var projectRoot: URL?
    @State private var scopeOpen = false
    @State private var isChoosing = false
    @State private var isBuilding = false
    @State private var isVisible = false
    @State private var pickerPresented = false
    @State private var cancellation: EmbeddedAdapterCancellation?
    @State private var resultText = ""
    @State private var resultMessage = ""
    @State private var copied = false

    private var canBuild: Bool {
        projectRoot != nil && !isChoosing && !isBuilding &&
        toolchain["compiler_linked"] == "yes" &&
        toolchain["verification"] == "passed" &&
        toolchain["resource_headers"] == "present" &&
        toolchain["sdk"] == "present" && toolchain["state"] == "ready"
    }

    var body: some View {
        List {
            Section("受限 C / Objective-C 工程编译") {
                Label("仅在所选工程的 build/minis-embedded/ 写入 dylib", systemImage: "folder.badge.gearshape")
                Label("不运行、不签名、不安装生成的 dylib", systemImage: "checkmark.shield")
                Label("通用 BuildProvider 仍保持禁用", systemImage: "lock.fill")
                if let projectRoot {
                    HStack {
                        Text("工程目录")
                        Spacer()
                        Text(projectRoot.lastPathComponent).foregroundStyle(.secondary)
                    }
                    Text(projectRoot.path).font(.caption2).textSelection(.enabled).foregroundStyle(.secondary)
                } else {
                    Text("尚未选择工程文件夹").foregroundStyle(.secondary)
                }
                Button { pickerPresented = true } label: {
                    Label(isChoosing ? "正在读取工程…" : "选择工程文件夹", systemImage: "folder")
                }.disabled(isChoosing || isBuilding)
            }
            Section {
                Button { buildProject() } label: {
                    HStack {
                        Label("编译并导出 dylib", systemImage: "hammer")
                        Spacer()
                        if isBuilding { ProgressView() }
                    }
                }.disabled(!canBuild)
                if isBuilding {
                    Button("取消编译") { cancellation?.cancel() }
                }
                if !resultMessage.isEmpty { Text(resultMessage).font(.callout) }
            } header: { Text("本地受限构建") } footer: {
                Text("首版仅限最多 4 个 C/Objective-C 源文件、20 个源/头文件、总计 512 KiB；仅支持引号本地 include。拒绝宏、条件编译、系统头、汇编和符号链接。dylib 先检查，再原子写入工程的 build/minis-embedded/project.dylib；若同名文件存在会原子替换。单 App 进程最多 3 次 link，RSS 448 MiB / 累计增加 64 MiB 即停。")
            }
            if !resultText.isEmpty {
                Section("构建报告") {
                    ScrollView(.horizontal) {
                        Text(resultText).font(.caption.monospaced()).textSelection(.enabled)
                    }
                    Button { UIPasteboard.general.string = resultText; copied = true } label: {
                        Label(copied ? "已复制构建报告" : "复制构建报告 JSON", systemImage: "doc.on.doc")
                    }
                }
            }
        }
        .navigationTitle("受限工程编译")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $pickerPresented, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): choose(urls.first)
            case .failure(let error): resultMessage = "选择工程失败：\(error.localizedDescription)"
            }
        }
        .onAppear { isVisible = true; toolchain = OMToolchain.capabilityStatus() }
        .onDisappear {
            isVisible = false
            cancellation?.cancel()
            if !isChoosing && !isBuilding { closeScope() }
        }
    }

    private func choose(_ url: URL?) {
        guard !isChoosing && !isBuilding else { return }
        closeScope()
        guard let url else { resultMessage = "没有选择工程文件夹"; return }
        isChoosing = true; resultMessage = "正在扫描受限源和本地头文件…"
        Task {
            let accessed = url.startAccessingSecurityScopedResource()
            do {
                guard accessed else { throw EmbeddedProjectBuildError.scopeUnavailable }
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try EmbeddedToolchainProjectSnapshotBuilder.loadProject(root: url)
                }.value
                guard isVisible else {
                    url.stopAccessingSecurityScopedResource()
                    isChoosing = false
                    return
                }
                projectRoot = url
                scopeOpen = true
                resultMessage = "快照通过：\(snapshot.entrySources.count) 个入口源，\(snapshot.files.count) 个总文件。"
            } catch {
                if accessed { url.stopAccessingSecurityScopedResource() }
                projectRoot = nil; scopeOpen = false
                resultMessage = "工程不符合首版受限规则：\(error.localizedDescription)"
            }
            isChoosing = false
            if !isVisible { closeScope() }
        }
    }

    private func buildProject() {
        guard let root = projectRoot, !isBuilding else { return }
        let token = EmbeddedAdapterCancellation()
        cancellation = token; isBuilding = true; copied = false; resultText = ""
        resultMessage = "正在快照、生成受限计划、编译、链接和检查…"
        Task {
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try EmbeddedToolchainProjectSnapshotBuilder.loadProject(root: root)
                }.value
                let plan = try EmbeddedToolchainProjectMaterializer.plan(snapshot: snapshot)
                let request = try EmbeddedToolchainRestrictedRequestBuilder.make(snapshot: snapshot, plan: plan)
                let execution = await EmbeddedToolchainRestrictedExecutor.shared.execute(
                    request, captureVerifiedDylib: true, cancellation: token)
                guard execution.passed, let dylib = execution.dylibData else {
                    throw EmbeddedProjectBuildError.adapter(execution.adapter.reason.isEmpty ? execution.adapter.state : execution.adapter.reason)
                }
                guard !token.isCancelled else { throw EmbeddedProjectBuildError.cancelled }
                let published = try await Task.detached(priority: .userInitiated) {
                    try EmbeddedToolchainProjectPublisher.publishVerifiedDylib(
                        dylib, named: request.outputName, projectRoot: root, cancellation: token)
                }.value
                let report = EmbeddedProjectBuildReport(
                    projectFingerprint: snapshot.fingerprint,
                    entrySources: snapshot.entrySources,
                    compiledSourceCount: plan.sources.count,
                    expectedOutputPath: published.relativePath,
                    outputBytes: published.bytes,
                    outputSHA256: published.sha256,
                    operations: execution.adapter.steps,
                    residentSamplesBytes: execution.adapter.residentSamplesBytes,
                    processLinkCount: execution.adapter.processLinkCount,
                    temporaryOutputsRemoved: execution.adapter.temporaryOutputsRemoved,
                    outputPublished: true,
                    passed: true
                )
                resultText = Self.render(report)
                resultMessage = "编译成功并已验证写入工程：\(published.relativePath)" +
                    (published.directorySynced ? "" : "（文件已原子提交，但目录持久化同步未确认）")
            } catch {
                resultMessage = "工程编译未完成：\(error.localizedDescription)"
            }
            isBuilding = false; cancellation = nil
            if !isVisible { closeScope() }
        }
    }

    private func closeScope() {
        if scopeOpen, let projectRoot { projectRoot.stopAccessingSecurityScopedResource() }
        scopeOpen = false; projectRoot = nil
    }

    private static func render(_ report: EmbeddedProjectBuildReport) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        guard let data = try? encoder.encode(report), let text = String(data: data, encoding: .utf8) else {
            return "{\"passed\":false,\"reason\":\"report encoding failed\"}"
        }
        return text
    }
}

private enum EmbeddedProjectBuildError: Error, LocalizedError {
    case cancelled
    case scopeUnavailable
    case adapter(String)
    var errorDescription: String? {
        switch self {
        case .cancelled: return "cancelled"
        case .scopeUnavailable: return "Files did not grant access to this folder"
        case .adapter(let reason): return reason
        }
    }
}
