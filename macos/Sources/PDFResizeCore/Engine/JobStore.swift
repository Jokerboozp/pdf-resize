import Foundation
import SQLite3

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class JobStore: @unchecked Sendable {
    public let dbURL: URL
    private let lock = NSRecursiveLock()
    private var db: OpaquePointer?

    public static func defaultDatabaseURL() -> URL {
        if let customDir = ProcessInfo.processInfo.environment["PDF_RESIZE_DATA_DIR"], !customDir.isEmpty {
            let dir = URL(fileURLWithPath: customDir, isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appendingPathComponent("jobs_native.sqlite3")
        }
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("PDF Resize", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("jobs_native.sqlite3")
    }

    public init(dbURL: URL = JobStore.defaultDatabaseURL()) throws {
        self.dbURL = dbURL
        try FileManager.default.createDirectory(at: dbURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "Unknown SQLite error"
            throw NSError(domain: "JobStore", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法打开数据库: \(msg)"])
        }
        try initSchema()
    }

    deinit {
        if let db {
            sqlite3_close(db)
        }
    }

    private func initSchema() throws {
        let sql = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        PRAGMA temp_store=MEMORY;

        CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            source_summary TEXT NOT NULL,
            output_mode TEXT NOT NULL,
            output_dir TEXT,
            backup_dir TEXT,
            config_json TEXT NOT NULL,
            status TEXT NOT NULL,
            created_at REAL NOT NULL,
            started_at REAL,
            finished_at REAL
        );

        CREATE TABLE IF NOT EXISTS job_files (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            job_id TEXT NOT NULL,
            rel_path TEXT NOT NULL,
            src_path TEXT NOT NULL,
            dst_path TEXT NOT NULL,
            backup_path TEXT,
            orig_size INTEGER NOT NULL,
            orig_mtime REAL NOT NULL,
            new_size INTEGER,
            saved_bytes INTEGER NOT NULL DEFAULT 0,
            status TEXT NOT NULL DEFAULT 'pending',
            error TEXT,
            duration_ms INTEGER,
            pages INTEGER NOT NULL DEFAULT 0,
            updated_at REAL NOT NULL
        );

        CREATE INDEX IF NOT EXISTS idx_job_files_job_status ON job_files(job_id, status);
        CREATE INDEX IF NOT EXISTS idx_job_files_job_id ON job_files(job_id, id);

        CREATE TABLE IF NOT EXISTS optimized_fingerprints (
            file_path TEXT PRIMARY KEY,
            file_size INTEGER NOT NULL,
            file_mtime REAL NOT NULL,
            preset TEXT NOT NULL,
            optimized_at REAL NOT NULL
        );
        """
        try execSQL(sql)
    }

    private func execSQL(_ sql: String) throws {
        lock.lock()
        defer { lock.unlock() }
        var errMsg: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &errMsg) != SQLITE_OK {
            let msg = errMsg.map { String(cString: $0) } ?? "SQLite error"
            sqlite3_free(errMsg)
            throw NSError(domain: "JobStore", code: 2, userInfo: [NSLocalizedDescriptionKey: msg])
        }
    }

    public func recoverInterruptedJobs() {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        _ = try? execSQL("UPDATE job_files SET status = 'pending', updated_at = \(now) WHERE status = 'processing';")
        _ = try? execSQL("UPDATE jobs SET status = 'paused' WHERE status = 'running';")
    }

    // MARK: - Jobs CRUD

    public func createJob(
        id: String,
        name: String,
        sourceSummary: String,
        outputMode: OutputMode,
        outputDir: String?,
        backupDir: String?,
        config: CompressionConfig,
        files: [(entry: ScannedFileEntry, dstPath: String, backupPath: String?)]
    ) throws -> JobRecord {
        lock.lock()
        defer { lock.unlock() }

        let now = Date().timeIntervalSince1970
        let cfgData = try JSONEncoder().encode(config)
        let cfgJSON = String(data: cfgData, encoding: .utf8) ?? "{}"

        try execSQL("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let jobSQL = """
            INSERT INTO jobs (id, name, source_summary, output_mode, output_dir, backup_dir, config_json, status, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, 'created', ?);
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, jobSQL, -1, &stmt, nil) == SQLITE_OK else {
                throw lastError()
            }
            defer { sqlite3_finalize(stmt) }

            bindText(stmt, 1, id)
            bindText(stmt, 2, name)
            bindText(stmt, 3, sourceSummary)
            bindText(stmt, 4, outputMode.rawValue)
            bindOptionalText(stmt, 5, outputDir)
            bindOptionalText(stmt, 6, backupDir)
            bindText(stmt, 7, cfgJSON)
            sqlite3_bind_double(stmt, 8, now)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw lastError()
            }

            let fileSQL = """
            INSERT INTO job_files (job_id, rel_path, src_path, dst_path, backup_path, orig_size, orig_mtime, new_size, saved_bytes, status, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, 0, ?, ?);
            """
            var fStmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, fileSQL, -1, &fStmt, nil) == SQLITE_OK else {
                throw lastError()
            }
            defer { sqlite3_finalize(fStmt) }

            for item in files {
                sqlite3_reset(fStmt)
                sqlite3_clear_bindings(fStmt)
                bindText(fStmt, 1, id)
                bindText(fStmt, 2, item.entry.relativePath)
                bindText(fStmt, 3, item.entry.sourceURL.path)
                bindText(fStmt, 4, item.dstPath)
                bindOptionalText(fStmt, 5, item.backupPath)
                sqlite3_bind_int64(fStmt, 6, item.entry.originalSize)
                sqlite3_bind_double(fStmt, 7, item.entry.modificationTime)
                if item.entry.initialStatus != .pending {
                    sqlite3_bind_int64(fStmt, 8, item.entry.originalSize)
                } else {
                    sqlite3_bind_null(fStmt, 8)
                }
                bindText(fStmt, 9, item.entry.initialStatus.rawValue)
                sqlite3_bind_double(fStmt, 10, now)
                guard sqlite3_step(fStmt) == SQLITE_DONE else {
                    throw lastError()
                }
            }

            try execSQL("COMMIT;")
        } catch {
            _ = try? execSQL("ROLLBACK;")
            throw error
        }

        guard let created = getJob(id: id) else {
            throw NSError(domain: "JobStore", code: 3, userInfo: [NSLocalizedDescriptionKey: "创建任务记录失败"])
        }
        return created
    }

    public func updateJobStatus(_ jobID: String, status: JobStatus, setStarted: Bool = false, setFinished: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        let sql: String
        if setStarted {
            sql = "UPDATE jobs SET status = ?, started_at = COALESCE(started_at, ?) WHERE id = ?;"
        } else if setFinished {
            sql = "UPDATE jobs SET status = ?, finished_at = ? WHERE id = ?;"
        } else {
            sql = "UPDATE jobs SET status = ? WHERE id = ?;"
        }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, status.rawValue)
        if setStarted || setFinished {
            sqlite3_bind_double(stmt, 2, now)
            bindText(stmt, 3, jobID)
        } else {
            bindText(stmt, 2, jobID)
        }
        _ = sqlite3_step(stmt)
    }

    public func getJob(id: String) -> JobRecord? {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT id, name, source_summary, output_mode, output_dir, backup_dir, config_json, status, created_at, started_at, finished_at FROM jobs WHERE id = ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        var rec = readJobRow(stmt)
        rec.stats = getJobStats(jobID: id)
        return rec
    }

    public func listJobs(limit: Int = 60) -> [JobRecord] {
        lock.lock()
        defer { lock.unlock() }
        let sql = "SELECT id, name, source_summary, output_mode, output_dir, backup_dir, config_json, status, created_at, started_at, finished_at FROM jobs ORDER BY created_at DESC LIMIT ?;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int(stmt, 1, Int32(limit))

        var jobs: [JobRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            jobs.append(readJobRow(stmt))
        }
        for idx in jobs.indices {
            jobs[idx].stats = getJobStats(jobID: jobs[idx].id)
        }
        return jobs
    }

    public func deleteJob(id: String) {
        lock.lock()
        defer { lock.unlock() }
        var s1: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM job_files WHERE job_id = ?;", -1, &s1, nil) == SQLITE_OK {
            bindText(s1, 1, id)
            _ = sqlite3_step(s1)
            sqlite3_finalize(s1)
        }
        var s2: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM jobs WHERE id = ?;", -1, &s2, nil) == SQLITE_OK {
            bindText(s2, 1, id)
            _ = sqlite3_step(s2)
            sqlite3_finalize(s2)
        }
    }

    public func getJobStats(jobID: String) -> JobStats {
        lock.lock()
        defer { lock.unlock() }
        let sql = """
        SELECT
            COUNT(*),
            COALESCE(SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN status = 'processing' THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN status = 'done' THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN status LIKE 'skipped_%' THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END), 0),
            COALESCE(SUM(orig_size), 0),
            COALESCE(SUM(CASE WHEN status NOT IN ('pending', 'processing') THEN orig_size ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN status NOT IN ('pending', 'processing') THEN COALESCE(new_size, orig_size) ELSE 0 END), 0),
            COALESCE(SUM(CASE WHEN status = 'done' THEN saved_bytes ELSE 0 END), 0)
        FROM job_files WHERE job_id = ?;
        """
        var stmt: OpaquePointer?
        var st = JobStats()
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return st }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, jobID)
        if sqlite3_step(stmt) == SQLITE_ROW {
            st.totalFiles = Int(sqlite3_column_int64(stmt, 0))
            st.pending = Int(sqlite3_column_int64(stmt, 1))
            st.processing = Int(sqlite3_column_int64(stmt, 2))
            st.done = Int(sqlite3_column_int64(stmt, 3))
            st.skipped = Int(sqlite3_column_int64(stmt, 4))
            st.failed = Int(sqlite3_column_int64(stmt, 5))
            st.totalOriginalBytes = sqlite3_column_int64(stmt, 6)
            st.processedOriginalBytes = sqlite3_column_int64(stmt, 7)
            st.processedNewBytes = sqlite3_column_int64(stmt, 8)
            st.savedBytes = sqlite3_column_int64(stmt, 9)
        }
        return st
    }

    // MARK: - Job Files Claim / Update / Query

    public func claimPendingFiles(jobID: String, limit: Int) -> [JobFileRow] {
        lock.lock()
        defer { lock.unlock() }
        let selectSQL = """
        SELECT id, job_id, rel_path, src_path, dst_path, backup_path, orig_size, orig_mtime, new_size, saved_bytes, status, error, duration_ms, pages
        FROM job_files WHERE job_id = ? AND status = 'pending' ORDER BY id ASC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL, -1, &stmt, nil) == SQLITE_OK else { return [] }
        bindText(stmt, 1, jobID)
        sqlite3_bind_int(stmt, 2, Int32(limit))

        var rows: [JobFileRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(readFileRow(stmt))
        }
        sqlite3_finalize(stmt)

        guard !rows.isEmpty else { return [] }
        let idsCSV = rows.map { String($0.id) }.joined(separator: ",")
        let now = Date().timeIntervalSince1970
        _ = try? execSQL("UPDATE job_files SET status = 'processing', updated_at = \(now) WHERE id IN (\(idsCSV));")
        for idx in rows.indices {
            rows[idx].status = .processing
        }
        return rows
    }

    public func resetJobProcessingToPending(jobID: String) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "UPDATE job_files SET status = 'pending', updated_at = ? WHERE job_id = ? AND status = 'processing';", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, now)
            bindText(stmt, 2, jobID)
            _ = sqlite3_step(stmt)
            sqlite3_finalize(stmt)
        }
    }

    public func retryFailedFiles(jobID: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "UPDATE job_files SET status = 'pending', error = NULL, new_size = NULL, saved_bytes = 0, duration_ms = NULL, updated_at = ? WHERE job_id = ? AND status = 'failed';", -1, &stmt, nil) == SQLITE_OK else {
            return 0
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, now)
        bindText(stmt, 2, jobID)
        _ = sqlite3_step(stmt)
        return Int(sqlite3_changes(db))
    }

    public func updateFileResult(fileID: Int64, result: SingleCompressionResult) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        let sql = """
        UPDATE job_files
        SET status = ?, new_size = ?, saved_bytes = ?, duration_ms = ?, pages = ?, error = ?, updated_at = ?
        WHERE id = ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, result.status.rawValue)
        sqlite3_bind_int64(stmt, 2, result.newSize)
        sqlite3_bind_int64(stmt, 3, result.savedBytes)
        sqlite3_bind_int(stmt, 4, Int32(result.durationMs))
        sqlite3_bind_int(stmt, 5, Int32(result.pages))
        bindOptionalText(stmt, 6, result.errorMessage)
        sqlite3_bind_double(stmt, 7, now)
        sqlite3_bind_int64(stmt, 8, fileID)
        _ = sqlite3_step(stmt)
    }

    public func listJobFiles(jobID: String, statusFilter: String = "all", search: String = "", limit: Int = 5000) -> [JobFileRow] {
        lock.lock()
        defer { lock.unlock() }
        var clauses = ["job_id = ?"]
        if statusFilter == "skipped" {
            clauses.append("status LIKE 'skipped_%'")
        } else if !statusFilter.isEmpty && statusFilter != "all" {
            clauses.append("status = ?")
        }
        if !search.isEmpty {
            clauses.append("rel_path LIKE ?")
        }
        let sql = """
        SELECT id, job_id, rel_path, src_path, dst_path, backup_path, orig_size, orig_mtime, new_size, saved_bytes, status, error, duration_ms, pages
        FROM job_files
        WHERE \(clauses.joined(separator: " AND "))
        ORDER BY id ASC LIMIT ?;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        var bindIdx: Int32 = 1
        bindText(stmt, bindIdx, jobID); bindIdx += 1
        if statusFilter != "skipped" && !statusFilter.isEmpty && statusFilter != "all" {
            bindText(stmt, bindIdx, statusFilter); bindIdx += 1
        }
        if !search.isEmpty {
            bindText(stmt, bindIdx, "%\(search)%"); bindIdx += 1
        }
        sqlite3_bind_int(stmt, bindIdx, Int32(limit))

        var rows: [JobFileRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(readFileRow(stmt))
        }
        return rows
    }

    // MARK: - Fingerprints

    public func recordFingerprint(filePath: String, fileSize: Int64, mtime: TimeInterval, preset: String) {
        lock.lock()
        defer { lock.unlock() }
        let resolved = URL(fileURLWithPath: filePath).standardizedFileURL.resolvingSymlinksInPath().path
        let sql = """
        INSERT INTO optimized_fingerprints (file_path, file_size, file_mtime, preset, optimized_at)
        VALUES (?, ?, ?, ?, ?)
        ON CONFLICT(file_path) DO UPDATE SET
            file_size = excluded.file_size,
            file_mtime = excluded.file_mtime,
            preset = excluded.preset,
            optimized_at = excluded.optimized_at;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, 1, resolved)
        sqlite3_bind_int64(stmt, 2, fileSize)
        sqlite3_bind_double(stmt, 3, mtime)
        bindText(stmt, 4, preset)
        sqlite3_bind_double(stmt, 5, Date().timeIntervalSince1970)
        _ = sqlite3_step(stmt)
    }

    public func getAllFingerprints() -> [String: (size: Int64, mtime: TimeInterval)] {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT file_path, file_size, file_mtime FROM optimized_fingerprints;", -1, &stmt, nil) == SQLITE_OK else {
            return [:]
        }
        defer { sqlite3_finalize(stmt) }
        var map: [String: (size: Int64, mtime: TimeInterval)] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let p = colString(stmt, 0)
            let sz = sqlite3_column_int64(stmt, 1)
            let mt = sqlite3_column_double(stmt, 2)
            map[p] = (sz, mt)
        }
        return map
    }

    public func clearFingerprints() -> Int {
        lock.lock()
        defer { lock.unlock() }
        _ = try? execSQL("DELETE FROM optimized_fingerprints;")
        return Int(sqlite3_changes(db))
    }

    // MARK: - Helpers

    private func bindText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String) {
        sqlite3_bind_text(stmt, idx, value, -1, SQLITE_TRANSIENT_DESTRUCTOR)
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ idx: Int32, _ value: String?) {
        if let value {
            bindText(stmt, idx, value)
        } else {
            sqlite3_bind_null(stmt, idx)
        }
    }

    private func colString(_ stmt: OpaquePointer?, _ idx: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, idx) else { return "" }
        return String(cString: c)
    }

    private func colOptionalString(_ stmt: OpaquePointer?, _ idx: Int32) -> String? {
        guard sqlite3_column_type(stmt, idx) != SQLITE_NULL,
              let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }

    private func readJobRow(_ stmt: OpaquePointer?) -> JobRecord {
        let id = colString(stmt, 0)
        let name = colString(stmt, 1)
        let sourceSummary = colString(stmt, 2)
        let outMode = OutputMode(rawValue: colString(stmt, 3)) ?? .inplace
        let outDir = colOptionalString(stmt, 4)
        let bkpDir = colOptionalString(stmt, 5)
        let cfgStr = colString(stmt, 6)
        let cfg = (try? JSONDecoder().decode(CompressionConfig.self, from: Data(cfgStr.utf8))) ?? CompressionConfig()
        let status = JobStatus(rawValue: colString(stmt, 7)) ?? .created
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 8))
        let startedAt: Date? = sqlite3_column_type(stmt, 9) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 9)) : nil
        let finishedAt: Date? = sqlite3_column_type(stmt, 10) != SQLITE_NULL ? Date(timeIntervalSince1970: sqlite3_column_double(stmt, 10)) : nil

        return JobRecord(
            id: id,
            name: name,
            sourceSummary: sourceSummary,
            outputMode: outMode,
            outputDir: outDir,
            backupDir: bkpDir,
            config: cfg,
            status: status,
            createdAt: createdAt,
            startedAt: startedAt,
            finishedAt: finishedAt,
            stats: JobStats()
        )
    }

    private func readFileRow(_ stmt: OpaquePointer?) -> JobFileRow {
        let id = sqlite3_column_int64(stmt, 0)
        let jobID = colString(stmt, 1)
        let rel = colString(stmt, 2)
        let src = colString(stmt, 3)
        let dst = colString(stmt, 4)
        let bkp = colOptionalString(stmt, 5)
        let origSize = sqlite3_column_int64(stmt, 6)
        let origMtime = sqlite3_column_double(stmt, 7)
        let newSize: Int64? = sqlite3_column_type(stmt, 8) != SQLITE_NULL ? sqlite3_column_int64(stmt, 8) : nil
        let saved = sqlite3_column_int64(stmt, 9)
        let st = FileProcessStatus(rawValue: colString(stmt, 10)) ?? .pending
        let err = colOptionalString(stmt, 11)
        let dur: Int? = sqlite3_column_type(stmt, 12) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 12)) : nil
        let pages = Int(sqlite3_column_int(stmt, 13))

        return JobFileRow(
            id: id,
            jobID: jobID,
            relativePath: rel,
            sourcePath: src,
            destinationPath: dst,
            backupPath: bkp,
            originalSize: origSize,
            modificationTime: origMtime,
            newSize: newSize,
            savedBytes: saved,
            status: st,
            errorMessage: err,
            durationMs: dur,
            pages: pages
        )
    }

    private func lastError() -> NSError {
        let msg = db.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "SQLite error"
        return NSError(domain: "JobStore", code: 9, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
