import XCTest
@testable import Minis

final class StructuredMemoryTests: XCTestCase {
    func testCredentialAdmissionRejectsSecrets() {
        XCTAssertFalse(MemoryCredentialGuard.admits("api_key=super-secret-value"))
        XCTAssertFalse(MemoryCredentialGuard.admits("Authorization: Bearer abcdefghijklmnopqrstuvwxyz"))
        XCTAssertTrue(MemoryCredentialGuard.admits("Build succeeded at commit 0123456789abcdef"))
        XCTAssertFalse(AutoMemoryAdmission.admits(content: "ordinary chat", origin: .ordinaryConversation, autoMemoryEnabled: true))
    }

    func testCheckpointCodecPreservesRecoveryFields() {
        let markdown = """
        ## Goal
        Ship the feature
        ## Acceptance Criteria
        - Tests pass
        ## Facts & Constraints
        - iOS 15
        ## Completed Steps
        - Added schema
        ## Changed Files
        - Store.swift
        ## Commands Run
        - swift test
        ## Test Results
        - PASS
        ## Failures & Blockers
        - None
        ## Next Action
        - Build IPA
        """
        let checkpoint = StructuredCheckpointCodec.parse(markdown, sessionId: "s", projectId: "p", sourceMarkerId: "m")
        XCTAssertEqual(checkpoint.goal, "Ship the feature")
        XCTAssertEqual(checkpoint.changedFiles, ["Store.swift"])
        XCTAssertEqual(checkpoint.commandsRun, ["swift test"])
        XCTAssertEqual(checkpoint.nextAction, "Build IPA")
        XCTAssertTrue(StructuredCheckpointCodec.render(checkpoint).contains("## Failures & Blockers"))
    }

    func testTokenBudgetReservesOutputAndStaysBounded() {
        let budget = TokenBudgetManager.allocation(contextWindow: 100_000, modelId: "test")
        XCTAssertGreaterThanOrEqual(budget.outputReserve, 2_048)
        XCTAssertLessThanOrEqual(budget.estimatedInput + budget.outputReserve, 100_000)
        XCTAssertGreaterThan(budget.checkpointAndMemory, 0)
    }

    func testProjectScopeDetectorCapturesCanonicalPathAndBranch() {
        let evidence = ProjectScopeDetector.detect(
            command: "cd '/var/minis/workspace/My Project' && git status --short --branch",
            output: "## ios15-port...origin/ios15-port\n")
        XCTAssertEqual(evidence?.canonicalPath, "/var/minis/workspace/My Project")
        XCTAssertEqual(evidence?.branch, "ios15-port")
    }

    func testProjectSearchDoesNotMixScopes() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(baseURL: root)
        let a = await store.upsertProject(ProjectEvidence(canonicalPath: "/tmp/a", remote: nil, branch: "a", commit: nil, buildCommands: [], stack: [], toolchain: []), sessionId: nil)
        let b = await store.upsertProject(ProjectEvidence(canonicalPath: "/tmp/b", remote: nil, branch: "b", commit: nil, buildCommands: [], stack: [], toolchain: []), sessionId: nil)
        guard let a, let b else { XCTFail("project migration/upsert failed"); return }
        let now = Date()
        for (project, content) in [(a, "alpha project fact"), (b, "beta project fact")] {
            let record = StructuredMemoryRecord(id: UUID().uuidString, scope: "project", type: "fact", projectId: project.id,
                key: nil, content: content, sourceSessionId: nil, sourceMessageId: nil, sourceRefs: [], confidence: 1,
                importance: 1, createdAt: now, updatedAt: now, lastUsedAt: nil, expiresAt: nil,
                supersedesId: nil, sensitivity: "normal", status: "active", isPinned: false)
            let saved = await store.saveStructuredMemory(record)
            XCTAssertTrue(saved)
        }
        let scoped = await store.searchStructuredMemories(projectId: a.id, limit: 10)
        XCTAssertTrue(scoped.contains { $0.content.contains("alpha") })
        XCTAssertFalse(scoped.contains { $0.content.contains("beta") })
        let unscoped = await store.searchStructuredMemories(limit: 10)
        XCTAssertFalse(unscoped.contains { $0.projectId != nil })
    }

    func testFTSChineseSearchAndSupersession() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = ChatStore(baseURL: root)
        let now = Date()
        let old = StructuredMemoryRecord(id: UUID().uuidString, scope: "project", type: "procedure", projectId: nil,
            key: "build.command", content: "使用旧命令编译项目", sourceSessionId: nil, sourceMessageId: nil,
            sourceRefs: ["/tmp/project"], confidence: 0.8, importance: 0.8, createdAt: now, updatedAt: now,
            lastUsedAt: nil, expiresAt: nil, supersedesId: nil, sensitivity: "normal", status: "active", isPinned: false)
        let oldSaved = await store.saveStructuredMemory(old)
        XCTAssertTrue(oldSaved)
        let newer = StructuredMemoryRecord(id: UUID().uuidString, scope: old.scope, type: old.type, projectId: nil,
            key: old.key, content: "使用 make package 编译越狱插件", sourceSessionId: nil, sourceMessageId: nil,
            sourceRefs: old.sourceRefs, confidence: 0.95, importance: 0.9, createdAt: now, updatedAt: now,
            lastUsedAt: nil, expiresAt: nil, supersedesId: nil, sensitivity: "normal", status: "active", isPinned: false)
        let newerSaved = await store.saveStructuredMemory(newer)
        XCTAssertTrue(newerSaved)
        let hits = await store.searchStructuredMemories(query: "编译 越狱插件", limit: 10)
        XCTAssertEqual(hits.first?.id, newer.id)
        let oldReloaded = await store.structuredMemory(id: old.id)
        let newerReloaded = await store.structuredMemory(id: newer.id)
        XCTAssertEqual(oldReloaded?.status, "superseded")
        XCTAssertEqual(newerReloaded?.supersedesId, old.id)
    }
}
