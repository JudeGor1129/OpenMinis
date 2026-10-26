import SwiftUI
import Combine

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

@MainActor
private final class LegacySessionActivitySnapshot: ObservableObject {
    @Published private(set) var active: Set<String> = []
    @Published private(set) var suspended: Set<String> = []

    private var cancellables: Set<AnyCancellable> = []
    private let activity = SessionActivityTracker.shared
    private let concurrency = SessionConcurrencyManager.shared

    init() {
        Publishers.CombineLatest(
            activity.$activeSessions,
            concurrency.$suspendedSessions
        )
        .map { value in (value.0, Set(value.1)) }
        .removeDuplicates { lhs, rhs in lhs.0 == rhs.0 && lhs.1 == rhs.1 }
        .receive(on: DispatchQueue.main)
        .sink { [weak self] value in
            self?.active = value.0
            self?.suspended = value.1
        }
        .store(in: &cancellables)
    }

    func isActive(_ id: String) -> Bool { active.contains(id) }
    func isSuspended(_ id: String) -> Bool { suspended.contains(id) }
}

/// iOS 15 Implementation of the essential conversation flow.
///
/// It deliberately uses destination-based `NavigationLink` rather than trying
/// to imitate `NavigationPath`. Additional behavior is migrated behind this
/// seam only after its iOS 15 build diagnostics pass.
private struct LegacyContentView: View {
    @State private var sessions: [ChatSession] = []
    @State private var folders: [ChatFolder] = []
    @StateObject private var activitySnapshot = LegacySessionActivitySnapshot()
    @State private var groupSessions: [String: [ChatSession]] = [:]
    @State private var expandedGroups: Set<String> = []
    @State private var groupsExpanded = false
    @State private var draftGroupId: String? = nil
    @State private var creatingGroup = false
    @State private var managingFolder: ChatFolder? = nil
    /// Set when a session row inside the group-management sheet was tapped.
    /// The sheet dismisses first, then the HOME navigation stack pushes the
    /// chat, so it opens full screen instead of inside the sheet's card.
    @State private var pendingOpenSessionId: String? = nil
    /// Session pushed from inside the group sheet. Only meaningful together
    /// with `showingSession`; kept separate from `draftID` so the draft link
    /// and the session link never fight over one isActive flag.
    @State private var openedSessionID = ""
    @State private var showingSession = false
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
    @ObservedObject private var shareCoordinator = ShareCoordinator.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationView {
            List {
                Section {
                    Button {
                        withAnimation(MinisMotion.transition) { groupsExpanded.toggle() }
                        if groupsExpanded { reloadFolders() }
                    } label: {
                        Label("会话分组", systemImage: groupsExpanded ? "folder.fill" : "folder")
                    }
                    if groupsExpanded {
                        // Every interactive element must be its OWN List row.
                        // A single row holding a VStack of buttons + links lets
                        // SwiftUI hand every tap to the row's button, which is
                        // exactly why "开始新会话" and the member rows inside a
                        // group stopped opening.
                        ForEach(folders) { folder in
                            DisclosuredGroupHeader(
                                folder: folder,
                                memberCount: members(of: folder.id).count,
                                expanded: expandedGroups.contains(folder.id),
                                onToggle: { toggleGroup(folder.id) },
                                onManage: { managingFolder = folder }
                            )
                            if expandedGroups.contains(folder.id) {
                                Button { startDraft(in: folder.id) } label: {
                                    Label("开始新会话", systemImage: "plus.bubble")
                                }
                                if members(of: folder.id).isEmpty {
                                    Text("组内暂无会话")
                                        .font(.footnote)
                                        .foregroundColor(.secondary)
                                }
                                ForEach(members(of: folder.id)) { session in
                                    // Deliberately read-only selection state:
                                    // group rows always push into the chat. A
                                    // live selectionMode binding turned them
                                    // into checkboxes whenever the home list
                                    // was in multi-select, so a tap selected
                                    // instead of opening.
                                    LegacySessionRow(
                                        session: session,
                                        selectionMode: .constant(false),
                                        selectedSessions: .constant([]),
                                        onChange: reload,
                                        isActiveOverride: sessionIsActive(session.id),
                                        isSuspendedOverride: sessionIsSuspended(session.id)
                                    )
                                }
                            }
                        }
                        if folders.isEmpty {
                            Button { creatingGroup = true } label: {
                                Label("新建分组", systemImage: "folder.badge.plus")
                            }
                        }
                    }
                }
                if ungroupedSessions.isEmpty && !sessions.isEmpty {
                    Text("所有会话都已归入分组；展开分组即可查看。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                } else if sessions.isEmpty {
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
                    ForEach(ungroupedSessions) { session in
                        LegacySessionRow(
                            session: session,
                            selectionMode: $selectionMode,
                            selectedSessions: $selectedSessions,
                            onChange: reload,
                            isActiveOverride: sessionIsActive(session.id),
                            isSuspendedOverride: sessionIsSuspended(session.id)
                        )
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
                    Button { startDraft() } label: {
                        Image(systemName: "square.and.pencil")
                    }
                    .accessibilityLabel("New conversation")
                }
            }
            .background(
                Group {
                    NavigationLink(
                        destination: AIChatView(sessionId: nil, draftId: draftID, initialGroupId: draftGroupId),
                        isActive: $showingDraft,
                        label: { EmptyView() }
                    )
                    // Second, independent link for "opened from the group
                    // sheet". Reusing $showingDraft would tear down a draft
                    // that is still in progress.
                    NavigationLink(
                        destination: openedSessionDestination,
                        isActive: $showingSession,
                        label: { EmptyView() }
                    )
                }
                .hidden()
            )
            .onAppear {
                reload()
                shareCoordinator.checkForPendingShare()
                routePendingShare()
            }
            .onChange(of: shareCoordinator.hasPendingShare) { pending in
                if pending { routePendingShare() }
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active { shareCoordinator.checkForPendingShare() }
            }
            .sheet(isPresented: $showingSettings, onDismiss: reload) {
                LegacySettingsSheet()
            }
            .sheet(item: $managingFolder, onDismiss: {
                reloadFolders()
                // Dismiss-then-push: the sheet's own stack would render the
                // chat card-sized on iOS 15.
                if let sid = pendingOpenSessionId {
                    pendingOpenSessionId = nil
                    DispatchQueue.main.async {
                        // Sheet dismissal owns the visible transition. Commit
                        // the home-stack push atomically after it finishes so
                        // the two UIKit transitions never overlap.
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) {
                            openedSessionID = sid
                            showingSession = true
                        }
                    }
                }
            }) { folder in
                MinisNavigationContainer {
                    LegacyGroupDetailView(
                        folder: folder,
                        onOpenSession: { sid in
                            pendingOpenSessionId = sid
                            managingFolder = nil
                        }
                    )
                }
            }
            .sheet(isPresented: $creatingGroup, onDismiss: reloadFolders) {
                LegacyGroupNameSheet(title: "新建分组", initialName: "") { name in
                    Task { @MainActor in
                        _ = await ChatStore.shared.createFolder(name: name)
                        creatingGroup = false
                        reloadFolders()
                    }
                }
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

    @MainActor
    private func routePendingShare() {
        guard shareCoordinator.hasPendingShare else { return }
        guard let pending = SharedContainerStore.loadPendingShare() else {
            shareCoordinator.hasPendingShare = false
            // Multiple scene/URL callbacks may observe the same notification.
            // The first delivery already consumed the on-disk record; absence
            // here is not evidence that the attachment failed to import.
            return
        }
        // The foreground chat owns delivery when it is visible. Otherwise use
        // an explicit draft; never let a hidden mounted chat steal this share.
        let target = AIChatViewModel.activeSessionId ?? (showingDraft ? draftID : "__new__\(UUID().uuidString)")
        shareCoordinator.storeBuffer(pending, targetSessionId: target)
        SharedContainerStore.clearPendingShare()
        shareCoordinator.hasPendingShare = false
        if AIChatViewModel.activeSessionId == nil {
            showingSettings = false
            showingTerminal = false
            showingRootfs = false
            showingBrowser = false
            showingBrowserSettings = false
            draftID = target
            showingDraft = true
        }
    }

    private var ungroupedSessions: [ChatSession] {
        sessions.filter { $0.folderId == nil }
    }

    private func sessionIsActive(_ id: String) -> Bool {
        activitySnapshot.isActive(id)
    }

    private func sessionIsSuspended(_ id: String) -> Bool {
        activitySnapshot.isSuspended(id)
    }

    private func toggleGroup(_ id: String) {
        withAnimation(MinisMotion.transition) {
            if expandedGroups.contains(id) { expandedGroups.remove(id) }
            else { expandedGroups.insert(id) }
        }
    }

    private func reload() {
        Task { @MainActor in
            // Load the folder list during the normal home refresh. Previously
            // the first tap on "会话分组" started listFolders() here, so the
            // disclosure opened empty and then filled in after the actor/DB
            // round-trip — the visible delay on iOS 15.
            async let loadedSessions = ChatStore.shared.listSessions()
            async let loadedFolders = ChatStore.shared.listFolders()
            let (allSessions, loadedFoldersValue) = await (loadedSessions, loadedFolders)
            sessions = allSessions.filter { !$0.isChild }
            folders = loadedFoldersValue
            reloadGroupMembers()
        }
    }

    private func reloadFolders() {
        Task { @MainActor in
            folders = await ChatStore.shared.listFolders()
            reloadGroupMembers()
        }
    }

    @MainActor
    private func reloadGroupMembers() {
        // We already have folder_id on ChatSession. Derive the visible members
        // locally instead of issuing one sessionIdsInFolder() query per folder
        // every time the disclosure is tapped.
        var members: [String: [ChatSession]] = [:]
        for session in sessions where !session.isChild {
            guard let folderID = session.folderId else { continue }
            members[folderID, default: []].append(session)
        }
        groupSessions = members
    }

    /// Destination for the sheet-dismiss-then-push path. Guarded so an empty
    /// id (initial state) never constructs a chat view for nothing.
    @ViewBuilder
    private var openedSessionDestination: some View {
        if openedSessionID.isEmpty {
            EmptyView()
        } else {
            LegacySessionDestination(sessionID: openedSessionID)
        }
    }

    private func members(of folderId: String) -> [ChatSession] {
        groupSessions[folderId] ?? []
    }

    private func startDraft(in folderId: String? = nil) {
        // NavigationView owns the push transition for user-initiated links;
        // changing the activation flag itself must stay atomic.
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            draftGroupId = folderId
            draftID = "__new__\(UUID().uuidString)"
            showingDraft = true
        }
    }

    private func displayTitle(for session: ChatSession) -> String {
        guard let title = session.title, !title.isEmpty else {
            return "New Conversation"
        }
        return title
    }
}

/// Group header row: disclosure toggle + management entry. Deliberately a
/// small View placed as its OWN List row — see the group block in body.
private struct DisclosuredGroupHeader: View {
    let folder: ChatFolder
    let memberCount: Int
    let expanded: Bool
    let onToggle: () -> Void
    let onManage: () -> Void

    var body: some View {
        HStack {
            Button(action: onToggle) {
                HStack {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Image(systemName: folder.icon ?? "folder")
                    Text(folder.name)
                    Spacer()
                    Text("\(memberCount)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(MinisPressFeedbackStyle())
            // Sibling of the toggle, not inside its label: a Button nested in
            // another Button's label swallows the inner tap.
            Button(action: onManage) {
                Image(systemName: "ellipsis.circle")
            }
            .buttonStyle(MinisPressFeedbackStyle())
        }
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
    /// When set, tapping the row invokes this instead of pushing a
    /// NavigationLink. Used from inside the group-management sheet: pushing
    /// into a sheet's own navigation stack renders the chat as a card-sized
    /// screen on iOS 15 (not full screen) and the sheet's presentation
    /// gestures then interfere with long-press text selection. The sheet
    /// dismisses and the home NavigationView performs the push instead.
    var onOpen: ((String) -> Void)? = nil
    var isActiveOverride: Bool? = nil
    var isSuspendedOverride: Bool? = nil
    @State private var editing = false
    @State private var choosingFolder = false
    @State private var confirmingDelete = false
    @State private var exportURL: URL?
    @State private var failure: String?
    @State private var busy = false
    @State private var folders: [ChatFolder] = []

    private var title: String { session.title ?? "New Conversation" }
    private var isActive: Bool { isActiveOverride ?? false }
    private var isSuspended: Bool { isSuspendedOverride ?? false }
    private var categoryIcon: (systemName: String, color: Color) {
        sessionCategoryIcon(for: session.category)
    }

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
                .buttonStyle(MinisPressFeedbackStyle())
            } else if let onOpen {
                // Sheet-hosted row: hand the push back to the home stack.
                Button { onOpen(session.id) } label: { rowLabel }
                    .buttonStyle(MinisPressFeedbackStyle())
            } else {
                NavigationLink {
                    LegacySessionDestination(sessionID: session.id)
                } label: { rowLabel }
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
        HStack(spacing: 10) {
            let icon = categoryIcon
            Image(systemName: icon.systemName)
                .font(.system(size: 17))
                .foregroundColor(icon.color)
                .frame(width: 36, height: 36)
                .background(icon.color.opacity(0.12))
                .clipShape(Circle())
                .overlay {
                    if isSuspended {
                        LegacySuspendedRing(color: .yellow)
                            .frame(width: 36, height: 36)
                    } else if isActive {
                        LegacySpinningRing(color: icon.color)
                            .frame(width: 36, height: 36)
                    }
                }
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(title).font(.headline).lineLimit(1)
                    if session.isPinned { Image(systemName: "pin.fill").font(.caption2) }
                    if busy { ProgressView().scaleEffect(0.75) }
                }
                if let preview = session.lastMessage, !preview.isEmpty {
                    Text(preview).font(.caption).foregroundColor(.secondary).lineLimit(2)
                }
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

private struct LegacySuspendedRing: View {
    let color: Color

    var body: some View {
        Circle().stroke(color, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
    }
}

private struct LegacySpinningRing: View {
    let color: Color

    var body: some View {
        Circle()
            .stroke(color.opacity(0.85), lineWidth: 2)
            .overlay {
                Circle()
                    .fill(color.opacity(0.18))
                    .padding(3)
            }
            .accessibilityLabel(Text("Running"))
    }
}

// iOS 15 destination-based group management: never depends on ModernContentView.
private struct LegacyGroupManagerView: View {
    @State private var folders: [ChatFolder] = []
    @State private var creating = false

    var body: some View {
        List {
            Button { creating = true } label: { Label("新建分组", systemImage: "folder.badge.plus") }
            if folders.isEmpty { Text("暂无分组，点上方新建。长按会话可选择移动到分组。") }
            ForEach(folders) { folder in
                NavigationLink(destination: LegacyGroupDetailView(folder: folder)) {
                    Label(folder.name, systemImage: folder.icon ?? "folder")
                }
            }
        }
        .navigationTitle("会话分组")
        .onAppear(perform: reload)
        .sheet(isPresented: $creating, onDismiss: reload) {
            LegacyGroupNameSheet(title: "新建分组", initialName: "") { name in
                Task { @MainActor in
                    _ = await ChatStore.shared.createFolder(name: name)
                    creating = false
                    reload()
                }
            }
        }
    }

    private func reload() {
        Task { @MainActor in folders = await ChatStore.shared.listFolders() }
    }
}

private struct LegacyGroupNameSheet: View {
    let title: String
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String

    init(title: String, initialName: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.onSave = onSave
        _name = State(initialValue: initialName)
    }

    var body: some View {
        MinisNavigationContainer {
            Form { TextField("分组名称", text: $name) }
                .navigationTitle(title)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("保存") { onSave(name.trimmingCharacters(in: .whitespacesAndNewlines)) }
                            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
        }
    }
}

private struct LegacyGroupDetailView: View {
    @State var folder: ChatFolder
    /// Injected by the home view so a tapped member opens on the HOME stack
    /// (full screen). Pushing inside this sheet renders the chat card-sized on
    /// iOS 15 and the sheet's gestures block text selection.
    var onOpenSession: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [ChatSession] = []
    @State private var selected: Set<String> = []
    @State private var selectionMode = false
    @State private var configuring = false
    @State private var renaming = false
    @State private var moving = false
    @State private var dissolving = false

    var body: some View {
        List {
            Section {
                Button { configuring = true } label: { Label("分组功能设置 · 技能 / 灵魂 / 记忆", systemImage: "slider.horizontal.3") }
                Button { moving = true } label: { Label("添加会话到分组", systemImage: "plus.bubble") }
                Button { renaming = true } label: { Label("重命名", systemImage: "pencil") }
                Button { dissolving = true } label: { Label("解散分组（保留会话）", systemImage: "folder.badge.minus") }
            }
            Section("组内会话") {
                if sessions.isEmpty { Text("暂无会话；可以添加已有会话。") }
                ForEach(sessions) { session in
                    // selectionMode stays read-only here: the sheet's list is
                    // not a multi-select surface, and a live binding would
                    // turn every tap into a checkbox toggle instead of opening
                    // the chat. `onOpen` hands the push to the home stack.
                    LegacySessionRow(
                        session: session,
                        selectionMode: .constant(false),
                        selectedSessions: .constant([]),
                        onChange: reload,
                        onOpen: onOpenSession
                    )
                }
            }
        }
        .navigationTitle(folder.name)
        .onAppear(perform: reload)
        .sheet(isPresented: $configuring, onDismiss: reload) { MinisGroupConfigurationView(folder: folder) }
        .sheet(isPresented: $moving, onDismiss: reload) { LegacyGroupSessionPicker(folderID: folder.id) }
        .sheet(isPresented: $renaming) {
            LegacyGroupNameSheet(title: "重命名分组", initialName: folder.name) { name in
                Task { @MainActor in
                    await ChatStore.shared.renameFolder(folder.id, name: name)
                    folder.name = name
                    renaming = false
                }
            }
        }
        .alert("解散分组？", isPresented: $dissolving) {
            Button("解散", role: .destructive) {
                Task { @MainActor in
                    _ = await ChatStore.shared.dissolveFolder(folder.id)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        } message: { Text("会话和文件不会删除，会话将回到未分组列表。") }
    }

    private func reload() {
        Task { @MainActor in
            let ids = Set(await ChatStore.shared.sessionIdsInFolder(folder.id))
            sessions = await ChatStore.shared.listSessions().filter { ids.contains($0.id) && !$0.isChild }
        }
    }
}

private struct LegacyGroupSessionPicker: View {
    let folderID: String
    @Environment(\.dismiss) private var dismiss
    @State private var sessions: [ChatSession] = []
    @State private var selected: Set<String> = []
    @State private var saving = false

    var body: some View {
        MinisNavigationContainer {
            List(sessions) { session in
                Button {
                    if selected.contains(session.id) { selected.remove(session.id) }
                    else { selected.insert(session.id) }
                } label: {
                    HStack {
                        Image(systemName: selected.contains(session.id) ? "checkmark.circle.fill" : "circle")
                        Text(session.title ?? "New Conversation")
                    }
                }
            }
            .navigationTitle("添加会话到分组")
            .task { sessions = await ChatStore.shared.listSessions().filter { !$0.isChild } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("移动所选 (\(selected.count))") {
                        saving = true
                        Task { @MainActor in
                            await ChatStore.shared.setFolder(folderID, forSessions: Array(selected))
                            dismiss()
                        }
                    }.disabled(selected.isEmpty || saving)
                }
            }
        }
    }
}

// Keep AIChatView's VM acquisition out of eager NavigationLink row creation.
private struct LegacySessionDestination: View {
    let sessionID: String
    var body: some View { AIChatView(sessionId: sessionID) }
}
