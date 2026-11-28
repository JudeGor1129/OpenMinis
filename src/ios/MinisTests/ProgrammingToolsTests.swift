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

    func testCodeIndexWorkerRefreshesIncrementallyOffMainActor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodeIndexWorker-\(UUID().uuidString)", isDirectory: true)
        let index = root.appendingPathComponent("cache/index.json")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = root.appendingPathComponent("Alpha.swift")
        try "struct Alpha {}\n".write(to: source, atomically: true, encoding: .utf8)
        let first = try await CodeIndexWorker.refresh(rootURL: root, projectPath: root.path,
            commit: "test", indexURL: index, force: true, extensions: ["swift"])
        let workerRanOnMainThread = await CodeIndexWorker.isRunningOnMainThread
        XCTAssertFalse(workerRanOnMainThread, "project enumeration and indexing must not execute on the UI actor")
        XCTAssertEqual(first.files.count, 1)
        XCTAssertTrue(first.files["Alpha.swift"]?.symbols.contains { $0.name == "Alpha" } == true)
        let firstHash = first.files["Alpha.swift"]?.hash

        try "struct Beta {}\n".write(to: source, atomically: true, encoding: .utf8)
        let added = root.appendingPathComponent("Gamma.swift")
        try "func gamma() {}\n".write(to: added, atomically: true, encoding: .utf8)
        let second = try await CodeIndexWorker.refresh(rootURL: root, projectPath: root.path,
            commit: "test", indexURL: index, force: false, extensions: ["swift"])
        XCTAssertEqual(second.files.count, 2)
        XCTAssertNotEqual(second.files["Alpha.swift"]?.hash, firstHash)
        XCTAssertTrue(second.files["Alpha.swift"]?.symbols.contains { $0.name == "Beta" } == true)
        XCTAssertTrue(second.files["Gamma.swift"]?.symbols.contains { $0.name == "gamma" } == true)

        try FileManager.default.removeItem(at: source)
        let third = try await CodeIndexWorker.refresh(rootURL: root, projectPath: root.path,
            commit: "test", indexURL: index, force: false, extensions: ["swift"])
        XCTAssertNil(third.files["Alpha.swift"])
        XCTAssertNotNil(third.files["Gamma.swift"])
    }

    func testRelativePathRejectsProjectEscape() throws {
        XCTAssertThrowsError(try ProgrammingPathPolicy.projectRelativePath("../Secrets.txt", projectRoot: "/repo"))
        XCTAssertThrowsError(try ProgrammingPathPolicy.projectRelativePath("/other/Secrets.txt", projectRoot: "/repo"))
        XCTAssertEqual(try ProgrammingPathPolicy.projectRelativePath("Sources/../Tests/Test.swift", projectRoot: "/repo"), "Tests/Test.swift")
        XCTAssertEqual(try ProgrammingPathPolicy.projectRelativePath("/repo/Sources/App.swift", projectRoot: "/repo"), "Sources/App.swift")
    }
}
