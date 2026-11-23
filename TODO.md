# PDF Resize 跨平台原生客户端路线图 (TODO)

## 已完成 (Done)
- [x] **macOS 原生桌面端（Swift + SwiftUI + Liquid Glass）** — 位于 `macos/`
  - 遵循 Apple Human Interface Guidelines (HIG)，采用原生 `NavigationSplitView` 侧边栏毛玻璃透景、统一工具栏（Unified Toolbar）、右栏检视器（Inspector）与悬浮液态玻璃胶囊操作栏（macOS 26 原生调用 `glassEffect` / `GlassEffectContainer`，macOS 14/15 自适应高光折射玻璃材质）。
  - 纯原生 `QuartzFilter` + `PDFKit` + `CoreGraphics` 压缩引擎，100% 保留矢量文字清晰度与可复制性。
  - 原生 C `SQLite3`（WAL 模式）断点续传与已优化指纹跳过，子进程分批隔离调度支持 60GB / 3000+ 海量 PDF 零内存累积。

## 待办 (TODO)
- [ ] **Windows 原生桌面端（WinUI 3 / Windows App SDK · Fluent 2 设计规范）** — 详见 [windows/TODO.md](windows/TODO.md)
  - [ ] 使用 C# / .NET 8 + Windows App SDK (WinUI 3) 构建纯原生 Windows 桌面窗口（彻底替代旧版内嵌网页壳）。
  - [ ] 遵循 Microsoft Fluent 2 设计规范：启用 `Mica` / `MicaAlt` 主窗口材质与 `DesktopAcrylic` 浮层材质，使用原生 `NavigationView`、`CommandBar`、`Expander`、`InfoBar` 与 `DataGrid`/虚拟化 `ListView`，自适应系统深浅色与主题强调色。
  - [ ] 接入高性能原生 PDF 压缩内核（PDFium / MuPDF 原生绑定或独立原生 Worker 进程池），支持多盘符多目录递归去重、同卷原子替换（`MoveFileExW` `MOVEFILE_REPLACE_EXISTING`）与断点续传。
  - [ ] 配置 GitHub Actions `windows-latest` MSBuild 自动打包签名发布 MSIX / 绿色单目录发行包。
