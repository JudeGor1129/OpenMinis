import SwiftUI
import UIKit

/// Opens on a frozen selection snapshot. Export reads no mutable ChatMessage or
/// AssistantBlock objects, and closing cancels any outstanding export work.
struct ChatShareSelectionView: View {
    @ObservedObject var vm: AIChatViewModel
    @StateObject private var model: ChatShareModel
    @State private var options = ChatExportOptions()
    @State private var exporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var result: ChatExportResult?
    @State private var errorText: String?
    @State private var warnings: [String] = []
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    init(vm: AIChatViewModel, title: String = "聊天记录", initialMessageIds: Set<UUID> = []) {
        self.vm = vm
        _model = StateObject(wrappedValue: ChatShareModel(messages: vm.messages, title: title,
                                                         initialMessageIds: initialMessageIds))
    }
    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                HStack {
                    Button("全选") { model.selectAll() }
                    Button("清空") { model.clear() }
                    Spacer()
                    Text("已选 \(model.selected.count) / \(model.items.count)").font(.caption)
                }.padding()
                List(model.items) { item in
                    Button { model.toggle(item) } label: {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: model.selected.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(model.selected.contains(item.id) ? .accentColor : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.label).font(.caption).foregroundColor(.secondary)
                                Text(String(item.markdown.prefix(240))).lineLimit(4).foregroundColor(.primary)
                                if !item.attachments.isEmpty {
                                    Text(item.attachments.map(\.name).joined(separator: " · ")).font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .accessibilityLabel(item.label + ": " + String(item.markdown.prefix(80)))
                    .accessibilityValue(model.selected.contains(item.id) ? "已选择" : "未选择")
                }.listStyle(.plain).disabled(exporting)
                Picker("导出格式", selection: $options.format) {
                    Text("长图").tag(ChatExportOptions.Format.image)
                    Text("可搜索 PDF").tag(ChatExportOptions.Format.pdf)
                    Text("原 Markdown").tag(ChatExportOptions.Format.markdown)
                }.pickerStyle(.segmented).padding(.horizontal)
                HStack {
                    Toggle("宽版", isOn: $options.wideLayout)
                    Toggle("深色", isOn: $options.dark)
                }.padding().disabled(exporting || options.format == .markdown)
                if !warnings.isEmpty {
                    Text(warnings.joined(separator: "\n")).font(.caption).foregroundColor(.secondary).padding(.horizontal)
                }
                Text("超长图自动分片；PDF 保留可搜索文字。附件仅嵌入当前会话可读取的本地图片。")
                    .font(.caption).foregroundColor(.secondary).padding(.horizontal)
                Button(action: export) {
                    HStack { if exporting { ProgressView() }; Text(exporting ? "正在导出…" : "导出所选消息") }
                        .frame(maxWidth: .infinity, minHeight: 44)
                }.buttonStyle(.borderedProminent).padding()
                    .disabled(exporting || model.selected.isEmpty)
            }
            .navigationTitle("选择消息").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { exportTask?.cancel(); dismiss() } } }
            .minisNavigationChrome()
        }
        .navigationViewStyle(.stack)
        .onAppear { options.dark = colorScheme == .dark }
        .onDisappear { exportTask?.cancel() }
        .sheet(item: $result) { value in
            ChatExportActivitySheet(urls: value.urls) {
                // UIActivityViewController owns URL lifetimes through completion.
                if let parent = value.urls.first?.deletingLastPathComponent() {
                    try? FileManager.default.removeItem(at: parent)
                }
                result = nil
            }
        }
        .alert("导出失败", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("好", role: .cancel) { errorText = nil }
        } message: { Text(errorText ?? "") }
    }
    private func export() {
        let selected = model.selectedItems, title = model.title, options = options
        exporting = true; errorText = nil; warnings = []
        exportTask = Task { @MainActor in
            defer { exporting = false; exportTask = nil }
            do {
                let exported = try await ChatExportRenderer.render(items: selected, title: title, options: options) { source in
                    await vm.resolveMinisPath(source)
                }
                if Task.isCancelled {
                    if let parent = exported.urls.first?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: parent) }
                    return
                }
                warnings = exported.warnings; result = exported
            } catch is CancellationError { /* Closing is not an export failure. */ }
            catch { errorText = error.localizedDescription }
        }
    }
}

private struct ChatExportActivitySheet: UIViewControllerRepresentable {
    let urls: [URL]
    let onComplete: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: urls, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in DispatchQueue.main.async { onComplete() } }
        return controller
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
