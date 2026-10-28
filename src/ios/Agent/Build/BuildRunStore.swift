import Foundation
import SQLite3

struct PersistedBuildRun: Sendable {
    let id: String
    let projectPath: String
    let gitCommit: String?
    let configuration: String
    let toolchain: String
    let provider: String
    let cacheFingerprint: String
    let cacheHit: Bool
    let sourceRunID: String?
    let command: String?
    let exitCode: Int?
    let buildState: BuildState
    let testsExitCode: Int?
    let testsState: TestState
    let diagnosticsJSON: String
    let artifactPath: String?
    let artifactJSON: String
    let artifactState: ArtifactState?
    let logPath: String?
    let duration: Double
    let resultJSON: String
    let createdAt: Date
}

struct CachedBuildRun: Sendable {
    let id: String
    let result: BuildToolResult
}

actor BuildRunStore {
    static let shared = BuildRunStore()

    private let databaseURL: URL
    private var database: OpaquePointer?
    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(databaseURL: URL? = nil) {
        if let databaseURL {
            self.databaseURL = databaseURL
        } else {
            // Share the existing ChatStore SQLite file. A separate connection is
            // safe under WAL and keeps this module independent of ChatStore's
            // actor interface while still making build_runs part of the app's
            // normal database backup/migration lifecycle.
            let base = ContainerLocator.libraryDirectory
                .appendingPathComponent("MinisChat", isDirectory: true)
            self.databaseURL = base.appendingPathComponent("minis.db")
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    /// Idempotent migration. It supports the proposal's original narrow
    /// build_runs table by adding columns only when absent, and can run on every launch.
    func migrate() throws {
        try openIfNeeded()
        try execute("""
        CREATE TABLE IF NOT EXISTS build_runs (
          id TEXT PRIMARY KEY,
          project_id TEXT,
          project_path TEXT NOT NULL,
          git_commit TEXT,
          configuration TEXT NOT NULL,
          toolchain TEXT NOT NULL,
          provider TEXT NOT NULL DEFAULT 'local_ish',
          cache_fingerprint TEXT NOT NULL DEFAULT '',
          cache_hit INTEGER NOT NULL DEFAULT 0,
          source_run_id TEXT,
          command TEXT,
          exit_code INTEGER,
          build_status TEXT NOT NULL DEFAULT 'not_run',
          tests_exit_code INTEGER,
          tests_status TEXT NOT NULL DEFAULT 'not_run',
          diagnostics_json TEXT NOT NULL DEFAULT '{}',
          artifact_path TEXT,
          artifact_json TEXT NOT NULL DEFAULT '[]',
          artifact_status TEXT,
          log_path TEXT,
          duration REAL NOT NULL DEFAULT 0,
          result_json TEXT NOT NULL DEFAULT '{}',
          created_at REAL NOT NULL
        );
        """)
        let columns: [(String, String)] = [
            ("project_id", "TEXT"),
            ("project_path", "TEXT NOT NULL DEFAULT ''"),
            ("git_commit", "TEXT"),
            ("configuration", "TEXT NOT NULL DEFAULT 'Debug'"),
            ("toolchain", "TEXT NOT NULL DEFAULT 'auto'"),
            ("provider", "TEXT NOT NULL DEFAULT 'local_ish'"),
            ("cache_fingerprint", "TEXT NOT NULL DEFAULT ''"),
            ("cache_hit", "INTEGER NOT NULL DEFAULT 0"),
            ("source_run_id", "TEXT"),
            ("command", "TEXT"),
            ("exit_code", "INTEGER"),
            ("build_status", "TEXT NOT NULL DEFAULT 'not_run'"),
            ("tests_exit_code", "INTEGER"),
            ("tests_status", "TEXT NOT NULL DEFAULT 'not_run'"),
            ("diagnostics_json", "TEXT NOT NULL DEFAULT '{}'"),
            ("artifact_path", "TEXT"),
            ("artifact_json", "TEXT NOT NULL DEFAULT '[]'"),
            ("artifact_status", "TEXT"),
            ("log_path", "TEXT"),
            ("duration", "REAL NOT NULL DEFAULT 0"),
            ("result_json", "TEXT NOT NULL DEFAULT '{}'"),
            ("created_at", "REAL NOT NULL DEFAULT 0"),
        ]
        for (name, definition) in columns {
            if try !hasColumn(name, table: "build_runs") {
                try execute("ALTER TABLE build_runs ADD COLUMN \(name) \(definition);")
            }
        }
        try execute("CREATE INDEX IF NOT EXISTS idx_build_runs_fingerprint ON build_runs(cache_fingerprint, provider, build_status, created_at DESC);")
        try execute("CREATE INDEX IF NOT EXISTS idx_build_runs_project_time ON build_runs(project_path, created_at DESC);")
        try execute("CREATE TABLE IF NOT EXISTS programming_schema_migrations (version INTEGER PRIMARY KEY, applied_at REAL NOT NULL);")
        try execute("INSERT OR IGNORE INTO programming_schema_migrations(version, applied_at) VALUES (1, strftime('%s','now'));")
    }

    func insert(_ run: PersistedBuildRun) throws {
        try migrate()
        let sql = """
        INSERT INTO build_runs (
          id, project_id, project_path, git_commit, configuration, toolchain, provider,
          cache_fingerprint, cache_hit, source_run_id, command, exit_code,
          build_status, tests_exit_code, tests_status, diagnostics_json,
          artifact_path, artifact_json, artifact_status, log_path, duration,
          result_json, created_at
        ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?);
        """
        guard let database else { throw SQLiteBuildRunError.notOpen }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw lastError()
        }
        defer { sqlite3_finalize(statement) }
        bind(run.id, at: 1, statement: statement)
        bind(run.projectPath, at: 2, statement: statement) // canonical path is the project identity
        bind(run.projectPath, at: 3, statement: statement)
        bind(run.gitCommit, at: 4, statement: statement)
        bind(run.configuration, at: 5, statement: statement)
        bind(run.toolchain, at: 6, statement: statement)
        bind(run.provider, at: 7, statement: statement)
        bind(run.cacheFingerprint, at: 8, statement: statement)
        sqlite3_bind_int(statement, 9, run.cacheHit ? 1 : 0)
        bind(run.sourceRunID, at: 10, statement: statement)
        bind(run.command, at: 11, statement: statement)
        bind(run.exitCode, at: 12, statement: statement)
        bind(run.buildState.rawValue, at: 13, statement: statement)
        bind(run.testsExitCode, at: 14, statement: statement)
        bind(run.testsState.rawValue, at: 15, statement: statement)
        bind(run.diagnosticsJSON, at: 16, statement: statement)
        bind(run.artifactPath, at: 17, statement: statement)
        bind(run.artifactJSON, at: 18, statement: statement)
        bind(run.artifactState?.rawValue, at: 19, statement: statement)
        bind(run.logPath, at: 20, statement: statement)
        sqlite3_bind_double(statement, 21, run.duration)
        bind(run.resultJSON, at: 22, statement: statement)
        sqlite3_bind_double(statement, 23, run.createdAt.timeIntervalSince1970)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw lastError() }
    }

    func cachedSuccess(fingerprint: String, provider: BuildProviderID) throws -> CachedBuildRun? {
        try migrate()
        guard let database else { throw SQLiteBuildRunError.notOpen }
        let sql = """
        SELECT id, result_json FROM build_runs
        WHERE cache_fingerprint = ? AND provider = ? AND build_status = 'success'
        ORDER BY created_at DESC LIMIT 1;
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        bind(fingerprint, at: 1, statement: statement)
        bind(provider.rawValue, at: 2, statement: statement)
        guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
        let id = columnText(statement, index: 0) ?? ""
        guard let json = columnText(statement, index: 1),
              let data = json.data(using: .utf8) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let result = try? decoder.decode(BuildToolResult.self, from: data) else { return nil }
        return CachedBuildRun(id: id, result: result)
    }

    func count() throws -> Int {
        try migrate()
        guard let database else { throw SQLiteBuildRunError.notOpen }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT count(*) FROM build_runs", -1, &statement, nil) == SQLITE_OK, let statement else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw lastError() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func openIfNeeded() throws {
        if database != nil { return }
        try FileManager.default.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var opened: OpaquePointer?
        let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(databaseURL.path, &opened, flags, nil) == SQLITE_OK, let opened else {
            if let opened { sqlite3_close(opened) }
            throw SQLiteBuildRunError.openFailed(databaseURL.path)
        }
        database = opened
        sqlite3_busy_timeout(opened, 5_000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA foreign_keys=ON;")
    }

    private func execute(_ sql: String) throws {
        guard let database else { throw SQLiteBuildRunError.notOpen }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown sqlite error"
            sqlite3_free(error)
            throw SQLiteBuildRunError.sqlite(message)
        }
    }

    private func hasColumn(_ name: String, table: String) throws -> Bool {
        guard let database else { throw SQLiteBuildRunError.notOpen }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA table_info(\(table));", -1, &statement, nil) == SQLITE_OK, let statement else { throw lastError() }
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            if columnText(statement, index: 1) == name { return true }
        }
        return false
    }

    private func bind(_ value: String?, at index: Int32, statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_text(statement, index, value, -1, Self.sqliteTransient)
    }

    private func bind(_ value: Int?, at index: Int32, statement: OpaquePointer) {
        guard let value else { sqlite3_bind_null(statement, index); return }
        sqlite3_bind_int64(statement, index, sqlite3_int64(value))
    }

    private func columnText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let pointer = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: pointer)
    }

    private func lastError() -> SQLiteBuildRunError {
        guard let database else { return .notOpen }
        return .sqlite(String(cString: sqlite3_errmsg(database)))
    }
}

enum SQLiteBuildRunError: LocalizedError {
    case notOpen
    case openFailed(String)
    case sqlite(String)

    var errorDescription: String? {
        switch self {
        case .notOpen: return "SQLite database is not open."
        case .openFailed(let path): return "Could not open SQLite database at \(path)."
        case .sqlite(let message): return message
        }
    }
}
