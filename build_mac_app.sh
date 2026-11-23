#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PYTHON_BIN="${PYTHON_BIN:-.venv/bin/python}"
if [ ! -x "$PYTHON_BIN" ]; then
  echo "错误：未找到 $PYTHON_BIN，请先运行 ./start.sh 创建虚拟环境。"
  exit 1
fi

if ! "$PYTHON_BIN" -c "import PyInstaller, webview" >/dev/null 2>&1; then
  echo "正在安装桌面打包依赖（pyinstaller / pywebview）..."
  "$PYTHON_BIN" -m pip install pyinstaller pywebview
fi

echo "1/4 生成 macOS 高清应用图标 assets/AppIcon.icns ..."
"$PYTHON_BIN" scripts/make_icon.py

echo "2/4 使用 PyInstaller 打包独立桌面应用 dist/PDF Resize.app ..."
rm -rf build "dist/PDF Resize" "dist/PDF Resize.app"
"$PYTHON_BIN" -m PyInstaller --noconfirm --clean "PDF Resize.spec"

echo "3/4 执行本地 ad-hoc 签名以确保 Apple Silicon 顺利运行 ..."
codesign --force --deep --sign - "dist/PDF Resize.app"

ARCH="$(uname -m)"
DMG_PATH="dist/PDF-Resize-macOS-${ARCH}.dmg"
echo "4/4 生成安装包镜像 ${DMG_PATH} ..."
rm -f "$DMG_PATH"
STAGE_DIR="$(mktemp -d)"
trap 'rm -rf "$STAGE_DIR"' EXIT
cp -R "dist/PDF Resize.app" "$STAGE_DIR/"
ln -s /Applications "$STAGE_DIR/Applications"
hdiutil create \
  -volname "PDF Resize" \
  -srcfolder "$STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo ""
echo "=========================================="
echo " 打包完成！"
echo " 桌面应用: dist/PDF Resize.app"
echo " 安装镜像: ${DMG_PATH}"
echo " 可直接双击 dist/PDF Resize.app 或拖入「应用程序」使用"
echo "=========================================="
