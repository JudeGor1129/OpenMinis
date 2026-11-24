import Foundation

/// Build349 adapter: only texts with a real highlight sink are indexed. Thinking,
/// tool detail sheets, queued rows and hidden bridge messages are deliberately excluded.
/// User text must match ChatMessageRow.userDisplayText (NOT a newer reminder stripper).
enum ChatSearchDisplayText {
    static func userBubble(_ content: String) -> String {
        var text = content
        if let start = text.range(of: "<user-attached-files>") {
            let end = text.range(of: "</user-attached-files>")
            let endBound = end?.upperBound ?? text.endIndex
            if endBound >= start.lowerBound {
                text = String(text[..<start.lowerBound] + text[endBound...])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }
}

struct ChatSearchPendingUnit {
    let key: ChatSearchUnitKey
    let raw: String
    let blocks: [BlockNode]?
    let finalised: Bool
    let isMarkdown: Bool
}

struct ChatSearchTextCacheEntry {
    // Equality of the SOURCE, not its length: same-length edits must invalidate.
    let raw: String
    let finalised: Bool
    let text: String
}

enum ChatSearchUnitBuilder {
    @MainActor
    static func snapshot(messages: [ChatMessage]) -> [ChatSearchPendingUnit] {
        var out: [ChatSearchPendingUnit] = []
        for m in messages where !m.isInternalBridge && !m.isQueued {
            if m.role == .user, m.agentCallback == nil {
                let text = ChatSearchDisplayText.userBubble(m.content)
                if !text.isEmpty {
                    out.append(ChatSearchPendingUnit(key: .init(messageId: m.id, blockId: nil, field: .body),
                        raw: text, blocks: nil, finalised: true, isMarkdown: false))
                }
            } else if m.role == .assistant {
                for b in m.blocks where b.kind == .text && !b.content.isEmpty {
                    out.append(ChatSearchPendingUnit(key: .init(messageId: m.id, blockId: b.id, field: .body),
                        raw: b.content, blocks: b.cachedMarkdown?.blocks,
                        finalised: b.cachedMarkdown != nil || b.cachedAttributedString != nil, isMarkdown: true))
                }
            }
        }
        return out
    }

    static func resolveMarkdown(raw: String, blocks: [BlockNode]?, finalised: Bool) -> String {
        let split = finalised ? (prefix: raw, plainSuffix: "") : splitStreamingTableTail(raw)
        let parsed = (split.plainSuffix.isEmpty ? blocks : nil)
            ?? MarkdownContent(prepareMarkdownForRender(split.prefix)).blocks
        return ChatSearchMarkdownText.text(blocks: parsed, plainSuffix: split.plainSuffix)
    }

    static func resolve(_ pending: [ChatSearchPendingUnit], cache: [UUID: ChatSearchTextCacheEntry],
                        isCancelled: () -> Bool) -> (units: [ChatSearchUnit], cache: [UUID: ChatSearchTextCacheEntry])? {
        var units: [ChatSearchUnit] = []
        var nextCache: [UUID: ChatSearchTextCacheEntry] = [:]
        for p in pending {
            if isCancelled() { return nil }
            var text = p.raw
            if p.isMarkdown {
                guard let bid = p.key.blockId else { continue }
                if let hit = cache[bid], hit.raw == p.raw, hit.finalised == p.finalised {
                    text = hit.text
                } else {
                    text = resolveMarkdown(raw: p.raw, blocks: p.blocks, finalised: p.finalised)
                }
                nextCache[bid] = .init(raw: p.raw, finalised: p.finalised, text: text)
            }
            units.append(.init(key: p.key, text: text))
        }
        return (units, nextCache)
    }
}
