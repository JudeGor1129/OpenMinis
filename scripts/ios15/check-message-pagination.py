#!/usr/bin/env python3
"""Source contracts for UI-only transcript windowing on the iOS 15 path."""
from pathlib import Path
root = Path(__file__).resolve().parents[2]
store = (root / "src/ios/Agent/Chat/ChatStore.swift").read_text()
persist = (root / "src/ios/Agent/Chat/AIChatViewModel+Persistence.swift").read_text()
view = (root / "src/ios/Agent/MessageList/CollectionViewMessageListV3.swift").read_text()
chat = (root / "src/ios/Views/Chat/AIChatView.swift").read_text()

# Model request context remains full and is never assigned from a UI page.
assert "rawMessages = await ChatStore.shared.loadMessages(sessionId: sessionId)" in persist
assert "loadedHistory.append(agentMsg)" in persist
assert "agentHistory = loadedHistory" in persist
assert "agentHistory = display" not in persist and "agentHistory = page" not in persist
assert "messages = loadedUIMessages" in persist  # full source retained in VM

# All rendered items and layout lookups use the bounded display window.
assert "let displaySource = boundedDisplayMessages(from: rawMessages)" in view
assert "let messages = displaySource.contains(where: { $0.isInternalBridge })" in view
assert "let displaySource = boundedDisplayMessages(from: allMessages)" not in view
assert "private let displayWindowSize = 64" in view
assert "return Array(all[start...])" in view
assert "messageIndex.removeAll(keepingCapacity: true)" in view
assert "for (i, msg) in messages.enumerated()" in view
assert "snapshot.appendItems(newItems, toSection: .main)" in view

# Paging is demand-driven, turn-aligned, and never mutates the list under touch/decel.
assert "private func requestDisplayWindowExpansionIfNeeded()" in view
assert "!cv.isTracking, !cv.isDragging, !cv.isDecelerating" in view
assert "all[$0].isUserTurnAnchor" in view
assert "displayWindowStep = 32" in view
assert 'caller: "display-page-older"' in view
assert "visibleDisplayAnchor()" in view and "restoreDisplayAnchor(browseAnchor, in: cv)" in view
assert "attrs.frame.minY - anchor.screenY" in view
assert "scrollMode == .userBrowsing" in view
assert "vm?.setStreamingUIUpdatesSuspended(true)" in view
scrolling = view.split('func scrollViewDidScroll(_ scrollView:', 1)[1].split('func scrollViewDidScrollToTop', 1)[0]
assert 'scheduleDisplayWindowExpansion()' not in scrolling  # never apply a structural diff per finger frame
assert 'private func scheduleDisplayWindowExpansion()' in view
assert 'private func requestDisplayWindowExpansionIfNeeded()' in view

# iOS15 uses a different inverted LazyVStack route and must also stay windowed.
assert "ForEach(rows.reversed())" in chat
assert "private let displayPageSize = 64" in chat
assert "private func loadOlderDisplayPageIfNeeded(isAtOldestEdge: Bool)" in chat
assert "onOlderEdge: { atOlderEdge in loadOlderDisplayPageIfNeeded(isAtOldestEdge: atOlderEdge) }" in chat
assert "resetDisplayWindowToLatest()" in chat
assert "onInteractionChanged: { active in" not in chat
assert "vm.setStreamingUIUpdatesSuspended(active)" not in chat
assert "browseEndIndex = vm.messages.count - 1" in chat
assert "if isAtOldestEdge, !olderEdgePending" in chat
assert "scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom" in chat
assert "if legacyFollowing" in chat and "Array(vm.messages[lower..<count])" in chat
assert "previousSnapshotIds.count > displayWindowMaximum" not in view
assert "private func loadOlderDisplayPageIfNeeded(isAtOldestEdge: Bool)" in chat

# No OFFSET pagination in production UI. Existing export API remains unchanged.
assert "LIMIT ? OFFSET ?" in store
assert store.count("loadMessagePage(sessionId:") == 1
assert "tailLimit: 48" in persist
print("PASS: iOS15 and UIKit message lists start with paged display windows;")
print("      complete agentHistory is preserved and older pages are turn-aligned.")
print("NOTE: source contract is not Swift type-check or UIKit runtime evidence.")
