from __future__ import annotations

import asyncio
from contextlib import asynccontextmanager
import json
import os
import shutil
import string
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import Any, Optional

from fastapi import FastAPI, File, Form, HTTPException, Query, Request, UploadFile
from fastapi.responses import FileResponse, HTMLResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

from .manager import JobManager, scan_pdf_directories
from .models import (
    PRESETS,
    CompressionConfig,
    CreateLocalJobRequest,
    CreateUploadJobRequest,
    PreviewRequest,
    ScanDirRequest,
    default_workers,
)
from .preview import get_preview_image_path, run_single_preview
from .storage import Storage

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"
DATA_DIR = BASE_DIR.parent / "data"
UPLOAD_ROOT = DATA_DIR / "uploads"

storage = Storage(DATA_DIR / "jobs.db")
manager = JobManager(storage, recover=False)


class NoCacheStaticFiles(StaticFiles):
    """Serve static assets with no-store headers without wrapping SSE in BaseHTTPMiddleware."""

    async def get_response(self, path: str, scope):
        response = await super().get_response(path, scope)
        response.headers["Cache-Control"] = "no-store, no-cache, must-revalidate"
        response.headers["Pragma"] = "no-cache"
        return response


@asynccontextmanager
async def _lifespan(_app: FastAPI):
    # Recover interrupted jobs only when the main ASGI server starts (never on worker import)
    manager.recover_on_startup()
    yield


app = FastAPI(title="PDF Resize", version="1.0.0", lifespan=_lifespan)
app.mount("/static", NoCacheStaticFiles(directory=str(STATIC_DIR)), name="static")


def _static_version() -> str:
    mtimes = []
    for name in ("index.html", "app.js", "styles.css"):
        p = STATIC_DIR / name
        if p.exists():
            mtimes.append(int(p.stat().st_mtime_ns))
    return str(max(mtimes) if mtimes else 1)


def _safe_rel_path(raw: str) -> str:
    """Sanitize a client-supplied relative path against directory traversal."""
    cleaned = raw.replace("\\", "/").lstrip("/")
    parts = [p for p in cleaned.split("/") if p not in ("", ".", "..")]
    if not parts:
        return "document.pdf"
    return "/".join(parts)


@app.get("/", response_class=HTMLResponse)
def index() -> HTMLResponse:
    html_path = STATIC_DIR / "index.html"
    ver = _static_version()
    html = (
        html_path.read_text(encoding="utf-8")
        .replace('href="/static/styles.css"', f'href="/static/styles.css?v={ver}"')
        .replace('src="/static/app.js"', f'src="/static/app.js?v={ver}"')
    )
    return HTMLResponse(
        html,
        headers={
            "Cache-Control": "no-store, no-cache, must-revalidate",
            "Pragma": "no-cache",
        },
    )


@app.get("/api/system")
def system_info() -> dict[str, Any]:
    return {
        "cpu_count": os.cpu_count() or 4,
        "recommended_workers": default_workers(),
        "presets": PRESETS,
        "default_config": CompressionConfig().model_dump(),
        "platform": sys.platform,
        "data_dir": str(DATA_DIR.resolve()),
    }


@app.get("/api/fs/list")
def fs_list(path: str = Query(default="")) -> dict[str, Any]:
    """List drives (Windows) or quick roots (macOS/Linux) and subdirectories."""
    raw = path.strip()
    if not raw:
        if os.name == "nt":
            drives = []
            for letter in string.ascii_uppercase:
                drive = f"{letter}:\\"
                if os.path.exists(drive):
                    drives.append({"name": drive, "path": drive, "is_drive": True})
            return {"current": "", "parent": None, "entries": drives}

        # macOS / Linux quick access roots (Home, Desktop, Documents, Downloads, external Volumes, /)
        entries = []
        home = Path.home()
        quick_paths = [
            (f"主目录 ({home.name})", home),
            ("桌面 (Desktop)", home / "Desktop"),
            ("文稿 (Documents)", home / "Documents"),
            ("下载 (Downloads)", home / "Downloads"),
        ]
        for label, p in quick_paths:
            if p.exists() and p.is_dir():
                entries.append({"name": label, "path": str(p.resolve()), "is_drive": True})
        volumes = Path("/Volumes")
        if volumes.exists() and volumes.is_dir():
            try:
                for v in sorted(volumes.iterdir(), key=lambda x: x.name.lower()):
                    if v.is_dir():
                        entries.append({"name": f"磁盘: {v.name}", "path": str(v), "is_drive": True})
            except OSError:
                pass
        entries.append({"name": "根目录 (/)", "path": "/", "is_drive": True})
        return {"current": "", "parent": None, "entries": entries}

    target = Path(raw).resolve()
    if not target.exists() or not target.is_dir():
        raise HTTPException(status_code=400, detail=f"目录不存在: {raw}")

    entries = []
    pdf_count_here = 0
    try:
        with os.scandir(target) as it:
            for entry in it:
                try:
                    if entry.is_dir(follow_symlinks=False):
                        entries.append(
                            {
                                "name": entry.name,
                                "path": str(Path(entry.path).resolve()),
                                "is_drive": False,
                            }
                        )
                    elif entry.is_file(follow_symlinks=False) and entry.name.lower().endswith(".pdf"):
                        pdf_count_here += 1
                except OSError:
                    continue
    except PermissionError:
        raise HTTPException(status_code=403, detail=f"无权限访问目录: {target}")

    entries.sort(key=lambda e: e["name"].lower())
    parent_str: Optional[str] = None
    if target.parent != target:
        parent_str = str(target.parent)
    else:
        parent_str = ""  # Back to drives / quick roots list

    return {
        "current": str(target),
        "parent": parent_str,
        "pdf_count_here": pdf_count_here,
        "entries": entries,
    }


@app.post("/api/fs/pick-folder")
def fs_pick_folder(multiple: bool = Query(default=False)) -> dict[str, Any]:
    """Open a native OS folder selection dialog (supports multi-select on macOS)."""
    if sys.platform == "darwin":
        try:
            if multiple:
                script = (
                    "activate\n"
                    'set chosenFolders to choose folder with prompt "可按住 Command(⌘) 多选多个包含 PDF 的文件夹" '
                    "with multiple selections allowed\n"
                    'set out to ""\n'
                    "repeat with f in chosenFolders\n"
                    "  set out to out & POSIX path of f & linefeed\n"
                    "end repeat\n"
                    "return out"
                )
            else:
                script = 'activate\nPOSIX path of (choose folder with prompt "选择包含 PDF 的文件夹")'

            proc = subprocess.run(
                ["osascript", "-e", script],
                capture_output=True,
                text=True,
                timeout=120,
            )
            if proc.returncode != 0:
                err_txt = (proc.stderr or "").strip()
                # -128 is standard macOS "User canceled"
                if "-128" in err_txt or "User canceled" in err_txt or not err_txt:
                    return {"path": None, "paths": []}
                raise HTTPException(
                    status_code=500,
                    detail=f"系统弹窗失败（请改用「浏览添加」或直接粘贴路径）: {err_txt}",
                )
            paths = [
                line.strip().rstrip("/") or "/"
                for line in proc.stdout.splitlines()
                if line.strip()
            ]
            return {"path": paths[0] if paths else None, "paths": paths}
        except HTTPException:
            raise
        except Exception as exc:
            raise HTTPException(status_code=500, detail=f"无法打开 macOS 文件夹选择器: {exc}")

    script = (
        "import tkinter as tk; from tkinter import filedialog; "
        "r = tk.Tk(); r.withdraw(); r.attributes('-topmost', True); "
        "p = filedialog.askdirectory(title='选择包含 PDF 的文件夹'); "
        "print(p or ''); r.destroy()"
    )
    try:
        proc = subprocess.run(
            [sys.executable, "-c", script],
            capture_output=True,
            text=True,
            timeout=120,
        )
        selected = proc.stdout.strip()
        return {"path": selected or None, "paths": [selected] if selected else []}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"无法打开系统文件夹选择器: {exc}")


@app.post("/api/fs/open-folder")
def fs_open_folder(payload: dict[str, str]) -> dict[str, Any]:
    raw_path = payload.get("path", "").strip()
    if not raw_path:
        raise HTTPException(status_code=400, detail="路径为空")
    # If multi-folder display string "dirA ; dirB", open the first existing folder
    candidates = [s.strip() for s in raw_path.split(" ; ") if s.strip()]
    p = None
    for c in candidates:
        cand = Path(c).expanduser().resolve()
        if cand.exists():
            p = cand
            break
    if p is None:
        raise HTTPException(status_code=404, detail="路径不存在")
    target = p if p.is_dir() else p.parent
    try:
        if os.name == "nt":
            os.startfile(str(target))  # type: ignore[attr-defined]
        elif sys.platform == "darwin":
            subprocess.Popen(["open", str(target)])
        else:
            subprocess.Popen(["xdg-open", str(target)])
        return {"ok": True, "path": str(target)}
    except Exception as exc:
        raise HTTPException(status_code=500, detail=str(exc))


@app.post("/api/scan")
def api_scan(req: ScanDirRequest) -> dict[str, Any]:
    paths = req.resolved_paths()
    if not paths:
        raise HTTPException(status_code=400, detail="请至少添加一个目录路径")
    try:
        fps = storage.get_all_fingerprints() if req.skip_already_optimized else None
        res = scan_pdf_directories(
            paths,
            recursive=req.recursive,
            skip_smaller_than_kb=req.skip_smaller_than_kb,
            fingerprints=fps,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))

    # Return summary + per-folder stats + largest 20 sample files
    samples = sorted(res["files"], key=lambda x: x["orig_size"], reverse=True)[:20]
    return {
        "root_dir": res["root_dir"],
        "root_dirs": res["root_dirs"],
        "folders": res["folders"],
        "total_files": res["total_files"],
        "total_bytes": res["total_bytes"],
        "already_optimized_count": res["already_optimized_count"],
        "too_small_count": res["too_small_count"],
        "pending_count": res["pending_count"],
        "sample_files": samples,
    }


@app.post("/api/preview/local")
def api_preview_local(req: PreviewRequest) -> dict[str, Any]:
    try:
        return run_single_preview(req.file_path, req.config, page=req.page)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"预览失败: {exc}")


@app.post("/api/preview/upload")
async def api_preview_upload(
    file: UploadFile = File(...),
    config_json: str = Form(default="{}"),
    page: int = Form(default=0),
) -> dict[str, Any]:
    try:
        cfg_data = json.loads(config_json) if config_json else {}
        cfg = CompressionConfig(**cfg_data)
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"参数无效: {exc}")

    tmp_dir = Path(tempfile.mkdtemp(prefix="pdfresize_prev_"))
    try:
        safe_name = Path(file.filename or "sample.pdf").name
        if not safe_name.lower().endswith(".pdf"):
            safe_name += ".pdf"
        src_path = tmp_dir / safe_name
        with src_path.open("wb") as out:
            while True:
                chunk = await file.read(1024 * 1024)
                if not chunk:
                    break
                out.write(chunk)
        return await asyncio.to_thread(run_single_preview, src_path, cfg, page=page)
    except Exception as exc:
        raise HTTPException(status_code=500, detail=f"预览失败: {exc}")
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


@app.get("/api/preview/image/{token}/{side}")
def api_preview_image(token: str, side: str) -> FileResponse:
    try:
        p = get_preview_image_path(token, side)
    except (ValueError, FileNotFoundError):
        raise HTTPException(status_code=404, detail="预览图不存在或已过期")
    return FileResponse(str(p), media_type="image/png")


@app.post("/api/jobs/local")
def api_create_local_job(req: CreateLocalJobRequest) -> dict[str, Any]:
    source_dirs = req.resolved_source_dirs()
    if not source_dirs:
        raise HTTPException(status_code=400, detail="请至少添加一个源目录")
    try:
        return manager.create_local_job(
            source_dirs=source_dirs,
            output_mode=req.output_mode,
            output_dir=req.output_dir,
            backup_dir=req.backup_dir,
            config=req.config,
            recursive=req.recursive,
            name=req.name,
            limit_files=req.limit_files,
            auto_start=True,
        )
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc))


@app.post("/api/jobs/upload/init")
def api_init_upload_job(req: CreateUploadJobRequest) -> dict[str, Any]:
    return manager.create_upload_job(
        upload_root=UPLOAD_ROOT,
        output_dir=req.output_dir,
        config=req.config,
        name=req.name,
    )


@app.post("/api/jobs/{job_id}/upload")
async def api_upload_file(
    job_id: str,
    file: UploadFile = File(...),
    relative_path: str = Form(default=""),
) -> dict[str, Any]:
    job = storage.get_job(job_id)
    if not job or job["source_type"] != "upload":
        raise HTTPException(status_code=404, detail="上传任务不存在")

    rel = _safe_rel_path(relative_path or file.filename or "file.pdf")
    if not rel.lower().endswith(".pdf"):
        raise HTTPException(status_code=400, detail="仅支持 PDF 文件")

    src_root = Path(job["source_dir"])
    out_root = Path(job["output_dir"])
    src_path = src_root / rel
    dst_path = out_root / rel
    src_path.parent.mkdir(parents=True, exist_ok=True)
    dst_path.parent.mkdir(parents=True, exist_ok=True)

    # Deduplicate filename if uploaded twice
    if src_path.exists():
        stem = src_path.stem
        suffix = src_path.suffix
        idx = 1
        while (src_path.parent / f"{stem}_{idx}{suffix}").exists():
            idx += 1
        src_path = src_path.parent / f"{stem}_{idx}{suffix}"
        rel = str(src_path.relative_to(src_root)).replace("\\", "/")
        dst_path = out_root / rel

    # Stream to disk in 1MB chunks to avoid RAM spikes on huge PDFs
    total_written = 0
    with src_path.open("wb") as out:
        while True:
            chunk = await file.read(1024 * 1024)
            if not chunk:
                break
            out.write(chunk)
            total_written += len(chunk)

    manager.register_uploaded_file(job_id, rel, src_path, dst_path)
    return {"ok": True, "rel_path": rel, "size": total_written}


@app.get("/api/jobs")
def api_list_jobs(limit: int = Query(default=30, ge=1, le=200)) -> dict[str, Any]:
    return {"jobs": storage.list_jobs(limit=limit)}


@app.get("/api/jobs/{job_id}")
def api_get_job(job_id: str) -> dict[str, Any]:
    detail = manager.get_job_detail(job_id)
    if not detail:
        raise HTTPException(status_code=404, detail="任务不存在")
    return detail


@app.get("/api/jobs/{job_id}/stream")
async def api_stream_job(job_id: str, request: Request) -> StreamingResponse:
    if not storage.get_job(job_id):
        raise HTTPException(status_code=404, detail="任务不存在")

    async def event_gen():
        last_ver = -1
        while True:
            if await request.is_disconnected():
                break
            detail = manager.get_job_detail(job_id)
            if not detail:
                break
            payload = json.dumps(detail, ensure_ascii=False)
            yield f"data: {payload}\n\n"
            if detail["status"] in ("completed", "cancelled", "failed", "paused"):
                break
            last_ver = await asyncio.to_thread(manager.wait_for_update, last_ver, 0.8)

    return StreamingResponse(
        event_gen(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache, no-store",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


@app.post("/api/jobs/{job_id}/start")
def api_start_job(job_id: str) -> dict[str, Any]:
    try:
        started = manager.start_job(job_id)
    except ValueError as exc:
        raise HTTPException(status_code=404, detail=str(exc))
    return {"ok": True, "started": started, "job": manager.get_job_detail(job_id)}


@app.post("/api/jobs/{job_id}/pause")
def api_pause_job(job_id: str) -> dict[str, Any]:
    ok = manager.pause_job(job_id)
    return {"ok": ok, "job": manager.get_job_detail(job_id)}


@app.post("/api/jobs/{job_id}/cancel")
def api_cancel_job(job_id: str) -> dict[str, Any]:
    ok = manager.cancel_job(job_id)
    return {"ok": ok, "job": manager.get_job_detail(job_id)}


@app.post("/api/jobs/{job_id}/retry-failed")
def api_retry_failed(job_id: str) -> dict[str, Any]:
    if not storage.get_job(job_id):
        raise HTTPException(status_code=404, detail="任务不存在")
    count = manager.retry_failed(job_id)
    return {"ok": True, "retried": count, "job": manager.get_job_detail(job_id)}


@app.delete("/api/jobs/{job_id}")
def api_delete_job(job_id: str, delete_upload_files: bool = Query(default=False)) -> dict[str, Any]:
    job = storage.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="任务不存在")
    if job["status"] == "running":
        raise HTTPException(status_code=400, detail="请先暂停或取消正在运行的任务")
    storage.delete_job(job_id)
    if delete_upload_files and job["source_type"] == "upload":
        job_dir = UPLOAD_ROOT / job_id
        if job_dir.exists():
            shutil.rmtree(job_dir, ignore_errors=True)
    return {"ok": True}


@app.get("/api/jobs/{job_id}/files")
def api_list_job_files(
    job_id: str,
    status: str = Query(default="all"),
    search: str = Query(default=""),
    sort_by: str = Query(default="id"),
    sort_dir: str = Query(default="asc"),
    page: int = Query(default=1, ge=1),
    page_size: int = Query(default=50, ge=10, le=200),
) -> dict[str, Any]:
    if not storage.get_job(job_id):
        raise HTTPException(status_code=404, detail="任务不存在")
    return storage.list_job_files(
        job_id,
        status=status,
        search=search,
        sort_by=sort_by,
        sort_dir=sort_dir,
        page=page,
        page_size=page_size,
    )


@app.get("/api/jobs/{job_id}/files/{file_id}/download")
def api_download_single(job_id: str, file_id: int) -> FileResponse:
    rec = storage.get_file_record(job_id, file_id)
    if not rec:
        raise HTTPException(status_code=404, detail="文件记录不存在")
    p = Path(rec["dst_path"])
    if not p.exists():
        p = Path(rec["src_path"])
    if not p.exists():
        raise HTTPException(status_code=404, detail="磁盘上未找到该文件")
    return FileResponse(str(p), filename=p.name, media_type="application/pdf")


@app.get("/api/jobs/{job_id}/download-zip")
def api_download_zip(job_id: str) -> FileResponse:
    job = storage.get_job(job_id)
    if not job:
        raise HTTPException(status_code=404, detail="任务不存在")
    out_dir = Path(job["output_dir"] or job["source_dir"])
    if not out_dir.exists():
        raise HTTPException(status_code=404, detail="输出目录不存在")

    zip_dir = DATA_DIR / "zips"
    zip_dir.mkdir(parents=True, exist_ok=True)
    zip_path = zip_dir / f"pdf_resize_{job_id}.zip"

    # Store without re-deflating already compressed PDFs for speed
    with zipfile.ZipFile(zip_path, "w", compression=zipfile.ZIP_STORED) as zf:
        count = 0
        for root, _, filenames in os.walk(out_dir):
            for fname in filenames:
                if not fname.lower().endswith(".pdf"):
                    continue
                full = Path(root) / fname
                rel = full.relative_to(out_dir)
                zf.write(full, arcname=str(rel))
                count += 1
        if count == 0:
            raise HTTPException(status_code=400, detail="输出目录中尚无可下载的 PDF")

    return FileResponse(
        str(zip_path),
        filename=f"compressed_{job_id}.zip",
        media_type="application/zip",
    )


@app.post("/api/fingerprints/clear")
def api_clear_fingerprints() -> dict[str, Any]:
    removed = storage.clear_fingerprints()
    return {"ok": True, "removed": removed}
