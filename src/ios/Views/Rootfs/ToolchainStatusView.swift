//
//  ToolchainStatusView.swift
//  MinisApp
//
//  Displays the status of iSH toolchain tools in the rootfs management page.
//  [T-ios-toolchain-status]
//

import SwiftUI

/// Single tool status entry
struct ToolStatusEntry: Identifiable {
    let id: String
    let name: String
    let command: String
    let description: String
    let category: ToolCategory
    /// Tools implemented in the Minis host process, not Alpine/iSH.
    let isBuiltin: Bool

    init(id: String, name: String, command: String, description: String, category: ToolCategory, isBuiltin: Bool = false) {
        self.id = id
        self.name = name
        self.command = command
        self.description = description
        self.category = category
        self.isBuiltin = isBuiltin
    }
}

/// Categories for grouping tools
enum ToolCategory: String, CaseIterable {
    case core = "核心工具"
    case reverse = "逆向工程"
    case debug = "调试分析"
    case system = "系统工具"

    var icon: String {
        switch self {
        case .core: return "terminal"
        case .reverse: return "magnifyingglass"
        case .debug: return "waveform.path.ecg"
        case .system: return "gear"
        }
    }
}

/// All known toolchain entries to check.
private let allToolEntries: [ToolStatusEntry] = [
    // Core tools
    ToolStatusEntry(id: "node", name: "Node.js", command: "node --version", description: "JavaScript 运行时", category: .core),
    ToolStatusEntry(id: "npm", name: "npm", command: "npm --version", description: "Node 包管理器", category: .core),
    ToolStatusEntry(id: "python", name: "Python", command: "python3 --version", description: "Python 解释器", category: .core),
    ToolStatusEntry(id: "pip", name: "pip", command: "pip3 --version", description: "Python 包管理器", category: .core),
    ToolStatusEntry(id: "make", name: "make", command: "make --version", description: "构建工具", category: .core),
    ToolStatusEntry(id: "git", name: "Git", command: "git --version", description: "版本控制", category: .core),

    // Reverse engineering tools
    ToolStatusEntry(id: "theos", name: "Theos", command: "test -d /opt/theos && echo installed", description: "越狱插件开发工具链", category: .reverse),
    ToolStatusEntry(id: "clang", name: "Clang", command: "clang --version", description: "C/C++ 编译器", category: .reverse),
    ToolStatusEntry(id: "ldid", name: "ldid", command: "test -x /usr/local/bin/ldid && echo installed", description: "签名工具", category: .reverse),
    ToolStatusEntry(id: "radare2", name: "radare2", command: "r2 -v", description: "反汇编与逆向框架", category: .reverse),
    // rea is an npx wrapper; do not execute it during status refresh because
    // that could resolve/download a package. Presence is the safe health check.
    ToolStatusEntry(id: "rea", name: "rea", command: "test -x /usr/local/bin/rea && echo installed", description: "逆向分析代理工具", category: .reverse),
    // Mach-O analysis is implemented by Minis' native host_macho_info tool.
    // It intentionally does not depend on a Darwin `otool` binary inside Alpine.
    ToolStatusEntry(id: "otool", name: "Mach-O 分析（Minis 内置）", command: "", description: "原生 Mach-O 分析器", category: .reverse, isBuiltin: true),
    ToolStatusEntry(id: "strip", name: "strip", command: "which strip", description: "符号剥离工具", category: .reverse),
    ToolStatusEntry(id: "llvm-lipo", name: "llvm-lipo", command: "which llvm-lipo", description: "Fat binary 合并工具", category: .reverse),

    // Debugging & analysis
    ToolStatusEntry(id: "frida", name: "Frida Server", command: "test -x /var/jb/usr/sbin/frida-server && echo installed", description: "动态插桩工具", category: .debug),
    ToolStatusEntry(id: "strace", name: "strace", command: "which strace", description: "系统调用追踪", category: .debug),
    ToolStatusEntry(id: "lsof", name: "lsof", command: "which lsof", description: "打开文件列表", category: .debug),

    // System tools
    ToolStatusEntry(id: "dpkg", name: "dpkg", command: "dpkg --version", description: "Debian 包管理", category: .system),
    ToolStatusEntry(id: "apt", name: "apt", command: "apk --version", description: "APK 包管理", category: .system),
    ToolStatusEntry(id: "procps", name: "procps", command: "ps --version", description: "进程状态工具", category: .system),
    ToolStatusEntry(id: "busybox", name: "BusyBox", command: "busybox", description: "嵌入式工具集", category: .system)
]

struct ToolchainStatusView: View {
    enum ToolStatus: Equatable {
        case installed(String)      // version/info string
        case missing
        case error(String)
    }

    @State private var toolStatuses: [String: ToolStatus] = [:]
    @State private var isChecking = false
    @State private var lastCheckTime: Date?
    @State private var notice: String?

    /// Auto-refresh every 60 seconds once a first pass has run.
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    var body: some View {
        Section("iSH 工具链状态") {
            ForEach(ToolCategory.allCases, id: \.self) { category in
                ToolCategoryRow(category: category,
                                entries: entries(for: category),
                                toolStatuses: toolStatuses)
            }

            HStack {
                Button(action: checkAllTools) {
                    HStack(spacing: 6) {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                        if isChecking { ProgressView() }
                    }
                }
                .disabled(isChecking)

                Spacer()

                if let time = lastCheckTime {
                    Text("上次: \(time, formatter: timeFormatter)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if let notice = notice {
                Text(notice)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onReceive(timer) { _ in
            if !isChecking && !toolStatuses.isEmpty && notice != "Alpine 未启动" {
                checkAllTools()
            }
        }
        .onAppear {
            if toolStatuses.isEmpty { checkAllTools() }
        }
    }

    private func entries(for category: ToolCategory) -> [ToolStatusEntry] {
        allToolEntries.filter { $0.category == category }
    }

    private func checkAllTools() {
        guard !isChecking else { return }

        isChecking = true
        toolStatuses = Dictionary(uniqueKeysWithValues: allToolEntries
            .filter(\.isBuiltin)
            .map { ($0.id, .installed("Minis 内置")) })

        let shellEntries = allToolEntries.filter { !$0.isBuiltin }
        guard ISHKernel.shared.isBooted else {
            isChecking = false
            lastCheckTime = Date()
            notice = "Alpine 未启动；Minis 内置工具可直接使用"
            return
        }
        guard !shellEntries.isEmpty else {
            isChecking = false
            lastCheckTime = Date()
            notice = "已检测 \(allToolEntries.count)/\(allToolEntries.count) 个工具"
            return
        }

        DispatchQueue.global(qos: .utility).async {
            // One shell round-trip for Alpine/iSH probes; host-native tools
            // are already represented above and never shell out to Alpine.
            let script = shellEntries.map { entry in
                "echo '@@\(entry.id)=START'; { \(entry.command); } 2>&1; echo '@@\(entry.id)=END'"
            }.joined(separator: "; ")

            let result = ISHShellExecutor.executeCommandSync(script, timeout: 30, lineCallback: nil)
            let output = result.output
            let exitCode = result.exitCode

            DispatchQueue.main.async {
                isChecking = false
                lastCheckTime = Date()

                var parsed: [String: ToolStatus] = [:]
                var currentId: String?
                var currentLines: [String] = []

                for rawLine in output.components(separatedBy: .newlines) {
                    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)

                    if line.hasPrefix("@@"), line.hasSuffix("=START") {
                        let id = String(line.dropFirst(2).dropLast(6))
                        currentId = id
                        currentLines = []
                    } else if line.hasPrefix("@@"), line.hasSuffix("=END") {
                        let id = String(line.dropFirst(2).dropLast(4))
                        if currentId == id {
                            parsed[id] = ToolchainStatusView.classify(currentLines)
                        }
                        currentId = nil
                        currentLines = []
                    } else if currentId != nil, !line.isEmpty {
                        currentLines.append(line)
                    }
                }

                let builtinStatuses = Dictionary(uniqueKeysWithValues: allToolEntries
                    .filter(\.isBuiltin)
                    .map { ($0.id, .installed("Minis 内置")) })
                toolStatuses = builtinStatuses.merging(parsed) { _, alpine in alpine }

                if exitCode == -1 {
                    notice = "检测超时；Minis 内置 Mach-O 分析器仍可用"
                } else if parsed.isEmpty {
                    notice = "未获取到 Alpine 结果；Minis 内置工具可用"
                } else {
                    let installed = toolStatuses.values.filter { $0 != .missing }.count
                    notice = "已检测 \(installed)/\(allToolEntries.count) 个工具"
                }
            }
        }
    }

    private static func classify(_ lines: [String]) -> ToolStatus {
        guard let first = lines.first, !lines.isEmpty else { return .missing }
        let joined = lines.joined(separator: "\n")
        if joined.contains("not found") || joined.contains("No such file") || joined.contains("Permission denied") {
            return .missing
        }
        if first == "installed" { return .installed("已安装") }
        let trimmed = first.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .missing }
        return .installed(String(trimmed.prefix(28)))
    }
}

/// Row for a tool category
private struct ToolCategoryRow: View {
    let category: ToolCategory
    let entries: [ToolStatusEntry]
    let toolStatuses: [String: ToolchainStatusView.ToolStatus]

    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Image(systemName: category.icon)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(category.rawValue)
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }

                ForEach(entries) { entry in
                    ToolRow(entry: entry, status: toolStatuses[entry.id])
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }
}

/// Single tool status row. The trailing probe output is untrusted text (some
/// tools print warnings or long paths); keep it inside the list row instead of
/// allowing it to widen the entire Settings page.
private struct ToolRow: View {
    let entry: ToolStatusEntry
    let status: ToolchainStatusView.ToolStatus?

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(entry.description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            statusView
                .frame(width: 148, alignment: .trailing)
                .clipped()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var statusView: some View {
        switch status {
        case .some(.installed(let info)):
            statusLabel(info, icon: "checkmark.circle.fill", color: .green, monospaced: true)
        case .some(.missing):
            statusLabel("未安装", icon: "xmark.circle.fill", color: .gray, monospaced: false)
        case .some(.error(let msg)):
            statusLabel(msg, icon: "exclamationmark.triangle.fill", color: .orange, monospaced: false)
        case .none:
            HStack { Spacer(); ProgressView().controlSize(.small) }
        }
    }

    private func statusLabel(_ text: String, icon: String, color: Color, monospaced: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 18)
            Text(text)
                .font(monospaced ? .caption.monospaced() : .caption)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityLabel(Text(text))
    }
}
