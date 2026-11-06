import SwiftUI
import UIKit

/// In-app compiler console ("编译器" in the chat's "…" menu).
///
/// Deliberately terminal-free: this is the build log surface, not a shell.
/// Content is whatever `BuildConsoleStore` captured for the owning session —
/// the page itself never executes a build.
struct BuildConsoleView: View {
    let sessionID: String?

    @ObservedObject private var store = BuildConsoleStore.shared
    @Environment(\.dismiss) private var dismiss

    @State private var copied = false

    private var state: BuildConsoleStore.State { store.state(for: sessionID) }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .background(Color(UIColor.systemBackground))
        .navigationTitle("控制台")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarLeading) {
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .accessibilityLabel("关闭")
            }
            ToolbarItem(placement: .navigationBarTrailing) { overflowMenu }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: state.status.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(statusColor)
            Text(state.status.title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if state.status == .running {
                ProgressView().scaleEffect(0.7)
            }
            Text("·").font(.system(size: 13)).foregroundStyle(.tertiary)
            Text("\(state.lines.count) 行")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusColor: Color {
        switch state.status {
        case .idle: return .secondary
        case .running: return .accentColor
        case .succeeded: return .green
        case .failed: return .red
        case .cancelled: return .orange
        }
    }

    private var overflowMenu: some View {
        Menu {
            Button {
                UIPasteboard.general.string = state.lines.map(\.text).joined(separator: "\n")
                copied = true
            } label: {
                Label(copied ? "已复制日志" : "复制全部日志", systemImage: "doc.on.doc")
            }
            .disabled(state.lines.isEmpty)

            Button(role: .destructive) {
                store.clear(sessionID: sessionID)
                copied = false
            } label: {
                Label("清空日志", systemImage: "trash")
            }
            .disabled(state.lines.isEmpty)
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .accessibilityLabel("更多")
    }

    // MARK: - Body

    @ViewBuilder
    private var content: some View {
        if state.lines.isEmpty {
            emptyState
        } else {
            logList
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "hammer")
                .font(.system(size: 44, weight: .regular))
                .foregroundStyle(.tertiary)
            Text("暂无编译输出")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Text("开始构建后，日志会显示在这里。")
                .font(.system(size: 14))
                .foregroundStyle(.tertiary)
            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(state.lines) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(lineColor(for: line.text))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(line.id)
                    }
                    if let artifact = state.artifactPath, !artifact.isEmpty {
                        artifactRow(artifact)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
            }
            .onChange(of: state.lines.count) { _ in
                guard let last = state.lines.last else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    private func artifactRow(_ path: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 6)
            Text("产物")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.primary)
        }
        .padding(.top, 4)
    }

    private func lineColor(for text: String) -> Color {
        let lower = text.lowercased()
        if lower.hasPrefix("error") || lower.contains(" error:") || lower.contains("failed") {
            return .red
        }
        if lower.hasPrefix("warning") || lower.contains(" warning:") {
            return .orange
        }
        if lower.hasPrefix("$ ") {
            return .secondary
        }
        return .primary
    }
}
