import Foundation
import SQLite3

// SQLite-backed structured memory. Kept as a ChatStore extension so sessions,
// checkpoints, projects and token calibration share one transaction boundary.
extension ChatStore {
    private static var memorySQLiteTransient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    func createStructuredMemoryTables() {
        guard let db else { return }
        sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        var committed = false
        defer { sqlite3_exec(db, committed ? "COMMIT" : "ROLLBACK", nil, nil, nil) }

        guard memoryExec("""
            CREATE TABLE IF NOT EXISTS memory_schema_migrations (
                version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at REAL NOT NULL
            )
            """),
        memoryExec("""
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                canonical_path TEXT NOT NULL UNIQUE,
                git_remote TEXT,
                current_branch TEXT,
                last_commit TEXT,
                language_stack TEXT NOT NULL DEFAULT '[]',
                toolchain_profile TEXT NOT NULL DEFAULT '[]',
                build_commands TEXT NOT NULL DEFAULT '[]',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """),
        memoryExec("""
            CREATE TABLE IF NOT EXISTS memories (
                id TEXT PRIMARY KEY,
                scope TEXT NOT NULL,
                type TEXT NOT NULL,
                project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
                key TEXT,
                content TEXT NOT NULL,
                source_session_id TEXT,
                source_message_id TEXT,
                source_refs TEXT NOT NULL DEFAULT '[]',
                confidence REAL NOT NULL DEFAULT 0.5,
                importance REAL NOT NULL DEFAULT 0.5,
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL,
                last_used_at REAL,
                expires_at REAL,
                supersedes_id TEXT REFERENCES memories(id),
                sensitivity TEXT NOT NULL DEFAULT 'normal',
                status TEXT NOT NULL DEFAULT 'active',
                is_pinned INTEGER NOT NULL DEFAULT 0,
                search_tokens TEXT NOT NULL DEFAULT '',
                version INTEGER NOT NULL DEFAULT 1
            )
            """),
        memoryExec("""
            CREATE TABLE IF NOT EXISTS task_checkpoints (
                id TEXT PRIMARY KEY,
                session_id TEXT NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
                project_id TEXT REFERENCES projects(id) ON DELETE SET NULL,
                goal TEXT NOT NULL,
                acceptance_criteria TEXT NOT NULL DEFAULT '[]',
                facts_constraints TEXT NOT NULL DEFAULT '[]',
                completed_steps TEXT NOT NULL DEFAULT '[]',
                changed_files TEXT NOT NULL DEFAULT '[]',
                commands_run TEXT NOT NULL DEFAULT '[]',
                test_results TEXT NOT NULL DEFAULT '[]',
                failures_blockers TEXT NOT NULL DEFAULT '[]',
                next_action TEXT NOT NULL DEFAULT '',
                source_marker_id TEXT,
                previous_checkpoint_id TEXT REFERENCES task_checkpoints(id),
                status TEXT NOT NULL DEFAULT 'active',
                created_at REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """),
        memoryExec("""
            CREATE TABLE IF NOT EXISTS token_budget_samples (
                id TEXT PRIMARY KEY,
                model_id TEXT NOT NULL,
                session_id TEXT,
                context_window INTEGER NOT NULL,
                system_tool_tokens INTEGER NOT NULL,
                checkpoint_memory_tokens INTEGER NOT NULL,
                recent_message_tokens INTEGER NOT NULL,
                code_log_tokens INTEGER NOT NULL,
                output_reserve INTEGER NOT NULL,
                estimated_input_tokens INTEGER NOT NULL,
                actual_input_tokens INTEGER NOT NULL,
                actual_output_tokens INTEGER NOT NULL,
                cache_read_tokens INTEGER NOT NULL,
                cache_write_tokens INTEGER NOT NULL,
                created_at REAL NOT NULL
            )
            """),
        memoryExec("""
            CREATE TABLE IF NOT EXISTS token_budget_calibrations (
                model_id TEXT PRIMARY KEY,
                sample_count INTEGER NOT NULL,
                estimated_input_total INTEGER NOT NULL,
                actual_input_total INTEGER NOT NULL,
                actual_output_total INTEGER NOT NULL,
                cache_read_total INTEGER NOT NULL,
                cache_write_total INTEGER NOT NULL,
                calibration_ratio REAL NOT NULL,
                updated_at REAL NOT NULL
            )
            """) else { return }

        ensureMemoryColumn(table: "sessions", name: "project_id", definition: "TEXT")
        ensureMemoryColumn(table: "compact_markers", name: "checkpoint_id", definition: "TEXT")
        let indexes = [
            "CREATE INDEX IF NOT EXISTS idx_projects_path ON projects(canonical_path)",
            "CREATE INDEX IF NOT EXISTS idx_memories_scope_project ON memories(scope, project_id, status, importance DESC)",
            "CREATE INDEX IF NOT EXISTS idx_memories_type_updated ON memories(type, updated_at DESC)",
            "CREATE INDEX IF NOT EXISTS idx_memories_expiry ON memories(expires_at)",
            "CREATE INDEX IF NOT EXISTS idx_checkpoints_session_updated ON task_checkpoints(session_id, updated_at DESC)",
            "CREATE INDEX IF NOT EXISTS idx_checkpoints_project_updated ON task_checkpoints(project_id, updated_at DESC)",
            "CREATE INDEX IF NOT EXISTS idx_token_samples_model_created ON token_budget_samples(model_id, created_at DESC)"
        ]
        guard indexes.allSatisfy(memoryExec) else { return }

        // iOS' system SQLite normally ships FTS5 but does not allow registering
        // cppjieba as an FTS tokenizer. Store jieba/NL pre-tokenized terms in a
        // unicode61 FTS table. If FTS5 is absent, CRUD/search falls back to the
        // same search_tokens column with LIKE, so migration remains usable.
        _ = memoryExec("CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(memory_id UNINDEXED, tokens, content, tokenize='unicode61')")
        guard memoryExec("INSERT OR IGNORE INTO memory_schema_migrations(version,name,applied_at) VALUES(1,'projects-memories-checkpoints',strftime('%s','now'))"),
              memoryExec("INSERT OR IGNORE INTO memory_schema_migrations(version,name,applied_at) VALUES(2,'pretokenized-fts5',strftime('%s','now'))"),
              memoryExec("INSERT OR IGNORE INTO memory_schema_migrations(version,name,applied_at) VALUES(3,'token-budget-calibration',strftime('%s','now'))") else { return }
        committed = true
    }

    private func memoryExec(_ sql: String) -> Bool {
        sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
    }

    private func ensureMemoryColumn(table: String, name: String, definition: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table))", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if String(cString: sqlite3_column_text(stmt, 1)) == name { return }
        }
        _ = memoryExec("ALTER TABLE \(table) ADD COLUMN \(name) \(definition)")
    }

    // MARK: Projects

    @discardableResult
    func upsertProject(_ evidence: ProjectEvidence, sessionId: String?) -> ProjectRecord? {
        guard !evidence.canonicalPath.isEmpty else { return nil }
        let existing = project(canonicalPath: evidence.canonicalPath)
        let now = Date()
        let merged = ProjectRecord(
            id: existing?.id ?? UUID().uuidString,
            canonicalPath: evidence.canonicalPath,
            gitRemote: evidence.remote ?? existing?.gitRemote,
            currentBranch: evidence.branch ?? existing?.currentBranch,
            lastCommit: evidence.commit ?? existing?.lastCommit,
            languageStack: merge(existing?.languageStack ?? [], evidence.stack),
            toolchainProfile: merge(existing?.toolchainProfile ?? [], evidence.toolchain),
            buildCommands: merge(existing?.buildCommands ?? [], evidence.buildCommands),
            createdAt: existing?.createdAt ?? now, updatedAt: now
        )
        let sql = """
        INSERT INTO projects(id,canonical_path,git_remote,current_branch,last_commit,language_stack,toolchain_profile,build_commands,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(canonical_path) DO UPDATE SET
        git_remote=excluded.git_remote,current_branch=excluded.current_branch,last_commit=excluded.last_commit,
        language_stack=excluded.language_stack,toolchain_profile=excluded.toolchain_profile,
        build_commands=excluded.build_commands,updated_at=excluded.updated_at
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(merged.id, 1, stmt); bind(merged.canonicalPath, 2, stmt); bind(merged.gitRemote, 3, stmt)
        bind(merged.currentBranch, 4, stmt); bind(merged.lastCommit, 5, stmt)
        bind(json(merged.languageStack), 6, stmt); bind(json(merged.toolchainProfile), 7, stmt)
        bind(json(merged.buildCommands), 8, stmt)
        sqlite3_bind_double(stmt, 9, merged.createdAt.timeIntervalSince1970)
        sqlite3_bind_double(stmt, 10, merged.updatedAt.timeIntervalSince1970)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return nil }
        if let sessionId { setSessionProject(sessionId: sessionId, projectId: merged.id) }
        return merged
    }

    func project(canonicalPath: String) -> ProjectRecord? {
        readProject(whereSQL: "canonical_path = ?", value: canonicalPath)
    }

    func project(id: String) -> ProjectRecord? {
        readProject(whereSQL: "id = ?", value: id)
    }

    func currentProject(sessionId: String) -> ProjectRecord? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT project_id FROM sessions WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(sessionId, 1, stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW, let id = text(stmt, 0) else { return nil }
        return project(id: id)
    }

    private func setSessionProject(sessionId: String, projectId: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE sessions SET project_id=? WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(projectId, 1, stmt); bind(sessionId, 2, stmt); sqlite3_step(stmt)
    }

    private func readProject(whereSQL: String, value: String) -> ProjectRecord? {
        let sql = "SELECT id,canonical_path,git_remote,current_branch,last_commit,language_stack,toolchain_profile,build_commands,created_at,updated_at FROM projects WHERE \(whereSQL) LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bind(value, 1, stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return ProjectRecord(id: text(stmt, 0) ?? "", canonicalPath: text(stmt, 1) ?? "",
            gitRemote: text(stmt, 2), currentBranch: text(stmt, 3), lastCommit: text(stmt, 4),
            languageStack: strings(text(stmt, 5)), toolchainProfile: strings(text(stmt, 6)),
            buildCommands: strings(text(stmt, 7)), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8)),
            updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)))
    }

    // MARK: Memories

    @discardableResult
    func saveStructuredMemory(_ memory: StructuredMemoryRecord) -> Bool {
        guard MemoryCredentialGuard.admits(memory.content) else { return false }
        var record = memory
        if let key = record.key, record.supersedesId == nil {
            record.supersedesId = activeMemoryId(scope: record.scope, projectId: record.projectId, key: key)
        }
        let tokens = memorySearchTokens(record.content + " " + (record.key ?? ""))
        let sql = """
        INSERT INTO memories(id,scope,type,project_id,key,content,source_session_id,source_message_id,source_refs,
        confidence,importance,created_at,updated_at,last_used_at,expires_at,supersedes_id,sensitivity,status,is_pinned,search_tokens,version)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,1)
        ON CONFLICT(id) DO UPDATE SET scope=excluded.scope,type=excluded.type,project_id=excluded.project_id,key=excluded.key,
        content=excluded.content,source_refs=excluded.source_refs,confidence=excluded.confidence,importance=excluded.importance,
        updated_at=excluded.updated_at,expires_at=excluded.expires_at,sensitivity=excluded.sensitivity,status=excluded.status,
        is_pinned=excluded.is_pinned,search_tokens=excluded.search_tokens
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        bind(record.id,1,stmt); bind(record.scope,2,stmt); bind(record.type,3,stmt); bind(record.projectId,4,stmt)
        bind(record.key,5,stmt); bind(record.content,6,stmt); bind(record.sourceSessionId,7,stmt)
        bind(record.sourceMessageId,8,stmt); bind(json(record.sourceRefs),9,stmt)
        sqlite3_bind_double(stmt,10,clamp(record.confidence)); sqlite3_bind_double(stmt,11,clamp(record.importance))
        sqlite3_bind_double(stmt,12,record.createdAt.timeIntervalSince1970); sqlite3_bind_double(stmt,13,record.updatedAt.timeIntervalSince1970)
        bind(record.lastUsedAt?.timeIntervalSince1970,14,stmt); bind(record.expiresAt?.timeIntervalSince1970,15,stmt)
        bind(record.supersedesId,16,stmt); bind(record.sensitivity,17,stmt); bind(record.status,18,stmt)
        sqlite3_bind_int(stmt,19,record.isPinned ? 1 : 0); bind(tokens,20,stmt)
        guard sqlite3_step(stmt) == SQLITE_DONE else { return false }
        if let old = record.supersedesId { setMemoryStatus(id: old, status: "superseded") }
        refreshMemoryFTS(id: record.id, tokens: tokens, content: record.content)
        NotificationCenter.default.post(name: .structuredMemoryDidChange, object: nil)
        return true
    }

    func searchStructuredMemories(query: String = "", projectId: String? = nil, limit: Int = 20,
                                  includeInactive: Bool = false) -> [StructuredMemoryRecord] {
        let terms = TextSegmenter.shared.segmentForSearch(query).map { $0.lowercased() }.filter { !$0.isEmpty }
        // Query the pre-tokenized FTS5 index first. A nil result means the
        // platform SQLite lacks FTS5 (or the table is unavailable), in which
        // case the same tokens fall back to bounded LIKE matching. An empty
        // non-nil result is an authoritative no-match and avoids a full scan.
        let ftsIDs = terms.isEmpty ? nil : memoryFTSCandidates(terms: terms, limit: max(limit * 8, 64))
        if let ftsIDs, ftsIDs.isEmpty { return [] }

        var sql = "SELECT id,scope,type,project_id,key,content,source_session_id,source_message_id,source_refs,confidence,importance,created_at,updated_at,last_used_at,expires_at,supersedes_id,sensitivity,status,is_pinned FROM memories WHERE 1=1"
        if !includeInactive { sql += " AND status='active' AND (expires_at IS NULL OR expires_at > strftime('%s','now'))" }
        if let ftsIDs {
            sql += " AND id IN (" + Array(repeating: "?", count: ftsIDs.count).joined(separator: ",") + ")"
        } else if !terms.isEmpty {
            sql += " AND " + terms.map { _ in "(search_tokens LIKE ? OR content LIKE ?)" }.joined(separator: " AND ")
        }
        sql += " ORDER BY is_pinned DESC, importance DESC, updated_at DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        if let ftsIDs {
            for id in ftsIDs { bind(id, idx, stmt); idx += 1 }
        } else {
            for term in terms { bind("%\(term)%",idx,stmt); idx += 1; bind("%\(term)%",idx,stmt); idx += 1 }
        }
        sqlite3_bind_int(stmt, idx, Int32(max(limit * 4, limit)))
        var scored: [(Double, StructuredMemoryRecord)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let item = readMemory(stmt)
            let projectBoost = projectId != nil && item.projectId == projectId ? 1.0 : (item.scope == "user" || item.scope == "procedure" ? 0.35 : 0)
            if projectId != nil && item.projectId != nil && item.projectId != projectId { continue }
            let ageDays = max(0, Date().timeIntervalSince(item.updatedAt) / 86_400)
            let decay = exp(-ageDays / 90)
            let score = projectBoost + item.importance * 1.3 + item.confidence * 0.7 + decay * 0.6 + (item.isPinned ? 2 : 0)
            scored.append((score, item))
        }
        let result = scored.sorted { $0.0 > $1.0 }.prefix(limit).map(\.1)
        for item in result { touchMemory(id: item.id) }
        return result
    }

    func structuredMemory(id: String) -> StructuredMemoryRecord? {
        var stmt: OpaquePointer?
        let sql = "SELECT id,scope,type,project_id,key,content,source_session_id,source_message_id,source_refs,confidence,importance,created_at,updated_at,last_used_at,expires_at,supersedes_id,sensitivity,status,is_pinned FROM memories WHERE id=?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }; bind(id,1,stmt)
        return sqlite3_step(stmt) == SQLITE_ROW ? readMemory(stmt) : nil
    }

    func setMemoryPinned(id: String, pinned: Bool) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,"UPDATE memories SET is_pinned=?,updated_at=? WHERE id=?",-1,&stmt,nil)==SQLITE_OK else{return}
        defer{sqlite3_finalize(stmt)}; sqlite3_bind_int(stmt,1,pinned ? 1:0); sqlite3_bind_double(stmt,2,Date().timeIntervalSince1970); bind(id,3,stmt); sqlite3_step(stmt)
        NotificationCenter.default.post(name: .structuredMemoryDidChange, object: nil)
    }

    func deleteStructuredMemory(id: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db,"DELETE FROM memories WHERE id=?",-1,&stmt,nil)==SQLITE_OK else{return}
        defer{sqlite3_finalize(stmt)}; bind(id,1,stmt); sqlite3_step(stmt)
        var fts: OpaquePointer?; if sqlite3_prepare_v2(db,"DELETE FROM memories_fts WHERE memory_id=?",-1,&fts,nil)==SQLITE_OK { bind(id,1,fts); sqlite3_step(fts) }; sqlite3_finalize(fts)
        NotificationCenter.default.post(name: .structuredMemoryDidChange, object: nil)
    }

    private func activeMemoryId(scope: String, projectId: String?, key: String) -> String? {
        var stmt: OpaquePointer?
        let sql = "SELECT id FROM memories WHERE scope=? AND key=? AND status='active' AND ((project_id IS NULL AND ? IS NULL) OR project_id=?) ORDER BY updated_at DESC LIMIT 1"
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK else{return nil}; defer{sqlite3_finalize(stmt)}
        bind(scope,1,stmt); bind(key,2,stmt); bind(projectId,3,stmt); bind(projectId,4,stmt)
        return sqlite3_step(stmt)==SQLITE_ROW ? text(stmt,0):nil
    }

    private func setMemoryStatus(id: String, status: String) {
        var stmt: OpaquePointer?; guard sqlite3_prepare_v2(db,"UPDATE memories SET status=?,updated_at=? WHERE id=?",-1,&stmt,nil)==SQLITE_OK else{return}; defer{sqlite3_finalize(stmt)}
        bind(status,1,stmt); sqlite3_bind_double(stmt,2,Date().timeIntervalSince1970); bind(id,3,stmt); sqlite3_step(stmt)
    }

    private func touchMemory(id: String) {
        var stmt: OpaquePointer?; guard sqlite3_prepare_v2(db,"UPDATE memories SET last_used_at=? WHERE id=?",-1,&stmt,nil)==SQLITE_OK else{return}; defer{sqlite3_finalize(stmt)}
        sqlite3_bind_double(stmt,1,Date().timeIntervalSince1970); bind(id,2,stmt); sqlite3_step(stmt)
    }

    /// Returns nil when FTS5 is unavailable so callers can use LIKE fallback.
    private func memoryFTSCandidates(terms: [String], limit: Int) -> [String]? {
        guard !terms.isEmpty else { return [] }
        let escaped = terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let match = escaped.joined(separator: " AND ")
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT memory_id FROM memories_fts WHERE memories_fts MATCH ? LIMIT ?", -1, &stmt, nil) == SQLITE_OK else {
            sqlite3_finalize(stmt)
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        bind(match, 1, stmt)
        sqlite3_bind_int(stmt, 2, Int32(max(1, limit)))
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let id = text(stmt, 0) { ids.append(id) }
        }
        return ids
    }

    private func refreshMemoryFTS(id: String, tokens: String, content: String) {
        var del: OpaquePointer?
        guard sqlite3_prepare_v2(db,"DELETE FROM memories_fts WHERE memory_id=?",-1,&del,nil)==SQLITE_OK else{return}
        bind(id,1,del); sqlite3_step(del); sqlite3_finalize(del)
        var ins: OpaquePointer?
        guard sqlite3_prepare_v2(db,"INSERT INTO memories_fts(memory_id,tokens,content) VALUES(?,?,?)",-1,&ins,nil)==SQLITE_OK else{return}
        defer{sqlite3_finalize(ins)}; bind(id,1,ins); bind(tokens,2,ins); bind(content,3,ins); sqlite3_step(ins)
    }

    private func readMemory(_ stmt: OpaquePointer?) -> StructuredMemoryRecord {
        StructuredMemoryRecord(id:text(stmt,0) ?? "",scope:text(stmt,1) ?? "user",type:text(stmt,2) ?? "fact",
            projectId:text(stmt,3),key:text(stmt,4),content:text(stmt,5) ?? "",sourceSessionId:text(stmt,6),sourceMessageId:text(stmt,7),
            sourceRefs:strings(text(stmt,8)),confidence:sqlite3_column_double(stmt,9),importance:sqlite3_column_double(stmt,10),
            createdAt:Date(timeIntervalSince1970:sqlite3_column_double(stmt,11)),updatedAt:Date(timeIntervalSince1970:sqlite3_column_double(stmt,12)),
            lastUsedAt:date(stmt,13),expiresAt:date(stmt,14),supersedesId:text(stmt,15),sensitivity:text(stmt,16) ?? "normal",
            status:text(stmt,17) ?? "active",isPinned:sqlite3_column_int(stmt,18) != 0)
    }

    private func memorySearchTokens(_ content: String) -> String {
        Array(Set(TextSegmenter.shared.segmentForSearch(content).map { $0.lowercased() })).sorted().joined(separator: " ")
    }

    // MARK: Checkpoints

    func saveTaskCheckpoint(_ checkpoint: TaskCheckpoint) {
        let sql = """
        INSERT OR REPLACE INTO task_checkpoints(id,session_id,project_id,goal,acceptance_criteria,facts_constraints,completed_steps,changed_files,commands_run,test_results,failures_blockers,next_action,source_marker_id,previous_checkpoint_id,status,created_at,updated_at)
        VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
        """
        var stmt: OpaquePointer?; guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK else{return}; defer{sqlite3_finalize(stmt)}
        bind(checkpoint.id,1,stmt);bind(checkpoint.sessionId,2,stmt);bind(checkpoint.projectId,3,stmt);bind(checkpoint.goal,4,stmt)
        bind(json(checkpoint.acceptanceCriteria),5,stmt);bind(json(checkpoint.factsAndConstraints),6,stmt);bind(json(checkpoint.completedSteps),7,stmt)
        bind(json(checkpoint.changedFiles),8,stmt);bind(json(checkpoint.commandsRun),9,stmt);bind(json(checkpoint.testResults),10,stmt)
        bind(json(checkpoint.failuresAndBlockers),11,stmt);bind(checkpoint.nextAction,12,stmt);bind(checkpoint.sourceMarkerId,13,stmt)
        bind(checkpoint.previousCheckpointId,14,stmt);bind(checkpoint.status,15,stmt);sqlite3_bind_double(stmt,16,checkpoint.createdAt.timeIntervalSince1970);sqlite3_bind_double(stmt,17,checkpoint.updatedAt.timeIntervalSince1970);sqlite3_step(stmt)
    }

    func linkTaskCheckpoint(_ checkpointId: String, toCompactMarker markerId: String) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE compact_markers SET checkpoint_id=? WHERE id=?", -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bind(checkpointId, 1, stmt)
        bind(markerId, 2, stmt)
        sqlite3_step(stmt)
    }

    func latestTaskCheckpoint(sessionId: String, projectId: String? = nil) -> TaskCheckpoint? {
        var sql = "SELECT id,session_id,project_id,goal,acceptance_criteria,facts_constraints,completed_steps,changed_files,commands_run,test_results,failures_blockers,next_action,source_marker_id,previous_checkpoint_id,status,created_at,updated_at FROM task_checkpoints WHERE session_id=?"
        if projectId != nil { sql += " OR project_id=?" }
        sql += " ORDER BY CASE WHEN session_id=? THEN 0 ELSE 1 END, updated_at DESC LIMIT 1"
        var stmt: OpaquePointer?;guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK else{return nil};defer{sqlite3_finalize(stmt)}
        bind(sessionId,1,stmt);var idx:Int32=2;if let projectId{bind(projectId,idx,stmt);idx += 1};bind(sessionId,idx,stmt)
        guard sqlite3_step(stmt)==SQLITE_ROW else{return nil}
        return TaskCheckpoint(id:text(stmt,0) ?? "",sessionId:text(stmt,1) ?? sessionId,projectId:text(stmt,2),goal:text(stmt,3) ?? "",
            acceptanceCriteria:strings(text(stmt,4)),factsAndConstraints:strings(text(stmt,5)),completedSteps:strings(text(stmt,6)),
            changedFiles:strings(text(stmt,7)),commandsRun:strings(text(stmt,8)),testResults:strings(text(stmt,9)),
            failuresAndBlockers:strings(text(stmt,10)),nextAction:text(stmt,11) ?? "",sourceMarkerId:text(stmt,12),previousCheckpointId:text(stmt,13),
            status:text(stmt,14) ?? "active",createdAt:Date(timeIntervalSince1970:sqlite3_column_double(stmt,15)),updatedAt:Date(timeIntervalSince1970:sqlite3_column_double(stmt,16)))
    }

    // MARK: Token budget calibration

    func recordTokenBudgetSample(_ snapshot: TokenBudgetSnapshot, sessionId: String?, actualInput: Int,
                                 actualOutput: Int, cacheRead: Int, cacheWrite: Int) {
        guard actualInput > 0 else { return }
        let now=Date().timeIntervalSince1970;let id=UUID().uuidString
        var stmt:OpaquePointer?;let sql="INSERT INTO token_budget_samples VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)"
        guard sqlite3_prepare_v2(db,sql,-1,&stmt,nil)==SQLITE_OK else{return};defer{sqlite3_finalize(stmt)}
        bind(id,1,stmt);bind(snapshot.modelId,2,stmt);bind(sessionId,3,stmt);sqlite3_bind_int64(stmt,4,Int64(snapshot.contextWindow));sqlite3_bind_int64(stmt,5,Int64(snapshot.systemAndTools));sqlite3_bind_int64(stmt,6,Int64(snapshot.checkpointAndMemory));sqlite3_bind_int64(stmt,7,Int64(snapshot.recentMessages));sqlite3_bind_int64(stmt,8,Int64(snapshot.codeAndLogs));sqlite3_bind_int64(stmt,9,Int64(snapshot.outputReserve));sqlite3_bind_int64(stmt,10,Int64(snapshot.estimatedInput));sqlite3_bind_int64(stmt,11,Int64(actualInput));sqlite3_bind_int64(stmt,12,Int64(actualOutput));sqlite3_bind_int64(stmt,13,Int64(cacheRead));sqlite3_bind_int64(stmt,14,Int64(cacheWrite));sqlite3_bind_double(stmt,15,now);
        guard sqlite3_step(stmt)==SQLITE_DONE else{return}
        let ratio = Double(actualInput) / Double(max(snapshot.estimatedInput,1))
        let up="""
        INSERT INTO token_budget_calibrations VALUES(?,1,?,?,?,?,?, ?,?)
        ON CONFLICT(model_id) DO UPDATE SET sample_count=sample_count+1,estimated_input_total=estimated_input_total+excluded.estimated_input_total,actual_input_total=actual_input_total+excluded.actual_input_total,actual_output_total=actual_output_total+excluded.actual_output_total,cache_read_total=cache_read_total+excluded.cache_read_total,cache_write_total=cache_write_total+excluded.cache_write_total,calibration_ratio=(calibration_ratio*0.75)+(excluded.calibration_ratio*0.25),updated_at=excluded.updated_at
        """
        var u:OpaquePointer?;guard sqlite3_prepare_v2(db,up,-1,&u,nil)==SQLITE_OK else{return};defer{sqlite3_finalize(u)}
        bind(snapshot.modelId,1,u);sqlite3_bind_int64(u,2,Int64(snapshot.estimatedInput));sqlite3_bind_int64(u,3,Int64(actualInput));sqlite3_bind_int64(u,4,Int64(actualOutput));sqlite3_bind_int64(u,5,Int64(cacheRead));sqlite3_bind_int64(u,6,Int64(cacheWrite));sqlite3_bind_double(u,7,ratio);sqlite3_bind_double(u,8,now);sqlite3_step(u)
    }

    // MARK: SQLite helpers

    private func bind(_ value: String?, _ index: Int32, _ stmt: OpaquePointer?) { if let value { sqlite3_bind_text(stmt,index,(value as NSString).utf8String,-1,Self.memorySQLiteTransient) } else { sqlite3_bind_null(stmt,index) } }
    private func bind(_ value: Double?, _ index: Int32, _ stmt: OpaquePointer?) { if let value { sqlite3_bind_double(stmt,index,value) } else { sqlite3_bind_null(stmt,index) } }
    private func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? { guard sqlite3_column_type(stmt,index) != SQLITE_NULL,let p=sqlite3_column_text(stmt,index) else{return nil};return String(cString:p) }
    private func date(_ stmt: OpaquePointer?, _ index: Int32) -> Date? { sqlite3_column_type(stmt,index)==SQLITE_NULL ? nil:Date(timeIntervalSince1970:sqlite3_column_double(stmt,index)) }
    private func strings(_ value: String?) -> [String] { guard let d=value?.data(using:.utf8) else{return[]};return (try? JSONDecoder().decode([String].self,from:d)) ?? [] }
    private func json(_ value: [String]) -> String { guard let d=try? JSONEncoder().encode(value) else{return"[]"};return String(data:d,encoding:.utf8) ?? "[]" }
    private func merge(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen = Set<String>()
        return (lhs + rhs).filter { seen.insert($0).inserted }
    }
    private func clamp(_ value:Double)->Double{min(1,max(0,value))}
}

extension Notification.Name {
    static let structuredMemoryDidChange = Notification.Name("com.openminis.app.structuredMemoryDidChange")
}
