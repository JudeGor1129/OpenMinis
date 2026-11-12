import Foundation
import SwiftUI
import UniformTypeIdentifiers
import UIKit

struct EmbeddedTargetBuildReport: Codable, Sendable {
    let architecture: String
    let steps: [EmbeddedAdapterStep]
    let residentSamplesBytes: [UInt64]
    let processLinkCount: Int
    let temporaryOutputsRemoved: Bool
    let artifact: EmbeddedAdapterArtifact
}

struct EmbeddedProjectBuildReport: Codable, Sendable {
    private enum CodingKeys: String, CodingKey {
        case schema, suite, projectFingerprint, entrySources, compiledSourceCount
        case targetArchitectures, targetReports, universalSlices, universalDylibBytes, universalDylibSHA256
        case expectedOutputPath, outputBytes, outputSHA256, outputArtifactKind, operations, directorySynced
        case residentSamplesBytes, processLinkCount, temporaryOutputsRemoved
        case outputPublished, outputExecutionAttempted, providerExecutable, passed
    }
    let schema = 2
    let suite = "restricted_project_build"
    let projectFingerprint: String
    let entrySources: [String]
    let compiledSourceCount: Int
    let targetArchitectures: [String]
    let targetReports: [EmbeddedTargetBuildReport]
    let universalSlices: [EmbeddedUniversalSlice]
    let universalDylibBytes: Int?
    let universalDylibSHA256: String?
    let expectedOutputPath: String
    let outputBytes: Int
    let outputSHA256: String
    let outputArtifactKind: String
    let directorySynced: Bool
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
    @State private var buildUniversal = true
    @State private var packageID = ""
    @State private var packageName = "My Tweak"
    @State private var packageVersion = "1.0"
    @State private var packageMaintainer = ""
    @State private var packageDescription = ""
    @State private var tweakName = "Project"
    @State private var bundleIDs = ""

    private var canBuild: Bool {
        projectRoot != nil && !isChoosing && !isBuilding &&
        toolchain["compiler_linked"] == "yes" &&
        (toolchain["verification"] == "passed" || toolchain["experimental_build"] == "yes") &&
        toolchain["resource_headers"] == "present" &&
        toolchain["sdk"] == "present" && toolchain["state"] == "ready"
    }

    var body: some View {
        List {
            Section("受限 C / Objective-C 工程编译") {
                Label("仅在所选工程的 build/minis-embedded/ 写入 dylib", systemImage: "folder.badge.gearshape")
                Label("校验后原子导出 dylib 或 rootless DEB；不运行、不签名、不安装生成物", systemImage: "checkmark.shield")
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
                Toggle(isOn: $buildUniversal) {
                    Label("编译 arm64 + arm64e 并导出 rootless DEB", systemImage: "shippingbox")
                }
                if buildUniversal {
                    TextField("包标识", text: $packageID)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("包名称", text: $packageName)
                    TextField("版本", text: $packageVersion)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("维护者", text: $packageMaintainer)
                    TextField("插件名称", text: $tweakName)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("过滤 Bundle ID（逗号分隔）", text: $bundleIDs)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled(true)
                    TextField("包描述", text: $packageDescription)
                }
            } header: { Text("交付架构") } footer: {
                Text(buildUniversal
                     ? "双架构链路会分别编译、链接并检查 arm64 与 arm64e，随后把 FAT dylib 放入 rootless DEB；最终只原子发布完整 DEB，不签名、不安装、不执行。"
                     : "单架构兼容模式只生成 arm64 dylib；它不满足双架构 rootless DEB 交付验收。")
            }
            Section {
                Button { buildProject() } label: {
                    HStack {
                        Label(buildUniversal ? "编译并导出 rootless DEB" : "编译并导出 arm64 dylib", systemImage: "hammer")
                        Spacer()
                        if isBuilding { ProgressView() }
                    }
                }.disabled(!canBuild)
                if isBuilding {
                    Button("取消编译") { cancellation?.cancel() }
                }
                if !resultMessage.isEmpty { Text(resultMessage).font(.callout) }
            } header: { Text("本地受限构建") } footer: {
                Text("首版仅限最多 4 个 C/Objective-C 源文件、20 个源/头文件、总计 512 KiB；仅支持引号本地 include。拒绝宏、条件编译、系统头、汇编和符号链接。双架构模式在 build/minis-embedded/ 原子发布完整 rootless DEB；单架构模式发布 arm64 dylib。单 App 进程最多 3 次 link，RSS 448 MiB / 累计增加 64 MiB 即停。")
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
        let universal = buildUniversal
        cancellation = token; isBuilding = true; copied = false; resultText = ""
        resultMessage = universal ? "正在为 arm64 与 arm64e 分别编译、生成 FAT dylib 并打包…" : "正在编译 arm64 dylib…"
        Task {
            do {
                let snapshot = try await Task.detached(priority: .userInitiated) {
                    try EmbeddedToolchainProjectSnapshotBuilder.loadProject(root: root)
                }.value
                let outputName: String
                if universal {
                    outputName = try validatedTweakOutputName()
                } else {
                    outputName = "project.dylib"
                }
                let plan = try EmbeddedToolchainProjectMaterializer.plan(snapshot: snapshot, outputName: outputName)
                let architectures: [EmbeddedToolchainArchitecture] = universal ? [.arm64, .arm64e] : [.arm64]
                let request = try EmbeddedToolchainRestrictedRequestBuilder.make(
                    snapshot: snapshot, plan: plan, targetArchitectures: architectures)
                let published: EmbeddedToolchainPublishedArtifact
                let slices: [EmbeddedUniversalSlice]
                let operations: [EmbeddedAdapterStep]
                let residentSamples: [UInt64]
                let processLinks: Int
                let temporaryOutputsRemoved: Bool
                let universalDylibBytes: Int?
                let universalDylibHash: String?
                let publishedOutputBytes: Int
                let publishedOutputHash: String
                let outputArtifactKind: String
                let targetReports: [EmbeddedTargetBuildReport]

                if universal {
                    let metadata = try makeDebMetadata(tweakOutputName: outputName)
                    let delivery = await EmbeddedToolchainRestrictedExecutor.shared.executeUniversal(
                        request, metadata: metadata, cancellation: token)
                    guard delivery.passed, let deb = delivery.debData,
                          let debArtifact = delivery.debArtifact,
                          let universalArtifact = delivery.universalArtifact else {
                        throw EmbeddedProjectBuildError.adapter(delivery.reason.isEmpty ? "双架构构建或 DEB 校验失败" : delivery.reason)
                    }
                    guard !token.isCancelled else { throw EmbeddedProjectBuildError.cancelled }
                    published = try await Task.detached(priority: .userInitiated) {
                        try EmbeddedToolchainProjectPublisher.publishRootlessDeb(
                            deb, metadata: metadata, projectRoot: root, cancellation: token)
                    }.value
                    guard published.sha256 == debArtifact.sha256 && published.bytes == debArtifact.bytes else {
                        throw EmbeddedProjectBuildError.adapter("发布后的 DEB 与已验证内存产物不匹配")
                    }
                    slices = universalArtifact.slices
                    targetReports = try zip(architectures, delivery.adapterReports).map { pair in
                        let (architecture, adapterReport) = pair
                        guard let artifact = adapterReport.artifacts.first(where: {
                            $0.filetype == 6 && $0.name == request.outputName && $0.architecture == architecture.rawValue
                        }) else {
                            throw EmbeddedProjectBuildError.adapter("缺少 \(architecture.rawValue) thin dylib 检查记录")
                        }
                        return EmbeddedTargetBuildReport(architecture: architecture.rawValue,
                            steps: adapterReport.steps, residentSamplesBytes: adapterReport.residentSamplesBytes,
                            processLinkCount: adapterReport.processLinkCount,
                            temporaryOutputsRemoved: adapterReport.temporaryOutputsRemoved, artifact: artifact)
                    }
                    operations = delivery.adapterReports.flatMap(\.steps)
                    residentSamples = delivery.adapterReports.flatMap(\.residentSamplesBytes)
                    processLinks = delivery.adapterReports.map(\.processLinkCount).max() ?? 0
                    temporaryOutputsRemoved = delivery.adapterReports.allSatisfy(\.temporaryOutputsRemoved)
                    universalDylibBytes = universalArtifact.bytes
                    universalDylibHash = universalArtifact.sha256
                    publishedOutputBytes = published.bytes
                    publishedOutputHash = published.sha256
                    outputArtifactKind = published.artifactKind
                } else {
                    let execution = await EmbeddedToolchainRestrictedExecutor.shared.execute(
                        request, captureVerifiedDylib: true, cancellation: token)
                    guard execution.passed, let dylib = execution.dylibData else {
                        throw EmbeddedProjectBuildError.adapter(execution.adapter.reason.isEmpty ? execution.adapter.state : execution.adapter.reason)
                    }
                    guard !token.isCancelled else { throw EmbeddedProjectBuildError.cancelled }
                    published = try await Task.detached(priority: .userInitiated) {
                        try EmbeddedToolchainProjectPublisher.publishVerifiedDylib(
                            dylib, named: request.outputName, projectRoot: root, cancellation: token)
                    }.value
                    slices = []
                    guard let artifact = execution.adapter.artifacts.first(where: {
                        $0.filetype == 6 && $0.name == request.outputName && $0.architecture == EmbeddedToolchainArchitecture.arm64.rawValue
                    }) else {
                        throw EmbeddedProjectBuildError.adapter("缺少 arm64 thin dylib 检查记录")
                    }
                    targetReports = [EmbeddedTargetBuildReport(architecture: EmbeddedToolchainArchitecture.arm64.rawValue,
                        steps: execution.adapter.steps, residentSamplesBytes: execution.adapter.residentSamplesBytes,
                        processLinkCount: execution.adapter.processLinkCount,
                        temporaryOutputsRemoved: execution.adapter.temporaryOutputsRemoved, artifact: artifact)]
                    operations = execution.adapter.steps
                    residentSamples = execution.adapter.residentSamplesBytes
                    processLinks = execution.adapter.processLinkCount
                    temporaryOutputsRemoved = execution.adapter.temporaryOutputsRemoved
                    universalDylibBytes = nil
                    universalDylibHash = nil
                    publishedOutputBytes = published.bytes
                    publishedOutputHash = published.sha256
                    outputArtifactKind = published.artifactKind
                }
                let report = EmbeddedProjectBuildReport(
                    projectFingerprint: snapshot.fingerprint,
                    entrySources: snapshot.entrySources,
                    compiledSourceCount: plan.sources.count,
                    targetArchitectures: architectures.map(\.rawValue),
                    targetReports: targetReports,
                    universalSlices: slices,
                    universalDylibBytes: universalDylibBytes,
                    universalDylibSHA256: universalDylibHash,
                    expectedOutputPath: published.relativePath,
                    outputBytes: publishedOutputBytes,
                    outputSHA256: publishedOutputHash,
                    outputArtifactKind: outputArtifactKind,
                    directorySynced: published.directorySynced,
                    operations: operations,
                    residentSamplesBytes: residentSamples,
                    processLinkCount: processLinks,
                    temporaryOutputsRemoved: temporaryOutputsRemoved,
                    outputPublished: true,
                    passed: true
                )
                resultText = Self.render(report)
                resultMessage = "构建成功并原子写入工程：\(published.relativePath)" +
                    (published.directorySynced ? "" : "（文件已提交，但目录持久化同步未确认）")
            } catch {
                resultMessage = "工程编译未完成：\(error.localizedDescription)"
            }
            isBuilding = false; cancellation = nil
            if !isVisible { closeScope() }
        }
    }

    private func validatedTweakOutputName() throws -> String {
        guard let range = tweakName.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression),
              range == tweakName.startIndex..<tweakName.endIndex else {
            throw EmbeddedProjectBuildError.adapter("插件名称须为 1–64 位 ASCII 字母、数字、下划线或连字符")
        }
        return tweakName + ".dylib"
    }

    private func makeDebMetadata(tweakOutputName: String) throws -> EmbeddedDebMetadata {
        let ids = bundleIDs.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let metadata = EmbeddedDebMetadata(
            packageID: packageID.trimmingCharacters(in: .whitespacesAndNewlines),
            name: packageName.trimmingCharacters(in: .whitespacesAndNewlines),
            version: packageVersion.trimmingCharacters(in: .whitespacesAndNewlines),
            maintainer: packageMaintainer.trimmingCharacters(in: .whitespacesAndNewlines),
            description: packageDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            tweakName: String(tweakOutputName.dropLast(".dylib".count)),
            bundleIDs: ids)
        do { try metadata.validate() }
        catch { throw EmbeddedProjectBuildError.adapter(error.localizedDescription) }
        return metadata
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
