from __future__ import annotations

import io
import time
import zipfile
from pathlib import Path

import pymupdf
import pytest
from fastapi.testclient import TestClient
from PIL import Image, ImageDraw

from pdf_resize.compressor import TMP_SUFFIX, compress_pdf_file
from pdf_resize.manager import JobManager
from pdf_resize.models import CompressionConfig, apply_preset
from pdf_resize.server import app
from pdf_resize.storage import Storage


def _make_photo_pdf(path: Path, pages: int = 2, img_size: tuple[int, int] = (1800, 1400)) -> Path:
    """Create a realistic heavy PDF containing noisy high-res photo scans + vector text."""
    doc = pymupdf.open()
    for p in range(pages):
        page = doc.new_page(width=595, height=842)  # A4
        page.insert_text((50, 50), f"PDF Resize Test Document - Page {p + 1}", fontsize=16)

        # Photographic texture (high entropy, realistic scanned page/photo)
        r_ch = Image.effect_noise(img_size, 55 + p * 5)
        g_ch = Image.effect_noise(img_size, 65)
        b_ch = Image.effect_noise(img_size, 45)
        img = Image.merge("RGB", (r_ch, g_ch, b_ch))
        draw = ImageDraw.Draw(img)
        for i in range(6):
            draw.ellipse(
                [80 + i * 160, 120 + i * 90, 420 + i * 160, 460 + i * 90],
                fill=(210 - i * 18, 90 + i * 12, 140),
                outline=(20, 20, 20),
                width=4,
            )
        buf = io.BytesIO()
        img.save(buf, format="JPEG", quality=96)
        page.insert_image(pymupdf.Rect(40, 80, 555, 780), stream=buf.getvalue())

    doc.save(str(path), deflate=True)
    doc.close()
    return path


def _make_transparent_pdf(path: Path) -> Path:
    doc = pymupdf.open()
    page = doc.new_page(width=595, height=842)
    img = Image.new("RGBA", (1400, 1400), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)
    for i in range(10):
        draw.ellipse(
            [100 + i * 60, 100 + i * 60, 800 + i * 50, 800 + i * 50],
            fill=(40 + i * 20, 130, 230, 180),
        )
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    page.insert_image(pymupdf.Rect(60, 60, 520, 520), stream=buf.getvalue())
    doc.save(str(path), deflate=True)
    doc.close()
    return path


def _make_encrypted_pdf(path: Path) -> Path:
    doc = pymupdf.open()
    page = doc.new_page()
    page.insert_text((72, 72), "Secret Document")
    doc.save(
        str(path),
        encryption=pymupdf.PDF_ENCRYPT_AES_256,
        user_pw="secret123",
        owner_pw="owner123",
    )
    doc.close()
    return path


def _make_tiny_text_pdf(path: Path) -> Path:
    doc = pymupdf.open()
    page = doc.new_page()
    page.insert_text((72, 72), "Tiny clean PDF")
    doc.save(str(path), garbage=4, deflate=True)
    doc.close()
    return path


def test_compress_photo_pdf_balanced_and_extreme(tmp_path: Path) -> None:
    src = _make_photo_pdf(tmp_path / "heavy.pdf", pages=2)
    orig_size = src.stat().st_size
    assert orig_size > 150_000

    out_bal = tmp_path / "balanced.pdf"
    res_bal = compress_pdf_file(src, out_bal, apply_preset("balanced"), inplace=False)
    assert res_bal.status == "done"
    assert res_bal.pages == 2
    assert res_bal.images_optimized >= 2
    assert res_bal.new_size < orig_size * 0.6
    assert out_bal.exists()

    # Verify text is still crisp and selectable
    with pymupdf.open(str(out_bal)) as d:
        assert d.page_count == 2
        assert "PDF Resize Test Document - Page 1" in d[0].get_text()
        assert "PDF Resize Test Document - Page 2" in d[1].get_text()

    out_ext = tmp_path / "extreme_gray.pdf"
    res_ext = compress_pdf_file(
        src, out_ext, apply_preset("extreme", {"grayscale": True}), inplace=False
    )
    assert res_ext.status == "done"
    assert res_ext.new_size < res_bal.new_size


def test_transparent_encrypted_and_never_grow_safety(tmp_path: Path) -> None:
    # 1. Transparent PNG image PDF
    trans_src = _make_transparent_pdf(tmp_path / "trans.pdf")
    trans_out = tmp_path / "trans_out.pdf"
    res_t = compress_pdf_file(trans_src, trans_out, apply_preset("balanced"), inplace=False)
    assert res_t.status in ("done", "skipped_no_gain")
    assert trans_out.exists()
    with pymupdf.open(str(trans_out)) as d:
        assert d.page_count == 1

    # 2. Encrypted PDF is cleanly skipped without error
    enc_src = _make_encrypted_pdf(tmp_path / "encrypted.pdf")
    enc_bytes_before = enc_src.read_bytes()
    res_e = compress_pdf_file(enc_src, enc_src, apply_preset("balanced"), inplace=True)
    assert res_e.status == "skipped_encrypted"
    assert enc_src.read_bytes() == enc_bytes_before

    # 3. Already-optimized PDF never grows on a second pass
    tiny_src = _make_tiny_text_pdf(tmp_path / "tiny.pdf")
    compress_pdf_file(tiny_src, tiny_src, CompressionConfig(min_saving_percent=0.0), inplace=True)
    tiny_size = tiny_src.stat().st_size
    res_tiny = compress_pdf_file(
        tiny_src,
        tiny_src,
        CompressionConfig(min_saving_percent=5.0),
        inplace=True,
    )
    assert res_tiny.status == "skipped_no_gain"
    assert tiny_src.stat().st_size == tiny_size


def test_inplace_atomic_with_backup_and_no_temp_leftover(tmp_path: Path) -> None:
    src = _make_photo_pdf(tmp_path / "orig.pdf", pages=1)
    orig_bytes = src.read_bytes()
    backup = tmp_path / "backups" / "orig.pdf"

    res = compress_pdf_file(
        src, src, apply_preset("balanced"), inplace=True, backup_path=backup
    )
    assert res.status == "done"
    assert backup.exists()
    assert backup.read_bytes() == orig_bytes
    assert src.stat().st_size == res.new_size
    assert src.stat().st_size < len(orig_bytes)

    # Ensure no temp files remain
    leftovers = list(tmp_path.rglob(f"*{TMP_SUFFIX}"))
    assert leftovers == []


def test_job_manager_local_batch_and_fingerprints(tmp_path: Path) -> None:
    src_dir = tmp_path / "pdfs"
    (src_dir / "sub").mkdir(parents=True)
    _make_photo_pdf(src_dir / "a.pdf", pages=1)
    _make_photo_pdf(src_dir / "sub" / "b.pdf", pages=1)
    _make_encrypted_pdf(src_dir / "locked.pdf")

    storage = Storage(tmp_path / "test.db")
    mgr = JobManager(storage)
    try:
        cfg = apply_preset("balanced", {"workers": 2})
        job = mgr.create_local_job(
            source_dir=str(src_dir),
            output_mode="inplace",
            output_dir=None,
            backup_dir=str(tmp_path / "bkp"),
            config=cfg,
            recursive=True,
            auto_start=True,
        )
        job_id = job["id"]

        deadline = time.time() + 30
        detail = None
        while time.time() < deadline:
            detail = mgr.get_job_detail(job_id)
            if detail and detail["status"] in ("completed", "failed", "cancelled"):
                break
            time.sleep(0.2)

        assert detail is not None
        assert detail["status"] == "completed"
        assert detail["stats"]["total_files"] == 3
        assert detail["stats"]["done"] == 2
        assert detail["stats"]["skipped"] == 1
        assert detail["stats"]["failed"] == 0
        assert detail["stats"]["saved_bytes"] > 0
        assert (tmp_path / "bkp" / "a.pdf").exists()
        assert (tmp_path / "bkp" / "sub" / "b.pdf").exists()

        # Second run with skip_already_optimized=True should auto-skip a.pdf and sub/b.pdf
        job2 = mgr.create_local_job(
            source_dir=str(src_dir),
            output_mode="inplace",
            output_dir=None,
            backup_dir=None,
            config=cfg,
            recursive=True,
            auto_start=False,
        )
        assert job2["stats"]["skipped"] == 2
        assert job2["stats"]["pending"] == 1  # locked.pdf wasn't fingerprinted
    finally:
        storage.close()


def test_fastapi_endpoints_scan_preview_and_upload_zip(tmp_path: Path) -> None:
    client = TestClient(app)

    r_home = client.get("/")
    assert r_home.status_code == 200
    assert "PDF Resize" in r_home.text

    r_sys = client.get("/api/system")
    assert r_sys.status_code == 200
    assert "balanced" in r_sys.json()["presets"]

    # Create sample directory and scan
    sample_dir = tmp_path / "scan_dir"
    sample_dir.mkdir()
    sample_pdf = _make_photo_pdf(sample_dir / "sample.pdf", pages=1)

    r_scan = client.post(
        "/api/scan",
        json={"path": str(sample_dir), "recursive": True, "skip_already_optimized": False},
    )
    assert r_scan.status_code == 200
    assert r_scan.json()["total_files"] == 1

    # Single-file visual preview
    r_prev = client.post(
        "/api/preview/local",
        json={
            "file_path": str(sample_pdf),
            "page": 0,
            "config": apply_preset("balanced").model_dump(),
        },
    )
    assert r_prev.status_code == 200
    prev_data = r_prev.json()
    assert prev_data["status"] == "done"
    assert prev_data["saved_bytes"] > 0
    assert client.get(prev_data["orig_image_url"]).status_code == 200
    assert client.get(prev_data["comp_image_url"]).status_code == 200

    # Upload job flow + ZIP download
    r_init = client.post(
        "/api/jobs/upload/init",
        json={"name": "API Upload Test", "config": apply_preset("balanced", {"workers": 2}).model_dump()},
    )
    assert r_init.status_code == 200
    job_id = r_init.json()["id"]

    with sample_pdf.open("rb") as fh:
        r_up = client.post(
            f"/api/jobs/{job_id}/upload",
            files={"file": ("folder/sample.pdf", fh, "application/pdf")},
            data={"relative_path": "folder/sample.pdf"},
        )
    assert r_up.status_code == 200

    assert client.post(f"/api/jobs/{job_id}/start").status_code == 200

    deadline = time.time() + 30
    final_job = None
    while time.time() < deadline:
        final_job = client.get(f"/api/jobs/{job_id}").json()
        if final_job["status"] in ("completed", "failed"):
            break
        time.sleep(0.2)

    assert final_job is not None
    assert final_job["status"] == "completed"
    assert final_job["stats"]["done"] == 1

    r_zip = client.get(f"/api/jobs/{job_id}/download-zip")
    assert r_zip.status_code == 200
    with zipfile.ZipFile(io.BytesIO(r_zip.content)) as zf:
        names = zf.namelist()
        assert any(n.endswith("sample.pdf") for n in names)

    # Clean up test job record and uploaded files
    r_del = client.delete(f"/api/jobs/{job_id}?delete_upload_files=true")
    assert r_del.status_code == 200


def test_multi_folder_scan_dedup_and_inplace_compression(tmp_path: Path) -> None:
    """Test multiple separate folders (including same-named folders + overlapping nested folder)."""
    dir_a = tmp_path / "disk1" / "Docs"
    dir_a_sub = dir_a / "2024"
    dir_b = tmp_path / "disk2" / "Docs"  # Same folder name "Docs" on another path
    dir_a_sub.mkdir(parents=True)
    dir_b.mkdir(parents=True)

    f1 = _make_photo_pdf(dir_a / "one.pdf", pages=1)
    f2 = _make_photo_pdf(dir_a_sub / "two.pdf", pages=1)
    f3 = _make_photo_pdf(dir_b / "one.pdf", pages=1)  # Same filename as f1!
    orig_sizes = (f1.stat().st_size, f2.stat().st_size, f3.stat().st_size)

    client = TestClient(app)

    # Scan with overlapping nested folder dir_a_sub — must deduplicate to 3 unique PDFs!
    r_scan = client.post(
        "/api/scan",
        json={
            "paths": [str(dir_a), str(dir_a_sub), str(dir_b)],
            "recursive": True,
            "skip_already_optimized": False,
        },
    )
    assert r_scan.status_code == 200
    scan_data = r_scan.json()
    assert scan_data["total_files"] == 3
    assert len(scan_data["folders"]) == 3

    # Run in-place multi-folder job with backup dir (must not collide on Docs/one.pdf!)
    backup_dir = tmp_path / "backups"
    r_job = client.post(
        "/api/jobs/local",
        json={
            "source_dirs": [str(dir_a), str(dir_b)],
            "recursive": True,
            "output_mode": "inplace",
            "backup_dir": str(backup_dir),
            "config": apply_preset("balanced", {"workers": 2, "skip_already_optimized": False}).model_dump(),
        },
    )
    assert r_job.status_code == 200
    job_id = r_job.json()["id"]

    deadline = time.time() + 30
    final_job = None
    while time.time() < deadline:
        final_job = client.get(f"/api/jobs/{job_id}").json()
        if final_job["status"] in ("completed", "failed"):
            break
        time.sleep(0.2)

    assert final_job is not None
    assert final_job["status"] == "completed"
    assert final_job["stats"]["total_files"] == 3
    assert final_job["stats"]["done"] == 3
    assert final_job["stats"]["failed"] == 0

    # All 3 files compressed in-place at their original locations
    assert f1.stat().st_size < orig_sizes[0]
    assert f2.stat().st_size < orig_sizes[1]
    assert f3.stat().st_size < orig_sizes[2]

    # Backups preserved without overwriting each other despite identical folder name "Docs"
    assert (backup_dir / "Docs" / "one.pdf").exists()
    assert (backup_dir / "Docs" / "2024" / "two.pdf").exists()
    assert (backup_dir / "Docs_2" / "one.pdf").exists()

    client.delete(f"/api/jobs/{job_id}")


def test_shared_resources_pdf_fast_compression_and_preview_upload(tmp_path: Path) -> None:
    """Verify cache-busting headers and fast compression + preview upload endpoint."""
    src = _make_photo_pdf(tmp_path / "album.pdf", pages=4, img_size=(1600, 1200))
    orig_size = src.stat().st_size

    out = tmp_path / "album_out.pdf"
    t0 = time.perf_counter()
    res = compress_pdf_file(src, out, apply_preset("balanced"), inplace=False, image_threads=2)
    elapsed = time.perf_counter() - t0
    assert res.status == "done"
    assert res.images_optimized >= 4
    assert res.new_size < orig_size * 0.6
    assert elapsed < 10.0

    client = TestClient(app)
    r_home = client.get("/")
    assert r_home.status_code == 200
    assert "no-store" in r_home.headers.get("cache-control", "")
    assert "/static/app.js?v=" in r_home.text

    with src.open("rb") as fh:
        r_prev = client.post(
            "/api/preview/upload",
            files={"file": ("album.pdf", fh, "application/pdf")},
            data={"config_json": apply_preset("balanced").model_dump_json(), "page": "0"},
        )
    assert r_prev.status_code == 200
    pdata = r_prev.json()
    assert pdata["status"] == "done"
    assert pdata["saved_bytes"] > 0
    assert client.get(pdata["orig_image_url"]).status_code == 200
    assert client.get(pdata["comp_image_url"]).status_code == 200
