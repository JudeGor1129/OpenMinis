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
