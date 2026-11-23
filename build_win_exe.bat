@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
cd /d "%~dp0"

set "PYTHON_BIN=.venv\Scripts\python.exe"
if not exist "%PYTHON_BIN%" (
  echo 正在创建虚拟环境 .venv ...
  python -m venv .venv
  if errorlevel 1 (
    echo 错误：未检测到 Python 3.10+，请先安装 Python。
    pause
    exit /b 1
  )
)

echo 1/3 安装依赖（requirements + pyinstaller + pywebview）...
"%PYTHON_BIN%" -m pip install --upgrade pip
"%PYTHON_BIN%" -m pip install -r requirements.txt pyinstaller pywebview
if errorlevel 1 exit /b 1

echo 2/3 生成 Windows 图标 assets\AppIcon.ico ...
"%PYTHON_BIN%" scripts\make_icon.py
if errorlevel 1 exit /b 1

echo 3/3 使用 PyInstaller 打包独立单文件桌面应用 dist\PDF Resize.exe ...
if exist build rmdir /s /q build
if exist "dist\PDF Resize.exe" del /f /q "dist\PDF Resize.exe"
"%PYTHON_BIN%" -m PyInstaller --noconfirm --clean "PDF Resize.spec"
if errorlevel 1 exit /b 1

echo.
echo ==========================================
echo  打包完成！
echo  独立桌面程序: dist\PDF Resize.exe
echo  无需 Python 或任何依赖，可直接拷贝到任意 Windows 电脑双击运行
echo ==========================================
pause
