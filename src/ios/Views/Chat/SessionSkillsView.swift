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
                            Text("分组专属提示词；留空表示继承全局。")
                            TextEditor(text: $configuration.soul).frame(minHeight: 240)
                        }.navigationTitle("灵魂")
                    } label: { Label("灵魂", systemImage: "sparkles") }
                    NavigationLink {
                        Form {
                            Text("本组独立的长期记忆。日记由记忆工具保存到本组目录，不会混入全局或其他分组。")
                            TextEditor(text: $configuration.memory).frame(minHeight: 240)
                        }.navigationTitle("记忆")
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
