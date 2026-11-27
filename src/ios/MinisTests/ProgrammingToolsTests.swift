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

    func testSearchCountsOnlyWholeQueryTokensIgnoringCase() {
        let counts = ProgrammingSearchWorker.queryTokenCounts(
            in: "Minis MINIS minis_ui; 页面 页面 ignored m", terms: ["minis", "minis_ui", "页面", "m"]
        )
        XCTAssertEqual(counts, ["minis": 2, "minis_ui": 1, "页面": 2])
    }

    func testSearchKeepsExistingTokenLimit() {
        let text = String(repeating: "x noise ", count: 199_999) + "match match"
        let counts = ProgrammingSearchWorker.queryTokenCounts(in: text, terms: ["match"])
        XCTAssertEqual(counts, ["match": 1])
    }

    func testSearchTokenCountsMatchReferenceWithUnicodeAndTrailingToken() {
        let text = "ΟΣ, ΟΣ! CAFÉ Cafe\u{301} 👩‍💻 ;; 123 _x Z last"
        let terms: Set<String> = ["ος", "οσ", "café", "123", "_x", "z", "last"]
        let reference = text.lowercased().split { !$0.isLetter && !$0.isNumber && $0 != "_" }
            .filter { $0.count > 1 }.map(String.init).filter { terms.contains($0) }
        XCTAssertEqual(ProgrammingSearchWorker.queryTokenCounts(in: text, terms: terms),
                       Dictionary(grouping: reference, by: { $0 }).mapValues { $0.count })
    }

    func testIndexReusesUnchangedSnapshotAndUpdatesRemovedFiles() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("Fixture.swift")
        let index = directory.appendingPathComponent("index.json")
        try "struct Fixture {}".write(to: source, atomically: true, encoding: .utf8)
        let worker = ProgrammingSearchWorker()
        let first = try await worker.refreshIndex(root: directory.path, rootURL: directory, commit: "first", indexURL: index, force: false)
        let bytes = try Data(contentsOf: index)
        let unchanged = try await worker.refreshIndex(root: directory.path, rootURL: directory, commit: "first", indexURL: index, force: false)
        XCTAssertEqual(unchanged.generatedAt, first.generatedAt)
        XCTAssertEqual(try Data(contentsOf: index), bytes)
        XCTAssertEqual(first.files.count, 1)
        try FileManager.default.removeItem(at: source)
        let removed = try await worker.refreshIndex(root: directory.path, rootURL: directory, commit: "first", indexURL: index, force: false)
        XCTAssertTrue(removed.files.isEmpty)
        let moved = try await worker.refreshIndex(root: directory.path, rootURL: directory, commit: "second", indexURL: index, force: false)
        XCTAssertEqual(moved.commit, "second")
    }

    func testRelativePathRejectsProjectEscape() throws {
        XCTAssertThrowsError(try ProgrammingPathPolicy.projectRelativePath("../Secrets.txt", projectRoot: "/repo"))
        XCTAssertThrowsError(try ProgrammingPathPolicy.projectRelativePath("/other/Secrets.txt", projectRoot: "/repo"))
        XCTAssertEqual(try ProgrammingPathPolicy.projectRelativePath("Sources/../Tests/Test.swift", projectRoot: "/repo"), "Tests/Test.swift")
        XCTAssertEqual(try ProgrammingPathPolicy.projectRelativePath("/repo/Sources/App.swift", projectRoot: "/repo"), "Sources/App.swift")
    }
}
