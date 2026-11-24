# PDF Resize 跨平台原生客户端路线图 (TODO)

## 已完成 (Done)
- [x] **macOS 原生桌面端（Swift + SwiftUI + Liquid Glass）** — 位于 `macos/`
  - 遵循 Apple Human Interface Guidelines (HIG)，采用原生 `NavigationSplitView` 侧边栏毛玻璃透景、统一工具栏（Unified Toolbar）、右栏检视器（Inspector）与悬浮液态玻璃胶囊操作栏（macOS 26 原生调用 `glassEffect` / `GlassEffectContainer`，macOS 14/15 自适应高光折射玻璃材质）。
  - 纯原生 `QuartzFilter` + `PDFKit` + `CoreGraphics` 压缩引擎，100% 保留矢量文字清晰度与可复制性。
  - 原生 C `SQLite3`（WAL 模式）断点续传与已优化指纹跳过，子进程分批隔离调度支持 60GB / 3000+ 海量 PDF 零内存累积。

- [x] **Windows 原生桌面端（WinUI 3 / Windows App SDK · Fluent 2 设计规范）** — 位于 `windows/`
  - [x] 使用 C# / .NET 8 + Windows App SDK 1.6 (WinUI 3) 构建纯原生自包含 Windows 桌面应用（零 WebView 内嵌网页壳）。
  - [x] 遵循 Microsoft Fluent 2 设计规范：启用 `MicaBackdrop` 云母主材质（自动回退 `DesktopAcrylicBackdrop`）、沉浸式自定义标题栏（完整保留 Windows 11 Snap Layouts）、原生 `NavigationView`、`Expander`、`InfoBar`、`InfoBadge` 与 UI 虚拟化 `ListView`，自适应系统深浅色与主题强调色。
  - [x] 原生 C# 矢量保留压缩引擎（`PDFsharp 6` 结构修改 + `SkiaSharp` 位图高质重采样重编码），支持 Win32 COM `IFileOpenDialog` 跨盘符一次多选文件夹、资源管理器拖拽导入、基于 `Windows.Data.Pdf` 的单文件卷帘/并排双模式对比、同卷临时文件页数校验与 `File.Move` 原子替换、`SQLite WAL` 断点续传及 `--worker-one` 子进程内存隔离。
  - [x] 配置 GitHub Actions `windows-latest` 自动执行 `xUnit` 测试并打包上传免安装自包含 `PDF-Resize-Windows-x64.zip`。
