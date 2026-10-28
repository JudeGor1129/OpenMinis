import XCTest
@testable import Minis

final class ProgrammingToolsTests: XCTestCase {
    func testWorkflowRolesEnforceWritePolicy() {
        XCTAssertTrue(ProgrammingRolePolicy.permits(role: .implementer, tool: "apply_patch"))
        XCTAssertTrue(ProgrammingRolePolicy.permits(role: .debugger, tool: "apply_patch"))
        XCTAssertFalse(ProgrammingRolePolicy.permits(role: .repositoryExplorer, tool: "apply_patch"))
        XCTAssertFalse(ProgrammingRolePolicy.permits(role: .reviewer, tool: "apply_patch"))
        XCTAssertTrue(ProgrammingRolePolicy.permits(role: .reviewer, tool: "git_diff"))
    }

    func testSymbolExtractorFindsSwiftTypesAndFunctions() {
        let source = """
        struct ProjectIndex { }
        private func refreshIndex() { }
        extension ProjectIndex { }
        """
        let symbols = CodeSymbolExtractor.extract(text: source, extension: "swift")
        XCTAssertTrue(symbols.contains { $0.name == "ProjectIndex" && $0.kind == "type" })
        XCTAssertTrue(symbols.contains { $0.name == "refreshIndex" && $0.kind == "function" })
    }

    func testRelativePathRejectsProjectEscape() throws {
        XCTAssertThrowsError(try ProgrammingPathPolicy.projectRelativePath("../Secrets.txt", projectRoot: "/repo"))
        XCTAssertThrowsError(try ProgrammingPathPolicy.projectRelativePath("/other/Secrets.txt", projectRoot: "/repo"))
        XCTAssertEqual(try ProgrammingPathPolicy.projectRelativePath("Sources/../Tests/Test.swift", projectRoot: "/repo"), "Tests/Test.swift")
        XCTAssertEqual(try ProgrammingPathPolicy.projectRelativePath("/repo/Sources/App.swift", projectRoot: "/repo"), "Sources/App.swift")
    }
}
