from __future__ import annotations

import shutil
import time
import uuid
from pathlib import Path
from typing import Any

import pymupdf

from .compressor import compress_pdf_file
from .models import CompressionConfig


PREVIEW_ROOT = Path(__file__).resolve().parent.parent / "data" / "previews"


def _cleanup_old_previews(max_keep: int = 12, max_age_sec: int = 1800) -> None:
    if not PREVIEW_ROOT.exists():
        return
    now = time.time()
    dirs = [d for d in PREVIEW_ROOT.iterdir() if d.is_dir()]
    dirs.sort(key=lambda p: p.stat().st_mtime, reverse=True)
    for idx, d in enumerate(dirs):
        try:
            age = now - d.stat().st_mtime
            if idx >= max_keep or age > max_age_sec:
                shutil.rmtree(d, ignore_errors=True)
        except OSError:
            pass


def _render_page_png(pdf_path: Path, page_index: int, out_png: Path, max_width: int = 1100) -> tuple[int, int]:
    with pymupdf.open(str(pdf_path)) as doc:
        total_pages = doc.page_count
        if total_pages == 0:
            raise ValueError("PDF 页数为 0")
        idx = max(0, min(page_index, total_pages - 1))
        page = doc[idx]
        rect = page.rect
        zoom = min(2.0, max(0.5, max_width / max(rect.width, 1.0)))
        pix = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom), alpha=False)
        pix.save(str(out_png))
        return idx, total_pages


def run_single_preview(
    src_path: str | Path,
    config: CompressionConfig,
    page: int = 0,
) -> dict[str, Any]:
    """Compress a copy of one PDF and render before/after PNGs for visual inspection."""
    src = Path(src_path)
    if not src.exists() or not src.is_file():
        raise ValueError(f"文件不存在: {src_path}")

    PREVIEW_ROOT.mkdir(parents=True, exist_ok=True)
    _cleanup_old_previews()

    token = uuid.uuid4().hex[:12]
    work_dir = PREVIEW_ROOT / token
    work_dir.mkdir(parents=True, exist_ok=True)

    out_pdf = work_dir / "compressed.pdf"
    res = compress_pdf_file(src, out_pdf, config, inplace=False)

    orig_png = work_dir / "orig.png"
    comp_png = work_dir / "comp.png"

    rendered_page, total_pages = _render_page_png(src, page, orig_png)
    comp_source = out_pdf if out_pdf.exists() else src
    _render_page_png(comp_source, rendered_page, comp_png)

    saving_pct = (
        round((res.saved_bytes / res.orig_size) * 100.0, 2) if res.orig_size > 0 else 0.0
    )

    return {
        "token": token,
        "file_name": src.name,
        "status": res.status,
        "orig_size": res.orig_size,
        "new_size": res.new_size,
        "saved_bytes": res.saved_bytes,
        "saving_percent": saving_pct,
        "duration_ms": res.duration_ms,
        "images_optimized": res.images_optimized,
        "pages": total_pages,
        "rendered_page": rendered_page,
        "error": res.error,
        "orig_image_url": f"/api/preview/image/{token}/orig",
        "comp_image_url": f"/api/preview/image/{token}/comp",
    }


def get_preview_image_path(token: str, side: str) -> Path:
    if side not in ("orig", "comp"):
        raise ValueError("Invalid side")
    # Prevent path traversal
    safe_token = "".join(ch for ch in token if ch.isalnum())
    p = PREVIEW_ROOT / safe_token / f"{side}.png"
    if not p.exists():
        raise FileNotFoundError("Preview image not found")
    return p
