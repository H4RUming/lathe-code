import CSQLite
import Foundation
import LatheDomain

/// Synchronous by design. The owning EngineRuntime actor serializes access;
/// the engine's process lock prevents another engine from recovering live runs.
public final class SQLiteStore {
    private var database: OpaquePointer?

    public init(databaseURL: URL) throws {
        guard databaseURL.isFileURL else {
            throw LatheError.invalidRequest("데이터베이스는 로컬 파일이어야 합니다.")
        }
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let result = sqlite3_open_v2(
            databaseURL.path, &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil
        )
        guard result == SQLITE_OK else {
            let error = storageError("데이터베이스 열기 실패")
            sqlite3_close(database)
            database = nil
            throw error
        }
        do {
            sqlite3_busy_timeout(database, 5_000)
            try execute("PRAGMA foreign_keys = ON")
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA synchronous = FULL")
            try migrate()
            try execute("CREATE INDEX IF NOT EXISTS run_events ON events(run_id, sequence)")
        } catch {
            sqlite3_close(database)
            database = nil
            throw error
        }
    }

    deinit { sqlite3_close(database) }

    public func listSessions(before: UUID? = nil, limit: Int = 50) throws -> SessionPage {
        guard (1...50).contains(limit) else {
            throw LatheError.invalidRequest("세션 페이지 limit은 1~50이어야 합니다.")
        }
        var sql = "SELECT id FROM sessions"
        var values: [Value] = []
        if let before {
            guard let row = try query("SELECT rowid FROM sessions WHERE id = ?", [.text(before.uuidString)]).first else {
                throw LatheError.notFound("세션 페이지 cursor를 찾을 수 없습니다.")
            }
            sql += " WHERE rowid < ?"
            values.append(row[0])
        }
        sql += " ORDER BY rowid DESC LIMIT ?"
        values.append(.integer(Int64(limit + 1)))
        let rows = try query(sql, values)
        let sessions = try rows.prefix(limit).map { try sessionMetadata(id: uuid($0[0])) }
        return SessionPage(sessions: sessions, nextBefore: rows.count > limit ? sessions.last?.id : nil)
    }

    public func session(id: UUID, beforeRunID: UUID? = nil, limit: Int = 4) throws -> SessionSnapshot {
        guard (1...4).contains(limit) else {
            throw LatheError.invalidRequest("실행 페이지 limit은 1~4여야 합니다.")
        }
        let metadata = try sessionMetadata(id: id)
        var sql = "SELECT id, session_id, prompt, response, state, started_at, finished_at FROM runs WHERE session_id = ?"
        var values: [Value] = [.text(id.uuidString)]
        if let beforeRunID {
            guard let row = try query(
                "SELECT rowid FROM runs WHERE id = ? AND session_id = ?",
                [.text(beforeRunID.uuidString), .text(id.uuidString)]
            ).first else { throw LatheError.notFound("이 세션에서 실행 페이지 cursor를 찾을 수 없습니다.") }
            sql += " AND rowid < ?"
            values.append(row[0])
        }
        sql += " ORDER BY rowid DESC LIMIT ?"
        values.append(.integer(Int64(limit + 1)))
        let rows = try query(sql, values)
        let runs = try rows.prefix(limit).reversed().map(decodeRun)
        return SessionSnapshot(
            id: metadata.id, title: metadata.title, workspacePath: metadata.workspacePath,
            createdAt: metadata.createdAt, updatedAt: metadata.updatedAt, runs: runs,
            totalRunCount: metadata.totalRunCount,
            nextBeforeRunID: rows.count > limit ? runs.first?.id : nil, activeRunID: metadata.activeRunID
        )
    }

    private func sessionMetadata(id: UUID) throws -> SessionSnapshot {
        guard let row = try query(
            """
            SELECT id, title, workspace_path, created_at, updated_at,
              (SELECT COUNT(*) FROM runs WHERE session_id = sessions.id),
              (SELECT id FROM runs WHERE session_id = sessions.id AND state = 'running')
            FROM sessions WHERE id = ?
            """,
            [.text(id.uuidString)]
        ).first else { throw LatheError.notFound("세션을 찾을 수 없습니다.") }
        return SessionSnapshot(
            id: try uuid(row[0]), title: try string(row[1]), workspacePath: try string(row[2]),
            createdAt: try date(row[3]), updatedAt: try date(row[4]),
            totalRunCount: try Int(integer(row[5])), activeRunID: try optionalString(row[6]).map { try uuid(.text($0)) }
        )
    }

    public func run(id: UUID) throws -> RunSnapshot {
        guard let row = try query(
            "SELECT id, session_id, prompt, response, state, started_at, finished_at FROM runs WHERE id = ?",
            [.text(id.uuidString)]
        ).first else { throw LatheError.notFound("실행을 찾을 수 없습니다.") }
        return try decodeRun(row)
    }

    public func createSession(title: String, workspacePath: String) throws -> SessionSnapshot {
        let now = storedTimestamp()
        let session = SessionSnapshot(title: title, workspacePath: workspacePath, createdAt: now, updatedAt: now)
        try transaction {
            try execute(
                "INSERT INTO sessions (id, title, workspace_path, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
                [.text(session.id.uuidString), .text(title), .text(workspacePath), .real(now.timeIntervalSince1970), .real(now.timeIntervalSince1970)]
            )
            try insertEvent(sessionID: session.id, kind: .sessionCreated, timestamp: now)
        }
        return session
    }

    /// The request key and run/event are committed together. Reusing a key for
    /// another payload never starts a second run, including after restart.
    public func submit(sessionID: UUID, prompt: String, requestID: UUID) throws -> (run: RunSnapshot, created: Bool) {
        try transaction {
            if let existing = try query(
                "SELECT session_id, prompt, run_id FROM requests WHERE request_id = ?",
                [.text(requestID.uuidString)]
            ).first {
                guard try uuid(existing[0]) == sessionID, try string(existing[1]) == prompt else {
                    throw LatheError.conflict("같은 요청 ID에 다른 내용이 지정되었습니다.")
                }
                return (try run(id: uuid(existing[2])), false)
            }
            guard !(try query("SELECT id FROM sessions WHERE id = ?", [.text(sessionID.uuidString)])).isEmpty else {
                throw LatheError.notFound("세션을 찾을 수 없습니다.")
            }
            guard (try query("SELECT id FROM runs WHERE session_id = ? AND state = 'running'", [.text(sessionID.uuidString)])).isEmpty else {
                throw LatheError.conflict("이 세션에서 이미 실행 중입니다.")
            }
            let run = RunSnapshot(sessionID: sessionID, prompt: prompt, startedAt: storedTimestamp())
            try execute(
                "INSERT INTO runs (id, session_id, prompt, response, state, started_at) VALUES (?, ?, ?, '', 'running', ?)",
                [.text(run.id.uuidString), .text(sessionID.uuidString), .text(prompt), .real(run.startedAt.timeIntervalSince1970)]
            )
            try execute(
                "INSERT INTO requests (request_id, session_id, prompt, run_id) VALUES (?, ?, ?, ?)",
                [.text(requestID.uuidString), .text(sessionID.uuidString), .text(prompt), .text(run.id.uuidString)]
            )
            try touch(sessionID, at: run.startedAt)
            try insertEvent(sessionID: sessionID, runID: run.id, kind: .runStarted, timestamp: run.startedAt)
            return (run, true)
        }
    }

    @discardableResult
    public func append(runID: UUID, text: String) throws -> Bool {
        try transaction {
            let run = try run(id: runID)
            guard run.state == .running else { return false }
            let now = storedTimestamp()
            try execute("UPDATE runs SET response = response || ? WHERE id = ?", [.text(text), .text(runID.uuidString)])
            try touch(run.sessionID, at: now)
            try insertEvent(sessionID: run.sessionID, runID: runID, kind: .textDelta, text: text, timestamp: now)
            return true
        }
    }

    @discardableResult
    public func finish(runID: UUID, state: RunState, reason: String? = nil) throws -> RunSnapshot {
        guard state != .running else { throw LatheError.invalidRequest("종료 상태가 필요합니다.") }
        return try transaction {
            var run = try run(id: runID)
            guard run.state == .running else { return run }
            let now = storedTimestamp()
            try execute(
                "UPDATE runs SET state = ?, finished_at = ? WHERE id = ?",
                [.text(state.rawValue), .real(now.timeIntervalSince1970), .text(runID.uuidString)]
            )
            try touch(run.sessionID, at: now)
            let kind: EventKind = switch state {
            case .completed: .runCompleted
            case .cancelled: .runCancelled
            case .interrupted: .runInterrupted
            case .running: fatalError("Guarded above")
            }
            try insertEvent(sessionID: run.sessionID, runID: runID, kind: kind, text: reason, timestamp: now)
            run.state = state
            run.finishedAt = now
            return run
        }
    }

    /// Called once by a newly started engine after acquiring the process lock.
    /// No model requests are resumed automatically.
    public func recoverInterruptedRuns() throws {
        try transaction {
            let ids = try query("SELECT id FROM runs WHERE state = 'running' ORDER BY started_at, rowid")
            for row in ids {
                let run = try run(id: uuid(row[0]))
                let now = storedTimestamp()
                try execute("UPDATE runs SET state = 'interrupted', finished_at = ? WHERE id = ?", [.real(now.timeIntervalSince1970), .text(run.id.uuidString)])
                try touch(run.sessionID, at: now)
                try insertEvent(sessionID: run.sessionID, runID: run.id, kind: .runInterrupted, text: "엔진 재시작으로 실행이 중단되었습니다.", timestamp: now)
            }
        }
    }

    public func events(after cursor: Int64, sessionID: UUID?, runID: UUID? = nil, limit: Int) throws -> EventPage {
        guard cursor >= 0, (1...1_024).contains(limit) else {
            throw LatheError.invalidRequest("cursor는 0 이상, limit은 1~1024여야 합니다.")
        }
        if let sessionID,
           try query("SELECT id FROM sessions WHERE id = ?", [.text(sessionID.uuidString)]).isEmpty {
            throw LatheError.notFound("세션을 찾을 수 없습니다.")
        }
        if let runID {
            let run = try run(id: runID)
            guard sessionID == nil || sessionID == run.sessionID else {
                throw LatheError.invalidRequest("실행이 지정된 세션에 속하지 않습니다.")
            }
        }
        let highWater = try integer(query("SELECT COALESCE(MAX(sequence), 0) FROM events")[0][0])
        var sql = "SELECT sequence, session_id, run_id, kind, text, timestamp FROM events WHERE sequence > ? AND sequence <= ?"
        var values: [Value] = [.integer(cursor), .integer(highWater)]
        if let sessionID { sql += " AND session_id = ?"; values.append(.text(sessionID.uuidString)) }
        if let runID { sql += " AND run_id = ?"; values.append(.text(runID.uuidString)) }
        sql += " ORDER BY sequence LIMIT ?"
        values.append(.integer(Int64(limit)))
        let events = try query(sql, values).map { row -> EngineEvent in
            guard let kind = EventKind(rawValue: try string(row[3])) else { throw LatheError.storage("잘못된 이벤트 종류입니다.") }
            return EngineEvent(
                sequence: try integer(row[0]), sessionID: try uuid(row[1]),
                runID: try optionalString(row[2]).map { try uuid(.text($0)) }, kind: kind,
                text: try optionalString(row[4]), timestamp: try date(row[5])
            )
        }
        let next = events.count == limit ? events.last!.sequence : max(cursor, highWater)
        return EventPage(events: events, nextCursor: next)
    }

    private func migrate() throws {
        let version = try integer(query("PRAGMA user_version")[0][0])
        guard version <= 1 else { throw LatheError.storage("더 새로운 데이터베이스 형식입니다. 앱을 업데이트하세요.") }
        guard version == 0 else { return }
        try transaction {
            try execute("CREATE TABLE sessions (id TEXT PRIMARY KEY, title TEXT NOT NULL, workspace_path TEXT NOT NULL, created_at REAL NOT NULL, updated_at REAL NOT NULL)")
            try execute("CREATE TABLE runs (id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), prompt TEXT NOT NULL, response TEXT NOT NULL, state TEXT NOT NULL CHECK(state IN ('running','completed','cancelled','interrupted')), started_at REAL NOT NULL, finished_at REAL)")
            try execute("CREATE UNIQUE INDEX one_running_run_per_session ON runs(session_id) WHERE state = 'running'")
            try execute("CREATE TABLE requests (request_id TEXT PRIMARY KEY, session_id TEXT NOT NULL REFERENCES sessions(id), prompt TEXT NOT NULL, run_id TEXT NOT NULL UNIQUE REFERENCES runs(id))")
            try execute("CREATE TABLE events (sequence INTEGER PRIMARY KEY AUTOINCREMENT, session_id TEXT NOT NULL REFERENCES sessions(id), run_id TEXT REFERENCES runs(id), kind TEXT NOT NULL, text TEXT, timestamp REAL NOT NULL)")
            try execute("CREATE INDEX session_events ON events(session_id, sequence)")
            try execute("PRAGMA user_version = 1")
        }
    }

    private func touch(_ sessionID: UUID, at date: Date) throws {
        try execute("UPDATE sessions SET updated_at = ? WHERE id = ?", [.real(date.timeIntervalSince1970), .text(sessionID.uuidString)])
    }

    // Date uses a different reference epoch internally. Normalize once to our
    // persisted seconds so an immediate result equals its SQLite replay exactly.
    private func storedTimestamp() -> Date {
        Date(timeIntervalSince1970: Date().timeIntervalSince1970)
    }

    private func insertEvent(sessionID: UUID, runID: UUID? = nil, kind: EventKind, text: String? = nil, timestamp: Date) throws {
        try execute(
            "INSERT INTO events (session_id, run_id, kind, text, timestamp) VALUES (?, ?, ?, ?, ?)",
            [.text(sessionID.uuidString), runID.map { .text($0.uuidString) } ?? .null, .text(kind.rawValue), text.map(Value.text) ?? .null, .real(timestamp.timeIntervalSince1970)]
        )
    }

    private func decodeRun(_ row: [Value]) throws -> RunSnapshot {
        guard let state = RunState(rawValue: try string(row[4])) else { throw LatheError.storage("잘못된 실행 상태입니다.") }
        let finishedAt: Date? = if case .null = row[6] { nil } else { try date(row[6]) }
        return RunSnapshot(id: try uuid(row[0]), sessionID: try uuid(row[1]), prompt: try string(row[2]), response: try string(row[3]), state: state, startedAt: try date(row[5]), finishedAt: finishedAt)
    }

    private enum Value {
        case text(String), integer(Int64), real(Double), null
    }

    private func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        _ = try query(sql, values)
    }

    private func query(_ sql: String, _ values: [Value] = []) throws -> [[Value]] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw storageError("쿼리 준비 실패")
        }
        defer { sqlite3_finalize(statement) }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32 = switch value {
            case .text(let text):
                text.withCString { sqlite3_bind_text(statement, index, $0, Int32(text.utf8.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self)) }
            case .integer(let number): sqlite3_bind_int64(statement, index, number)
            case .real(let number): sqlite3_bind_double(statement, index, number)
            case .null: sqlite3_bind_null(statement, index)
            }
            guard result == SQLITE_OK else { throw storageError("쿼리 인수 저장 실패") }
        }
        var rows: [[Value]] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return rows }
            guard result == SQLITE_ROW else { throw storageError("데이터베이스 작업 실패") }
            var row: [Value] = []
            for index in 0..<sqlite3_column_count(statement) {
                switch sqlite3_column_type(statement, index) {
                case SQLITE_INTEGER: row.append(.integer(sqlite3_column_int64(statement, index)))
                case SQLITE_FLOAT: row.append(.real(sqlite3_column_double(statement, index)))
                case SQLITE_TEXT:
                    guard let bytes = sqlite3_column_text(statement, index) else { throw storageError("텍스트 읽기 실패") }
                    row.append(.text(String(decoding: UnsafeBufferPointer(start: bytes, count: Int(sqlite3_column_bytes(statement, index))), as: UTF8.self)))
                case SQLITE_NULL: row.append(.null)
                default: throw LatheError.storage("지원하지 않는 데이터베이스 값입니다.")
                }
            }
            rows.append(row)
        }
    }

    private func string(_ value: Value) throws -> String {
        guard case .text(let text) = value else { throw LatheError.storage("텍스트 형식이 올바르지 않습니다.") }
        return text
    }

    private func optionalString(_ value: Value) throws -> String? {
        if case .null = value { return nil }
        return try string(value)
    }

    private func integer(_ value: Value) throws -> Int64 {
        guard case .integer(let number) = value else { throw LatheError.storage("정수 형식이 올바르지 않습니다.") }
        return number
    }

    private func uuid(_ value: Value) throws -> UUID {
        guard let id = UUID(uuidString: try string(value)) else { throw LatheError.storage("식별자 형식이 올바르지 않습니다.") }
        return id
    }

    private func date(_ value: Value) throws -> Date {
        switch value {
        case .real(let number): return Date(timeIntervalSince1970: number)
        case .integer(let number): return Date(timeIntervalSince1970: Double(number))
        default: throw LatheError.storage("날짜 형식이 올바르지 않습니다.")
        }
    }

    private func storageError(_ context: String) -> LatheError {
        let detail = database.map { String(cString: sqlite3_errmsg($0)) } ?? "SQLite 연결 없음"
        return .storage("\(context): \(detail)")
    }
}
