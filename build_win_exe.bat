@echo off
setlocal enabledelayedexpansion
chcp 65001 >nul
cd /d "%~dp0"

where dotnet >nul 2>nul
if errorlevel 1 (
  echo 错误：未检测到 .NET 8 SDK ^(dotnet^)。
  echo 请先安装 .NET 8 SDK 与 Windows App SDK 构建组件，或直接从 GitHub Actions 下载预编译原生包。
  pause
  exit /b 1
)

echo [1/3] 运行 PDFResize.Core 原生引擎单元测试...
dotnet test windows\PDFResize.Tests\PDFResize.Tests.csproj -c Release
if errorlevel 1 exit /b 1

echo [2/3] 编译并发布自包含原生 WinUI 3 客户端 ^(win-x64^)...
if exist "dist\PDF-Resize-Windows-x64" rmdir /s /q "dist\PDF-Resize-Windows-x64"
dotnet publish windows\PDFResize.App\PDFResize.App.csproj ^
  -c Release ^
  -r win-x64 ^
  -p:Platform=x64 ^
  -p:WindowsPackageType=None ^
  -p:WindowsAppSDKSelfContained=true ^
  --self-contained true ^
  -o "dist\PDF-Resize-Windows-x64"
if errorlevel 1 exit /b 1

echo [3/3] 生成免安装绿色压缩包 dist\PDF-Resize-Windows-x64.zip ...
if exist "dist\PDF-Resize-Windows-x64.zip" del /f /q "dist\PDF-Resize-Windows-x64.zip"
powershell -NoProfile -Command "Compress-Archive -Path 'dist\PDF-Resize-Windows-x64\*' -DestinationPath 'dist\PDF-Resize-Windows-x64.zip' -Force"
if errorlevel 1 exit /b 1

echo.
echo ==========================================================
echo  Windows 原生 WinUI 3 客户端构建完成！
echo  可执行程序: dist\PDF-Resize-Windows-x64\PDFResize.exe
echo  绿色发行包: dist\PDF-Resize-Windows-x64.zip
echo  内置 .NET 8 与 Windows App SDK 1.6 运行时，解压双击即用！
echo ==========================================================
pause
