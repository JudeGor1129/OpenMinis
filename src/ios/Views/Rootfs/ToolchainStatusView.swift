//
//  ToolchainStatusView.swift
//  MinisApp
//
//  Displays the status of iSH toolchain tools in the rootfs management page
//

import SwiftUI

/// Single tool status entry
struct ToolStatusEntry: Identifiable {
    let id: String
    let name: String
    let command: String
    let description: String
    let category: ToolCategory
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

/// All known toolchain entries to check
let allToolEntries: [ToolStatusEntry] = [
    // Core tools
    ToolStatusEntry(id: "node", name: "Node.js", command: "node --version", description: "JavaScript 运行时", category: .core),
    ToolStatusEntry(id: "npm", name: "npm", command: "npm --version", description: "Node 包管理器", category: .core),
    ToolStatusEntry(id: "python", name: "Python", command: "python3 --version", description: "Python 解释器", category: .core),
    ToolStatusEntry(id: "pip", name: "pip", command: "pip3 --version", description: "Python 包管理器", category: .core),
    ToolStatusEntry(id: "make", name: "make", command: "make --version | head -1", description: "构建工具", category: .core),
    ToolStatusEntry(id: "git", name: "Git", command: "git --version", description: "版本控制", category: .core),
    
    // Reverse engineering tools
    ToolStatusEntry(id: "theos", name: "Theos", command: "[ -d /opt/theos ] && echo 'installed'", description: "越狱插件开发工具链", category: .reverse),
    ToolStatusEntry(id: "clang", name: "Clang", command: "clang --version | head -1", description: "C/C++ 编译器", category: .reverse),
    ToolStatusEntry(id: "ldid", name: "ldid", command: "[ -x /usr/local/bin/ldid ] && echo 'installed'", description: "签名工具", category: .reverse),
    ToolStatusEntry(id: "radare2", name: "radare2", command: "r2 --version | head -1", description: "反汇编与逆向框架", category: .reverse),
    ToolStatusEntry(id: "otool", name: "otool", command: "which otool", description: "Mach-O 分析工具", category: .reverse),
    ToolStatusEntry(id: "strip", name: "strip", command: "which strip", description: "符号剥离工具", category: .reverse),
    ToolStatusEntry(id: "llvm-lipo", name: "llvm-lipo", command: "which llvm-lipo", description: "Fat binary 合并工具", category: .reverse),
    
    // Debugging & analysis
    ToolStatusEntry(id: "frida", name: "Frida Server", command: "[ -x /var/jb/usr/sbin/frida-server ] && echo 'installed'", description: "动态插桩工具", category: .debug),
    ToolStatusEntry(id: "strace", name: "strace", command: "which strace", description: "系统调用追踪", category: .debug),
    ToolStatusEntry(id: "lsof", name: "lsof", command: "which lsof", description: "打开文件列表", category: .debug),
    
    // System tools
    ToolStatusEntry(id: "dpkg", name: "dpkg", command: "dpkg --version | head -1", description: "Debian 包管理", category: .system),
    ToolStatusEntry(id: "apt", name: "apt", command: "apt-get --version | head -1", description: "APT 包管理", category: .system),
    ToolStatusEntry(id: "procps", name: "procps", command: "which ps && ps --version | head -1", description: "进程状态工具", category: .system),
    ToolStatusEntry(id: "busybox", name: "BusyBox", command: "busybox | head -1", description: "嵌入式工具集", category: .system),
]

struct ToolchainStatusView: View {
    @State private var toolStatuses: [String: ToolStatus] = [:]
    @State private var isChecking = false
    @State private var lastCheckTime: Date?
    @State private var notice: String?
    
    /// Auto-refresh every 60 seconds when tools are partially detected
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    
    enum ToolStatus {
        case installed(String)      // version/info string
        case missing
        case error(String)
    }
    
    var body: some View {
        Section("iSH 工具链状态") {
            // Category headers and rows
            ForEach(ToolCategory.allCases, id: \.self) { category in
                ToolCategoryRow(category: category, entries: getEntries(for: category), toolStatuses: toolStatuses)
            }
            
            // Refresh button and info
            HStack {
                Button(action: checkAllTools) {
                    HStack {
                        Label("刷新状态", systemImage: "arrow.clockwise")
                        if isChecking { Spacer(); ProgressView() }
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
            
            if let notice {
                Text(notice)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .onReceive(timer) { _ in
            // Auto-refresh every 60 seconds
            if !isChecking && toolStatuses.count >= 3 {
                checkAllTools()
            }
        }
        .onAppear {
            checkAllTools()
        }
    }
    
    private func getEntries(for category: ToolCategory) -> [ToolStatusEntry] {
        allToolEntries.filter { $0.category == category }
    }
    
    private func checkAllTools() {
        guard !isChecking else { return }
        guard ISHKernel.shared.isBooted else {
            notice = "请先在内置终端中启动 Alpine 环境"
            return
        }
        
        isChecking = true
        notice = nil
        toolStatuses.removeAll()
        
        DispatchQueue.global(qos: .utility).async {
            // Build combined check command
            let commands = allToolEntries.map { entry in
                "echo \"\(entry.id)=START\"; \(entry.command) 2>&1; echo \"\(entry.id)=END\""
            }.joined(separator: "; ")
            
            let result = ISHShellExecutor.executeCommandSync(commands, timeout: 30, lineCallback: nil)
            let output = result.output
            
            DispatchQueue.main.async {
                self.isChecking = false
                self.lastCheckTime = Date()
                
                guard result.exitCode != -1 else {
                    self.notice = "执行失败: \(result.error.rawValue == 0 ? "超时" : "错误")"
                    return
                }
                
                // Parse results
                var currentId: String?
                var currentOutput: String = ""
                
                for line in output.components(separatedBy: .newlines) {
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    
                    if trimmed.hasPrefix("=START") {
                        let id = String(trimmed.dropFirst(6))
                        currentId = id
                        currentOutput = ""
                    } else if trimmed.hasPrefix("=END") {
                        if let id = currentId {
                            let status: ToolStatus
                            if currentOutput.contains("not found") || currentOutput.isEmpty {
                                status = .missing
                            } else {
                                let cleanOutput = currentOutput
                                    .components(separatedBy: .newlines)
                                    .first?
                                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                status = .installed(cleanOutput)
                            }
                            self.toolStatuses[id] = status
                        }
                        currentId = nil
                        currentOutput = ""
                    } else if let id = currentId {
                        currentOutput += (currentOutput.isEmpty ? "" : "\n") + line
                    }
                }
                
                let installed = self.toolStatuses.values.filter { $0 != .missing }.count
                self.notice = "已检测 \(installed)/\(allToolEntries.count) 个工具"
            }
        }
    }
    
    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

/// Row for a tool category
private struct ToolCategoryRow: View {
    let category: ToolCategory
    let entries: [ToolStatusEntry]
    let toolStatuses: [String: ToolchainStatusView.ToolStatus]
    
    var body: some View {
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: category.icon)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(category.rawValue)
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
                
                ForEach(entries) { entry in
                    ToolRow(entry: entry, status: toolStatuses[entry.id])
                }
            }
            .padding(.vertical, 4)
        }
    }
}

/// Single tool status row
private struct ToolRow: View {
    let entry: ToolStatusEntry
    let status: ToolchainStatusView.ToolStatus?
    
    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                    .font(.body)
                Text(entry.description)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            statusView
        }
    }
    
    private var statusView: some View {
        switch status {
        case .installed(let info):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(info)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
            }
        case .missing:
            HStack(spacing: 6) {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.gray)
                Text("未安装")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .error(let msg):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        case .none:
            ProgressView()
                .controlSize(.small)
        }
    }
}

#Preview {
    ToolchainStatusView()
}
