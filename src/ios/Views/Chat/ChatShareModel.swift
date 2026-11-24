import Combine
import Foundation

struct ChatShareAttachment: Equatable {
    let source: String
    let name: String
    let isImage: Bool
}

/// Immutable snapshot: a streamed or edited source message cannot change an export
/// after the picker opens. Selection uses message/block IDs, never array indices.
struct ChatShareItem: Identifiable {
    enum Kind { case user, text, thinking, tool, note, callback }
    let id: String
    let messageId: UUID
    let blockId: UUID?
    let kind: Kind
    let markdown: String
    let label: String
    let attachments: [ChatShareAttachment]
}

@MainActor
final class ChatShareModel: ObservableObject {
    let title: String
    let items: [ChatShareItem]
    @Published var selected: Set<String>
    var selectedItems: [ChatShareItem] { items.filter { selected.contains($0.id) } }

    init(messages: [ChatMessage], title: String, initialMessageIds: Set<UUID> = []) {
        self.title = String(title.prefix(160))
        var items: [ChatShareItem] = []
        for m in messages where !m.isQueued && !m.isInternalBridge {
            let mid = m.id.uuidString
            let files = m.attachments.map {
                ChatShareAttachment(source: $0.path, name: $0.fileName, isImage: $0.isImage)
            }
            if m.role == .user {
                items.append(.init(id: mid, messageId: m.id, blockId: nil,
                    kind: m.agentCallback == nil ? .user : .callback, markdown: m.content,
                    label: m.agentCallback?.title ?? "用户", attachments: files))
            } else if m.role == .assistant {
                if m.blocks.isEmpty && !m.content.isEmpty {
                    items.append(.init(id: mid, messageId: m.id, blockId: nil, kind: .text,
                        markdown: m.content, label: "Minis", attachments: files))
                }
                for b in m.blocks {
                    let kind: ChatShareItem.Kind
                    switch b.kind {
                    case .text: kind = .text
                    case .thinking: kind = .thinking
                    case .info: kind = .note
                    default: kind = .tool
                    }
                    let toolTitle = (b.toolSummary?.isEmpty == false ? b.toolSummary : nil) ?? b.toolDescription
                    guard !b.content.isEmpty || kind == .tool else { continue }
                    items.append(.init(id: mid + "/" + b.id.uuidString, messageId: m.id, blockId: b.id,
                        kind: kind, markdown: b.content,
                        label: kind == .tool ? toolTitle : (kind == .thinking ? "思考" : "Minis"),
                        attachments: files))
                }
                if let error = m.error, !error.isEmpty {
                    items.append(.init(id: mid + "/error", messageId: m.id, blockId: nil,
                        kind: .note, markdown: error, label: "错误", attachments: []))
                }
            }
        }
        self.items = items
        self.selected = Set(items.filter { initialMessageIds.contains($0.messageId) }.map(\.id))
    }
    func toggle(_ item: ChatShareItem) {
        if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) }
    }
    func selectAll() { selected = Set(items.map(\.id)) }
    func selectMessage(_ id: UUID) { selected.formUnion(items.filter { $0.messageId == id }.map(\.id)) }
    func clear() { selected.removeAll() }
}

enum ChatShareMarkdown {
    /// Encode path SEGMENTS once. urlPathAllowed alone allows #/? and breaks names
    /// such as 中文 #?.png; decoding first also prevents %25 double encoding.
    static func encodedSource(_ source: String) -> String {
        let prefix: String, rest: String
        if source.hasPrefix("/var/minis/") {
            prefix = "minis://"; rest = String(source.dropFirst("/var/minis/".count))
        } else if source.hasPrefix("minis://") {
            prefix = "minis://"; rest = String(source.dropFirst("minis://".count))
        } else { return source }
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return prefix + rest.split(separator: "/", omittingEmptySubsequences: false).map {
            // Filesystem paths are raw: a literal %20 filename is NOT a space.
            // Only an existing minis:// URL is decoded before its idempotent re-encode.
            let decoded = source.hasPrefix("minis://") ? (String($0).removingPercentEncoding ?? String($0)) : String($0)
            return decoded.addingPercentEncoding(withAllowedCharacters: safe) ?? String($0)
        }.joined(separator: "/")
    }
    static func document(title: String, items: [ChatShareItem]) -> String {
        var parts = ["# " + title.replacingOccurrences(of: "\n", with: " ")]
        for item in items {
            parts.append("## " + (item.kind == .user ? "用户" : item.label).replacingOccurrences(of: "\n", with: " "))
            // Intentionally not stripped, rendered or normalized: original Markdown
            // (including code, tools and Unicode) is preserved byte-for-byte here.
            parts.append(item.markdown)
            for a in item.attachments {
                let label = a.name.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]")
                let destination = encodedSource(a.source)
                parts.append("\(a.isImage ? "!" : "")[\(label)](<\(destination)>)")
            }
        }
        return parts.joined(separator: "\n\n") + "\n"
    }
}

struct ChatExportOptions: Equatable {
    enum Format: String, CaseIterable { case image, pdf, markdown }
    var format: Format = .image
    var wideLayout = false
    var dark = false
}

/// Explicit ceilings; images are emitted sequentially as PNG parts, never stitched
/// into an unbounded bitmap. PDF is always vector text with bounded page count.
enum ChatShareExportBudget {
    static let maxTotalUTF16 = 2_000_000
    static let maxItemUTF16 = 500_000
    static let maxItems = 1000
    static let maxPages = 200
    static let maxImageParts = 64
    static let maxAttachments = 128
    static let maxDecodedImageSide = 1600
    static let imageScale: CGFloat = 2
    static let maxBitmapPixels: CGFloat = 4_000_000
    static let maxPixelHeight: CGFloat = 8192
    static func partHeight(width: CGFloat) -> CGFloat {
        min(2048, maxPixelHeight / imageScale,
            (maxBitmapPixels / (width * imageScale * imageScale)).rounded(.down))
    }
}
