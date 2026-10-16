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
    @State private var showingSettings = false

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
                        NavigationLink(destination: AIChatView(sessionId: session.id)) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(displayTitle(for: session))
                                    .font(.headline)
                                    .lineLimit(1)
                                if let preview = session.lastMessage, !preview.isEmpty {
                                    Text(preview)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
            }
            .listStyle(PlainListStyle())
            .navigationTitle("Minis")
            .toolbar {
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
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }

    private func reload() {
        sessions = ChatStore.shared.listSessions()
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
