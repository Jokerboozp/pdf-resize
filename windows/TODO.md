# Windows 原生应用待办规划（WinUI 3 · Microsoft Fluent 2）

> 当前状态：**待办（Planned / Todo）** — 现阶段优先交付 macOS 纯 Swift 液态玻璃原生客户端。

## 1. 视觉与交互设计规范（Microsoft Fluent Design System）
- **窗口与材质**：
  - 主窗口采用 `MicaBackdrop`（Windows 11 原生云母材质，随桌面壁纸微妙透色），浮层面板与抽屉采用 `DesktopAcrylicBackdrop`（亚克力半透明模糊）。
  - 集成 `AppWindowTitleBar.ExtendsContentIntoTitleBar = true`，保留原生最大化 Snap Layouts 悬停菜单与丝滑窗口动画。
- **导航与布局**：
  - 使用原生 `NavigationView`（`PaneDisplayMode="Left"`），分为：**批量压缩**、**画质对比**、**任务队列**，底部固定 **设置** 入口。
  - 使用原生 Fluent 控件：`Segmented` / `RadioButtons`、`Slider`、`ToggleSwitch`、`NumberBox`、`Expander`（收纳高级压缩参数）、`BreadcrumbBar` 与 `TeachingTip`。
  - 彻底杜绝 WebView 内嵌网页感，严格遵循 4px/8px 栅格、圆角（8px 卡片 / 4px 控件）与 `Segoe UI Variable` 字体层级。

## 2. 核心功能对齐清单
- [ ] **多文件夹与拖拽导入**：调用 `FolderPicker` / Win32 `IFileOpenDialog`（`FOS_PICKFOLDERS | FOS_ALLOWMULTISELECT`）一次多选多个文件夹，支持资源管理器直接拖入文件夹与海量 PDF。
- [ ] **压缩预设与自定义参数**：无损优化 / 轻度高清 / 均衡推荐 / 极致瘦身 + DPI、JPEG 质量、灰度、元数据清理、最小节省阈值。
- [ ] **单文件卷帘画质对比**：基于 `Windows.Data.Pdf` / PDFium 高分渲染原图与压缩后页面，支持平滑分割线拖拽与同步缩放。
- [ ] **60GB / 3000+ 海量任务调度**：SQLite WAL 任务队列 + 多进程隔离工作池 + 同盘临时文件页数校验 + `MoveFileExW` 原子替换 + 暂停/继续/失败重试。
