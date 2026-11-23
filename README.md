# PDF Resize — 海量 PDF 智能批量压缩引擎

专为 **数十 GB、数千个 PDF 文件**（如 60GB / 3000+ 文件）打造的高性能本地 Web + 命令行批量 PDF 压缩工具。

## 核心特性

- **双输入模式**：
  - **本地目录直连（推荐 60GB / 3000+ 文件）**：直接扫描本地文件夹（递归子目录），零拷贝、支持 **原地直接优化原 PDF**（也可设置自动备份目录或输出到新目录）。
  - **批量拖拽 / 文件夹上传**：支持在浏览器中直接拖入大量 PDF 或整个文件夹，分块流式写入磁盘，不爆内存，支持实时边传边压。
- **自定义压缩程度**：
  - 4 套开箱即用预设：**无损优化**、**轻度压缩（200 DPI）**、**均衡压缩（150 DPI，推荐）**、**强力压缩（100 DPI）**。
  - 支持自定义 **目标图片 DPI（50–300）**、**JPEG 质量（15–95）**、**转灰度/黑白**、**字体子集化**、**清除元数据**、**QPDF 深度流压缩**、**最小节省阈值**、**并发进程数**。
- **单文件效果试压与肉眼对比**：
  - 在处理 60GB 大批量任务前，先挑 1 个文件试压，立即查看 **压缩前后大小对比** 及 **高清渲染页面并排对比**。
- **为 60GB / 3000+ 文件设计的工程可靠性**：
  - **多进程并行（ProcessPoolExecutor + 进程定期回收）**：充分释放多核 CPU，处理 3000+ PDF 零内存泄漏。
  - **原子写入 + 完整性校验 + 变大保护**：先写入同盘临时文件 -> 校验页数与可读性 -> 仅在确实变小时才原子替换原文件，绝不损坏原文件或越压越大。
  - **断点续传与跳过已优化**：全部进度持久化到 SQLite（WAL 模式），支持暂停/继续/失败重试，并记录已优化文件指纹，重复运行自动秒跳过。
  - **零外部二进制依赖**：基于 `PyMuPDF (MuPDF)` + `Pillow` + `pikepdf (QPDF)` 原生 C/C++ 库，无需手动安装 Ghostscript。

## 快速启动

### 方式一：macOS 启动（推荐）

首次运行会自动创建 `.venv` 并安装所需依赖，之后直接启动 Web 界面：

- **终端运行**：
  ```bash
  ./start.sh
  ```
- **访达（Finder）双击运行**：直接双击 `start.command` 即可（若提示权限不足，先执行一次 `chmod +x start.sh start.command`）。

浏览器会自动打开 `http://127.0.0.1:8765`。

### 方式二：Windows 启动

双击 `start.bat`，或在终端运行：

```powershell
.\.venv\Scripts\python.exe run.py serve --port 8765
```

### 方式三：命令行批量压缩（适合无人值守跑 60GB）

**macOS / Linux：**
```bash
# 原地均衡压缩，并自动备份原文件到外接硬盘（8 进程并行）
./.venv/bin/python -m pdf_resize compress "/Volumes/MySSD/PDFs" --preset balanced --inplace --backup "/Volumes/Backup/PDF_Backup" --workers 8

# 先试跑前 10 个文件看看压缩效果
./.venv/bin/python -m pdf_resize compress ~/Documents/PDFs --preset balanced --output ~/Documents/PDFs_test --limit 10
```

**Windows：**
```powershell
.\.venv\Scripts\python.exe -m pdf_resize compress "D:\MyPDFs" --preset balanced --inplace --backup "E:\PDF_Backup" --workers 8
```

## 依赖安装（如需重新配置环境）

```powershell
python -m venv .venv
.\.venv\Scripts\python.exe -m pip install -r requirements.txt
```
