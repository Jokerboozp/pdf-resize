from __future__ import annotations

import os
import sys
from pathlib import Path

APP_NAME = "PDF Resize"


def is_frozen() -> bool:
    """Return True when running inside a PyInstaller / frozen bundle."""
    return bool(getattr(sys, "frozen", False))


def get_static_dir() -> Path:
    """Resolve the bundled web UI static directory in both dev and frozen modes."""
    if is_frozen() and hasattr(sys, "_MEIPASS"):
        cand = Path(sys._MEIPASS) / "pdf_resize" / "static"  # type: ignore[attr-defined]
        if cand.exists():
            return cand
    return Path(__file__).resolve().parent / "static"


def get_data_dir() -> Path:
    """Return a writable directory for SQLite DB, previews, uploads, zips, and logs."""
    override = os.environ.get("PDF_RESIZE_DATA_DIR", "").strip()
    if override:
        p = Path(override).expanduser().resolve()
        p.mkdir(parents=True, exist_ok=True)
        return p

    if is_frozen():
        if sys.platform == "darwin":
            p = Path.home() / "Library" / "Application Support" / APP_NAME
        elif os.name == "nt":
            base = os.environ.get("LOCALAPPDATA") or str(Path.home())
            p = Path(base) / APP_NAME
        else:
            xdg = os.environ.get("XDG_DATA_HOME")
            p = (Path(xdg) if xdg else Path.home() / ".local" / "share") / "pdf-resize"
        p.mkdir(parents=True, exist_ok=True)
        return p

    p = Path(__file__).resolve().parent.parent / "data"
    p.mkdir(parents=True, exist_ok=True)
    return p
