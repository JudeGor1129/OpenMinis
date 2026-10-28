import XCTest
@testable import Minis

final class GroupWorkspaceStoreTests: XCTestCase {
    func testDirectoryNameUsesGroupNameAndStableIdentity() {
        let a = GroupWorkspaceStore.directoryName(folderID: "folder-A", name: "开发/项目")
        let b = GroupWorkspaceStore.directoryName(folderID: "folder-B", name: "开发/项目")
        XCTAssertTrue(a.hasPrefix("开发_项目--"))
        XCTAssertNotEqual(a, b)
        XCTAssertFalse(a.contains("/"))
    }

    func testDirectoryNameIsBoundedAndHasFallback() {
        let long = String(repeating: "组", count: 100)
        let value = GroupWorkspaceStore.directoryName(folderID: "id", name: long)
        XCTAssertLessThan(value.count, 60)
        XCTAssertTrue(GroupWorkspaceStore.directoryName(folderID: "id", name: "  ").hasPrefix("未命名分组--"))
    }
}
