#!/usr/bin/env bash
# macOS Finder 双击启动脚本
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
exec bash "$SCRIPT_DIR/start.sh" "$@"
