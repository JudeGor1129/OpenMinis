import CoreText
import ImageIO
import SwiftUI
import UIKit

struct ChatExportResult: Identifiable {
    let id = UUID()
    let urls: [URL]
    let warnings: [String]
}

enum ChatExportError: LocalizedError {
    case nothingToExport, budgetExceeded, writeFailed, noProgress
    var errorDescription: String? {
        switch self {
        case .nothingToExport: return "请至少选择一条消息。"
        case .budgetExceeded: return "选择内容超过导出限额，请减少选择或分批导出。"
        case .writeFailed: return "无法创建导出文件。"
        case .noProgress: return "文字无法在当前页面排版，请缩小选择范围。"
        }
    }
}

/// Build349 adapter. Uses the OLD markdown parser/theme/renderer, not the new
/// official renderer's row types. CoreText draws real glyphs into PDF (no screenshot
/// PDF and no hidden OCR layer). Codes/tables are converted to selectable styled
/// text; local images are downsampled one at a time and appended under their item.
@MainActor
enum ChatExportRenderer {
    static func render(items: [ChatShareItem], title: String, options: ChatExportOptions,
                       resolveAttachment: (String) async -> URL?) async throws -> ChatExportResult {
        guard !items.isEmpty else { throw ChatExportError.nothingToExport }
        guard items.count <= ChatShareExportBudget.maxItems,
              items.allSatisfy({ $0.markdown.utf16.count <= ChatShareExportBudget.maxItemUTF16 }),
              items.reduce(0, { $0 + $1.markdown.utf16.count }) <= ChatShareExportBudget.maxTotalUTF16,
              items.reduce(0, { $0 + $1.attachments.count }) <= ChatShareExportBudget.maxAttachments
        else { throw ChatExportError.budgetExceeded }
        try Task.checkCancellation()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MinisChatExport-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: directory) } }
        if options.format == .markdown {
            let url = directory.appendingPathComponent("chat.md")
            try ChatShareMarkdown.document(title: title, items: items).write(to: url, atomically: true, encoding: .utf8)
            success = true; return .init(urls: [url], warnings: [])
        }
        let width: CGFloat = options.wideLayout ? 768 : 390
        let height = options.format == .pdf ? width * 297 / 210 : ChatShareExportBudget.partHeight(width: width)
        let pdfURL = directory.appendingPathComponent("chat.pdf")
        let writer = try VectorWriter(url: pdfURL, width: width, height: height, dark: options.dark, title: title)
        var warnings: [String] = []
        var resourceCount = 0
        do {
            if !title.isEmpty {
                try writer.append(NSAttributedString(string: String(title.prefix(160)) + "\n", attributes: [
                    .font: UIFont.boldSystemFont(ofSize: 20),
                    .foregroundColor: options.dark ? UIColor.white : UIColor.black]), userBubble: false)
            }
            for item in items {
                try Task.checkCancellation()
                let trait = UITraitCollection(userInterfaceStyle: options.dark ? .dark : .light)
                var attributed = NSAttributedString()
                trait.performAsCurrent { attributed = selectableText(item, dark: options.dark) }
                try writer.append(attributed, userBubble: item.kind == .user)
                // Resource resolution retains the owning session via the closure supplied by
                // the picker. Remote URLs are NEVER downloaded implicitly during export.
                for file in mediaSources(item) {
                    resourceCount += 1
                    guard resourceCount <= ChatShareExportBudget.maxAttachments,
                          file.name.utf16.count <= 4096, file.source.utf16.count <= 4096 else { throw ChatExportError.budgetExceeded }
                    try Task.checkCancellation()
                    let readableSource = file.source.hasPrefix("/var/minis/") || file.source.hasPrefix("minis://")
                    if file.isImage, readableSource,
                       let local = await resolveAttachment(ChatShareMarkdown.encodedSource(file.source)),
                       local.isFileURL, let image = thumbnail(local) {
                        try writer.append(image)
                    } else if file.isImage {
                        warnings.append("附件未嵌入：" + file.name)
                    }
                    let caption = NSMutableAttributedString(string: file.name + "\n", attributes: [
                        .font: UIFont.systemFont(ofSize: 12),
                        .foregroundColor: options.dark ? UIColor.lightGray : UIColor.darkGray])
                    if let url = URL(string: ChatShareMarkdown.encodedSource(file.source)) {
                        caption.addAttribute(.link, value: url, range: NSRange(location: 0, length: caption.length))
                    }
                    try writer.append(caption, userBubble: false)
                }
                await Task.yield() // UIKit/CoreText work serialized; release one item before next.
            }
            writer.finish()
        } catch { writer.finish(); throw error }
        if options.format == .pdf {
            success = true; return .init(urls: [pdfURL], warnings: warnings)
        }
        let urls = try await rasterParts(pdfURL: pdfURL, directory: directory, writer: writer)
        if urls.count > 1 { warnings.append("超长内容已分为 \(urls.count) 张连续长图，避免一次分配巨型位图。") }
        success = true; return .init(urls: urls, warnings: warnings)
    }

    private static func mediaSources(_ item: ChatShareItem) -> [ChatShareAttachment] {
        var sources = item.attachments
        // Preserve rendered inline media sources as read-only refs as well.
        func walkInline(_ nodes: [InlineNode]) {
            for node in nodes {
                if case .image(let source, let children) = node {
                    let name = ChatSearchMarkdownText.inlineText(children)
                    sources.append(.init(source: source, name: name.isEmpty ? source : name, isImage: true))
                } else { walkInline(node.children) }
            }
        }
        func walk(_ blocks: [BlockNode]) {
            for block in blocks {
                switch block {
                case .paragraph(let inlines), .heading(_, let inlines): walkInline(inlines)
                case .table(_, let rows): for row in rows { for cell in row.cells { walkInline(cell.content) } }
                default: walk(block.children)
                }
            }
        }
        walk(MarkdownContent(prepareMarkdownForRender(item.markdown)).blocks)
        var seen = Set<String>()
        return sources.filter { seen.insert($0.source).inserted }
    }

    private static func thumbnail(_ url: URL) -> UIImage? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options as CFDictionary) else { return nil }
        let downsample: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: ChatShareExportBudget.maxDecodedImageSide]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, downsample as CFDictionary).map { UIImage(cgImage: $0) }
    }

    private static func selectableText(_ item: ChatShareItem, dark: Bool) -> NSAttributedString {
        let theme = SelectableMarkdownTheme(baseFontSize: FontSettings.shared.scaledMessage(16.5))
        let color: UIColor = dark ? .white : .black
        let result = NSMutableAttributedString(string: item.label + "\n", attributes: [
            .font: UIFont.boldSystemFont(ofSize: 13), .foregroundColor: color])
        let rendered: NSAttributedString
        if item.kind == .user || item.kind == .tool || item.kind == .note || item.kind == .callback || item.kind == .thinking {
            let text = item.kind == .user ? ChatSearchDisplayText.userBubble(item.markdown) : item.markdown
            rendered = NSAttributedString(string: text, attributes: [.font: theme.baseFont, .foregroundColor: color])
        } else { rendered = renderMarkdownBlocks(MarkdownContent(prepareMarkdownForRender(item.markdown)).blocks) }
        // A fresh attributed copy; never mutate live renderer/cachedAttributedString.
        rendered.enumerateAttribute(.attachment, in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            let part: NSAttributedString
            if let code = value as? CodeBlockAttachment {
                part = NSAttributedString(string: code.code, attributes: [.font: theme.codeBlockFont,
                    .foregroundColor: dark ? UIColor.systemGreen : UIColor.darkGray])
            } else if let table = value as? TableAttachment {
                part = NSAttributedString(string: ChatSearchMarkdownText.tableText(rows: table.rows, columnCount: table.alignments.count),
                    attributes: [.font: theme.baseFont, .foregroundColor: color])
            } else if let math = value as? MathAttachment {
                part = NSAttributedString(string: math.latex, attributes: [.font: theme.baseFont, .foregroundColor: color])
            } else if value is NSTextAttachment {
                part = NSAttributedString(string: "", attributes: [.font: theme.baseFont])
            } else { part = rendered.attributedSubstring(from: range) }
            result.append(part)
        }
        result.append(NSAttributedString(string: "\n", attributes: [.font: theme.baseFont, .foregroundColor: color]))
        // Resolve dynamic UIKit colours before CoreText writes them into the PDF.
        result.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: result.length)) { value, range, _ in
            if let c = value as? UIColor { result.addAttribute(.foregroundColor, value: c.resolvedColor(with: UITraitCollection.current), range: range) }
        }
        return result
    }

    @MainActor
    private final class VectorWriter {
        let width: CGFloat, height: CGFloat
        let context: CGContext
        let dark: Bool
        private var pageOpen = false
        private var pageCount = 0
        private var y: CGFloat = 16
        private let margin: CGFloat = 16
        private(set) var usedHeights: [CGFloat] = []
        init(url: URL, width: CGFloat, height: CGFloat, dark: Bool, title: String) throws {
            self.width = width; self.height = height; self.dark = dark
            var media = CGRect(x: 0, y: 0, width: width, height: height)
            guard let consumer = CGDataConsumer(url: url as CFURL),
                  let context = CGContext(consumer: consumer, mediaBox: &media,
                    auxiliaryInfo: [kCGPDFContextTitle as String: String(title.prefix(160)),
                        kCGPDFContextCreator as String: "Minis"] as CFDictionary)
            else { throw ChatExportError.writeFailed }
            self.context = context
        }
        private func beginPage() throws {
            guard pageCount < ChatShareExportBudget.maxPages else { throw ChatExportError.budgetExceeded }
            context.beginPDFPage(nil); pageOpen = true; pageCount += 1; y = margin
            context.setFillColor((dark ? UIColor(white: 0.08, alpha: 1) : UIColor.white).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        private func endPage() {
            guard pageOpen else { return }
            usedHeights.append(min(height, ceil(y + margin)))
            context.endPDFPage(); pageOpen = false
        }
        func finish() { endPage(); context.closePDF() }

        func append(_ text: NSAttributedString, userBubble: Bool) throws {
            guard text.length > 0 else { return }
            let framesetter = CTFramesetterCreateWithAttributedString(text)
            var offset = 0
            let x: CGFloat = userBubble ? 76 : margin
            let textWidth = width - x - margin - (userBubble ? 28 : 0)
            while offset < text.length {
                if !pageOpen { try beginPage() }
                let available = height - y - margin - 20
                if available < 40 { endPage(); continue }
                let path = CGPath(rect: CGRect(x: x + (userBubble ? 14 : 0), y: margin + 10,
                    width: textWidth, height: available), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
                let visible = CTFrameGetVisibleStringRange(frame)
                guard visible.length > 0 else { throw ChatExportError.noProgress }
                let lines = CTFrameGetLines(frame) as! [CTLine]
                var origins = [CGPoint](repeating: .zero, count: lines.count)
                CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
                var used: CGFloat = 0
                for (line, origin) in zip(lines, origins) {
                    var descent: CGFloat = 0
                    CTLineGetTypographicBounds(line, nil, &descent, nil)
                    used = max(used, available - origin.y + descent)
                }
                used = max(1, ceil(used))
                context.saveGState()
                // The frame's top is anchored at height - y - 10; when it ends
                // early its unused lower area is not added to the continuous flow.
                let topCorrection = height - y - 10 - (margin + 10 + available)
                context.translateBy(x: 0, y: topCorrection)
                if userBubble {
                    let rect = CGRect(x: x, y: margin + 10 + available - used - 10,
                        width: width - x - margin, height: used + 20)
                    context.setFillColor((dark ? UIColor(white: 0.18, alpha: 1) : UIColor(white: 0.94, alpha: 1)).cgColor)
                    context.addPath(UIBezierPath(roundedRect: rect, cornerRadius: 18).cgPath); context.fillPath()
                }
                context.textMatrix = .identity
                CTFrameDraw(frame, context) // actual PDF text operators, including tables/code
                context.restoreGState()
                offset += visible.length; y += used + (userBubble ? 20 : 10)
                if offset < text.length { endPage() }
            }
        }
        func append(_ image: UIImage) throws {
            guard let cg = image.cgImage else { return }
            let w = min(width - margin * 2, CGFloat(cg.width))
            let h = min(height - margin * 2, w * CGFloat(cg.height) / CGFloat(cg.width))
            let scaledWidth = h * CGFloat(cg.width) / CGFloat(cg.height)
            if !pageOpen { try beginPage() }
            if y + h + margin > height { endPage(); try beginPage() }
            context.draw(cg, in: CGRect(x: margin, y: height - y - h, width: scaledWidth, height: h))
            y += h + 10
        }
    }

    private static func rasterParts(pdfURL: URL, directory: URL, writer: VectorWriter) async throws -> [URL] {
        guard let document = CGPDFDocument(pdfURL as CFURL) else { throw ChatExportError.writeFailed }
        guard document.numberOfPages <= ChatShareExportBudget.maxImageParts else { throw ChatExportError.budgetExceeded }
        var urls: [URL] = []
        for index in 1...document.numberOfPages {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw ChatExportError.writeFailed }
            let cropHeight = max(1, min(writer.height, writer.usedHeights[index - 1]))
            let scale = ChatShareExportBudget.imageScale
            guard ceil(writer.width * scale) * ceil(cropHeight * scale) <= ChatShareExportBudget.maxBitmapPixels,
                  ceil(cropHeight * scale) <= ChatShareExportBudget.maxPixelHeight
            else { throw ChatExportError.budgetExceeded }
            let url = directory.appendingPathComponent(String(format: "chat-%03d.png", index))
            try autoreleasepool {
                let format = UIGraphicsImageRendererFormat()
                format.scale = scale; format.opaque = true; format.preferredRange = .standard
                let image = UIGraphicsImageRenderer(size: CGSize(width: writer.width, height: cropHeight), format: format).image { renderer in
                    let c = renderer.cgContext
                    c.setFillColor((writer.dark ? UIColor.black : UIColor.white).cgColor)
                    c.fill(CGRect(x: 0, y: 0, width: writer.width, height: cropHeight))
                    c.translateBy(x: 0, y: cropHeight); c.scaleBy(x: 1, y: -1)
                    c.translateBy(x: 0, y: -(writer.height - cropHeight))
                    c.drawPDFPage(page)
                }
                // ImageIO writes directly to disk: avoid another full-size pngData
                // allocation. Neither previous UIImages nor encoded data are retained.
                guard let cg = image.cgImage,
                      let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
                else { throw ChatExportError.writeFailed }
                CGImageDestinationAddImage(destination, cg, nil)
                guard CGImageDestinationFinalize(destination) else { throw ChatExportError.writeFailed }
            }
            urls.append(url); await Task.yield()
        }
        return urls
    }
}
