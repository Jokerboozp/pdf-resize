# Windows 原生客户端架构说明（WinUI 3 · Microsoft Fluent 2）

> 当前状态：**已完成（Completed）** — 代码位于 `windows/`，并由 GitHub Actions `windows-latest` 自动构建自包含发行包。

## 1. 工程结构
- `windows/PDFResize.sln` — Visual Studio 2022 解决方案（支持 `x64` / `ARM64`）
- `windows/PDFResize.Core/` — 核心压缩与批量调度类库（.NET 8）：
  - `Engine/PdfCompressor.cs`：`PDFsharp 6` + `SkiaSharp` 嵌入式图像重采样与 JPEG 重编码（兼容 `/DCTDecode` 与含 PNG 预测器的 `/FlateDecode` RGB/Gray/CMYK 位图），100% 保留矢量文字、字体、书签与超链接；内置变大自动跳过、页数完整性校验、同卷 `.pdfresize.tmp` 原子替换与可选备份。
  - `Engine/DirectoryScanner.cs`：跨盘符多目录递归扫描、大小写不敏感路径去重、同名根目录自动消歧及分批试跑游标推进。
  - `Engine/JobStore.cs`：`Microsoft.Data.Sqlite`（WAL 模式）任务状态与已优化指纹持久化（`%LOCALAPPDATA%\PDF Resize\jobs_winui.sqlite3`）。
  - `Engine/BatchCoordinator.cs`：多核并发任务池与 `PDFResize.exe --worker-one` 独立子进程内存隔离执行器。
- `windows/PDFResize.App/` — 原生 WinUI 3 桌面客户端（Windows App SDK 1.6）：
  - `MainWindow.xaml(.cs)`：`MicaBackdrop` 云母透景材质、沉浸式标题栏（保留 Snap Layouts）、`NavigationView` 导航壳层与全窗口资源管理器拖拽导入浮层。
  - `Interop/NativeFolderPicker.cs`：Win32 COM `IFileOpenDialog`（`FOS_PICKFOLDERS | FOS_ALLOWMULTISELECT`）原生多选文件夹对话框。
  - `Views/WorkbenchPage.xaml(.cs)`：多文件夹管理、扫描统计、四档预设卡片、DPI/JPEG 滑块、`Expander` 高级参数与底部常驻安全操作栏。
  - `Views/ComparePage.xaml(.cs)`：基于系统原生 `Windows.Data.Pdf` 高清渲染的**卷帘分割对比**与**同步滚动左右并排对比**。
  - `Views/JobsPage.xaml(.cs)`：3,000+ 文件 UI 虚拟化实时监控列表、吞吐速度/ETA 仪表盘、暂停/继续/失败重试。
  - `Views/SettingsPage.xaml(.cs)`：深浅色外观切换、默认并发进程数与跳过指纹库重置。
- `windows/PDFResize.Tests/` — `xUnit` 自动化测试套件（矢量保留校验、Flate/JPEG 压缩率、密码保护跳过、多目录试跑与子进程 CLI 验证）。

## 2. 已对齐核心能力清单
- [x] **多文件夹与拖拽导入**：Win32 `IFileOpenDialog` 一次多选多个文件夹 + 资源管理器直接拖入文件夹与海量 PDF。
- [x] **压缩预设与自定义参数**：无损清理 / 高清轻压 / 均衡推荐 / 极致瘦身 + DPI、JPEG 质量、灰度、元数据清理、最小节省阈值。
- [x] **单文件卷帘与并排画质对比**：基于 `Windows.Data.Pdf` 高分渲染原图与压缩后页面，支持平滑分割线拖拽与同步滚动。
- [x] **60GB / 3000+ 海量任务调度**：SQLite WAL 任务队列 + `--worker-one` 多进程隔离工作池 + 同盘临时文件页数校验 + 原子替换 + 暂停/继续/失败重试。
