from __future__ import annotations

import logging
import multiprocessing
import socket
import sys
import threading
import time
import urllib.request
import webbrowser
from pathlib import Path
from typing import Optional

import uvicorn

from .paths import APP_NAME, get_data_dir


def _setup_logging() -> logging.Logger:
    log_path = get_data_dir() / "app.log"
    handlers: list[logging.Handler] = []
    try:
        handlers.append(logging.FileHandler(str(log_path), encoding="utf-8"))
    except OSError:
        pass
    if sys.stderr is not None:
        handlers.append(logging.StreamHandler(sys.stderr))
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        handlers=handlers or None,
    )
    return logging.getLogger("pdf_resize.desktop")


def _find_free_port(host: str = "127.0.0.1", preferred: int = 8765) -> int:
    for port in (preferred, 0):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            try:
                s.bind((host, port))
                return int(s.getsockname()[1])
            except OSError:
                continue
    return preferred


def _wait_for_server(url: str, timeout: float = 15.0) -> bool:
    deadline = time.monotonic() + timeout
    health_url = f"{url}/api/system"
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(health_url, timeout=1.0) as resp:
                if resp.status == 200:
                    return True
        except Exception:
            time.sleep(0.1)
    return False


class _DesktopAPI:
    def __init__(self, url: str) -> None:
        self._url = url
        self._window = None

    def bind_window(self, window) -> None:
        self._window = window

    def open_in_browser(self) -> bool:
        webbrowser.open(self._url)
        return True

    def pick_folders(self, multiple: bool = True) -> list[str]:
        if self._window is None:
            return []
        import webview

        dialog_type = getattr(getattr(webview, "FileDialog", None), "FOLDER", webview.FOLDER_DIALOG)
        result = self._window.create_file_dialog(dialog_type, allow_multiple=bool(multiple))
        if not result:
            return []
        if isinstance(result, str):
            return [result]
        return [str(p) for p in result if p]


def run_desktop(
    *,
    host: str = "127.0.0.1",
    preferred_port: int = 8765,
    use_browser: bool = False,
    self_test_seconds: Optional[float] = None,
) -> None:
    """Launch the embedded FastAPI backend and native desktop window (pywebview)."""
    multiprocessing.freeze_support()
    logger = _setup_logging()

    # Import app object directly so PyInstaller bundles all routes cleanly
    from .server import app

    port = _find_free_port(host, preferred_port)
    url = f"http://{host}:{port}"
    logger.info("Starting %s backend on %s", APP_NAME, url)

    # IMPORTANT: log_config=None prevents uvicorn's DefaultFormatter from calling
    # sys.stderr.isatty() when running inside a macOS/Windows windowed bundle (stderr=None).
    config = uvicorn.Config(
        app,
        host=host,
        port=port,
        log_level="warning",
        log_config=None,
        access_log=False,
    )
    server = uvicorn.Server(config)

    server_thread = threading.Thread(target=server.run, name="uvicorn-server", daemon=True)
    server_thread.start()

    if not _wait_for_server(url, timeout=15.0):
        logger.error("Backend failed to respond at %s within 15s", url)
        server.should_exit = True
        sys.exit(1)

    logger.info("Backend ready at %s", url)

    if self_test_seconds is not None:
        time.sleep(max(0.1, self_test_seconds))
        server.should_exit = True
        server_thread.join(timeout=3.0)
        return

    if use_browser:
        webbrowser.open(url)
        try:
            while server_thread.is_alive():
                server_thread.join(timeout=0.5)
        except KeyboardInterrupt:
            server.should_exit = True
        return

    try:
        import webview
    except Exception as exc:
        logger.warning("pywebview unavailable (%s); falling back to default browser", exc)
        webbrowser.open(url)
        try:
            while server_thread.is_alive():
                server_thread.join(timeout=0.5)
        except KeyboardInterrupt:
            server.should_exit = True
        return

    webview.settings["ALLOW_DOWNLOADS"] = True
    webview.settings["OPEN_EXTERNAL_LINKS_IN_BROWSER"] = True

    api = _DesktopAPI(url)
    window = webview.create_window(
        title=f"{APP_NAME} — 海量 PDF 智能批量压缩引擎",
        url=url,
        width=1360,
        height=880,
        min_size=(960, 640),
        background_color="#0b0d12",
        js_api=api,
        text_select=True,
    )
    api.bind_window(window)

    def _on_closed() -> None:
        logger.info("Desktop window closed; shutting down backend")
        server.should_exit = True

    window.events.closed += _on_closed

    try:
        webview.start(debug=False)
    finally:
        server.should_exit = True
        server_thread.join(timeout=3.0)
