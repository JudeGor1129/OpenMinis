import XCTest
@testable import Minis

final class SystemFileToolsTests: XCTestCase {
    func testSystemDiffIsBounded() {
        let old = (0..<30).map { "old\($0)" }.joined(separator: "\n")
        let new = (0..<30).map { "new\($0)" }.joined(separator: "\n")
        let diff = AIChatViewModel.boundedSystemDiff(old: old, new: new)
        XCTAssertLessThanOrEqual(diff.components(separatedBy: .newlines).count, 9)
        XCTAssertTrue(diff.contains("前 8 行"))
    }

    func testDirectHostWritesCannotBypassSystemConfirmation() {
        let denial = AIChatViewModel.hostWriteDenial(for: "/var/jb/var/tmp/test.txt", allowSystem: true)
        XCTAssertNotNil(denial)
        XCTAssertTrue(denial?.contains("system_file_write") == true)
        XCTAssertNil(AIChatViewModel.hostWriteDenial(for: "/var/mobile/Documents/test.txt", allowSystem: false))
    }

    func testModesHaveDistinctChineseLabels() {
        XCTAssertEqual(SystemAccessMode.readonly.title, "只读")
        XCTAssertEqual(SystemAccessMode.limited.title, "有限写入")
        XCTAssertEqual(SystemAccessMode.expert.title, "专家写入")
    }
}
