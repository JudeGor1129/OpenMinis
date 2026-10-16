import SwiftUI

/// Stable root Module. Its Interface remains `ContentView()` while navigation
/// behavior lives behind OS-specific Implementations.
struct ContentView: View {
    @ViewBuilder
    var body: some View {
        if #available(iOS 16.0, *) {
            ModernContentView()
        } else {
            LegacyContentView()
        }
    }
}

/// iOS 15 Implementation of the essential conversation flow.
///
/// It deliberately uses destination-based `NavigationLink` rather than trying
/// to imitate `NavigationPath`. Additional behavior is migrated behind this
/// seam only after its iOS 15 build diagnostics pass.
private struct LegacyContentView: View {
    @State private var sessions: [ChatSession] = []
    @State private var draftID = ""
    @State private var showingDraft = false
    @State private var selectedSessions: Set<String> = []
    @State private var selectionMode = false
    @State private var showingSettings = false
    @State private var showingTerminal = false
    @State private var showingRootfs = false
    @State private var showingBrowser = false
    @State private var showingBrowserSettings = false
    @State private var keepScreenAwake = false
    @StateObject private var browserPool = BrowserTabPool()

    var body: some View {
        NavigationView {
            List {
                if sessions.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 38))
                            .foregroundColor(.secondary)
                        Text("No Conversations")
                            .font(.headline)
                        Text("Start a new chat or refresh the list.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                } else {
                    ForEach(sessions) { session in
                        LegacySessionRow(session: session, selectionMode: $selectionMode, selectedSessions: $selectedSessions, onChange: reload)
                    }
                }
            }
            .listStyle(PlainListStyle())
            .navigationTitle(selectionMode ? "Selected: \(selectedSessions.count)" : "Minis")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if selectionMode {
                        Button("Done") { selectionMode = false; selectedSessions.removeAll() }
                    }
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(action: reload) {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh conversations")
                }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showingSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Settings")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button { showingTerminal = true } label: {
                            Label("Shell Terminal", systemImage: "terminal")
                        }
                        Button { showingRootfs = true } label: {
                            Label("Rootfs Management", systemImage: "externaldrive")
                        }
                        Divider()
                        Button { showingBrowser = true } label: {
                            Label("Open Browser", systemImage: "globe")
                        }
                        Button { showingBrowserSettings = true } label: {
                            Label("Browser Settings", systemImage: "globe")
                        }
                        Toggle("Keep Screen Awake", isOn: $keepScreenAwake)
                    } label: {
                        Image(systemName: "terminal")
                    }
                    .accessibilityLabel("Tools")
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: startDraft) {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New conversation")
                }
            }
            .background(
                NavigationLink(
                    destination: AIChatView(sessionId: nil, draftId: draftID),
                    isActive: $showingDraft,
                    label: { EmptyView() }
                )
                .hidden()
            )
            .onAppear(perform: reload)
            .sheet(isPresented: $showingSettings, onDismiss: reload) {
                LegacySettingsSheet()
            }
            .fullScreenCover(isPresented: $showingTerminal) {
                MinisNavigationContainer { ISHTerminalView(showCloseButton: true) }
            }
            .sheet(isPresented: $showingRootfs) {
                MinisNavigationContainer {
                    RootfsManagementView()
                        .toolbar {
                            ToolbarItem(placement: .navigationBarTrailing) {
                                Button("Done") { showingRootfs = false }
                            }
                        }
                }
            }
            .sheet(isPresented: $showingBrowser) { BrowserSheetView(pool: browserPool) }
            .sheet(isPresented: $showingBrowserSettings) {
                MinisNavigationContainer { BrowserManagementView(pool: browserPool) }
            }
            .onChange(of: keepScreenAwake) { enabled in
                UIApplication.shared.isIdleTimerDisabled = enabled
            }
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func reload() {
        Task { @MainActor in
            sessions = await ChatStore.shared.listSessions().filter { !$0.isChild }
        }
    }

    private func startDraft() {
        draftID = "__new__\(UUID().uuidString)"
        showingDraft = true
    }

    private func displayTitle(for session: ChatSession) -> String {
        guard let title = session.title, !title.isEmpty else {
            return "New Conversation"
        }
        return title
    }
}

/// Full settings catalogue for the iOS 15 destination-based navigation Adapter.
private struct LegacySettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        MinisNavigationContainer {
            List {
                providerSection
                Section("Appearance") {
                    NavigationLink(destination: AppearanceSettingsView()) {
                        Label("Appearance", systemImage: "paintbrush.fill")
                    }
                }
                runtimeSection
                storageSection
                Section("Permissions") {
                    NavigationLink(destination: OffloadPermissionSettingsView()) {
                        Label("Permissions", systemImage: "hand.raised.fill")
                    }
                    if BiometricAuth.isAvailable {
                        NavigationLink(destination: FaceIDProtectionSettingsView()) {
                            Label("\(BiometricAuth.biometryDisplayName) Protection", systemImage: BiometricAuth.biometryIconName)
                        }
                    }
                }
                Section("Logs") {
                    NavigationLink(destination: LogManagementView()) {
                        Label("Logs", systemImage: "doc.text")
                    }
                }
                Section("About") {
                    NavigationLink(destination: AboutView()) {
                        Label("About Minis", systemImage: "info.circle")
                    }
                    Link(destination: URL(string: "https://openminis.github.io/privacy-policy.html")!) {
                        Label("Privacy Policy", systemImage: "hand.raised")
                    }
                    Link(destination: URL(string: "mailto:dev@openminis.app?subject=Minis%20Feedback")!) {
                        Label("Feedback (Email)", systemImage: "envelope")
                    }
                    Link(destination: URL(string: "https://github.com/OpenMinis/OpenMinis/issues/new")!) {
                        Label("Report a Bug", systemImage: "ladybug")
                    }
                    Link(destination: URL(string: "https://t.me/+2NzhOJuzRyI1YmM1")!) {
                        Label("Feedback (Telegram)", systemImage: "bubble.left.and.bubble.right")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var providerSection: some View {
        Section {
            NavigationLink(destination: ProviderInstancesView()) {
                Label("Manage Providers", systemImage: "lock.circle.fill")
            }
            NavigationLink(destination: ModelGroupsView()) {
                Label("Model Groups", systemImage: "gearshape.circle.fill")
            }
            NavigationLink(destination: UsageStatsView()) {
                Label("Token Usage", systemImage: "chart.line.uptrend.xyaxis.circle.fill")
            }
        } header: {
            Text("LLM Providers")
        } footer: {
            Text("Configure which models the agent uses, manage API keys & OAuth for each provider, and create model groups for fallback or load balancing.")
        }
    }

    private var runtimeSection: some View {
        Section("Agent Runtime") {
            NavigationLink(destination: ToolsSettingsView()) {
                Label("Agent Tools", systemImage: "wrench.and.screwdriver.fill")
            }
            NavigationLink(destination: HelperSettingsView()) {
                Label("Sub Agents", systemImage: "person.2.fill")
            }
            NavigationLink(destination: SkillsManagementView()) {
                Label("Skills", systemImage: "puzzlepiece.extension")
            }
            NavigationLink(destination: SoulSettingsView()) {
                Label("Soul", systemImage: "sparkles")
            }
            NavigationLink(destination: MemoryManagementView()) {
                Label("Memory", systemImage: "brain.head.profile")
            }
            NavigationLink(destination: MCPIntegrationsView()) {
                Label("MCP Integrations", systemImage: "square.stack.3d.up")
            }
            NavigationLink(destination: EnvironmentVariablesView()) {
                Label("Environment Variables", systemImage: "terminal")
            }
            NavigationLink(destination: EnhancedBackgroundSettingsView()) {
                Label("Background", systemImage: "moon.fill")
            }
        }
    }

    private var storageSection: some View {
        Section("Storage") {
            NavigationLink(destination: StorageManagementView()) {
                Label("Storage", systemImage: "archivebox")
            }
            NavigationLink(destination: SharedFoldersSettingsView()) {
                Label("Shared Folders", systemImage: "folder.fill.badge.person.crop")
            }
            NavigationLink(destination: MountedFoldersSettingsView()) {
                Label("Mount External Folders", systemImage: "externaldrive.badge.plus")
            }
            Label {
                VStack(alignment: .leading) {
                    Text("iCloud Sync")
                    Text("Requires iOS 17 or newer")
                        .font(.caption).foregroundColor(.secondary)
                }
            } icon: {
                Image(systemName: "icloud")
            }
            NavigationLink(destination: BackupAndRestoreView()) {
                Label("Backup & Restore", systemImage: "arrow.triangle.2.circlepath")
            }
        }
    }
}

/// Destination navigation and context actions share the same stored session.
private struct LegacySessionRow: View {
    let session: ChatSession
    @Binding var selectionMode: Bool
    @Binding var selectedSessions: Set<String>
    let onChange: () -> Void
    @State private var editing = false
    @State private var choosingFolder = false
    @State private var confirmingDelete = false
    @State private var exportURL: URL?
    @State private var failure: String?
    @State private var busy = false
    @State private var folders: [ChatFolder] = []

    private var title: String { session.title ?? "New Conversation" }

    var body: some View {
        Group {
            if selectionMode {
                Button {
                    if selectedSessions.contains(session.id) { selectedSessions.remove(session.id) }
                    else { selectedSessions.insert(session.id) }
                } label: {
                    HStack {
                        Image(systemName: selectedSessions.contains(session.id) ? "checkmark.circle.fill" : "circle")
                        rowLabel
                    }
                }
            } else {
                NavigationLink(destination: AIChatView(sessionId: session.id)) { rowLabel }
            }
        }
        .contextMenu { contextActions }
        .sheet(isPresented: $editing) {
            SessionEditSheet(session: session) { title, category in
                Task { @MainActor in
                    await ChatStore.shared.updateSessionTitle(session.id, title: title, category: category)
                    onChange()
                }
            }
        }
        .sheet(isPresented: $choosingFolder) { folderPicker }
        .sheet(item: $exportURL) { MinisShareSheet(url: $0) }
        .alert("Delete Conversation?", isPresented: $confirmingDelete) {
            Button("Delete", role: .destructive) { deleteSession() }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This deletes the conversation and its local files.") }
        .alert("Operation Failed", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK") { failure = nil }
        } message: { Text(failure ?? "") }
    }

    private var rowLabel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if session.isPinned { Image(systemName: "pin.fill") }
                Text(title).font(.headline).lineLimit(1)
                if busy { ProgressView() }
            }
            if let preview = session.lastMessage, !preview.isEmpty {
                Text(preview).font(.caption).foregroundColor(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    @ViewBuilder private var contextActions: some View {
        Button {
            Task { @MainActor in
                _ = await ChatStore.shared.toggleSessionPin(session.id)
                onChange()
            }
        } label: { Label(session.isPinned ? "Unpin" : "Pin", systemImage: "pin") }
        Button { exportSession() } label: { Label("Export", systemImage: "square.and.arrow.up") }
        Button { editing = true } label: { Label("Edit Title & Category", systemImage: "square.and.pencil") }
        Button { regenerateTitle() } label: { Label("Regenerate Title", systemImage: "arrow.triangle.2.circlepath") }
            .disabled(busy)
        Button { duplicateSession() } label: { Label("Duplicate Session", systemImage: "plus.square.on.square") }
            .disabled(busy)
        Button { choosingFolder = true } label: { Label("Move to Group", systemImage: "folder") }
        Button { selectionMode = true; selectedSessions = [session.id] } label: { Label("Select", systemImage: "checkmark.circle") }
        Button { reportContent() } label: { Label("Report Content", systemImage: "exclamationmark.bubble") }
        Button(role: .destructive) { confirmingDelete = true } label: { Label("Delete", systemImage: "trash") }
    }

    private var folderPicker: some View {
        MinisNavigationContainer {
            List {
                Button("Ungrouped") { moveToFolder(nil) }
                ForEach(folders) { folder in
                    Button(folder.name) { moveToFolder(folder.id) }
                }
            }
            .navigationTitle("Move to Group")
            .task { folders = await ChatStore.shared.listFolders() }
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { choosingFolder = false }
                }
            }
        }
    }

    private func moveToFolder(_ id: String?) {
        Task { @MainActor in
            await ChatStore.shared.setFolder(id, forSessions: [session.id])
            choosingFolder = false
            onChange()
        }
    }

    private func regenerateTitle() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                try await AIChatViewModel.regenerateSessionTitle(sessionId: session.id)
                onChange()
            } catch { failure = error.localizedDescription }
        }
    }

    private func duplicateSession() {
        busy = true
        Task { @MainActor in
            defer { busy = false }
            if await SessionForkManager.shared.duplicateSession(sessionId: session.id) != nil {
                onChange()
            } else { failure = "Unable to duplicate this conversation." }
        }
    }

    private func exportSession() {
        Task { @MainActor in
            do {
                let messages = await ChatStore.shared.loadMessages(sessionId: session.id)
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("Conversation-\(UUID().uuidString).json")
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                encoder.dateEncodingStrategy = .iso8601
                try encoder.encode(messages).write(to: url, options: .atomic)
                exportURL = url
            } catch { failure = error.localizedDescription }
        }
    }

    private func reportContent() {
        var url = URLComponents()
        url.scheme = "mailto"
        url.path = "dev@openminis.app"
        url.queryItems = [URLQueryItem(name: "subject", value: "Content Report: \(title.prefix(60))"),
                          URLQueryItem(name: "body", value: "Session: \(session.id)\n\nPlease describe the issue:\n")]
        if let target = url.url { UIApplication.shared.open(target) }
    }

    private func deleteSession() {
        Task { @MainActor in
            let ids = await ChatStore.shared.sessionIdsWithDescendants([session.id])
            for id in ids {
                AgentJobRegistry.shared.cancelAll(parent: id, reason: "sessionDeleted")
                AgentJobRegistry.shared.cancelAll(session: id, reason: "sessionDeleted")
                ViewModelCache.shared.remove(sessionId: id)
                BrowserUseOffloadBridge.releasePool(forSession: id)
            }
            await ChatStore.shared.deleteSession(session.id)
            selectedSessions.remove(session.id)
            onChange()
        }
    }
}
