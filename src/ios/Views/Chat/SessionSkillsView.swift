//
//  SessionSkillsView.swift
//  MinisApp
//
//  Per-session skill toggle sheet: override which skills are active in a chat.
//

import SwiftUI

struct SessionSkillsView: View {
    /// The real session id, or nil for a draft chat that hasn't sent its first
    /// message yet. Never coerced to "" — an empty-string key would write the
    /// override to a phantom session and accumulate stale state across drafts
    /// (T-ios-session-skill-override-init-timing).
    let sessionId: String?
    /// Materializes the draft into a real, persisted session and returns its id.
    /// Called lazily on the first toggle so a pre-first-message override binds
    /// to the session the chat will actually use. Mirrors SessionModelPicker.
    var ensureSessionId: (() async -> String)?
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = SkillStore.shared
    @State private var searchQuery = ""
    /// The id reads/writes resolve against. Seeded from `sessionId`; once a
    /// draft is materialized on first toggle it holds the real id so the rest
    /// of the sheet stays consistent without re-creating the session.
    @State private var resolvedSessionId: String?
    @State private var groupDefaultsReady = false

    init(sessionId: String?, ensureSessionId: (() async -> String)? = nil) {
        self.sessionId = sessionId
        self.ensureSessionId = ensureSessionId
        _resolvedSessionId = State(initialValue: sessionId)
    }

    /// Whether `skill` is enabled for this session. With no resolved session
    /// (draft, pre-first-message) this reads the skill's GLOBAL default so the
    /// sheet shows the correct initial state.
    private func isEnabled(_ skill: Skill) -> Bool {
        if let sid = resolvedSessionId {
            return store.isEnabledForSession(skill.id, sessionId: sid)
        }
        return skill.isEnabled
    }

    /// Apply a toggle: materialize the draft session if needed, then write the
    /// override against the real id. Runs async because session creation is.
    private func setOverride(_ skill: Skill, _ enabled: Bool) {
        if let sid = resolvedSessionId {
            store.setSessionOverride(skillId: skill.id, sessionId: sid, enabled: enabled)
            return
        }
        Task {
            guard let sid = await ensureSessionId?() else { return }
            await store.refreshGroupDefaults(sessionId: sid)
            resolvedSessionId = sid
            store.setSessionOverride(skillId: skill.id, sessionId: sid, enabled: enabled)
        }
    }

    /// Enable/Disable All: materialize the draft session ONCE (not per-skill, to
    /// avoid racing N createSession calls), then write every override.
    private func applyToAll(_ scope: [Skill], enabled: Bool) {
        if let sid = resolvedSessionId {
            for skill in scope {
                store.setSessionOverride(skillId: skill.id, sessionId: sid, enabled: enabled)
            }
            return
        }
        Task {
            guard let sid = await ensureSessionId?() else { return }
            await store.refreshGroupDefaults(sessionId: sid)
            resolvedSessionId = sid
            for skill in scope {
                store.setSessionOverride(skillId: skill.id, sessionId: sid, enabled: enabled)
            }
        }
    }

    private var filteredSkills: [Skill] {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.skills }
        return store.skills.filter {
            $0.name.lowercased().contains(q) || $0.description.lowercased().contains(q)
        }
    }

    var body: some View {
        // Reference the version counter so SwiftUI refreshes on override changes.
        let _ = store.sessionOverrideVersion

        MinisNavigationContainer {
            List {
                if store.skills.isEmpty {
                    Section {
                        Text("No skills installed. Add skills in Settings.")
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                } else if filteredSkills.isEmpty {
                    Section {
                        Text(AppLocalized("No skills match \"\(searchQuery)\"."))
                            .foregroundStyle(.secondary)
                            .font(.subheadline)
                    }
                } else {
                    Section(footer: Text("优先级：会话覆盖 → 分组默认 → 全局默认。显式切换仅影响本会话，正在运行的任务保持启动时的技能配置。")) {
                        ForEach(filteredSkills) { skill in
                            NavigationLink {
                                SessionSkillDetailView(skill: skill)
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(skill.name).font(.body)
                                        Text(resolvedSessionId.map {
                                            store.skillConfigurationSource(skill.id, sessionId: $0)
                                        } ?? "全局默认（草稿）")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                        if !skill.description.isEmpty {
                                            Text(skill.description)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                                .lineLimit(2)
                                        }
                                    }
                                    Spacer()
                                    Toggle("", isOn: Binding(
                                        get: { isEnabled(skill) },
                                        set: { setOverride(skill, $0) }
                                    ))
                                    .labelsHidden()
                                }
                            }
                        }
                    }
                }
                if let sid = resolvedSessionId {
                    Section {
                        Button("恢复继承分组／全局默认") {
                            store.resetSessionOverrides(sessionId: sid)
                        }
                    }
                }
            }
            .disabled(!groupDefaultsReady)
            .navigationTitle("Skills in Session")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $searchQuery, placement: .navigationBarDrawer(displayMode: .always),
                        prompt: Text(AppLocalized("Search skills")))
            .task {
                store.reload()
                if let sid = resolvedSessionId {
                    await store.refreshGroupDefaults(sessionId: sid)
                }
                groupDefaultsReady = true
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if !filteredSkills.isEmpty {
                        let scope = filteredSkills
                        let allEnabled = scope.allSatisfy { isEnabled($0) }
                        Button(allEnabled ? "Disable All" : "Enable All") {
                            let newValue = !allEnabled
                            applyToAll(scope, enabled: newValue)
                        }
                        .font(.subheadline)
                        .disabled(!groupDefaultsReady)
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct SessionSkillDetailView: View {
    let skill: Skill
    @ObservedObject private var store = SkillStore.shared

    private var additionalFiles: [String] {
        store.listSkillFiles(skill.id).filter { $0 != "SKILL.md" }
    }

    var body: some View {
        List {
            Section("SKILL.md") {
                let content = store.readSkillContent(skill.id) ?? "(empty)"
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
            }

            if !additionalFiles.isEmpty {
                Section("Other Files") {
                    ForEach(additionalFiles, id: \.self) { relativePath in
                        NavigationLink {
                            SkillFilePreviewView(skillId: skill.id, relativePath: relativePath)
                        } label: {
                            Label {
                                Text(relativePath)
                                    .font(.system(.subheadline, design: .monospaced))
                            } icon: {
                                Image(systemName: iconName(for: relativePath))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(skill.name)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func iconName(for path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "md": return "doc.text"
        case "py": return "chevron.left.forwardslash.chevron.right"
        case "json": return "curlybraces"
        case "sh": return "terminal"
        case "yaml", "yml": return "list.bullet.indent"
        case "png", "jpg", "jpeg", "gif", "webp": return "photo"
        default: return "doc"
        }
    }
}

private struct SkillFilePreviewView: View {
    let skillId: String
    let relativePath: String

    @ObservedObject private var store = SkillStore.shared
    @State private var content: String = ""

    private var fileName: String {
        (relativePath as NSString).lastPathComponent
    }

    private var isImage: Bool {
        ["png", "jpg", "jpeg", "gif", "webp"].contains((relativePath as NSString).pathExtension.lowercased())
    }

    var body: some View {
        Group {
            if isImage {
                let fileURL = store.skillDirectoryURL(for: skillId).appendingPathComponent(relativePath)
                if let data = try? Data(contentsOf: fileURL),
                   let uiImage = UIImage(data: data) {
                    ScrollView {
                        Image(uiImage: uiImage)
                            .resizable()
                            .scaledToFit()
                            .padding()
                    }
                } else {
                    Text("Could not load image.")
                        .foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    Text(content)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
            }
        }
        .navigationTitle(fileName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            if !isImage {
                content = store.readSkillFile(skillId, relativePath: relativePath) ?? ""
            }
        }
    }
}

// MARK: - Group configuration (local, independent from transcript storage)
struct MinisGroupConfiguration: Codable {
    var skillDefaults: [String: Bool] = [:]
    var soul: String = ""
    var memory: String = ""
    // Optional fields preserve configurations saved by version 47.
    var soulName: String?
    var soulStyle: String?
    var soulLanguage: String?
    var soulIcon: String?
    var memoryEnabled: Bool?

    var renderedSoul: String {
        let fields = [soulName.map { "Name: \($0)" }, soulStyle.map { "Style: \($0)" },
                      soulLanguage.flatMap { $0 == "auto" ? nil : "Language: \($0)" }]
            .compactMap { $0 }.filter { !$0.hasSuffix(": ") }
        return (fields + [soul]).filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

enum MinisGroupConfigurationStore {
    static func memoryDirectory(_ folderID: String) -> URL {
        // IDs are data, never host path segments (including imported IDs).
        let key = folderID.utf8.map { String(format: "%02x", $0) }.joined()
        return AIChatViewModel.minisConfigRoot
            .appendingPathComponent("group-memory", isDirectory: true)
            .appendingPathComponent(key, isDirectory: true)
    }

    static func load(_ folderID: String) -> MinisGroupConfiguration {
        var value = UserDefaults.standard.data(forKey: "group.configuration." + folderID)
            .flatMap { try? JSONDecoder().decode(MinisGroupConfiguration.self, from: $0) }
            ?? MinisGroupConfiguration()
        if let memory = try? String(contentsOf: memoryDirectory(folderID).appendingPathComponent("GLOBAL.md"), encoding: .utf8) {
            value.memory = memory
        }
        return value
    }
    static func save(_ value: MinisGroupConfiguration, folderID: String) throws {
        let data = try JSONEncoder().encode(value)
        let dir = memoryDirectory(folderID)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try value.memory.write(to: dir.appendingPathComponent("GLOBAL.md"), atomically: true, encoding: .utf8)
        UserDefaults.standard.set(data, forKey: "group.configuration." + folderID)
    }
}

struct MinisGroupConfigurationView: View {
    let folder: ChatFolder
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var skills = SkillStore.shared
    @State private var configuration: MinisGroupConfiguration
    @State private var showEmojiPrompt = false
    @State private var emojiDraft = ""
    @State private var showPhotoPicker = false
    @State private var iconError: String?
    @State private var saveError: String?

    init(folder: ChatFolder) {
        self.folder = folder
        _configuration = State(initialValue: MinisGroupConfigurationStore.load(folder.id))
    }

    var body: some View {
        MinisNavigationContainer {
            Form {
                Section {
                    NavigationLink {
                        Form {
                            Button("全部开启") {
                                for skill in skills.skills { configuration.skillDefaults[skill.id] = true }
                            }
                            Button("全部关闭") {
                                for skill in skills.skills { configuration.skillDefaults[skill.id] = false }
                            }
                            ForEach(skills.skills) { skill in
                                Toggle(skill.name, isOn: Binding(
                                    get: { configuration.skillDefaults[skill.id] ?? skill.isEnabled },
                                    set: { configuration.skillDefaults[skill.id] = $0 }
                                ))
                            }
                            Button("恢复全部继承全局") { configuration.skillDefaults = [:] }
                        }
                        .navigationTitle("技能")
                    } label: { Label("技能", systemImage: "puzzlepiece.extension") }
                    NavigationLink {
                        Form {
                            Section {
                                HStack(spacing: 12) {
                                    SoulIconView(icon: configuration.soulIcon ?? SoulStore.cachedMetadata.icon, size: 44)
                                    Text(configuration.soulName ?? folder.name).font(.headline)
                                }
                                Button("从照片选择头像") { showPhotoPicker = true }
                                Button("选择表情头像") {
                                    emojiDraft = configuration.soulIcon ?? ""
                                    showEmojiPrompt = true
                                }
                                Button("继承全局头像") { configuration.soulIcon = nil }
                            }
                            Section("标识") {
                                TextField("名称", text: Binding(get: { configuration.soulName ?? "" }, set: { configuration.soulName = $0 }))
                                TextField("风格：温和、直接、有主见", text: Binding(get: { configuration.soulStyle ?? "" }, set: { configuration.soulStyle = $0 }))
                                Picker("语言", selection: Binding(get: { configuration.soulLanguage ?? "auto" }, set: { configuration.soulLanguage = $0 })) {
                                    Text("自动").tag("auto")
                                    Text("中文").tag("中文")
                                    Text("English").tag("English")
                                }
                            }
                            Section("人格提示词") {
                                TextEditor(text: $configuration.soul).frame(minHeight: 240)
                                Text("\(configuration.soul.count) 字符；留空并清除标识字段则继承全局灵魂。")
                                    .font(.caption).foregroundColor(.secondary)
                            }
                            Button("恢复继承全局", role: .destructive) {
                                configuration.soul = ""
                                configuration.soulName = nil
                                configuration.soulStyle = nil
                                configuration.soulLanguage = nil
                                configuration.soulIcon = nil
                            }
                        }.navigationTitle("灵魂")
                        .modifier(SoulIconEditing(
                            icon: Binding(get: { configuration.soulIcon ?? "" }, set: { configuration.soulIcon = $0 }),
                            showEmojiPrompt: $showEmojiPrompt, emojiDraft: $emojiDraft,
                            showPhotoPicker: $showPhotoPicker, iconError: $iconError
                        ))
                    } label: { Label("灵魂", systemImage: "sparkles") }
                    NavigationLink {
                        MinisGroupMemorySettings(configuration: $configuration, folderID: folder.id)
                    } label: { Label("记忆", systemImage: "brain.head.profile") }
                } footer: {
                    Text("保存后在下一次任务启动时生效。技能：会话覆盖优先于分组默认；灵魂留空继承全局；分组记忆独立读写，记忆开关仍有效。分组配置及记忆暂不云同步。")
                }
            }
            .navigationTitle(folder.name)
            .alert("保存失败", isPresented: Binding(get: { saveError != nil }, set: { if !$0 { saveError = nil } })) {
                Button("确定") { saveError = nil }
            } message: { Text(saveError ?? "") }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        do {
                            try MinisGroupConfigurationStore.save(configuration, folderID: folder.id)
                            dismiss()
                        } catch { saveError = error.localizedDescription }
                    }
                }
            }
        }
    }
}

// Group-scoped memory browser. GLOBAL uses the parent's save transaction;
// daily files are edited explicitly and never sync into global memory.
private struct MinisGroupMemorySettings: View {
    @Binding var configuration: MinisGroupConfiguration
    let folderID: String
    @State private var files: [URL] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                Toggle("本分组启用记忆", isOn: Binding(get: { configuration.memoryEnabled ?? true }, set: { configuration.memoryEnabled = $0 }))
            } footer: {
                Text("关闭后，本组任务不会读取或写入长期记忆、每日日志和结构化项目记忆，相关记忆工具也会停用。不会删除已有记录；主页面保存后生效。")
            }
            Section {
                HStack {
                    Label("本组使用结构化项目记忆", systemImage: "brain.head.profile")
                    Spacer()
                    Text((configuration.memoryEnabled ?? true) ? "已启用" : "已停用")
                        .foregroundStyle((configuration.memoryEnabled ?? true) ? Color.green : Color.secondary)
                }
                NavigationLink {
                    StructuredMemoryCenterView()
                } label: {
                    Label("管理结构化记忆", systemImage: "list.bullet.rectangle")
                }
            } header: {
                Text("结构化项目记忆")
            } footer: {
                Text("此功能沿用上方“本分组启用记忆”总开关，不需要重复开关。自动写入还受“设置 → 记忆 → 自动项目记忆”全局开关控制；记录按项目隔离，不会与其他项目混用。")
            }
            Section("记忆文件") {
                NavigationLink {
                    TextEditor(text: $configuration.memory).padding()
                        .navigationTitle("GLOBAL.md")
                } label: {
                    fileLabel("GLOBAL.md", content: configuration.memory, date: nil)
                }
                ForEach(files, id: \.path) { url in
                    NavigationLink {
                        MinisGroupMemoryFileEditor(url: url)
                    } label: {
                        fileLabel(url.lastPathComponent,
                                  content: (try? String(contentsOf: url, encoding: .utf8)) ?? "",
                                  date: (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate)
                    }
                }
                .onDelete { indices in
                    do {
                        for index in indices { try FileManager.default.removeItem(at: files[index]) }
                        reload()
                    } catch { errorMessage = error.localizedDescription }
                }
            }
            Section {
                Text("灵魂由本组的“灵魂”页面管理；此处仅列出本组记忆，不显示其他分组或全局日志。每日日志保存与删除立即生效。")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .navigationTitle("记忆")
        .onAppear(perform: reload)
        .alert("文件操作失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("确定") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func fileLabel(_ name: String, content: String, date: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(name)
                Text(ByteCountFormatter.string(fromByteCount: Int64(content.utf8.count), countStyle: .file))
                    .font(.caption).foregroundColor(.secondary)
                Spacer()
                if let date { Text(date, style: .date).font(.caption2).foregroundColor(.secondary) }
            }
            if let line = content.components(separatedBy: .newlines).first(where: { !$0.isEmpty && !$0.hasPrefix("<!--") }) {
                Text(line).lineLimit(1).font(.caption).foregroundColor(.secondary)
            }
        }
    }

    private func reload() {
        files = ((try? FileManager.default.contentsOfDirectory(at: MinisGroupConfigurationStore.memoryDirectory(folderID), includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
            .filter { $0.pathExtension == "md" && $0.lastPathComponent != "GLOBAL.md" && $0.lastPathComponent != "SOUL.md" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}

private struct MinisGroupMemoryFileEditor: View {
    let url: URL
    @State private var text = ""
    @State private var loaded = false
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TextEditor(text: $text).padding()
            .navigationTitle(url.lastPathComponent)
            .onAppear {
                guard !loaded else { return }
                do { text = try String(contentsOf: url, encoding: .utf8); loaded = true }
                catch { errorMessage = error.localizedDescription }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("保存") {
                        do { try text.write(to: url, atomically: true, encoding: .utf8); dismiss() }
                        catch { errorMessage = error.localizedDescription }
                    }.disabled(!loaded)
                }
            }
            .alert("读写失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("确定") { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
    }
}
