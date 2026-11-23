from __future__ import annotations

import os
import threading
import time
import uuid
from collections import deque
from concurrent.futures import FIRST_COMPLETED, Future, ProcessPoolExecutor, wait
from pathlib import Path
from typing import Any, Optional

from .compressor import TMP_SUFFIX, CompressionResult, compress_pdf_file
from .models import CompressionConfig
from .storage import Storage


def _worker_compress(
    src_path: str,
    dst_path: str,
    config_dict: dict[str, Any],
    inplace: bool,
    backup_path: Optional[str],
) -> dict[str, Any]:
    """Top-level picklable worker function for ProcessPoolExecutor."""
    cfg = CompressionConfig(**config_dict)
    res: CompressionResult = compress_pdf_file(
        src_path,
        dst_path,
        cfg,
        inplace=inplace,
        backup_path=backup_path,
    )
    return {
        "status": res.status,
        "orig_size": res.orig_size,
        "new_size": res.new_size,
        "saved_bytes": res.saved_bytes,
        "duration_ms": res.duration_ms,
        "images_optimized": res.images_optimized,
        "pages": res.pages,
        "error": res.error,
        "new_mtime": res.new_mtime,
    }


def scan_pdf_directory(
    root_dir: str | Path,
    *,
    recursive: bool = True,
    skip_smaller_than_kb: int = 0,
    fingerprints: Optional[dict[str, tuple[int, float]]] = None,
    limit_files: Optional[int] = None,
) -> dict[str, Any]:
    """Fast recursive directory scanner using os.scandir for thousands of PDFs."""
    root = Path(root_dir).resolve()
    if not root.exists() or not root.is_dir():
        raise ValueError(f"目录不存在或不可访问: {root_dir}")

    files: list[dict[str, Any]] = []
    total_bytes = 0
    already_optimized_count = 0
    too_small_count = 0
    min_bytes = max(0, skip_smaller_than_kb) * 1024

    def _walk(current: Path) -> None:
        nonlocal total_bytes, already_optimized_count, too_small_count
        try:
            with os.scandir(current) as it:
                entries = sorted(it, key=lambda e: e.name.lower())
        except PermissionError:
            return

        for entry in entries:
            if limit_files and len(files) >= limit_files:
                return
            try:
                if entry.is_dir(follow_symlinks=False):
                    if recursive:
                        _walk(Path(entry.path))
                elif entry.is_file(follow_symlinks=False):
                    name_lower = entry.name.lower()
                    if not name_lower.endswith(".pdf") or name_lower.endswith(TMP_SUFFIX):
                        continue
                    st = entry.stat(follow_symlinks=False)
                    size = st.st_size
                    mtime = st.st_mtime
                    abs_path = str(Path(entry.path).resolve())
                    rel_path = str(Path(abs_path).relative_to(root))

                    status = "pending"
                    if fingerprints:
                        fp = fingerprints.get(abs_path.lower())
                        if fp and fp[0] == size and abs(fp[1] - mtime) < 2.0:
                            status = "skipped_already_done"
                            already_optimized_count += 1
                    if status == "pending" and min_bytes > 0 and size < min_bytes:
                        status = "skipped_small"
                        too_small_count += 1

                    total_bytes += size
                    files.append(
                        {
                            "rel_path": rel_path,
                            "src_path": abs_path,
                            "orig_size": size,
                            "orig_mtime": mtime,
                            "status": status,
                        }
                    )
            except OSError:
                continue

    _walk(root)
    return {
        "root_dir": str(root),
        "total_files": len(files),
        "total_bytes": total_bytes,
        "already_optimized_count": already_optimized_count,
        "too_small_count": too_small_count,
        "pending_count": len(files) - already_optimized_count - too_small_count,
        "files": files,
    }


class _ActiveJobRuntime:
    def __init__(self, job_id: str) -> None:
        self.job_id = job_id
        self.pause_event = threading.Event()
        self.cancel_event = threading.Event()
        self.thread: Optional[threading.Thread] = None
        self.speed_window: deque[tuple[float, int]] = deque(maxlen=60)
        self.recent_events: deque[dict[str, Any]] = deque(maxlen=30)
        self.active_files: dict[int, str] = {}
        self.lock = threading.Lock()

    def record_progress(self, orig_bytes: int, event: dict[str, Any]) -> None:
        now = time.time()
        with self.lock:
            self.speed_window.append((now, orig_bytes))
            self.recent_events.appendleft(event)

    def get_live_metrics(self, remaining_bytes: int) -> dict[str, Any]:
        now = time.time()
        with self.lock:
            # Compute throughput over the last 30 seconds
            cutoff = now - 30.0
            window_bytes = sum(b for ts, b in self.speed_window if ts >= cutoff)
            earliest = min((ts for ts, _ in self.speed_window if ts >= cutoff), default=now)
            elapsed = max(1.0, now - earliest)
            bytes_per_sec = window_bytes / elapsed if window_bytes > 0 else 0.0
            eta_seconds = int(remaining_bytes / bytes_per_sec) if bytes_per_sec > 1 else None
            return {
                "bytes_per_sec": round(bytes_per_sec, 1),
                "eta_seconds": eta_seconds,
                "active_files": list(self.active_files.values()),
                "recent_events": list(self.recent_events)[:15],
            }


class JobManager:
    def __init__(self, storage: Storage) -> None:
        self.storage = storage
        self.storage.recover_interrupted_jobs()
        self._lock = threading.RLock()
        self._runtimes: dict[str, _ActiveJobRuntime] = {}
        self._version_cond = threading.Condition()
        self._version = 0

    def _notify_update(self) -> None:
        with self._version_cond:
            self._version += 1
            self._version_cond.notify_all()

    def wait_for_update(self, last_version: int, timeout: float = 1.0) -> int:
        with self._version_cond:
            if self._version == last_version:
                self._version_cond.wait(timeout=timeout)
            return self._version

    def create_local_job(
        self,
        *,
        source_dir: str,
        output_mode: str,
        output_dir: Optional[str],
        backup_dir: Optional[str],
        config: CompressionConfig,
        recursive: bool = True,
        name: Optional[str] = None,
        limit_files: Optional[int] = None,
        auto_start: bool = True,
    ) -> dict[str, Any]:
        src_root = Path(source_dir).resolve()
        if not src_root.exists() or not src_root.is_dir():
            raise ValueError(f"源目录不存在: {source_dir}")

        if output_mode == "output_dir":
            if not output_dir or not output_dir.strip():
                raise ValueError("选择输出到新目录时，必须指定输出目录路径")
            out_root = Path(output_dir).resolve()
            out_root.mkdir(parents=True, exist_ok=True)
        else:
            out_root = src_root

        bkp_root = Path(backup_dir).resolve() if backup_dir and backup_dir.strip() else None
        if bkp_root:
            bkp_root.mkdir(parents=True, exist_ok=True)

        fingerprints = (
            self.storage.get_all_fingerprints()
            if (config.skip_already_optimized and output_mode == "inplace")
            else None
        )
        scan = scan_pdf_directory(
            src_root,
            recursive=recursive,
            skip_smaller_than_kb=config.skip_smaller_than_kb,
            fingerprints=fingerprints,
            limit_files=limit_files,
        )
        if scan["total_files"] == 0:
            raise ValueError("该目录下未找到任何 PDF 文件")

        job_id = uuid.uuid4().hex[:12]
        job_name = name or f"{src_root.name} ({scan['total_files']} 个 PDF)"

        self.storage.create_job(
            job_id=job_id,
            name=job_name,
            source_type="local_dir",
            source_dir=str(src_root),
            output_mode=output_mode,
            output_dir=str(out_root) if output_mode == "output_dir" else None,
            backup_dir=str(bkp_root) if bkp_root else None,
            config_dict=config.model_dump(),
            status="created",
        )

        bulk_rows: list[dict[str, Any]] = []
        for f in scan["files"]:
            rel = f["rel_path"]
            dst_path = f["src_path"] if output_mode == "inplace" else str(out_root / rel)
            bkp_path = str(bkp_root / rel) if (output_mode == "inplace" and bkp_root) else None
            bulk_rows.append(
                {
                    "rel_path": rel,
                    "src_path": f["src_path"],
                    "dst_path": dst_path,
                    "backup_path": bkp_path,
                    "orig_size": f["orig_size"],
                    "orig_mtime": f["orig_mtime"],
                    "status": f["status"],
                }
            )
        self.storage.add_files_bulk(job_id, bulk_rows)

        if auto_start:
            self.start_job(job_id)

        return self.get_job_detail(job_id)  # type: ignore[return-value]

    def create_upload_job(
        self,
        *,
        upload_root: Path,
        output_dir: Optional[str],
        config: CompressionConfig,
        name: Optional[str] = None,
    ) -> dict[str, Any]:
        job_id = uuid.uuid4().hex[:12]
        src_dir = (upload_root / job_id / "input").resolve()
        out_dir = (
            Path(output_dir).resolve()
            if output_dir and output_dir.strip()
            else (upload_root / job_id / "output").resolve()
        )
        src_dir.mkdir(parents=True, exist_ok=True)
        out_dir.mkdir(parents=True, exist_ok=True)

        self.storage.create_job(
            job_id=job_id,
            name=name or f"批量上传任务 {job_id[:6]}",
            source_type="upload",
            source_dir=str(src_dir),
            output_mode="output_dir",
            output_dir=str(out_dir),
            backup_dir=None,
            config_dict=config.model_dump(),
            status="created",
        )
        return self.get_job_detail(job_id)  # type: ignore[return-value]

    def register_uploaded_file(
        self, job_id: str, rel_path: str, src_path: Path, dst_path: Path
    ) -> None:
        st = src_path.stat()
        self.storage.add_files_bulk(
            job_id,
            [
                {
                    "rel_path": rel_path,
                    "src_path": str(src_path),
                    "dst_path": str(dst_path),
                    "backup_path": None,
                    "orig_size": st.st_size,
                    "orig_mtime": st.st_mtime,
                    "status": "pending",
                }
            ],
        )
        self._notify_update()

    def start_job(self, job_id: str) -> bool:
        job = self.storage.get_job(job_id)
        if not job:
            raise ValueError("任务不存在")

        with self._lock:
            rt = self._runtimes.get(job_id)
            if rt and rt.thread and rt.thread.is_alive():
                return False
            self.storage.reset_job_processing_to_pending(job_id)
            self.storage.update_job_status(job_id, "running", set_started=True)
            rt = _ActiveJobRuntime(job_id)
            self._runtimes[job_id] = rt
            t = threading.Thread(target=self._run_job_loop, args=(job_id, rt), daemon=True)
            rt.thread = t
            t.start()
        self._notify_update()
        return True

    def pause_job(self, job_id: str) -> bool:
        with self._lock:
            rt = self._runtimes.get(job_id)
            if rt:
                rt.pause_event.set()
                self._notify_update()
                return True
        return False

    def cancel_job(self, job_id: str) -> bool:
        with self._lock:
            rt = self._runtimes.get(job_id)
            if rt:
                rt.cancel_event.set()
                self._notify_update()
                return True
        job = self.storage.get_job(job_id)
        if job and job["status"] in ("created", "paused"):
            self.storage.update_job_status(job_id, "cancelled", set_finished=True)
            self._notify_update()
            return True
        return False

    def retry_failed(self, job_id: str) -> int:
        count = self.storage.retry_failed_files(job_id)
        if count > 0:
            self.start_job(job_id)
        return count

    def get_job_detail(self, job_id: str) -> Optional[dict[str, Any]]:
        job = self.storage.get_job(job_id)
        if not job:
            return None
        stats = self.storage.get_job_stats(job_id)
        job["stats"] = stats
        remaining_bytes = max(0, stats["total_orig_bytes"] - stats["processed_orig_bytes"])
        with self._lock:
            rt = self._runtimes.get(job_id)
        if rt:
            job["live"] = rt.get_live_metrics(remaining_bytes)
        else:
            job["live"] = {
                "bytes_per_sec": 0.0,
                "eta_seconds": None,
                "active_files": [],
                "recent_events": [],
            }
        return job

    def _run_job_loop(self, job_id: str, rt: _ActiveJobRuntime) -> None:
        job = self.storage.get_job(job_id)
        if not job:
            return

        cfg_dict = job["config"]
        cfg = CompressionConfig(**cfg_dict)
        inplace = job["output_mode"] == "inplace"
        max_workers = max(1, min(cfg.workers, os.cpu_count() or 8))
        max_inflight = max_workers * 2

        in_flight: dict[Future, dict[str, Any]] = {}

        try:
            # max_tasks_per_child recycles worker processes periodically to avoid C-library memory retention over 3000+ PDFs
            with ProcessPoolExecutor(
                max_workers=max_workers, max_tasks_per_child=25
            ) as executor:
                while True:
                    # Fill sliding window if neither paused nor cancelled
                    if not rt.pause_event.is_set() and not rt.cancel_event.is_set():
                        slots = max_inflight - len(in_flight)
                        if slots > 0:
                            batch = self.storage.claim_pending_files(job_id, slots)
                            for rec in batch:
                                fut = executor.submit(
                                    _worker_compress,
                                    rec["src_path"],
                                    rec["dst_path"],
                                    cfg_dict,
                                    inplace,
                                    rec.get("backup_path"),
                                )
                                in_flight[fut] = rec
                                with rt.lock:
                                    rt.active_files[rec["id"]] = rec["rel_path"]
                            if batch:
                                self._notify_update()

                    if not in_flight:
                        break

                    done_futs, _ = wait(
                        in_flight.keys(), timeout=0.5, return_when=FIRST_COMPLETED
                    )

                    for fut in done_futs:
                        rec = in_flight.pop(fut)
                        with rt.lock:
                            rt.active_files.pop(rec["id"], None)

                        try:
                            res = fut.result()
                        except Exception as exc:
                            res = {
                                "status": "failed",
                                "orig_size": rec["orig_size"],
                                "new_size": rec["orig_size"],
                                "saved_bytes": 0,
                                "duration_ms": 0,
                                "images_optimized": 0,
                                "pages": 0,
                                "error": f"工作进程异常: {exc}",
                                "new_mtime": None,
                            }

                        self.storage.update_file_result(
                            rec["id"],
                            status=res["status"],
                            new_size=res["new_size"],
                            saved_bytes=res["saved_bytes"],
                            duration_ms=res["duration_ms"],
                            images_optimized=res["images_optimized"],
                            pages=res["pages"],
                            error=res["error"],
                        )

                        # Record fingerprint for in-place optimized or already optimal files
                        if inplace and res["status"] in ("done", "skipped_no_gain"):
                            mtime = res.get("new_mtime") or rec["orig_mtime"]
                            self.storage.record_fingerprint(
                                rec["src_path"],
                                res["new_size"],
                                mtime,
                                cfg.preset,
                            )

                        rt.record_progress(
                            rec["orig_size"],
                            {
                                "rel_path": rec["rel_path"],
                                "status": res["status"],
                                "orig_size": rec["orig_size"],
                                "new_size": res["new_size"],
                                "saved_bytes": res["saved_bytes"],
                                "duration_ms": res["duration_ms"],
                                "error": res["error"],
                                "ts": time.time(),
                            },
                        )
                        self._notify_update()

            if rt.cancel_event.is_set():
                self.storage.reset_job_processing_to_pending(job_id)
                self.storage.update_job_status(job_id, "cancelled", set_finished=True)
            elif rt.pause_event.is_set():
                self.storage.reset_job_processing_to_pending(job_id)
                self.storage.update_job_status(job_id, "paused")
            else:
                self.storage.update_job_status(job_id, "completed", set_finished=True)

        except Exception:
            self.storage.reset_job_processing_to_pending(job_id)
            self.storage.update_job_status(job_id, "failed", set_finished=True)
        finally:
            self._notify_update()
