import PDFKit
import UIKit
import XCTest
@testable import Minis

/// Real framework checks for an Xcode/iOS15 test run. Not run in iSH.
@MainActor
final class ChatSearchExport349RuntimeTests: XCTestCase {
    private func item(_ markdown: String) -> ChatShareItem {
        .init(id: "test", messageId: UUID(), blockId: UUID(), kind: .text,
              markdown: markdown, label: "Minis", attachments: [])
    }
    func testSearchablePDFContainsChineseAndCodeAcrossPages() async throws {
        let text = String(repeating: "Unicode中文 hello café 😀\n\n", count: 120)
            + "\n```swift\nprint(\"代码可搜索\")\n```\n\n| 甲 | 乙 |\n| --- | --- |\n| 表格 | 文字 |\n"
        let result = try await ChatExportRenderer.render(items: [item(text)], title: "测试", options: .init(format: .pdf)) { _ in nil }
        defer { try? FileManager.default.removeItem(at: result.urls[0].deletingLastPathComponent()) }
        let document = try XCTUnwrap(PDFDocument(url: result.urls[0]))
        XCTAssertGreaterThan(document.pageCount, 1)
        let extracted = (0..<document.pageCount).compactMap { document.page(at: $0)?.string }.joined(separator: "\n")
        XCTAssertTrue(extracted.contains("Unicode"))
        XCTAssertTrue(extracted.contains("中文"))
        XCTAssertTrue(extracted.contains("代码可搜索"))
        XCTAssertTrue(extracted.contains("表格"))
    }
    func testLongPNGPartsStayWithinPixelBudget() async throws {
        let result = try await ChatExportRenderer.render(items: [item(String(repeating: "长图 split image\n\n", count: 600))], title: "分片", options: .init(format: .image)) { _ in nil }
        defer { try? FileManager.default.removeItem(at: result.urls[0].deletingLastPathComponent()) }
        XCTAssertGreaterThan(result.urls.count, 1)
        for url in result.urls {
            let image = try XCTUnwrap(UIImage(contentsOfFile: url.path)?.cgImage)
            XCTAssertLessThanOrEqual(image.width * image.height, Int(ChatShareExportBudget.maxBitmapPixels))
            XCTAssertLessThanOrEqual(image.height, Int(ChatShareExportBudget.maxPixelHeight))
        }
    }
    func testUnicodeAttachmentEncodingAndOriginalMarkdown() {
        let source = "/var/minis/attachments/中文 #?😀.png"
        let encoded = ChatShareMarkdown.encodedSource(source)
        XCTAssertEqual(encoded, "minis://attachments/%E4%B8%AD%E6%96%87%20%23%3F%F0%9F%98%80.png")
        XCTAssertEqual(ChatShareMarkdown.encodedSource(encoded), encoded)
        let raw = "**原文**\n```swift\nlet x = 1\n```"
        XCTAssertTrue(ChatShareMarkdown.document(title: "测试", items: [item(raw)]).contains(raw))
    }
    func testProjectionPreservesUTF16ForEmojiAndPadding() {
        let projection = ChatSearchTextProjection("😀\u{200A}中")
        XCTAssertEqual(projection.text, "😀中")
        XCTAssertEqual(projection.sourceRange(NSRange(location: 2, length: 1)), NSRange(location: 3, length: 1))
    }
    func testBudgetRejectionIsNotBlankSuccessfulFile() async {
        do {
            _ = try await ChatExportRenderer.render(items: [item(String(repeating: "x", count: ChatShareExportBudget.maxItemUTF16 + 1))], title: "测试", options: .init(format: .pdf)) { _ in nil }
            XCTFail("must reject an oversized item")
        } catch { XCTAssertTrue(error is ChatExportError) }
    }
}
