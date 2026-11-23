"""Standalone desktop app entry point for PyInstaller bundles."""

from __future__ import annotations

import argparse
import multiprocessing
import sys


def main() -> None:
    # MUST be called first so ProcessPoolExecutor worker processes on macOS/Windows
    # don't spawn recursive copies of the desktop app window.
    multiprocessing.freeze_support()

    parser = argparse.ArgumentParser(prog="PDF Resize", add_help=True)
    parser.add_argument("--browser", action="store_true", help="Open in default web browser instead of native window")
    parser.add_argument("--port", type=int, default=8765, help="Preferred local port")
    parser.add_argument("--self-test", type=float, default=None, help="Start backend, verify health, and exit after N seconds")
    # Ignore macOS Finder launch flags such as -psn_0_xxxxx
    args, _unknown = parser.parse_known_args(sys.argv[1:])

    from pdf_resize.desktop import run_desktop

    run_desktop(
        preferred_port=args.port,
        use_browser=args.browser,
        self_test_seconds=args.self_test,
    )


if __name__ == "__main__":
    main()
