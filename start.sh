#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

if [ "$(uname -s)" = "Darwin" ]; then
  APP_BIN="dist/PDF Resize.app/Contents/MacOS/PDFResize"
  NEED_BUILD=0
  if [ ! -x "$APP_BIN" ]; then
    NEED_BUILD=1
  elif [ -n "$(find macos -type f \( -name '*.swift' -o -name 'Info.plist' -o -name 'Package.swift' \) -newer "$APP_BIN" 2>/dev/null)" ]; then
    NEED_BUILD=1
  fi

  if [ "$NEED_BUILD" -eq 1 ]; then
    echo "正在构建原生 Swift 液态玻璃 macOS 应用 ..."
    SKIP_DMG=1 bash ./build_mac_app.sh
  fi

  echo "正在启动原生应用: dist/PDF Resize.app"
  open "dist/PDF Resize.app"
  exit 0
fi

# 非 macOS 环境回退到命令行 / Python 服务
python3 run.py serve --port "${PORT:-8765}"
