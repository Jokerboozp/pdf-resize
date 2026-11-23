from __future__ import annotations

import io
import os
import re
import shutil
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import pymupdf
import pikepdf
from PIL import Image

from .models import CompressionConfig

# Suppress DecompressionBombWarning for very large scanned blueprint pages
Image.MAX_IMAGE_PIXELS = 300_000_000

TMP_SUFFIX = ".pdfresize.tmp"
_DO_NAME_RE = re.compile(rb"/([^\s/()<>[\]{}%]+)\s+Do\b")


@dataclass
class CompressionResult:
    status: str  # done | skipped_no_gain | skipped_small | skipped_encrypted | skipped_empty | failed
    orig_size: int
    new_size: int
    saved_bytes: int
    duration_ms: int
    images_optimized: int = 0
    pages: int = 0
    error: Optional[str] = None
    new_mtime: Optional[float] = None


def _recompress_opaque_image(
    orig_bytes: bytes,
    orig_w: int,
    orig_h: int,
    max_disp_w_in: Optional[float],
    max_disp_h_in: Optional[float],
    cfg: CompressionConfig,
) -> Optional[bytes]:
    """Recompress an opaque image to JPEG, downscaling if effective DPI exceeds target."""
    try:
        with Image.open(io.BytesIO(orig_bytes)) as img:
            w, h = img.size
            if w <= 0 or h <= 0:
                return None

            new_w, new_h = w, h
            if cfg.downsample_images and cfg.target_dpi > 0:
                if max_disp_w_in and max_disp_h_in:
                    target_w = max(32, int(round(max_disp_w_in * cfg.target_dpi)))
                    target_h = max(32, int(round(max_disp_h_in * cfg.target_dpi)))
                else:
                    # Fallback cap assuming ~11-inch longest side if bbox unavailable
                    cap = max(256, int(round(11.7 * cfg.target_dpi)))
                    target_w, target_h = cap, cap

                scale = min(target_w / w, target_h / h)
                # Only downscale when significantly larger (>8%) to avoid useless resampling
                if scale < 0.92:
                    new_w = max(16, int(round(w * scale)))
                    new_h = max(16, int(round(h * scale)))

            # Fast libjpeg DCT prescaling (>=2x target keeps LANCZOS quality intact while cutting decode cost)
            if img.format == "JPEG" and (new_w, new_h) != (w, h):
                draft_mode = "L" if cfg.grayscale else None
                img.draft(draft_mode, (new_w * 2, new_h * 2))

            img.load()

            if cfg.grayscale:
                if img.mode != "L":
                    img = img.convert("L")
            else:
                if img.mode in ("L", "1"):
                    img = img.convert("L")
                elif img.mode != "RGB":
                    img = img.convert("RGB")

            if img.size != (new_w, new_h):
                img = img.resize((new_w, new_h), Image.Resampling.LANCZOS)

            buf = io.BytesIO()
            img.save(
                buf,
                format="JPEG",
                quality=cfg.jpeg_quality,
                optimize=True,
                subsampling="4:2:0" if cfg.jpeg_quality < 85 else "4:4:4",
            )
            new_bytes = buf.getvalue()
            # Keep only if meaningfully smaller
            if len(new_bytes) < len(orig_bytes) - 512 and len(new_bytes) < len(orig_bytes) * 0.97:
                return new_bytes
            return None
    except Exception:
        return None


def _recompress_transparent_image(
    doc: pymupdf.Document,
    xref: int,
    smask_xref: int,
    orig_combined_size: int,
    max_disp_w_in: Optional[float],
    max_disp_h_in: Optional[float],
    cfg: CompressionConfig,
) -> Optional[bytes]:
    """Optimize a large transparent image as RGBA PNG while preserving transparency."""
    try:
        base_pix = pymupdf.Pixmap(doc, xref)
        mask_pix = pymupdf.Pixmap(doc, smask_xref)
        if base_pix.n > 3:
            base_pix = pymupdf.Pixmap(pymupdf.csRGB, base_pix)
        elif base_pix.n == 1:
            base_pix = pymupdf.Pixmap(pymupdf.csRGB, base_pix)

        rgba_pix = pymupdf.Pixmap(base_pix, mask_pix)
        img = Image.frombytes("RGBA", (rgba_pix.width, rgba_pix.height), rgba_pix.samples)
        w, h = img.size

        new_w, new_h = w, h
        if cfg.downsample_images and cfg.target_dpi > 0:
            if max_disp_w_in and max_disp_h_in:
                target_w = max(32, int(round(max_disp_w_in * cfg.target_dpi)))
                target_h = max(32, int(round(max_disp_h_in * cfg.target_dpi)))
            else:
                cap = max(256, int(round(11.7 * cfg.target_dpi)))
                target_w, target_h = cap, cap
            scale = min(target_w / w, target_h / h)
            if scale < 0.92:
                new_w = max(16, int(round(w * scale)))
                new_h = max(16, int(round(h * scale)))

        if (new_w, new_h) != (w, h):
            img = img.resize((new_w, new_h), Image.Resampling.LANCZOS)

        if cfg.grayscale:
            # Convert RGB channels to luminance while keeping alpha channel intact
            r, g, b, a = img.split()
            gray = img.convert("L")
            img = Image.merge("LA", (gray, a))

        buf = io.BytesIO()
        img.save(buf, format="PNG", optimize=True, compress_level=9)
        new_bytes = buf.getvalue()
        if len(new_bytes) < orig_combined_size * 0.92:
            return new_bytes
        return None
    except Exception:
        return None


def _optimize_images(
    doc: pymupdf.Document,
    cfg: CompressionConfig,
    *,
    image_threads: int = 1,
) -> int:
    """Scan all pages, compute max displayed size per xref, and optimize unique images."""
    if not cfg.compress_images or cfg.preset == "lossless":
        return 0

    # Map xref -> [max_disp_w_in, max_disp_h_in, page_index]
    xref_display: dict[int, list] = {}
    smask_xrefs: set[int] = set()
    xref_to_smask: dict[int, int] = {}

    # NOTE: Avoid page.get_image_info(xrefs=True) and page.get_image_rects(), which
    # decode and MD5-hash every image in /Resources on every page (O(pages * resources),
    # taking 20+ minutes on PDFs with a shared XObject table). Matching `/Name Do`
    # operators in the page content stream + page.get_image_bbox(img_tuple) is ~3000x faster.
    for page_idx in range(doc.page_count):
        page = doc[page_idx]
        try:
            raw_contents = page.read_contents()
            used_names = {
                m.decode("latin1") for m in _DO_NAME_RE.findall(raw_contents)
            }
        except Exception:
            used_names = set()

        for img_tuple in page.get_images(full=True):
            xref = img_tuple[0]
            smask = img_tuple[1]
            img_name = img_tuple[7] if len(img_tuple) > 7 else ""
            referencer = img_tuple[9] if len(img_tuple) > 9 else 0
            if smask and smask > 0:
                smask_xrefs.add(smask)
                xref_to_smask[xref] = smask
            if xref not in xref_display:
                xref_display[xref] = [None, None, page_idx]

            # Only compute bbox for images actually drawn on this page (or inside a Form XObject)
            if (img_name and img_name in used_names) or referencer != 0:
                try:
                    bbox = page.get_image_bbox(img_tuple)
                    if bbox and not bbox.is_empty and not bbox.is_infinite:
                        bw = abs(float(bbox.width)) / 72.0
                        bh = abs(float(bbox.height)) / 72.0
                        if bw > 0.05 and bh > 0.05:
                            entry = xref_display[xref]
                            entry[0] = bw if entry[0] is None else max(entry[0], bw)
                            entry[1] = bh if entry[1] is None else max(entry[1], bh)
                            entry[2] = page_idx
                except Exception:
                    pass

    optimized_count = 0
    opaque_tasks: list[tuple[int, int, bytes, int, int, Optional[float], Optional[float]]] = []

    for xref, (max_w_in, max_h_in, page_idx) in xref_display.items():
        if xref in smask_xrefs:
            continue

        try:
            base = doc.extract_image(xref)
        except Exception:
            continue
        if not base or not base.get("image"):
            continue

        orig_bytes: bytes = base["image"]
        orig_w: int = base.get("width", 0)
        orig_h: int = base.get("height", 0)
        bpc: int = base.get("bpc", 8)
        smask_xref: int = base.get("smask", 0) or xref_to_smask.get(xref, 0)

        # Skip tiny icons / thumbnails / already super-compact streams
        if orig_w * orig_h < 4096 or len(orig_bytes) < 4096:
            continue

        # Protect 1-bit monochrome JBIG2/CCITT scans unless unexpectedly huge
        if bpc == 1 and len(orig_bytes) < 65536:
            continue

        if smask_xref > 0:
            if not cfg.optimize_transparent or len(orig_bytes) < 24576:
                continue
            try:
                mask_base = doc.extract_image(smask_xref)
                mask_len = len(mask_base["image"]) if mask_base and mask_base.get("image") else 0
            except Exception:
                mask_len = 0
            new_png = _recompress_transparent_image(
                doc, xref, smask_xref, len(orig_bytes) + mask_len, max_w_in, max_h_in, cfg
            )
            if new_png is not None:
                try:
                    doc[page_idx].replace_image(xref, stream=new_png)
                    optimized_count += 1
                except Exception:
                    pass
            continue

        opaque_tasks.append((xref, page_idx, orig_bytes, orig_w, orig_h, max_w_in, max_h_in))

    if opaque_tasks:
        threads = max(1, min(image_threads, len(opaque_tasks)))
        if threads > 1:
            with ThreadPoolExecutor(max_workers=threads) as pool:
                results = list(
                    pool.map(
                        lambda t: _recompress_opaque_image(t[2], t[3], t[4], t[5], t[6], cfg),
                        opaque_tasks,
                    )
                )
        else:
            results = [
                _recompress_opaque_image(t[2], t[3], t[4], t[5], t[6], cfg)
                for t in opaque_tasks
            ]

        for (xref, page_idx, *_), new_jpeg in zip(opaque_tasks, results):
            if new_jpeg is not None:
                try:
                    doc[page_idx].replace_image(xref, stream=new_jpeg)
                    optimized_count += 1
                except Exception:
                    pass

    return optimized_count


def _verify_pdf_integrity(pdf_path: Path, expected_pages: int) -> bool:
    """Verify the output PDF opens cleanly and has the exact expected page count."""
    try:
        with pymupdf.open(str(pdf_path)) as check_doc:
            if check_doc.page_count != expected_pages:
                return False
            # Touch first and last page to ensure page tree is valid
            if expected_pages > 0:
                _ = check_doc[0].rect
                if expected_pages > 1:
                    _ = check_doc[expected_pages - 1].rect
            return True
    except Exception:
        return False


def _run_qpdf_pass(src_tmp: Path, dst_tmp: Path) -> bool:
    """Run pikepdf (QPDF) structural & object stream optimization pass."""
    try:
        with pikepdf.open(str(src_tmp)) as pdf:
            pdf.save(
                str(dst_tmp),
                compress_streams=True,
                stream_decode_level=pikepdf.StreamDecodeLevel.generalized,
                object_stream_mode=pikepdf.ObjectStreamMode.generate,
                recompress_flate=True,
                linearize=False,
            )
        return dst_tmp.exists() and dst_tmp.stat().st_size > 0
    except Exception:
        return False


def compress_pdf_file(
    src_path: str | Path,
    dst_path: str | Path,
    config: CompressionConfig,
    *,
    inplace: bool = False,
    backup_path: Optional[str | Path] = None,
    image_threads: int = 1,
) -> CompressionResult:
    """Compress a single PDF file safely with integrity verification and atomic replacement."""
    t0 = time.perf_counter()
    src = Path(src_path)
    dst = Path(dst_path)

    if not src.exists() or not src.is_file():
        return CompressionResult(
            status="failed",
            orig_size=0,
            new_size=0,
            saved_bytes=0,
            duration_ms=int((time.perf_counter() - t0) * 1000),
            error="源文件不存在",
        )

    src_stat = src.stat()
    orig_size = src_stat.st_size
    orig_mtime = src_stat.st_mtime
    orig_atime = src_stat.st_atime

    if orig_size == 0:
        return CompressionResult(
            status="skipped_empty",
            orig_size=0,
            new_size=0,
            saved_bytes=0,
            duration_ms=int((time.perf_counter() - t0) * 1000),
            error="空文件",
        )

    if config.skip_smaller_than_kb > 0 and orig_size < config.skip_smaller_than_kb * 1024:
        if not inplace and src.resolve() != dst.resolve():
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(str(src), str(dst))
        return CompressionResult(
            status="skipped_small",
            orig_size=orig_size,
            new_size=orig_size,
            saved_bytes=0,
            duration_ms=int((time.perf_counter() - t0) * 1000),
        )

    # Create temp files in the destination directory for same-volume atomic rename
    dst.parent.mkdir(parents=True, exist_ok=True)
    token = f"{os.getpid()}.{uuid.uuid4().hex[:8]}"
    tmp_mupdf = dst.parent / f".{dst.name}.{token}.mupdf{TMP_SUFFIX}"
    tmp_qpdf = dst.parent / f".{dst.name}.{token}.qpdf{TMP_SUFFIX}"

    images_optimized = 0
    orig_pages = 0

    try:
        doc = pymupdf.open(str(src))
        try:
            if doc.is_encrypted:
                if not doc.authenticate(""):
                    if not inplace and src.resolve() != dst.resolve():
                        shutil.copy2(str(src), str(dst))
                    return CompressionResult(
                        status="skipped_encrypted",
                        orig_size=orig_size,
                        new_size=orig_size,
                        saved_bytes=0,
                        duration_ms=int((time.perf_counter() - t0) * 1000),
                        error="PDF 受密码保护",
                    )

            orig_pages = doc.page_count
            if orig_pages == 0:
                return CompressionResult(
                    status="skipped_empty",
                    orig_size=orig_size,
                    new_size=orig_size,
                    saved_bytes=0,
                    duration_ms=int((time.perf_counter() - t0) * 1000),
                    error="PDF 页数为 0",
                )

            images_optimized = _optimize_images(doc, config, image_threads=image_threads)

            if config.strip_metadata:
                try:
                    doc.set_metadata({})
                    doc.del_xml_metadata()
                except Exception:
                    pass

            if config.subset_fonts:
                try:
                    doc.subset_fonts()
                except Exception:
                    pass

            save_kwargs = dict(
                garbage=4,
                deflate=True,
                deflate_images=True,
                deflate_fonts=True,
                clean=config.clean_streams,
            )
            try:
                doc.save(str(tmp_mupdf), **save_kwargs)
            except Exception:
                # Fallback without stream cleaning for slightly malformed PDFs
                save_kwargs["clean"] = False
                save_kwargs["garbage"] = 3
                doc.save(str(tmp_mupdf), **save_kwargs)
        finally:
            doc.close()

        # Select best candidate between MuPDF pass and optional QPDF pass
        winner = tmp_mupdf
        if not _verify_pdf_integrity(tmp_mupdf, orig_pages):
            raise RuntimeError("MuPDF 输出文件完整性校验失败")

        if config.use_qpdf:
            if _run_qpdf_pass(tmp_mupdf, tmp_qpdf):
                if (
                    tmp_qpdf.stat().st_size < tmp_mupdf.stat().st_size
                    and _verify_pdf_integrity(tmp_qpdf, orig_pages)
                ):
                    winner = tmp_qpdf

        new_size = winner.stat().st_size
        saved_bytes = orig_size - new_size
        saved_pct = (saved_bytes / orig_size) * 100.0 if orig_size > 0 else 0.0

        # Safety gate: never replace if file grew or didn't meet min saving threshold
        if saved_bytes <= 0 or saved_pct < config.min_saving_percent:
            if not inplace and src.resolve() != dst.resolve():
                shutil.copy2(str(src), str(dst))
            return CompressionResult(
                status="skipped_no_gain",
                orig_size=orig_size,
                new_size=orig_size,
                saved_bytes=0,
                duration_ms=int((time.perf_counter() - t0) * 1000),
                images_optimized=images_optimized,
                pages=orig_pages,
                new_mtime=orig_mtime,
            )

        # Optional backup before in-place overwrite
        if inplace and backup_path is not None:
            bpath = Path(backup_path)
            bpath.parent.mkdir(parents=True, exist_ok=True)
            if not bpath.exists():
                shutil.copy2(str(src), str(bpath))

        if config.preserve_mtime:
            try:
                os.utime(str(winner), (orig_atime, orig_mtime))
            except Exception:
                pass

        # Atomic same-volume replacement
        os.replace(str(winner), str(dst))
        final_mtime = dst.stat().st_mtime

        return CompressionResult(
            status="done",
            orig_size=orig_size,
            new_size=new_size,
            saved_bytes=saved_bytes,
            duration_ms=int((time.perf_counter() - t0) * 1000),
            images_optimized=images_optimized,
            pages=orig_pages,
            new_mtime=final_mtime,
        )

    except Exception as exc:
        return CompressionResult(
            status="failed",
            orig_size=orig_size,
            new_size=orig_size,
            saved_bytes=0,
            duration_ms=int((time.perf_counter() - t0) * 1000),
            images_optimized=images_optimized,
            pages=orig_pages,
            error=str(exc)[:500],
        )
    finally:
        for p in (tmp_mupdf, tmp_qpdf):
            try:
                if p.exists():
                    p.unlink()
            except Exception:
                pass
