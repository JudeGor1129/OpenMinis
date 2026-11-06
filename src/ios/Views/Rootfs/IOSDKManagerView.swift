import SwiftUI
import UniformTypeIdentifiers
import UIKit

/// iPhoneOS SDK 管理：导入 ZIP、从下载链接安装、列出/选择/删除已安装 SDK。
///
/// 页面只做文件管理。构建在 App 进程内由 OMToolchain 完成，这里不执行任何
/// shell 命令，也不碰 Alpine 系统文件（rootfs 里的那份只读列出，用于导入）。
struct IOSDKManagerView: View {
    @ObservedObject private var library = ToolchainSDKLibrary.shared

    @State private var importPresented = false
    @State private var downloadURL = ""
    @State private var pendingImport: URL?

    var body: some View {
        List {
            installedSection
            importSection
            downloadSection
            noteSection
        }
        .navigationTitle("iPhoneSDK")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    library.refresh()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("刷新 SDK 列表")
            }
        }
        .onAppear { library.refresh() }
        .fileImporter(
            isPresented: $importPresented,
            allowedContentTypes: [.zip, .archive],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                let accessed = url.startAccessingSecurityScopedResource()
                defer { if accessed { url.stopAccessingSecurityScopedResource() } }
                install(url)
            case .failure(let error):
                library.notice = "选择文件失败：\(error.localizedDescription)"
            }
        }
    }

    // MARK: - Sections

    private var installedSection: some View {
        Section {
            if library.sdks.isEmpty {
                HStack {
                    Text("未安装 SDK")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("导入或下载后可用")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            } else {
                ForEach(library.sdks) { sdk in
                    Button {
                        library.select(sdk)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: library.selectedSDK?.version == sdk.version
                                  ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(library.selectedSDK?.version == sdk.version ? .green : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(sdk.displayName)
                                    .foregroundStyle(.primary)
                                Text(sdk.isAppOwned ? "App 内 · \(sdk.formattedSize)" : "iSH rootfs · \(sdk.formattedSize)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .swipeActions(edge: .trailing) {
                        if sdk.isAppOwned {
                            Button(role: .destructive) {
                                library.remove(sdk)
                            } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                    }
                }
            }

            if case .working(let text) = library.phase {
                HStack(spacing: 8) {
                    ProgressView()
                    Text(text).font(.footnote).foregroundStyle(.secondary)
                }
            }
            if case .failed(let text) = library.phase {
                Label(text, systemImage: "exclamationmark.triangle")
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if let notice = library.notice, !notice.isEmpty {
                Text(notice).font(.footnote).foregroundStyle(.secondary)
            }
        } header: {
            Text("已安装")
        } footer: {
            Text("原生编译优先使用 App 内 SDK（toolchain.selectedSDKVersion）。rootfs 里的 SDK 只用于导入，重置 rootfs 后不会影响构建。")
        }
    }

    private var importSection: some View {
        Section {
            Button {
                importPresented = true
            } label: {
                Label("选择 ZIP 并导入", systemImage: "square.and.arrow.down")
            }
            .disabled(isWorking)

            ToolchainSDKImportRow()
        } header: {
            Text("导入")
        } footer: {
            Text("支持直接导入 iPhoneOS*.sdk 的 ZIP（解包后自动识别版本并校验头文件与 libSystem 库桩）。也可以把 iSH 里已装好的 SDK 整份拷贝过来。")
        }
    }

    private var downloadSection: some View {
        Section {
            TextField("https://…/iPhoneOS16.5.sdk.zip", text: $downloadURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled(true)
                .keyboardType(.URL)
            Button {
                guard let url = URL(string: downloadURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    library.notice = "链接格式不正确"
                    return
                }
                library.download(from: url)
            } label: {
                Label("下载并安装", systemImage: "arrow.down.circle")
            }
            .disabled(isWorking || downloadURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } header: {
            Text("下载")
        } footer: {
            Text("填入 SDK ZIP 的直链。App 只下载并校验你给的链接，不内置任何 SDK 下载源，也不会上传任何内容。")
        }
    }

    private var noteSection: some View {
        Section {
            Label("SDK 只写入 App 容器，不会修改 iOS 系统文件", systemImage: "lock.shield")
            Label("导入过程不执行包内任何脚本或二进制", systemImage: "checkmark.shield")
        } header: {
            Text("说明")
        } footer: {
            Text("编译所需的 Clang 资源与 ld64 已内置在 App 中；这里只补充 SDK 头文件和库桩。")
        }
    }

    private var isWorking: Bool {
        if case .working = library.phase { return true }
        return false
    }

    /// Copy the picked ZIP into our container first: the security-scoped URL is
    /// only valid while the scope is held, and extraction runs asynchronously.
    private func install(_ url: URL) {
        let copy = FileManager.default.temporaryDirectory
            .appendingPathComponent("sdk-pick-\(UUID().uuidString).zip")
        do {
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: url, to: copy)
            library.install(zipURL: copy)
        } catch {
            library.notice = "复制 ZIP 失败：\(error.localizedDescription)"
        }
    }
}
