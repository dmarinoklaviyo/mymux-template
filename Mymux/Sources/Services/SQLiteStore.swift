import Foundation
import GRDB

final class SQLiteStore {
    let dbPool: DatabasePool

    init() throws {
        let dbDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mymux")
        try FileManager.default.createDirectory(
            at: dbDir,
            withIntermediateDirectories: true,
            attributes: nil
        )
        let dbPath = dbDir.appendingPathComponent("mymux.db").path
        dbPool = try DatabasePool(path: dbPath)

        var migrator = DatabaseMigrator()

        #if DEBUG
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        migrator.registerMigration("001_baseSchema") { db in
            try db.execute(sql: """
                CREATE TABLE work_tracks (
                    id              TEXT PRIMARY KEY,
                    name            TEXT NOT NULL,
                    repoPath        TEXT NOT NULL,
                    branch          TEXT NOT NULL,
                    linearTicketUrl TEXT,
                    contextNotes    TEXT DEFAULT '',
                    status          TEXT NOT NULL DEFAULT 'active',
                    createdAt       TEXT NOT NULL,
                    updatedAt       TEXT NOT NULL
                );

                CREATE TABLE terminals (
                    id              TEXT PRIMARY KEY,
                    trackId         TEXT NOT NULL REFERENCES work_tracks(id) ON DELETE CASCADE,
                    name            TEXT NOT NULL,
                    runtimeStatus   TEXT NOT NULL DEFAULT 'live',
                    createdAt       TEXT NOT NULL,
                    lastAccessedAt  TEXT
                );
                CREATE INDEX idx_terminals_track ON terminals(trackId);
                CREATE INDEX idx_terminals_status ON terminals(runtimeStatus);

                CREATE TABLE reference_files (
                    id          TEXT PRIMARY KEY,
                    trackId     TEXT NOT NULL REFERENCES work_tracks(id) ON DELETE CASCADE,
                    filePath    TEXT NOT NULL,
                    description TEXT DEFAULT '',
                    sortOrder   INTEGER NOT NULL DEFAULT 0
                );

                CREATE TABLE activity_log (
                    id          TEXT PRIMARY KEY,
                    terminalId  TEXT NOT NULL REFERENCES terminals(id) ON DELETE CASCADE,
                    message     TEXT NOT NULL,
                    createdAt   TEXT NOT NULL
                );
                CREATE INDEX idx_activity_log_terminal ON activity_log(terminalId);
            """)
        }

        migrator.registerMigration("002_trackKeywords") { db in
            try db.execute(sql: """
                CREATE TABLE track_keywords (
                    id       TEXT PRIMARY KEY,
                    trackId  TEXT NOT NULL REFERENCES work_tracks(id) ON DELETE CASCADE,
                    keyword  TEXT NOT NULL
                );
            """)
        }

        migrator.registerMigration("003_worktreeName") { db in
            try db.execute(sql: """
                ALTER TABLE terminals ADD COLUMN worktreeName TEXT NOT NULL DEFAULT '';
            """)
        }

        try migrator.migrate(dbPool)
    }

    // MARK: - WorkTrack CRUD

    func insertTrack(_ track: WorkTrack) throws {
        try dbPool.write { db in
            try track.insert(db)
        }
    }

    func fetchAllTracks() throws -> [WorkTrack] {
        try dbPool.read { db in
            try WorkTrack.order(Column("updatedAt").desc).fetchAll(db)
        }
    }

    func fetchTrack(id: String) throws -> WorkTrack? {
        try dbPool.read { db in
            try WorkTrack.fetchOne(db, key: id)
        }
    }

    func updateTrack(_ track: WorkTrack) throws {
        try dbPool.write { db in
            var updated = track
            updated.updatedAt = ISO8601DateFormatter().string(from: Date())
            try updated.update(db)
        }
    }

    func deleteTrack(id: String) throws {
        try dbPool.write { db in
            _ = try WorkTrack.deleteOne(db, key: id)
        }
    }

    // MARK: - Terminal CRUD

    func insertTerminal(_ terminal: Terminal) throws {
        try dbPool.write { db in
            try terminal.insert(db)
        }
    }

    func fetchTerminals(forTrackId trackId: String) throws -> [Terminal] {
        try dbPool.read { db in
            try Terminal
                .filter(Column("trackId") == trackId)
                .order(Column("createdAt").asc)
                .fetchAll(db)
        }
    }

    func fetchAllTerminals() throws -> [Terminal] {
        try dbPool.read { db in
            try Terminal.order(Column("createdAt").asc).fetchAll(db)
        }
    }

    func fetchTerminal(id: String) throws -> Terminal? {
        try dbPool.read { db in
            try Terminal.fetchOne(db, key: id)
        }
    }

    func updateTerminal(_ terminal: Terminal) throws {
        try dbPool.write { db in
            try terminal.update(db)
        }
    }

    func updateTerminalName(id: String, name: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE terminals SET name = ?, worktreeName = ? WHERE id = ?",
                arguments: [name, name.toKebabCase(), id]
            )
        }
    }

    func updateTerminalTrack(terminalId: String, newTrackId: String) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE terminals SET trackId = ? WHERE id = ?",
                arguments: [newTrackId, terminalId]
            )
        }
    }

    func updateTerminalRuntimeStatus(id: String, status: RuntimeStatus) throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE terminals SET runtimeStatus = ? WHERE id = ?",
                arguments: [status.rawValue, id]
            )
        }
    }

    func updateTerminalLastAccessed(id: String) throws {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE terminals SET lastAccessedAt = ? WHERE id = ?",
                arguments: [timestamp, id]
            )
        }
    }

    func deleteTerminal(id: String) throws {
        try dbPool.write { db in
            _ = try Terminal.deleteOne(db, key: id)
        }
    }

    func markAllLiveTerminalsAsSuspended() throws {
        try dbPool.write { db in
            try db.execute(
                sql: "UPDATE terminals SET runtimeStatus = ? WHERE runtimeStatus = ?",
                arguments: [RuntimeStatus.suspended.rawValue, RuntimeStatus.live.rawValue]
            )
        }
    }

    // MARK: - ActivityLogEntry CRUD

    func insertActivityLogEntry(_ entry: ActivityLogEntry) throws {
        try dbPool.write { db in
            try entry.insert(db)
        }
    }

    func fetchActivityLogEntries(forTerminalId terminalId: String, limit: Int = 100) throws -> [ActivityLogEntry] {
        try dbPool.read { db in
            try ActivityLogEntry
                .filter(Column("terminalId") == terminalId)
                .order(Column("createdAt").asc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    func deleteActivityLogEntries(forTerminalId terminalId: String) throws {
        _ = try dbPool.write { db in
            try ActivityLogEntry
                .filter(Column("terminalId") == terminalId)
                .deleteAll(db)
        }
    }

    // MARK: - ReferenceFile CRUD

    func insertReferenceFile(_ file: ReferenceFile) throws {
        try dbPool.write { db in
            try file.insert(db)
        }
    }

    func fetchReferenceFiles(forTrackId trackId: String) throws -> [ReferenceFile] {
        try dbPool.read { db in
            try ReferenceFile
                .filter(Column("trackId") == trackId)
                .order(Column("sortOrder").asc)
                .fetchAll(db)
        }
    }

    func deleteReferenceFile(id: String) throws {
        try dbPool.write { db in
            _ = try ReferenceFile.deleteOne(db, key: id)
        }
    }

    // MARK: - TrackKeyword CRUD

    func insertTrackKeyword(_ keyword: TrackKeyword) throws {
        try dbPool.write { db in
            try keyword.insert(db)
        }
    }

    func fetchTrackKeywords(forTrackId trackId: String) throws -> [TrackKeyword] {
        try dbPool.read { db in
            try TrackKeyword
                .filter(Column("trackId") == trackId)
                .fetchAll(db)
        }
    }

    func deleteTrackKeyword(id: String) throws {
        try dbPool.write { db in
            _ = try TrackKeyword.deleteOne(db, key: id)
        }
    }
}
