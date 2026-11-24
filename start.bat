@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
cd /d "%~dp0"

if exist "dist\PDF-Resize-Windows-x64\PDFResize.exe" (
  echo 正在启动原生 Windows WinUI 3 客户端...
  start "" "dist\PDF-Resize-Windows-x64\PDFResize.exe"
  exit /b 0
)

where dotnet >nul 2>nul
if errorlevel 1 (
  echo 未检测到本地已编译产物 dist\PDF-Resize-Windows-x64\PDFResize.exe，且系统未安装 .NET 8 SDK。
  echo.
  echo 推荐方式：直接从 GitHub Actions 下载免安装自包含包 PDF-Resize-Windows-WinUI3-x64.zip，
  echo 解压后双击 PDFResize.exe 即可运行（无需安装 .NET 或任何依赖）。
  pause
  exit /b 1
)

echo 首次运行：正在编译原生 WinUI 3 客户端 ^(PDFResize.exe^)...
dotnet publish windows\PDFResize.App\PDFResize.App.csproj ^
  -c Release ^
  -r win-x64 ^
  -p:Platform=x64 ^
  -p:WindowsPackageType=None ^
  -p:WindowsAppSDKSelfContained=true ^
  --self-contained true ^
  -o "dist\PDF-Resize-Windows-x64"
if errorlevel 1 (
  echo 编译失败，请检查是否已安装 Windows App SDK 构建组件。
  pause
  exit /b 1
)

echo 编译完成，正在启动 PDF Resize...
start "" "dist\PDF-Resize-Windows-x64\PDFResize.exe"
