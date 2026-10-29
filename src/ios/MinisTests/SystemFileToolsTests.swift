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

    func testIdentityDiagnosticsPreserveSpecificFailureAndIDs() {
        let result = SystemAccessEnvelope(value: [
            "ok": false, "code": "request_open_failed", "stage": "request_validation",
            "uid": 0, "euid": 0, "gid": 0, "egid": 0, "exit_code": 1
        ])
        XCTAssertFalse(result.ok)
        XCTAssertTrue(result.diagnosticSummary.contains("request_open_failed"))
        XCTAssertTrue(result.diagnosticSummary.contains("request_validation"))
        XCTAssertTrue(result.diagnosticSummary.contains("uid=0 euid=0 gid=0 egid=0"))
        let missing = SystemAccessEnvelope(value: ["ok": false])
        XCTAssertTrue(missing.diagnosticSummary.contains("uid=未返回"))
    }

    func testModesHaveDistinctChineseLabels() {
        XCTAssertEqual(SystemAccessMode.readonly.title, "只读")
        XCTAssertEqual(SystemAccessMode.limited.title, "有限写入")
        XCTAssertEqual(SystemAccessMode.expert.title, "专家写入")
    }
}
