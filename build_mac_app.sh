#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

if ! command -v swift >/dev/null 2>&1; then
  echo "错误：未检测到 Swift 工具链，请先运行 xcode-select --install 安装命令行开发者工具。"
  exit 1
fi

ARCH="$(uname -m)"
APP_NAME="PDF Resize"
APP_BUNDLE="dist/${APP_NAME}.app"
DMG_PATH="dist/PDF-Resize-macOS-${ARCH}.dmg"

echo "1/4 编译原生 Swift + Liquid Glass macOS 应用 (Release) ..."
(
  cd macos
  swift build -c release --product PDFResize
)

BIN_PATH="$(cd macos && swift build -c release --show-bin-path)/PDFResize"
if [ ! -x "$BIN_PATH" ]; then
  echo "错误：未找到编译产物 $BIN_PATH"
  exit 1
fi

echo "2/4 组装原生应用包 ${APP_BUNDLE} ..."
rm -rf "$APP_BUNDLE"
mkdir -p "${APP_BUNDLE}/Contents/MacOS" "${APP_BUNDLE}/Contents/Resources"

cp "$BIN_PATH" "${APP_BUNDLE}/Contents/MacOS/PDFResize"
chmod +x "${APP_BUNDLE}/Contents/MacOS/PDFResize"
cp "macos/Info.plist" "${APP_BUNDLE}/Contents/Info.plist"
printf "APPL????" > "${APP_BUNDLE}/Contents/PkgInfo"

if [ -f "assets/AppIcon.icns" ]; then
  cp "assets/AppIcon.icns" "${APP_BUNDLE}/Contents/Resources/AppIcon.icns"
fi

echo "3/4 执行本地 ad-hoc 代码签名 ..."
codesign --force --deep --sign - "$APP_BUNDLE"

if [ "${SKIP_DMG:-0}" != "1" ]; then
  echo "4/4 生成安装包镜像 ${DMG_PATH} ..."
  rm -f "$DMG_PATH"
  STAGE_DIR="$(mktemp -d)"
  trap 'rm -rf "$STAGE_DIR"' EXIT
  cp -R "$APP_BUNDLE" "$STAGE_DIR/"
  ln -s /Applications "$STAGE_DIR/Applications"
  hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGE_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH"
fi

echo ""
echo "=========================================="
echo " 原生 Swift macOS 应用构建完成！"
echo " 应用包: ${APP_BUNDLE}"
if [ "${SKIP_DMG:-0}" != "1" ]; then
  echo " 安装包: ${DMG_PATH}"
fi
echo "=========================================="
