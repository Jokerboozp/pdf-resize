# PDF Resize — 原生海量 PDF 智能批量压缩

专为 **数十 GB、数千个 PDF 文件**（如 60GB / 3000+ 文件）打造的双平台纯原生桌面 PDF 批量压缩工具。

## 双平台纯原生架构

### 1. Windows 原生客户端（已完成 · `windows/`）
- **100% 纯 C# / .NET 8 + WinUI 3 (Windows App SDK 1.6)** 构建（零 WebView、零网页套壳，自包含免安装解压即用）。
- **Microsoft Fluent 2 视觉规范**：主窗口采用 Windows 11 原生 `MicaBackdrop` 云母透景材质（自动兼容 `DesktopAcrylicBackdrop`）、沉浸式自定义标题栏（完整支持最大化按钮悬停 Snap Layouts）、原生 `NavigationView`、`Expander`、`InfoBar` 与 UI 虚拟化 `ListView`，完美跟随系统深色/浅色主题。
- **跨盘符多文件夹导入**：调用 Win32 COM `IFileOpenDialog`（`FOS_PICKFOLDERS | FOS_ALLOWMULTISELECT`）支持按住 `Ctrl` / `Shift` 一次多选任意多个文件夹，同时支持直接从资源管理器拖入文件夹与 PDF。
- **原生矢量保留压缩内核**：基于 `PDFsharp 6` + `SkiaSharp` 仅对嵌入高分辨率位图重采样与重编码，**100% 保留矢量文字清晰度、可复制文本、书签与超链接**。
- **原生 `Windows.Data.Pdf` 画质对比**：内置**卷帘分割拖拽对比**与**左右同步滚动并排对比**，先验画质再跑批量。
- **60GB / 3000+ 海量工程保障**：`SQLite WAL` 断点续传 + 历史已优化指纹秒跳过 + `--worker-one` 独立子进程池隔离执行（进程退出即 100% 释放非托管位图内存，连续跑完 60GB 零内存堆积）+ 同卷 `.pdfresize.tmp` 页数校验原子替换与变大自动跳过保护。

### 2. macOS 原生客户端（已完成 · `macos/`）
- **100% 纯 Swift + SwiftUI 构建**（零 WebView、零网页套壳、安装包仅 1.3 MB，秒开即用）。
- **Apple 官方 HIG + 液态玻璃（Liquid Glass）视觉语言**：原生 `NavigationSplitView` 毛玻璃透景侧边栏、统一工具栏（Unified Toolbar）、右栏参数检视器（`.inspector`）及底部悬浮液态玻璃胶囊操作栏（在 macOS 26 Tahoe 自动启用系统原生 `glassEffect` / `GlassEffectContainer`，在 macOS 14/15 自动启用高光折射多层玻璃材质）。
- **原生 Quartz + PDFKit 矢量保留引擎**：支持卷帘拖拽与并排双栏对比、C `SQLite3` WAL 断点续传与子进程隔离调度。

---

## Windows 快速运行与打包

### 方式一：直接下载云端自动构建成品（推荐 · 无需安装任何开发环境）
每次推送代码，GitHub Actions（`.github/workflows/build-desktop.yml`）都会自动运行单元测试并编译上传自包含绿色包：
- 在 GitHub 仓库 **Actions** 页面下载 **`PDF-Resize-Windows-WinUI3-x64`** 产物，解压后直接双击 **`PDFResize.exe`** 即可运行（已内置 .NET 8 与 Windows App SDK 1.6 运行时）。

### 方式二：本地源码编译打包（需安装 .NET 8 SDK）
```bat
:: 一键编译并直接启动 WinUI 3 原生客户端
start.bat

:: 或运行完整单元测试并打包 dist\PDF-Resize-Windows-x64.zip
build_win_exe.bat
```

---

## macOS 快速运行与打包

确保已安装 Xcode 或命令行工具（`xcode-select --install`）：

```bash
# 一键编译并启动原生 App
./start.sh

# 打包独立 .app 与 .dmg 安装镜像
./build_mac_app.sh
```
构建产物：`dist/PDF Resize.app` 与 `dist/PDF-Resize-macOS-arm64.dmg`。
