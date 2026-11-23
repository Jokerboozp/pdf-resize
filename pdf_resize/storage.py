from __future__ import annotations

import json
import sqlite3
import threading
import time
from pathlib import Path
from typing import Any, Optional


from .paths import get_data_dir


DEFAULT_DB_PATH = get_data_dir() / "jobs.db"


class Storage:
    def __init__(self, db_path: Path | str = DEFAULT_DB_PATH) -> None:
        self.db_path = Path(db_path)
        self.db_path.parent.mkdir(parents=True, exist_ok=True)
        self._lock = threading.RLock()
        self._conn = sqlite3.connect(str(self.db_path), check_same_thread=False)
        self._conn.row_factory = sqlite3.Row
        self._init_schema()

    def _init_schema(self) -> None:
        with self._lock:
            cur = self._conn.cursor()
            cur.executescript(
                """
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=NORMAL;
                PRAGMA temp_store=MEMORY;

                CREATE TABLE IF NOT EXISTS jobs (
                    id TEXT PRIMARY KEY,
                    name TEXT NOT NULL,
                    source_type TEXT NOT NULL,
                    source_dir TEXT NOT NULL,
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
                    images_optimized INTEGER NOT NULL DEFAULT 0,
                    pages INTEGER NOT NULL DEFAULT 0,
                    updated_at REAL NOT NULL,
                    FOREIGN KEY (job_id) REFERENCES jobs(id) ON DELETE CASCADE
                );

                CREATE INDEX IF NOT EXISTS idx_job_files_job_status
                    ON job_files(job_id, status);
                CREATE INDEX IF NOT EXISTS idx_job_files_job_id
                    ON job_files(job_id, id);

                CREATE TABLE IF NOT EXISTS optimized_fingerprints (
                    file_path TEXT PRIMARY KEY,
                    file_size INTEGER NOT NULL,
                    file_mtime REAL NOT NULL,
                    preset TEXT NOT NULL,
                    optimized_at REAL NOT NULL
                );
                """
            )
            self._conn.commit()

    def close(self) -> None:
        with self._lock:
            self._conn.close()

    def recover_interrupted_jobs(self) -> None:
        """Reset any jobs/files left running after an abrupt shutdown."""
        now = time.time()
        with self._lock:
            self._conn.execute(
                "UPDATE job_files SET status = 'pending', updated_at = ? WHERE status = 'processing'",
                (now,),
            )
            self._conn.execute(
                "UPDATE jobs SET status = 'paused' WHERE status = 'running'"
            )
            self._conn.commit()

    def create_job(
        self,
        *,
        job_id: str,
        name: str,
        source_type: str,
        source_dir: str,
        output_mode: str,
        output_dir: Optional[str],
        backup_dir: Optional[str],
        config_dict: dict[str, Any],
        status: str = "created",
    ) -> dict[str, Any]:
        now = time.time()
        with self._lock:
            self._conn.execute(
                """
                INSERT INTO jobs (
                    id, name, source_type, source_dir, output_mode,
                    output_dir, backup_dir, config_json, status, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                (
                    job_id,
                    name,
                    source_type,
                    source_dir,
                    output_mode,
                    output_dir,
                    backup_dir,
                    json.dumps(config_dict, ensure_ascii=False),
                    status,
                    now,
                ),
            )
            self._conn.commit()
        return self.get_job(job_id)  # type: ignore[return-value]

    def add_files_bulk(self, job_id: str, files: list[dict[str, Any]]) -> int:
        if not files:
            return 0
        now = time.time()
        rows = [
            (
                job_id,
                f["rel_path"],
                f["src_path"],
                f["dst_path"],
                f.get("backup_path"),
                int(f["orig_size"]),
                float(f["orig_mtime"]),
                f.get("status", "pending"),
                int(f["orig_size"]) if f.get("status", "pending") != "pending" else None,
                0,
                f.get("error"),
                now,
            )
            for f in files
        ]
        with self._lock:
            self._conn.executemany(
                """
                INSERT INTO job_files (
                    job_id, rel_path, src_path, dst_path, backup_path,
                    orig_size, orig_mtime, status, new_size, saved_bytes, error, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                rows,
            )
            self._conn.commit()
        return len(rows)

    def update_job_status(
        self,
        job_id: str,
        status: str,
        *,
        set_started: bool = False,
        set_finished: bool = False,
    ) -> None:
        now = time.time()
        with self._lock:
            if set_started:
                self._conn.execute(
                    "UPDATE jobs SET status = ?, started_at = COALESCE(started_at, ?) WHERE id = ?",
                    (status, now, job_id),
                )
            elif set_finished:
                self._conn.execute(
                    "UPDATE jobs SET status = ?, finished_at = ? WHERE id = ?",
                    (status, now, job_id),
                )
            else:
                self._conn.execute(
                    "UPDATE jobs SET status = ? WHERE id = ?",
                    (status, job_id),
                )
            self._conn.commit()

    def get_job(self, job_id: str) -> Optional[dict[str, Any]]:
        with self._lock:
            row = self._conn.execute("SELECT * FROM jobs WHERE id = ?", (job_id,)).fetchone()
            if not row:
                return None
            return self._job_row_to_dict(row)

    def list_jobs(self, limit: int = 50) -> list[dict[str, Any]]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT * FROM jobs ORDER BY created_at DESC LIMIT ?", (limit,)
            ).fetchall()
            jobs = [self._job_row_to_dict(r) for r in rows]
        for j in jobs:
            j["stats"] = self.get_job_stats(j["id"])
        return jobs

    def delete_job(self, job_id: str) -> bool:
        with self._lock:
            self._conn.execute("DELETE FROM job_files WHERE job_id = ?", (job_id,))
            cur = self._conn.execute("DELETE FROM jobs WHERE id = ?", (job_id,))
            self._conn.commit()
            return cur.rowcount > 0

    def get_job_stats(self, job_id: str) -> dict[str, Any]:
        with self._lock:
            row = self._conn.execute(
                """
                SELECT
                    COUNT(*) AS total_files,
                    SUM(CASE WHEN status = 'pending' THEN 1 ELSE 0 END) AS pending,
                    SUM(CASE WHEN status = 'processing' THEN 1 ELSE 0 END) AS processing,
                    SUM(CASE WHEN status = 'done' THEN 1 ELSE 0 END) AS done,
                    SUM(CASE WHEN status LIKE 'skipped_%' THEN 1 ELSE 0 END) AS skipped,
                    SUM(CASE WHEN status = 'failed' THEN 1 ELSE 0 END) AS failed,
                    COALESCE(SUM(orig_size), 0) AS total_orig_bytes,
                    COALESCE(SUM(CASE WHEN status NOT IN ('pending', 'processing') THEN orig_size ELSE 0 END), 0) AS processed_orig_bytes,
                    COALESCE(SUM(CASE WHEN status NOT IN ('pending', 'processing') THEN COALESCE(new_size, orig_size) ELSE 0 END), 0) AS processed_new_bytes,
                    COALESCE(SUM(CASE WHEN status = 'done' THEN saved_bytes ELSE 0 END), 0) AS saved_bytes,
                    COALESCE(SUM(images_optimized), 0) AS images_optimized
                FROM job_files
                WHERE job_id = ?
                """,
                (job_id,),
            ).fetchone()

        total_files = int(row["total_files"] or 0)
        pending = int(row["pending"] or 0)
        processing = int(row["processing"] or 0)
        done = int(row["done"] or 0)
        skipped = int(row["skipped"] or 0)
        failed = int(row["failed"] or 0)
        completed_files = done + skipped + failed
        total_orig_bytes = int(row["total_orig_bytes"] or 0)
        processed_orig_bytes = int(row["processed_orig_bytes"] or 0)
        processed_new_bytes = int(row["processed_new_bytes"] or 0)
        saved_bytes = int(row["saved_bytes"] or 0)
        saving_percent = (
            round((saved_bytes / processed_orig_bytes) * 100.0, 2)
            if processed_orig_bytes > 0
            else 0.0
        )
        progress_files_pct = (
            round((completed_files / total_files) * 100.0, 2) if total_files > 0 else 0.0
        )
        progress_bytes_pct = (
            round((processed_orig_bytes / total_orig_bytes) * 100.0, 2)
            if total_orig_bytes > 0
            else progress_files_pct
        )

        return {
            "total_files": total_files,
            "pending": pending,
            "processing": processing,
            "done": done,
            "skipped": skipped,
            "failed": failed,
            "completed_files": completed_files,
            "total_orig_bytes": total_orig_bytes,
            "processed_orig_bytes": processed_orig_bytes,
            "processed_new_bytes": processed_new_bytes,
            "saved_bytes": saved_bytes,
            "saving_percent": saving_percent,
            "progress_files_pct": progress_files_pct,
            "progress_bytes_pct": progress_bytes_pct,
            "images_optimized": int(row["images_optimized"] or 0),
        }

    def claim_pending_files(self, job_id: str, limit: int) -> list[dict[str, Any]]:
        """Atomically claim up to `limit` pending files and mark them processing."""
        now = time.time()
        with self._lock:
            rows = self._conn.execute(
                """
                SELECT * FROM job_files
                WHERE job_id = ? AND status = 'pending'
                ORDER BY id ASC
                LIMIT ?
                """,
                (job_id, limit),
            ).fetchall()
            if not rows:
                return []
            ids = [r["id"] for r in rows]
            placeholders = ",".join("?" for _ in ids)
            self._conn.execute(
                f"UPDATE job_files SET status = 'processing', updated_at = ? WHERE id IN ({placeholders})",
                [now, *ids],
            )
            self._conn.commit()
            return [dict(r) for r in rows]

    def reset_job_processing_to_pending(self, job_id: str) -> None:
        now = time.time()
        with self._lock:
            self._conn.execute(
                "UPDATE job_files SET status = 'pending', updated_at = ? WHERE job_id = ? AND status = 'processing'",
                (now, job_id),
            )
            self._conn.commit()

    def retry_failed_files(self, job_id: str) -> int:
        now = time.time()
        with self._lock:
            cur = self._conn.execute(
                """
                UPDATE job_files
                SET status = 'pending', error = NULL, new_size = NULL, saved_bytes = 0, duration_ms = NULL, updated_at = ?
                WHERE job_id = ? AND status = 'failed'
                """,
                (now, job_id),
            )
            self._conn.commit()
            return cur.rowcount

    def update_file_result(
        self,
        file_id: int,
        *,
        status: str,
        new_size: int,
        saved_bytes: int,
        duration_ms: int,
        images_optimized: int,
        pages: int,
        error: Optional[str] = None,
    ) -> None:
        now = time.time()
        with self._lock:
            self._conn.execute(
                """
                UPDATE job_files
                SET status = ?, new_size = ?, saved_bytes = ?, duration_ms = ?,
                    images_optimized = ?, pages = ?, error = ?, updated_at = ?
                WHERE id = ?
                """,
                (
                    status,
                    new_size,
                    saved_bytes,
                    duration_ms,
                    images_optimized,
                    pages,
                    error,
                    now,
                    file_id,
                ),
            )
            self._conn.commit()

    def list_job_files(
        self,
        job_id: str,
        *,
        status: str = "all",
        search: str = "",
        sort_by: str = "id",
        sort_dir: str = "asc",
        page: int = 1,
        page_size: int = 50,
    ) -> dict[str, Any]:
        where = ["job_id = ?"]
        params: list[Any] = [job_id]

        if status == "skipped":
            where.append("status LIKE 'skipped_%'")
        elif status and status != "all":
            where.append("status = ?")
            params.append(status)

        if search:
            where.append("rel_path LIKE ?")
            params.append(f"%{search}%")

        where_sql = " AND ".join(where)

        allowed_sorts = {
            "id": "id",
            "rel_path": "rel_path",
            "orig_size": "orig_size",
            "new_size": "COALESCE(new_size, orig_size)",
            "saved_bytes": "saved_bytes",
            "status": "status",
            "updated_at": "updated_at",
        }
        order_col = allowed_sorts.get(sort_by, "id")
        direction = "DESC" if sort_dir.lower() == "desc" else "ASC"

        page = max(1, page)
        page_size = max(10, min(200, page_size))
        offset = (page - 1) * page_size

        with self._lock:
            total = int(
                self._conn.execute(
                    f"SELECT COUNT(*) FROM job_files WHERE {where_sql}", params
                ).fetchone()[0]
            )
            rows = self._conn.execute(
                f"""
                SELECT * FROM job_files
                WHERE {where_sql}
                ORDER BY {order_col} {direction}
                LIMIT ? OFFSET ?
                """,
                [*params, page_size, offset],
            ).fetchall()

        return {
            "items": [dict(r) for r in rows],
            "total": total,
            "page": page,
            "page_size": page_size,
            "total_pages": max(1, (total + page_size - 1) // page_size),
        }

    def get_file_record(self, job_id: str, file_id: int) -> Optional[dict[str, Any]]:
        with self._lock:
            row = self._conn.execute(
                "SELECT * FROM job_files WHERE job_id = ? AND id = ?",
                (job_id, file_id),
            ).fetchone()
            return dict(row) if row else None

    def record_fingerprint(
        self, file_path: str, file_size: int, file_mtime: float, preset: str
    ) -> None:
        norm = str(Path(file_path).resolve()).lower()
        with self._lock:
            self._conn.execute(
                """
                INSERT INTO optimized_fingerprints (file_path, file_size, file_mtime, preset, optimized_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(file_path) DO UPDATE SET
                    file_size = excluded.file_size,
                    file_mtime = excluded.file_mtime,
                    preset = excluded.preset,
                    optimized_at = excluded.optimized_at
                """,
                (norm, int(file_size), float(file_mtime), preset, time.time()),
            )
            self._conn.commit()

    def get_all_fingerprints(self) -> dict[str, tuple[int, float]]:
        with self._lock:
            rows = self._conn.execute(
                "SELECT file_path, file_size, file_mtime FROM optimized_fingerprints"
            ).fetchall()
            return {r["file_path"]: (int(r["file_size"]), float(r["file_mtime"])) for r in rows}

    def clear_fingerprints(self) -> int:
        with self._lock:
            cur = self._conn.execute("DELETE FROM optimized_fingerprints")
            self._conn.commit()
            return cur.rowcount

    @staticmethod
    def _job_row_to_dict(row: sqlite3.Row) -> dict[str, Any]:
        d = dict(row)
        d["config"] = json.loads(d.pop("config_json"))
        return d
