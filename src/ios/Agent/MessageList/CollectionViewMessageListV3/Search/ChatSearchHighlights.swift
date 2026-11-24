//
//  ChatSearchHighlights.swift
//  Minis - V3 chat message list (Agent/MessageList/CollectionViewMessageListV3)
//
//  [T-in-chat-search] How search highlights reach the cells without touching
//  the list.
//
//  Each piece of visible text observes one small token (per unit key), not
//  the search as a whole. Moving to the next result changes two tokens - the
//  unit losing the current mark and the unit gaining it - so exactly those
//  two views redraw, and nothing reconfigures a cell, clears a height cache
//  or re-measures: a highlight never changes a text's size.
//
//    ChatSearchController --apply/setCurrent--> ChatSearchHighlightCenter
//        --token(for: key).state--> SearchHighlightText (SwiftUI Text rows)
//                                 \-> SelectableMarkdownTextView (TextKit,
//                                     draws in MinisLayoutManager)
//
//  The center reaches a cell through the `chatSearchHighlights` environment
//  value, injected by the list's cell configuration (a UIHostingConfiguration
//  does not inherit the chat view's environment). Anything rendered outside
//  the list (share export, previews) has no center and draws plain text.
//
//  File map and split rules: CollectionViewMessageListV3.swift (this folder).
//

import SwiftUI
import UIKit
import Combine

/// What one unit highlights: the first `count` occurrences of `query`, with
/// occurrence `current` (if any) drawn as the current result.
struct ChatSearchUnitHighlight: Equatable {
    let query: String
    let count: Int
    let current: Int?

    /// Occurrences to draw: the first `ChatSearchEngine.perUnitLimit`, and
    /// the current one is always among them (it is < count <= limit).
    var drawLimit: Int { min(count, ChatSearchEngine.perUnitLimit) }
}

/// One unit's highlight, observed by the view that draws that unit.
@MainActor
final class ChatSearchHighlightToken: ObservableObject {
    @Published fileprivate(set) var state: ChatSearchUnitHighlight?
    init(state: ChatSearchUnitHighlight?) { self.state = state }
}

@MainActor
final class ChatSearchHighlightCenter {
    /// Opens the chat's search bar with an optional query. Set by the chat
    /// page while it shows this conversation (nil in lists with no search
    /// bar, such as a sub agent's transcript), so the long-press menus can
    /// offer "Search in Chat" without a callback threaded through every cell.
    var openSearch: ((String?) -> Void)?
    /// Which chat page installed `openSearch`, so a page going away cannot
    /// clear the opener a newer page for the same conversation installed.
    var openSearchOwner: UUID?

    private var tokens: [ChatSearchUnitKey: ChatSearchHighlightToken] = [:]
    private var states: [ChatSearchUnitKey: ChatSearchUnitHighlight] = [:]

    /// The token for `key`, created on first use with the current state.
    /// Tokens live as long as the center (one per chat view model), so a view
    /// that keeps its token across cell reuse still receives later updates.
    func token(for key: ChatSearchUnitKey) -> ChatSearchHighlightToken {
        if let t = tokens[key] { return t }
        let t = ChatSearchHighlightToken(state: states[key])
        tokens[key] = t
        return t
    }

    func state(for key: ChatSearchUnitKey) -> ChatSearchUnitHighlight? { states[key] }

    /// A new result set. Only units whose state actually changed publish.
    func apply(result: ChatSearchResult, query: String, current: ChatSearchMatch?) {
        var next: [ChatSearchUnitKey: ChatSearchUnitHighlight] = [:]
        next.reserveCapacity(result.countByUnit.count)
        for (key, count) in result.countByUnit {
            next[key] = ChatSearchUnitHighlight(query: query, count: count,
                                                current: current?.key == key ? current?.ordinal : nil)
        }
        let changed = Set(next.keys).union(states.keys).filter { next[$0] != states[$0] }
        states = next
        for key in changed { tokens[key]?.state = next[key] }
    }

    /// Moves the current mark: touches at most the two units involved.
    func setCurrent(from old: ChatSearchMatch?, to new: ChatSearchMatch?) {
        var keys: [ChatSearchUnitKey] = []
        if let old { keys.append(old.key) }
        if let new, new.key != old?.key { keys.append(new.key) }
        for key in keys {
            guard let s = states[key] else { continue }
            let current = new?.key == key ? new?.ordinal : nil
            let updated = ChatSearchUnitHighlight(query: s.query, count: s.count, current: current)
            guard updated != s else { continue }
            states[key] = updated
            tokens[key]?.state = updated
        }
    }

    /// Search closed: every highlight goes away.
    func clear() {
        let keys = Array(states.keys)
        states.removeAll()
        for key in keys { tokens[key]?.state = nil }
    }
}

// MARK: - Environment

private struct ChatSearchHighlightsKey: EnvironmentKey {
    static let defaultValue: ChatSearchHighlightCenter? = nil
}

private struct ChatSearchDimmedKey: EnvironmentKey {
    static let defaultValue = false
}

private struct ChatSearchMessageIdKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}

extension EnvironmentValues {
    /// The chat's highlight center; nil outside the message list.
    var chatSearchHighlights: ChatSearchHighlightCenter? {
        get { self[ChatSearchHighlightsKey.self] }
        set { self[ChatSearchHighlightsKey.self] = newValue }
    }

    /// The row is drawn at reduced opacity (compacted history): highlights
    /// use stronger colours so they still read through the fade.
    var chatSearchDimmed: Bool {
        get { self[ChatSearchDimmedKey.self] }
        set { self[ChatSearchDimmedKey.self] = newValue }
    }

    /// The message a block view belongs to, for views that only hold the
    /// block (tool capsule, sub agent card, user_ask card).
    var chatSearchMessageId: UUID? {
        get { self[ChatSearchMessageIdKey.self] }
        set { self[ChatSearchMessageIdKey.self] = newValue }
    }
}

// MARK: - Colours

enum ChatSearchHighlightStyle {
    /// Every match: a highlighter-pen yellow.
    static func matchColor(dimmed: Bool) -> UIColor {
        UIColor.systemYellow.withAlphaComponent(dimmed ? 0.9 : 0.45)
    }

    /// The current match: orange, clearly stronger than the others.
    static func currentColor(dimmed: Bool) -> UIColor {
        UIColor.systemOrange.withAlphaComponent(dimmed ? 1 : 0.85)
    }
}

// MARK: - SwiftUI text with highlights

/// Drop-in for `Text(text)` on a searchable row. Outside the message list (no
/// highlight center) it IS `Text(text)`. Font, colour and line limits applied
/// to it reach the inner Text through the environment, as with a plain Text.
///
/// `searchOffset` skips a leading part of `text` that is drawn but not
/// searched (the agent callback card's "Agent result · " label): matches are
/// counted in `text` from that character on, the same string the search unit
/// holds.
struct SearchHighlightText: View {
    let text: String
    let key: ChatSearchUnitKey?
    var searchOffset: Int = 0
    @Environment(\.chatSearchHighlights) private var center
    @Environment(\.chatSearchDimmed) private var dimmed

    init(_ text: String, key: ChatSearchUnitKey?, searchOffset: Int = 0) {
        self.text = text
        self.key = key
        self.searchOffset = searchOffset
    }

    /// For a block's views: the key from the message id in the environment.
    init(_ text: String, blockId: UUID, field: ChatSearchField, messageId: UUID?) {
        self.init(text, key: messageId.map { ChatSearchUnitKey(messageId: $0, blockId: blockId, field: field) })
    }

    var body: some View {
        if let center, let key {
            Observed(token: center.token(for: key), text: text, searchOffset: searchOffset, dimmed: dimmed)
        } else {
            Text(text)
        }
    }

    private struct Observed: View {
        @ObservedObject var token: ChatSearchHighlightToken
        let text: String
        let searchOffset: Int
        let dimmed: Bool

        var body: some View {
            if let state = token.state {
                Text(SearchHighlightText.attributed(text, searchOffset: searchOffset, state: state, dimmed: dimmed))
            } else {
                Text(text)
            }
        }
    }

    /// `text` with its first `state.drawLimit` occurrences backed in yellow
    /// and the current one in orange. Built piecewise, so its cost is linear
    /// in the text however many highlights it carries.
    static func attributed(_ text: String, searchOffset: Int, state: ChatSearchUnitHighlight,
                           dimmed: Bool) -> AttributedString {
        let start = text.index(text.startIndex, offsetBy: min(max(searchOffset, 0), text.count))
        let searchable = text[start...]
        let ranges = ChatSearchMatcher.ranges(of: state.query, in: String(searchable), limit: state.drawLimit)
        guard !ranges.isEmpty else { return AttributedString(text) }
        let searchableString = String(searchable)
        var out = AttributedString(String(text[..<start]))
        var cursor = searchableString.startIndex
        let match = Color(ChatSearchHighlightStyle.matchColor(dimmed: dimmed))
        let current = Color(ChatSearchHighlightStyle.currentColor(dimmed: dimmed))
        for (ordinal, r) in ranges.enumerated() {
            out += AttributedString(String(searchableString[cursor..<r.lowerBound]))
            var hit = AttributedString(String(searchableString[r]))
            hit.backgroundColor = ordinal == state.current ? current : match
            out += hit
            cursor = r.upperBound
        }
        out += AttributedString(String(searchableString[cursor...]))
        return out
    }
}

// MARK: - Build349 drawing adapter (does not mutate attributed text or height caches)

struct ChatSearchPaintRange {
    let range: NSRange
    let current: Bool
}

/// Reversible visible-text projection. Invisible renderer padding is removed but
/// every remaining UTF16 unit remembers its source offset, including surrogate pairs.
struct ChatSearchTextProjection {
    let text: String
    let offsets: [Int]
    init(_ raw: String) {
        var text = "", offsets: [Int] = [], source = 0
        for scalar in raw.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            let mapped: Unicode.Scalar?
            if let normalization = ChatSearchMarkdownText.normalizedScalar(scalar) { mapped = normalization }
            else { mapped = scalar }
            if let mapped {
                text.unicodeScalars.append(mapped)
                let mappedWidth = mapped.value > 0xFFFF ? 2 : 1
                for i in 0..<mappedWidth { offsets.append(source + min(i, width - 1)) }
            }
            source += width
        }
        self.text = text; self.offsets = offsets
    }
    func sourceRange(_ range: NSRange) -> NSRange? {
        guard range.length > 0, range.location >= 0, NSMaxRange(range) <= offsets.count else { return nil }
        let first = offsets[range.location], last = offsets[NSMaxRange(range) - 1]
        return NSRange(location: first, length: last - first + 1)
    }
}

struct ChatSearchRenderedPiece {
    let sourceRange: NSRange
    let visibleRange: NSRange
    let projection: ChatSearchTextProjection
    let attachment: NSTextAttachment?
}
struct ChatSearchRenderedText {
    let text: String
    let pieces: [ChatSearchRenderedPiece]
    init(_ attributed: NSAttributedString) {
        var text = "", pieces: [ChatSearchRenderedPiece] = []
        attributed.enumerateAttribute(.attachment, in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            let attachment = value as? NSTextAttachment
            let raw: String
            if let code = attachment as? CodeBlockAttachment { raw = code.code }
            else if let table = attachment as? TableAttachment {
                raw = ChatSearchMarkdownText.tableText(rows: table.rows, columnCount: table.alignments.count)
            } else if attachment != nil { raw = "" }
            else { raw = attributed.attributedSubstring(from: range).string }
            let projection = ChatSearchTextProjection(raw)
            let visible = NSRange(location: text.utf16.count, length: projection.text.utf16.count)
            pieces.append(.init(sourceRange: range, visibleRange: visible, projection: projection, attachment: attachment))
            text += projection.text
        }
        self.text = text; self.pieces = pieces
    }
    func hits(_ state: ChatSearchUnitHighlight) -> [ChatSearchPaintRange] {
        ChatSearchMatcher.nsRanges(of: state.query, in: text, limit: state.drawLimit)
            .enumerated().map { .init(range: $0.element, current: $0.offset == state.current) }
    }
    static func local(_ hits: [ChatSearchPaintRange], in range: NSRange) -> [ChatSearchPaintRange] {
        hits.compactMap { hit in
            let overlap = NSIntersectionRange(hit.range, range)
            guard overlap.length > 0 else { return nil }
            return .init(range: NSRange(location: overlap.location - range.location, length: overlap.length), current: hit.current)
        }
    }
}

/// A label overlay, not an attributedText replacement: TableCellLabel's original
/// syntax, inline-code backgrounds and selectableAttributedText stay intact.
final class ChatSearchLabelPaintView: UIView {
    weak var label: UILabel?
    var hits: [ChatSearchPaintRange] = []
    override func draw(_ rect: CGRect) {
        guard let label, let raw = label.attributedText, !hits.isEmpty else { return }
        let storage = NSTextStorage(attributedString: raw)
        let manager = NSLayoutManager(), container = NSTextContainer(size: label.bounds.size)
        container.lineFragmentPadding = 0; container.maximumNumberOfLines = label.numberOfLines
        container.lineBreakMode = label.lineBreakMode
        manager.addTextContainer(container); storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        let y = max(0, (bounds.height - manager.usedRect(for: container).height) / 2)
        for hit in hits where NSMaxRange(hit.range) <= storage.length {
            let glyph = manager.glyphRange(forCharacterRange: hit.range, actualCharacterRange: nil)
            let color = hit.current ? ChatSearchHighlightStyle.currentColor(dimmed: false) : ChatSearchHighlightStyle.matchColor(dimmed: false)
            color.setFill()
            manager.enumerateEnclosingRects(forGlyphRange: glyph, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { box, _ in
                UIBezierPath(roundedRect: box.offsetBy(dx: 0, dy: y), cornerRadius: 2).fill()
            }
        }
    }
    static func apply(to label: UILabel, hits: [ChatSearchPaintRange]) {
        let existing = label.subviews.compactMap { $0 as? ChatSearchLabelPaintView }.first
        guard existing != nil || !hits.isEmpty else { return }
        let overlay = existing ?? ChatSearchLabelPaintView()
        if overlay.superview == nil {
            overlay.isUserInteractionEnabled = false; overlay.isAccessibilityElement = false
            overlay.backgroundColor = .clear; overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            label.addSubview(overlay)
        }
        overlay.label = label; overlay.frame = label.bounds; overlay.hits = hits
        overlay.isHidden = hits.isEmpty; overlay.setNeedsDisplay()
    }
}

/// Paint-only overlay for attachment UITextViews. It deliberately leaves their
/// attributed storage alone, preserving source code colours and inline styles.
final class ChatSearchTextViewPaintView: UIView {
    weak var textView: UITextView?
    var hits: [ChatSearchPaintRange] = []

    override func draw(_ rect: CGRect) {
        guard let textView, !hits.isEmpty else { return }
        let storage = NSTextStorage(attributedString: textView.attributedText)
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: textView.contentSize)
        container.lineFragmentPadding = textView.textContainer.lineFragmentPadding
        container.maximumNumberOfLines = textView.textContainer.maximumNumberOfLines
        container.lineBreakMode = textView.textContainer.lineBreakMode
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        for hit in hits where NSMaxRange(hit.range) <= storage.length {
            let glyphs = manager.glyphRange(forCharacterRange: hit.range, actualCharacterRange: nil)
            let color = hit.current ? ChatSearchHighlightStyle.currentColor(dimmed: false)
                                    : ChatSearchHighlightStyle.matchColor(dimmed: false)
            color.setFill()
            manager.enumerateEnclosingRects(forGlyphRange: glyphs,
                withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0), in: container) { box, _ in
                    UIBezierPath(roundedRect: box.offsetBy(dx: textView.textContainerInset.left,
                        dy: textView.textContainerInset.top), cornerRadius: 2).fill()
                }
        }
    }

    static func apply(to textView: UITextView, hits: [ChatSearchPaintRange]) {
        let existing = textView.subviews.compactMap { $0 as? ChatSearchTextViewPaintView }.first
        guard existing != nil || !hits.isEmpty else { return }
        let overlay = existing ?? ChatSearchTextViewPaintView()
        if overlay.superview == nil {
            overlay.isUserInteractionEnabled = false
            overlay.isAccessibilityElement = false
            overlay.backgroundColor = .clear
            overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            textView.addSubview(overlay)
        }
        overlay.textView = textView
        overlay.frame = CGRect(origin: .zero, size: textView.contentSize)
        overlay.hits = hits
        overlay.isHidden = hits.isEmpty
        overlay.setNeedsDisplay()
    }
}

/// Overlay mirrors only the old user's text HStack and its 14/10 padding. It is
/// outside the sizing graph, ignores touches and keeps the old bubble/attachments.
/// Not used for queued messages or callbacks. No geometry cache is invalidated.
struct ChatSearchUserBubbleOverlay: View {
    let message: ChatMessage
    @Environment(\.chatSearchHighlights) private var center
    var body: some View {
        if message.role == .user, !message.isQueued, message.agentCallback == nil, let center {
            Observed(message: message, token: center.token(for: .init(messageId: message.id, blockId: nil, field: .body)))
        }
    }
    private struct Observed: View {
        @ObservedObject var message: ChatMessage
        @ObservedObject var token: ChatSearchHighlightToken
        var body: some View {
            if token.state != nil {
                HStack {
                    Spacer(minLength: 60)
                    SearchHighlightText(ChatSearchDisplayText.userBubble(message.content),
                        key: .init(messageId: message.id, blockId: nil, field: .body))
                        .font(.system(size: FontSettings.shared.scaledMessage(16.5)))
                        .foregroundStyle(ChatColors.primaryText)
                        .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .padding(.horizontal, 16).padding(.vertical, 4)
                .allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
}
