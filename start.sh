#!/usr/bin/env bash
set -euo pipefail

# 切换到脚本所在项目根目录
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# 补充 Homebrew 等常见路径（Finder 双击 .command 启动时 PATH 较精简）
export PATH="/opt/homebrew/bin:/usr/local/bin:/Library/Frameworks/Python.framework/Versions/Current/bin:$PATH"

PORT="${PORT:-8765}"
HOST="${HOST:-127.0.0.1}"

# 查找合适的 Python 3 (>= 3.10)
PYTHON_BIN=""
for candidate in python3.13 python3.12 python3.11 python3.10 python3; do
  if command -v "$candidate" >/dev/null 2>&1; then
    if "$candidate" -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 10) else 1)' 2>/dev/null; then
      PYTHON_BIN="$(command -v "$candidate")"
      break
    fi
  fi
done

if [ -z "$PYTHON_BIN" ]; then
  echo "错误：未检测到 Python 3.10 或更高版本。"
  echo "请先通过 Homebrew 安装：brew install python"
  echo "或前往 https://www.python.org/downloads/ 下载安装 macOS 版本。"
  exit 1
fi

echo "使用 Python: $PYTHON_BIN ($("$PYTHON_BIN" --version))"

# 首次运行自动创建虚拟环境
if [ ! -x ".venv/bin/python" ]; then
  echo "正在创建虚拟环境 .venv ..."
  "$PYTHON_BIN" -m venv .venv
fi

# 检查依赖是否已安装，缺失则自动安装
if ! ".venv/bin/python" -c "import fastapi, uvicorn, pymupdf, pikepdf, PIL" >/dev/null 2>&1; then
  echo "首次运行，正在安装依赖包（pymupdf / pikepdf / pillow / fastapi）..."
  ".venv/bin/python" -m pip install --upgrade pip
  ".venv/bin/python" -m pip install -r requirements.txt
fi

echo ""
echo "=========================================="
echo " PDF Resize 正在启动: http://${HOST}:${PORT}"
echo " 按 Ctrl+C 可随时安全停止服务"
echo "=========================================="
echo ""

exec ".venv/bin/python" run.py serve --host "$HOST" --port "$PORT"
