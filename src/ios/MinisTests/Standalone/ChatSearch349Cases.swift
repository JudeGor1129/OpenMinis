import Foundation

func check349(_ name: String, _ test: @autoclosure () -> Bool) {
    precondition(test(), name)
    print("PASS", name)
}
let mid349 = UUID(uuidString: "00000000-0000-0000-0000-000000000349")!
let bid349 = UUID(uuidString: "00000000-0000-0000-0000-000000000350")!
let key349 = ChatSearchUnitKey(messageId: mid349, blockId: bid349, field: .body)
let unit349 = ChatSearchUnit(key: key349, text: "😀 Café 搜索 hello 搜索 HELLO")
check349("Unicode UTF16 offset", ChatSearchMatcher.nsRanges(of: "Café", in: unit349.text) == [NSRange(location: 3, length: 4)])
check349("accent insensitive", ChatSearchMatcher.count(of: "cafe", in: unit349.text, limit: 9) == 1)
check349("CJK repeated hits", ChatSearchMatcher.count(of: "搜索", in: unit349.text, limit: 9) == 2)
check349("case insensitive", ChatSearchMatcher.count(of: "hello", in: unit349.text, limit: 9) == 2)
check349("trim query", ChatSearchMatcher.normalizedQuery(" \n 搜索 \n") == "搜索")
check349("nonoverlapping", ChatSearchMatcher.count(of: "aa", in: "aaaaa", limit: 9) == 2)
let many349 = ChatSearchUnit(key: key349, text: String(repeating: "x ", count: 201))
let capped349 = ChatSearchEngine.search(units: [many349], query: "x")!
check349("per unit cap is reported truncated", capped349.matches.count == 200 && capped349.truncated)
let exact349 = ChatSearchUnit(key: key349, text: String(repeating: "x ", count: 200))
check349("exact cap is not truncated", ChatSearchEngine.search(units: [exact349], query: "x")!.truncated == false)
check349("cancelled returns nil", ChatSearchEngine.search(units: [unit349], query: "hello", isCancelled: { true }) == nil)
let result349 = ChatSearchEngine.search(units: [unit349], query: "搜索")!
check349("stable identity", result349.matches == [ChatSearchMatch(key: key349, ordinal: 0), ChatSearchMatch(key: key349, ordinal: 1)])
check349("newest initial", ChatSearchNavigation.initialIndex(count: 2) == 1)
check349("next wraps", ChatSearchNavigation.step(from: 1, count: 2, forward: true)!.index == 0)
check349("previous wraps", ChatSearchNavigation.step(from: 0, count: 2, forward: false)!.index == 1)
check349("stream append relocation", ChatSearchNavigation.relocate(previous: result349.matches[1], previousIndex: 1, in: result349.matches) == 1)
check349("no results no movement", ChatSearchNavigation.step(from: nil, count: 0, forward: true) == nil)
let md349: [BlockNode] = [.paragraph(content: [.strong(children: [.text("强调")]), .text(" "), .link(destination: "https://hidden", children: [.text("链接")])]), .codeBlock(fenceInfo: "swift", content: "print(\"中文\")\n")]
let visible349 = ChatSearchMarkdownText.text(blocks: md349)
check349("rendered Markdown text", visible349.contains("强调 链接") && !visible349.contains("https://hidden"))
check349("code text searchable", visible349.contains("print(\"中文\")"))
check349("invisible padding removed", ChatSearchMarkdownText.normalized("a\u{200B}\u{200A}b\u{2028}c") == "ab\nc")
print("PASS 18 direct-source Swift cases")
