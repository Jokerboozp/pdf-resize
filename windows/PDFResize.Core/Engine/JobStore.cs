using System.Text.Json;
using Microsoft.Data.Sqlite;
using PDFResize.Core.Models;

namespace PDFResize.Core.Engine;

public sealed class JobStore : IDisposable
{
    public string DbPath { get; }
    private readonly object _sync = new();
    private readonly SqliteConnection _conn;

    public static string DefaultDatabasePath()
    {
        string? custom = Environment.GetEnvironmentVariable("PDF_RESIZE_DATA_DIR");
        string dir = !string.IsNullOrWhiteSpace(custom)
            ? custom
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PDF Resize");
        Directory.CreateDirectory(dir);
        return Path.Combine(dir, "jobs_winui.sqlite3");
    }

    public JobStore(string? dbPath = null)
    {
        DbPath = dbPath ?? DefaultDatabasePath();
        if (Path.GetDirectoryName(DbPath) is { Length: > 0 } parent)
            Directory.CreateDirectory(parent);

        var csb = new SqliteConnectionStringBuilder
        {
            DataSource = DbPath,
            Mode = SqliteOpenMode.ReadWriteCreate,
            Pooling = false
        };
        _conn = new SqliteConnection(csb.ToString());
        _conn.Open();
        InitSchema();
    }

    private void InitSchema()
    {
        lock (_sync)
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = """
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
                    status TEXT NOT NULL DEFAULT 'Pending',
                    error TEXT,
                    duration_ms INTEGER,
                    images_optimized INTEGER NOT NULL DEFAULT 0,
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
                """;
            cmd.ExecuteNonQuery();
        }
    }

    public void RecoverInterruptedJobs()
    {
        lock (_sync)
        {
            double now = NowUnix();
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = """
                UPDATE job_files SET status = 'Pending', updated_at = $now WHERE status = 'Processing';
                UPDATE jobs SET status = 'Paused' WHERE status = 'Running';
                """;
            cmd.Parameters.AddWithValue("$now", now);
            cmd.ExecuteNonQuery();
        }
    }

    public JobRecord CreateJob(
        string id,
        string name,
        string sourceSummary,
        OutputMode outputMode,
        string? outputDir,
        string? backupDir,
        CompressionConfig config,
        IReadOnlyList<(ScannedFileEntry Entry, string DstPath, string? BackupPath)> files)
    {
        lock (_sync)
        {
            double now = NowUnix();
            string cfgJson = JsonSerializer.Serialize(config);

            using var tx = _conn.BeginTransaction();
            using (var jCmd = _conn.CreateCommand())
            {
                jCmd.Transaction = tx;
                jCmd.CommandText = """
                    INSERT INTO jobs (id, name, source_summary, output_mode, output_dir, backup_dir, config_json, status, created_at)
                    VALUES ($id, $name, $src, $mode, $out, $bkp, $cfg, 'Created', $now);
                    """;
                jCmd.Parameters.AddWithValue("$id", id);
                jCmd.Parameters.AddWithValue("$name", name);
                jCmd.Parameters.AddWithValue("$src", sourceSummary);
                jCmd.Parameters.AddWithValue("$mode", outputMode.ToString());
                jCmd.Parameters.AddWithValue("$out", (object?)outputDir ?? DBNull.Value);
                jCmd.Parameters.AddWithValue("$bkp", (object?)backupDir ?? DBNull.Value);
                jCmd.Parameters.AddWithValue("$cfg", cfgJson);
                jCmd.Parameters.AddWithValue("$now", now);
                jCmd.ExecuteNonQuery();
            }

            using (var fCmd = _conn.CreateCommand())
            {
                fCmd.Transaction = tx;
                fCmd.CommandText = """
                    INSERT INTO job_files (job_id, rel_path, src_path, dst_path, backup_path, orig_size, orig_mtime, new_size, saved_bytes, status, updated_at)
                    VALUES ($jid, $rel, $src, $dst, $bkp, $osz, $omt, $nsz, 0, $st, $now);
                    """;
                var pJid = fCmd.Parameters.Add("$jid", SqliteType.Text);
                var pRel = fCmd.Parameters.Add("$rel", SqliteType.Text);
                var pSrc = fCmd.Parameters.Add("$src", SqliteType.Text);
                var pDst = fCmd.Parameters.Add("$dst", SqliteType.Text);
                var pBkp = fCmd.Parameters.Add("$bkp", SqliteType.Text);
                var pOsz = fCmd.Parameters.Add("$osz", SqliteType.Integer);
                var pOmt = fCmd.Parameters.Add("$omt", SqliteType.Real);
                var pNsz = fCmd.Parameters.Add("$nsz", SqliteType.Integer);
                var pSt = fCmd.Parameters.Add("$st", SqliteType.Text);
                var pNow = fCmd.Parameters.Add("$now", SqliteType.Real);

                foreach (var item in files)
                {
                    pJid.Value = id;
                    pRel.Value = item.Entry.RelativePath;
                    pSrc.Value = item.Entry.SourcePath;
                    pDst.Value = item.DstPath;
                    pBkp.Value = (object?)item.BackupPath ?? DBNull.Value;
                    pOsz.Value = item.Entry.OriginalSize;
                    pOmt.Value = item.Entry.ModificationTimeUnix;
                    pNsz.Value = item.Entry.InitialStatus != FileProcessStatus.Pending
                        ? item.Entry.OriginalSize
                        : DBNull.Value;
                    pSt.Value = item.Entry.InitialStatus.ToString();
                    pNow.Value = now;
                    fCmd.ExecuteNonQuery();
                }
            }

            tx.Commit();
            return GetJob(id)!;
        }
    }

    public void UpdateJobStatus(string jobId, JobStatus status, bool setStarted = false, bool setFinished = false)
    {
        lock (_sync)
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = setStarted
                ? "UPDATE jobs SET status = $st, started_at = COALESCE(started_at, $now) WHERE id = $id;"
                : setFinished
                    ? "UPDATE jobs SET status = $st, finished_at = $now WHERE id = $id;"
                    : "UPDATE jobs SET status = $st WHERE id = $id;";
            cmd.Parameters.AddWithValue("$st", status.ToString());
            cmd.Parameters.AddWithValue("$id", jobId);
            if (setStarted || setFinished)
                cmd.Parameters.AddWithValue("$now", NowUnix());
            cmd.ExecuteNonQuery();
        }
    }

    public JobRecord? GetJob(string jobId)
    {
        lock (_sync)
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "SELECT id, name, source_summary, output_mode, output_dir, backup_dir, config_json, status, created_at, started_at, finished_at FROM jobs WHERE id = $id;";
            cmd.Parameters.AddWithValue("$id", jobId);
            using var reader = cmd.ExecuteReader();
            if (!reader.Read()) return null;
            var job = ReadJobRow(reader);
            reader.Close();
            job.Stats = GetJobStats(jobId);
            return job;
        }
    }

    public List<JobRecord> ListJobs(int limit = 60)
    {
        lock (_sync)
        {
            var jobs = new List<JobRecord>();
            using (var cmd = _conn.CreateCommand())
            {
                cmd.CommandText = "SELECT id, name, source_summary, output_mode, output_dir, backup_dir, config_json, status, created_at, started_at, finished_at FROM jobs ORDER BY created_at DESC LIMIT $lim;";
                cmd.Parameters.AddWithValue("$lim", limit);
                using var reader = cmd.ExecuteReader();
                while (reader.Read())
                    jobs.Add(ReadJobRow(reader));
            }
            foreach (var j in jobs)
                j.Stats = GetJobStats(j.Id);
            return jobs;
        }
    }

    public void DeleteJob(string jobId)
    {
        lock (_sync)
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "DELETE FROM job_files WHERE job_id = $id; DELETE FROM jobs WHERE id = $id;";
            cmd.Parameters.AddWithValue("$id", jobId);
            cmd.ExecuteNonQuery();
        }
    }

    public JobStats GetJobStats(string jobId)
    {
        lock (_sync)
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = """
                SELECT
                    COUNT(*),
                    COALESCE(SUM(CASE WHEN status = 'Pending' THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN status = 'Processing' THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN status = 'Done' THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN status LIKE 'Skipped%' THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN status = 'Failed' THEN 1 ELSE 0 END), 0),
                    COALESCE(SUM(orig_size), 0),
                    COALESCE(SUM(CASE WHEN status NOT IN ('Pending', 'Processing') THEN orig_size ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN status NOT IN ('Pending', 'Processing') THEN COALESCE(new_size, orig_size) ELSE 0 END), 0),
                    COALESCE(SUM(CASE WHEN status = 'Done' THEN saved_bytes ELSE 0 END), 0),
                    COALESCE(SUM(images_optimized), 0)
                FROM job_files WHERE job_id = $id;
                """;
            cmd.Parameters.AddWithValue("$id", jobId);
            using var r = cmd.ExecuteReader();
            if (!r.Read()) return new JobStats();
            return new JobStats
            {
                TotalFiles = r.GetInt32(0),
                Pending = r.GetInt32(1),
                Processing = r.GetInt32(2),
                Done = r.GetInt32(3),
                Skipped = r.GetInt32(4),
                Failed = r.GetInt32(5),
                TotalOriginalBytes = r.GetInt64(6),
                ProcessedOriginalBytes = r.GetInt64(7),
                ProcessedNewBytes = r.GetInt64(8),
                SavedBytes = r.GetInt64(9),
                ImagesOptimized = r.GetInt32(10)
            };
        }
    }

    public List<JobFileRow> ClaimPendingFiles(string jobId, int limit)
    {
        lock (_sync)
        {
            var rows = new List<JobFileRow>();
            using (var cmd = _conn.CreateCommand())
            {
                cmd.CommandText = """
                    SELECT id, job_id, rel_path, src_path, dst_path, backup_path, orig_size, orig_mtime, new_size, saved_bytes, status, error, duration_ms, pages
                    FROM job_files WHERE job_id = $id AND status = 'Pending' ORDER BY id ASC LIMIT $lim;
                    """;
                cmd.Parameters.AddWithValue("$id", jobId);
                cmd.Parameters.AddWithValue("$lim", limit);
                using var r = cmd.ExecuteReader();
                while (r.Read())
                    rows.Add(ReadFileRow(r));
            }

            if (rows.Count == 0) return rows;

            string csv = string.Join(",", rows.Select(x => x.Id));
            using (var upd = _conn.CreateCommand())
            {
                upd.CommandText = $"UPDATE job_files SET status = 'Processing', updated_at = $now WHERE id IN ({csv});";
                upd.Parameters.AddWithValue("$now", NowUnix());
                upd.ExecuteNonQuery();
            }

            foreach (var row in rows)
                row.Status = FileProcessStatus.Processing;
            return rows;
        }
    }

    public void ResetJobProcessingToPending(string jobId)
    {
        lock (_sync)
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "UPDATE job_files SET status = 'Pending', updated_at = $now WHERE job_id = $id AND status = 'Processing';";
            cmd.Parameters.AddWithValue("$now", NowUnix());
            cmd.Parameters.AddWithValue("$id", jobId);
            cmd.ExecuteNonQuery();
        }
    }

    public int RetryFailedFiles(string jobId)
    {
        lock (_sync)
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "UPDATE job_files SET status = 'Pending', error = NULL, new_size = NULL, saved_bytes = 0, duration_ms = NULL, updated_at = $now WHERE job_id = $id AND status = 'Failed';";
            cmd.Parameters.AddWithValue("$now", NowUnix());
            cmd.Parameters.AddWithValue("$id", jobId);
            return cmd.ExecuteNonQuery();
        }
    }

    public void UpdateFileResult(long fileId, SingleCompressionResult res)
    {
        lock (_sync)
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = """
                UPDATE job_files
                SET status = $st, new_size = $nsz, saved_bytes = $sav, duration_ms = $dur,
                    images_optimized = $img, pages = $pg, error = $err, updated_at = $now
                WHERE id = $id;
                """;
            cmd.Parameters.AddWithValue("$st", res.Status.ToString());
            cmd.Parameters.AddWithValue("$nsz", res.NewSize);
            cmd.Parameters.AddWithValue("$sav", res.SavedBytes);
            cmd.Parameters.AddWithValue("$dur", res.DurationMs);
            cmd.Parameters.AddWithValue("$img", res.ImagesOptimized);
            cmd.Parameters.AddWithValue("$pg", res.Pages);
            cmd.Parameters.AddWithValue("$err", (object?)res.ErrorMessage ?? DBNull.Value);
            cmd.Parameters.AddWithValue("$now", NowUnix());
            cmd.Parameters.AddWithValue("$id", fileId);
            cmd.ExecuteNonQuery();
        }
    }

    public List<JobFileRow> ListJobFiles(string jobId, string statusFilter = "all", string search = "", int limit = 5000)
    {
        lock (_sync)
        {
            var clauses = new List<string> { "job_id = $id" };
            if (statusFilter == "skipped")
                clauses.Add("status LIKE 'Skipped%'");
            else if (!string.IsNullOrEmpty(statusFilter) && statusFilter != "all")
                clauses.Add("status = $st");

            if (!string.IsNullOrWhiteSpace(search))
                clauses.Add("rel_path LIKE $q");

            using var cmd = _conn.CreateCommand();
            cmd.CommandText = $"""
                SELECT id, job_id, rel_path, src_path, dst_path, backup_path, orig_size, orig_mtime, new_size, saved_bytes, status, error, duration_ms, pages
                FROM job_files WHERE {string.Join(" AND ", clauses)} ORDER BY id ASC LIMIT $lim;
                """;
            cmd.Parameters.AddWithValue("$id", jobId);
            if (statusFilter != "skipped" && !string.IsNullOrEmpty(statusFilter) && statusFilter != "all")
                cmd.Parameters.AddWithValue("$st", statusFilter);
            if (!string.IsNullOrWhiteSpace(search))
                cmd.Parameters.AddWithValue("$q", $"%{search.Trim()}%");
            cmd.Parameters.AddWithValue("$lim", limit);

            var rows = new List<JobFileRow>();
            using var r = cmd.ExecuteReader();
            while (r.Read())
                rows.Add(ReadFileRow(r));
            return rows;
        }
    }

    public void RecordFingerprint(string filePath, long fileSize, double mtimeUnix, CompressionPreset preset)
    {
        lock (_sync)
        {
            string norm = Path.GetFullPath(filePath).ToLowerInvariant();
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = """
                INSERT INTO optimized_fingerprints (file_path, file_size, file_mtime, preset, optimized_at)
                VALUES ($p, $sz, $mt, $pr, $now)
                ON CONFLICT(file_path) DO UPDATE SET
                    file_size = excluded.file_size,
                    file_mtime = excluded.file_mtime,
                    preset = excluded.preset,
                    optimized_at = excluded.optimized_at;
                """;
            cmd.Parameters.AddWithValue("$p", norm);
            cmd.Parameters.AddWithValue("$sz", fileSize);
            cmd.Parameters.AddWithValue("$mt", mtimeUnix);
            cmd.Parameters.AddWithValue("$pr", preset.ToString());
            cmd.Parameters.AddWithValue("$now", NowUnix());
            cmd.ExecuteNonQuery();
        }
    }

    public Dictionary<string, (long Size, double Mtime)> GetAllFingerprints()
    {
        lock (_sync)
        {
            var dict = new Dictionary<string, (long, double)>(StringComparer.OrdinalIgnoreCase);
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "SELECT file_path, file_size, file_mtime FROM optimized_fingerprints;";
            using var r = cmd.ExecuteReader();
            while (r.Read())
                dict[r.GetString(0)] = (r.GetInt64(1), r.GetDouble(2));
            return dict;
        }
    }

    public int ClearFingerprints()
    {
        lock (_sync)
        {
            using var cmd = _conn.CreateCommand();
            cmd.CommandText = "DELETE FROM optimized_fingerprints;";
            return cmd.ExecuteNonQuery();
        }
    }

    private static JobRecord ReadJobRow(SqliteDataReader r)
    {
        string cfgJson = r.GetString(6);
        var cfg = JsonSerializer.Deserialize<CompressionConfig>(cfgJson) ?? new CompressionConfig();
        return new JobRecord
        {
            Id = r.GetString(0),
            Name = r.GetString(1),
            SourceSummary = r.GetString(2),
            OutputMode = Enum.TryParse<OutputMode>(r.GetString(3), true, out var om) ? om : OutputMode.Inplace,
            OutputDir = r.IsDBNull(4) ? null : r.GetString(4),
            BackupDir = r.IsDBNull(5) ? null : r.GetString(5),
            Config = cfg,
            Status = Enum.TryParse<JobStatus>(r.GetString(7), true, out var st) ? st : JobStatus.Created,
            CreatedAt = DateTimeOffset.FromUnixTimeMilliseconds((long)(r.GetDouble(8) * 1000)),
            StartedAt = r.IsDBNull(9) ? null : DateTimeOffset.FromUnixTimeMilliseconds((long)(r.GetDouble(9) * 1000)),
            FinishedAt = r.IsDBNull(10) ? null : DateTimeOffset.FromUnixTimeMilliseconds((long)(r.GetDouble(10) * 1000))
        };
    }

    private static JobFileRow ReadFileRow(SqliteDataReader r) => new()
    {
        Id = r.GetInt64(0),
        JobId = r.GetString(1),
        RelativePath = r.GetString(2),
        SourcePath = r.GetString(3),
        DestinationPath = r.GetString(4),
        BackupPath = r.IsDBNull(5) ? null : r.GetString(5),
        OriginalSize = r.GetInt64(6),
        ModificationTimeUnix = r.GetDouble(7),
        NewSize = r.IsDBNull(8) ? null : r.GetInt64(8),
        SavedBytes = r.GetInt64(9),
        Status = Enum.TryParse<FileProcessStatus>(r.GetString(10), true, out var st) ? st : FileProcessStatus.Pending,
        ErrorMessage = r.IsDBNull(11) ? null : r.GetString(11),
        DurationMs = r.IsDBNull(12) ? null : r.GetInt32(12),
        Pages = r.GetInt32(13)
    };

    private static double NowUnix() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    public void Dispose()
    {
        lock (_sync)
        {
            _conn.Close();
            _conn.Dispose();
        }
    }
}
