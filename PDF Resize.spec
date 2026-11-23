# -*- mode: python ; coding: utf-8 -*-
import sys
from pathlib import Path
from PyInstaller.utils.hooks import collect_all, collect_submodules

PROJECT_ROOT = Path(SPECPATH).resolve()
IS_MAC = sys.platform == "darwin"
IS_WIN = sys.platform == "win32"

datas = [
    (str(PROJECT_ROOT / "pdf_resize" / "static"), "pdf_resize/static"),
]
binaries = []
hiddenimports = [
    "pdf_resize",
    "pdf_resize.paths",
    "pdf_resize.models",
    "pdf_resize.storage",
    "pdf_resize.compressor",
    "pdf_resize.preview",
    "pdf_resize.manager",
    "pdf_resize.server",
    "pdf_resize.desktop",
    "multipart",
    "python_multipart",
    "uvicorn.logging",
    "uvicorn.loops",
    "uvicorn.loops.auto",
    "uvicorn.loops.asyncio",
    "uvicorn.protocols",
    "uvicorn.protocols.http",
    "uvicorn.protocols.http.auto",
    "uvicorn.protocols.http.h11_impl",
    "uvicorn.protocols.http.httptools_impl",
    "uvicorn.protocols.websockets",
    "uvicorn.protocols.websockets.auto",
    "uvicorn.lifespan",
    "uvicorn.lifespan.on",
    "uvicorn.lifespan.off",
    "anyio._backends._asyncio",
]

if IS_MAC:
    hiddenimports += [
        "webview.platforms.cocoa",
        "objc",
        "Foundation",
        "AppKit",
        "Cocoa",
        "WebKit",
        "Quartz",
        "Security",
        "UniformTypeIdentifiers",
    ]
elif IS_WIN:
    hiddenimports += [
        "webview.platforms.edgechromium",
        "webview.platforms.winforms",
        "clr",
    ]

pkgs_to_collect = ["pymupdf", "pikepdf", "PIL", "webview"]
if IS_WIN:
    pkgs_to_collect += ["clr_loader", "pythonnet"]

for pkg in pkgs_to_collect:
    try:
        p_datas, p_bins, p_hidden = collect_all(pkg)
        datas += p_datas
        binaries += p_bins
        hiddenimports += p_hidden
    except Exception:
        pass

hiddenimports += collect_submodules("uvicorn")
hiddenimports += collect_submodules("fastapi")
hiddenimports += collect_submodules("starlette")
hiddenimports += collect_submodules("pydantic")

block_cipher = None

a = Analysis(
    [str(PROJECT_ROOT / "desktop_main.py")],
    pathex=[str(PROJECT_ROOT)],
    binaries=binaries,
    datas=datas,
    hiddenimports=hiddenimports,
    hookspath=[],
    hooksconfig={},
    runtime_hooks=[],
    excludes=[
        "pytest",
        "tkinter",
        "_tkinter",
        "matplotlib",
        "scipy",
        "numpy.testing",
    ],
    noarchive=False,
    optimize=0,
)

pyz = PYZ(a.pure, a.zipped_data, cipher=block_cipher)

if IS_MAC:
    exe = EXE(
        pyz,
        a.scripts,
        [],
        exclude_binaries=True,
        name="PDF Resize",
        debug=False,
        bootloader_ignore_signals=False,
        strip=False,
        upx=False,
        console=False,
        disable_windowed_traceback=False,
        argv_emulation=False,
        target_arch=None,
        codesign_identity=None,
        entitlements_file=None,
        icon=str(PROJECT_ROOT / "assets" / "AppIcon.icns"),
    )

    coll = COLLECT(
        exe,
        a.binaries,
        a.datas,
        strip=False,
        upx=False,
        upx_exclude=[],
        name="PDF Resize",
    )

    app = BUNDLE(
        coll,
        name="PDF Resize.app",
        icon=str(PROJECT_ROOT / "assets" / "AppIcon.icns"),
        bundle_identifier="com.pdfresize.desktop",
        info_plist={
            "CFBundleName": "PDF Resize",
            "CFBundleDisplayName": "PDF Resize",
            "CFBundleShortVersionString": "1.0.0",
            "CFBundleVersion": "1.0.0",
            "NSHighResolutionCapable": True,
            "LSMinimumSystemVersion": "12.0",
            "NSAppTransportSecurity": {
                "NSAllowsLocalNetworking": True,
            },
        },
    )
elif IS_WIN:
    # Single standalone zero-dependency Windows desktop executable
    exe = EXE(
        pyz,
        a.scripts,
        a.binaries,
        a.datas,
        [],
        name="PDF Resize",
        debug=False,
        bootloader_ignore_signals=False,
        strip=False,
        upx=False,
        upx_exclude=[],
        runtime_tmpdir=None,
        console=False,
        disable_windowed_traceback=False,
        icon=str(PROJECT_ROOT / "assets" / "AppIcon.ico"),
    )
else:
    exe = EXE(
        pyz,
        a.scripts,
        a.binaries,
        a.datas,
        [],
        name="PDF-Resize",
        debug=False,
        bootloader_ignore_signals=False,
        strip=False,
        upx=False,
        console=False,
    )
