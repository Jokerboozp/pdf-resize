# PDF Resize — 原生海量 PDF 智能批量压缩

专为 **数十 GB、数千个 PDF 文件**（如 60GB / 3000+ 文件）打造的高性能原生桌面 PDF 批量压缩工具。

## 平台架构与状态

- **macOS 原生客户端（已完成 · `macos/`）**：
  - **100% 纯 Swift + SwiftUI 构建**（零 WebView、零网页套壳、安装包仅数 MB，秒开即用）。
  - **Apple 官方 HIG + 液态玻璃（Liquid Glass）视觉语言**：原生 `NavigationSplitView` 毛玻璃透景侧边栏、统一工具栏（Unified Toolbar）、右栏参数检视器（`.inspector`）及底部悬浮液态玻璃胶囊操作栏（在 macOS 26 Tahoe 自动启用系统原生 `glassEffect` / `GlassEffectContainer`，在 macOS 14/15 自动启用高光折射多层玻璃材质，完美跟随系统深色/浅色外观）。
  - **原生 Quartz + PDFKit 矢量保留引擎**：仅对嵌入位图进行重采样与 JPEG 重编码，100% 保留矢量文字清晰度、可复制文本与书签结构。
  - **原生 `PDFKit` 画质对比工作台**：支持**卷帘拖拽逐像素对比**与**并排双栏对比**，支持触控板无级缩放。
  - **60GB / 3000+ 海量工程保障**：C `SQLite3`（WAL 模式）断点续传 + 历史已优化指纹秒跳过 + 子进程分批隔离调度（彻底释放 CoreGraphics 内存，杜绝单文件损坏拖垮主界面）+ 同卷临时文件原子替换与变大自动跳过保护。
- **Windows 原生客户端（待办 · 见 [TODO.md](TODO.md) 与 [windows/TODO.md](windows/TODO.md)）**：
  - 规划采用 **WinUI 3 / Windows App SDK** 构建纯原生 Windows 应用，遵循 Microsoft Fluent 2 设计规范（`Mica` 云母主背景 + `DesktopAcrylic` 亚克力浮层 + 原生 `NavigationView`）。

---

## macOS 快速运行与打包

确保已安装 Xcode 或命令行工具（`xcode-select --install`）：

### 1. 一键编译并启动原生 App
```bash
git pull origin master
./start.sh
```
（或直接在访达双击 `start.command`；首次运行会自动编译 `dist/PDF Resize.app` 并启动，后续秒开。）

### 2. 打包独立 `.app` 与 `.dmg` 安装镜像
```bash
./build_mac_app.sh
```
构建完成后输出：
- `dist/PDF Resize.app`（可直接拖入 `/Applications` 应用程序目录）
- `dist/PDF-Resize-macOS-arm64.dmg`

### 3. 云端自动构建下载
每次推送到 `master` 或创建 `v*` 标签，GitHub Actions（`.github/workflows/build-desktop.yml`）会自动运行 `swift test` 单元测试并打包上传原生 **macOS `.dmg`** 产物，可在仓库 **Actions** 页面直接下载安装。
