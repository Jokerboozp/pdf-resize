@echo off
chcp 65001 >nul
cd /d "%~dp0"
if exist ".venv\Scripts\python.exe" (
    ".venv\Scripts\python.exe" run.py serve --port 8765
) else (
    python run.py serve --port 8765
)
pause
