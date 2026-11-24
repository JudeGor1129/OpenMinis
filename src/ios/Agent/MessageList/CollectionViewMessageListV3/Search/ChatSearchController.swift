import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class ChatSearchController: ObservableObject {
    @Published private(set) var isActive = false
    @Published var query = "" {
        didSet { if query != oldValue && isActive { schedule(landOnNewest: true, delay: 0.25) } }
    }
    @Published private(set) var matchCount = 0
    @Published private(set) var isTruncated = false
    @Published private(set) var currentIndex: Int?
    @Published private(set) var isSearching = false
    @Published private(set) var focusRequest = 0
    let highlights = ChatSearchHighlightCenter()
    private(set) var matches: [ChatSearchMatch] = []
    var onNavigate: ((ChatSearchMatch) -> Void)?
    private weak var viewModel: AIChatViewModel?
    private var subscriptions: [AnyCancellable] = []
    private var messageSubscriptions: [AnyCancellable] = []
    private var blockSubscriptions: [AnyCancellable] = []
    private var observedBlockIds: [UUID] = []
    private var work: DispatchWorkItem?
    private var task: Task<Void, Never>?
    private var refresh: DispatchWorkItem?
    private var generation = 0
    private var cache: [UUID: ChatSearchTextCacheEntry] = [:]
    private var dirty = false

    var currentMatch: ChatSearchMatch? {
        currentIndex.flatMap { matches.indices.contains($0) ? matches[$0] : nil }
    }
    var counterText: String {
        ChatSearchNavigation.counterText(index: currentIndex, count: matchCount, truncated: isTruncated)
    }

    /// AIChatView owns this controller; no published/search property is added to its VM.
    func bind(to vm: AIChatViewModel) {
        guard viewModel !== vm else { return }
        cancel()
        subscriptions.removeAll(); messageSubscriptions.removeAll(); blockSubscriptions.removeAll()
        observedBlockIds = []
        viewModel = vm; cache.removeAll(); matches.removeAll()
        currentIndex = nil; matchCount = 0; highlights.clear()
        subscriptions = [vm.$messages.sink { [weak self] messages in
            // Published emits before assignment: snapshot the new graph on the next runloop.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.observe(messages)
                self.contentChanged()
            }
        }]
        observe(vm.messages)
        if isActive { schedule(landOnNewest: true, delay: 0) }
    }

    func activate(prefill: String? = nil) {
        let wasActive = isActive
        isActive = true; focusRequest += 1
        if !wasActive { observe(viewModel?.messages ?? []) }
        if let prefill { query = ChatSearchMatcher.normalizedQuery(prefill) }
        schedule(landOnNewest: true, delay: 0)
    }
    func deactivate() {
        isActive = false; cancel(); refresh?.cancel(); refresh = nil
        query = ""; matches = []; currentIndex = nil; matchCount = 0; isTruncated = false
        highlights.clear(); cache.removeAll()
        messageSubscriptions.removeAll(); blockSubscriptions.removeAll(); observedBlockIds = []
    }
    func next() { step(true) }
    func previous() { step(false) }
    private func step(_ forward: Bool) {
        guard !isSearching,
              let moved = ChatSearchNavigation.step(from: currentIndex, count: matches.count, forward: forward) else { return }
        let old = currentMatch
        currentIndex = moved.index; highlights.setCurrent(from: old, to: currentMatch)
        if let hit = currentMatch { onNavigate?(hit) }
        UIAccessibility.post(notification: .announcement, argument: counterText)
    }

    private func observe(_ messages: [ChatMessage]) {
        guard isActive else { return }
        messageSubscriptions = messages.map { message in
            message.objectWillChange.sink { [weak self] _ in
                self?.contentChanged()
                DispatchQueue.main.async { [weak self] in self?.observeBlocks() }
            }
        }
        observeBlocks()
    }
    private func observeBlocks() {
        // Blocks publish independently of the VM and messages. Subscribe explicitly:
        // streaming append, same-length replacement, cached parse completion and reuse.
        guard isActive else { return }
        let blocks = (viewModel?.messages ?? []).flatMap(\.blocks)
        let ids = blocks.map(\.id)
        guard ids != observedBlockIds else { return }
        observedBlockIds = ids
        blockSubscriptions = blocks.map { block in
            block.objectWillChange.sink { [weak self] _ in self?.contentChanged() }
        }
    }
    private func contentChanged() {
        guard isActive, !ChatSearchMatcher.normalizedQuery(query).isEmpty else { return }
        dirty = true
        guard refresh == nil else { return }
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refresh = nil
            if self.isSearching || self.work != nil { return } // completion drains dirty
            if self.dirty { self.schedule(landOnNewest: false, delay: 0) }
        }
        refresh = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }
    private func cancel() {
        generation += 1; work?.cancel(); work = nil; task?.cancel(); task = nil; isSearching = false
    }
    private func schedule(landOnNewest: Bool, delay: TimeInterval) {
        cancel()
        let gen = generation
        isSearching = !ChatSearchMatcher.normalizedQuery(query).isEmpty
        if landOnNewest {
            // Never let navigation/highlights from the previous query survive an edit.
            highlights.clear(); matches = []; currentIndex = nil; matchCount = 0
        }
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == gen, self.isActive else { return }
            self.work = nil
            self.search(gen: gen, landOnNewest: landOnNewest)
        }
        work = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }
    private func search(gen: Int, landOnNewest: Bool) {
        let query = ChatSearchMatcher.normalizedQuery(self.query)
        guard !query.isEmpty, let vm = viewModel else {
            matches = []; matchCount = 0; currentIndex = nil; isSearching = false
            isTruncated = false; highlights.clear(); dirty = false; return
        }
        dirty = false
        let pending = ChatSearchUnitBuilder.snapshot(messages: vm.messages)
        let oldCache = cache
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let resolved = ChatSearchUnitBuilder.resolve(pending, cache: oldCache,
                    isCancelled: { Task.isCancelled }),
                  let result = ChatSearchEngine.search(units: resolved.units, query: query,
                    isCancelled: { Task.isCancelled }) else { return }
            await MainActor.run { [weak self] in
                guard let self, self.generation == gen, self.isActive else { return }
                let old = self.currentMatch, oldIndex = self.currentIndex
                self.cache = resolved.cache; self.matches = result.matches
                self.matchCount = result.matches.count; self.isTruncated = result.truncated
                self.currentIndex = landOnNewest
                    ? ChatSearchNavigation.initialIndex(count: result.matches.count)
                    : ChatSearchNavigation.relocate(previous: old, previousIndex: oldIndex, in: result.matches)
                self.isSearching = false; self.task = nil
                self.highlights.apply(result: result, query: query, current: self.currentMatch)
                if landOnNewest, let hit = self.currentMatch { self.onNavigate?(hit) }
                if self.dirty { self.schedule(landOnNewest: false, delay: 0.3) }
            }
        }
    }
}

/// iOS15-compatible toolbar: use in AIChatView overlay/safeAreaInset. No newer
/// presentationDetents, NavigationStack or ShareLink requirement.
struct ChatSearchControls: View {
    @ObservedObject var search: ChatSearchController
    @FocusState private var focused: Bool
    var body: some View {
        HStack(spacing: 8) {
            TextField("搜索聊天", text: $search.query)
                .textFieldStyle(.roundedBorder).focused($focused)
                .submitLabel(.search).onSubmit { search.next() }
                .accessibilityLabel("搜索聊天")
            if search.isSearching { ProgressView() } else {
                Text(search.counterText).font(.caption).monospacedDigit()
            }
            Button(action: search.previous) { Image(systemName: "chevron.up") }
                .frame(minWidth: 44, minHeight: 44).accessibilityLabel("上一命中")
                .disabled(search.matchCount == 0 || search.isSearching)
            Button(action: search.next) { Image(systemName: "chevron.down") }
                .frame(minWidth: 44, minHeight: 44).accessibilityLabel("下一命中")
                .disabled(search.matchCount == 0 || search.isSearching)
            Button("完成") { focused = false; search.deactivate() }
        }
        .padding(.horizontal, 12).background(Color(UIColor.secondarySystemBackground))
        .onAppear { focused = true }
        .onChange(of: search.focusRequest) { _ in focused = true }
    }
}
