from __future__ import annotations

import argparse
import sys
import time
import webbrowser
from pathlib import Path

import uvicorn

from .models import PRESETS, apply_preset, default_workers
from .manager import JobManager
from .storage import Storage


def _fmt_size(num: int | float) -> str:
    val = float(num)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if abs(val) < 1024.0:
            return f"{val:.2f} {unit}"
        val /= 1024.0
    return f"{val:.2f} PB"


def cmd_serve(args: argparse.Namespace) -> None:
    url = f"http://{args.host}:{args.port}"
    print(f"PDF Resize Web UI 启动中: {url}")
    if not args.no_browser:
        def _open() -> None:
            time.sleep(1.2)
            webbrowser.open(url)
        import threading
        threading.Thread(target=_open, daemon=True).start()
    uvicorn.run("pdf_resize.server:app", host=args.host, port=args.port, log_level="info")


def cmd_compress(args: argparse.Namespace) -> None:
    overrides: dict = {
        "workers": args.workers,
        "grayscale": args.grayscale,
        "skip_already_optimized": not args.no_skip_done,
        "min_saving_percent": args.min_saving,
    }
    if args.dpi is not None:
        overrides["target_dpi"] = args.dpi
        overrides["downsample_images"] = True
    if args.quality is not None:
        overrides["jpeg_quality"] = args.quality
    if args.strip_metadata:
        overrides["strip_metadata"] = True

    cfg = apply_preset(args.preset, overrides)
    output_mode = "inplace" if args.inplace else "output_dir"
    if output_mode == "output_dir" and not args.output:
        print("错误: 非原地模式请通过 --output 指定输出目录，或使用 --inplace 直接优化原文件", file=sys.stderr)
        sys.exit(1)

    storage = Storage()
    manager = JobManager(storage)
    print(f"正在扫描目录: {args.source} ...")
    job = manager.create_local_job(
        source_dir=args.source,
        output_mode=output_mode,
        output_dir=args.output,
        backup_dir=args.backup,
        config=cfg,
        recursive=not args.no_recursive,
        limit_files=args.limit,
        auto_start=True,
    )
    job_id = job["id"]
    print(f"任务已创建 [{job_id}]，共 {job['stats']['total_files']} 个 PDF ({_fmt_size(job['stats']['total_orig_bytes'])})，并行进程: {cfg.workers}")

    try:
        while True:
            detail = manager.get_job_detail(job_id)
            if not detail:
                break
            st = detail["stats"]
            live = detail["live"]
            speed = _fmt_size(live["bytes_per_sec"]) + "/s"
            eta = f"{live['eta_seconds']}s" if live["eta_seconds"] is not None else "--"
            line = (
                f"\r进度: {st['completed_files']}/{st['total_files']} ({st['progress_bytes_pct']:.1f}%) | "
                f"已省: {_fmt_size(st['saved_bytes'])} ({st['saving_percent']:.1f}%) | "
                f"成功:{st['done']} 跳过:{st['skipped']} 失败:{st['failed']} | "
                f"速度:{speed} ETA:{eta}   "
            )
            print(line, end="", flush=True)
            if detail["status"] in ("completed", "failed", "cancelled"):
                print("\n任务结束，状态:", detail["status"])
                break
            time.sleep(0.8)
    except KeyboardInterrupt:
        print("\n收到中断信号，正在安全暂停任务（已处理文件均已完成原子写入）...")
        manager.pause_job(job_id)
        time.sleep(1.5)
    finally:
        storage.close()


def main() -> None:
    parser = argparse.ArgumentParser(prog="pdf_resize", description="海量 PDF 批量智能压缩工具")
    sub = parser.add_subparsers(dest="command")

    p_serve = sub.add_parser("serve", help="启动 Web 可视化界面")
    p_serve.add_argument("--host", default="127.0.0.1")
    p_serve.add_argument("--port", type=int, default=8765)
    p_serve.add_argument("--no-browser", action="store_true")

    p_comp = sub.add_parser("compress", help="命令行批量压缩本地 PDF 目录")
    p_comp.add_argument("source", help="PDF 源目录路径")
    p_comp.add_argument("--preset", choices=list(PRESETS.keys()), default="balanced", help="压缩预设")
    p_comp.add_argument("--dpi", type=int, default=None, help="自定义目标图片 DPI (50-600)")
    p_comp.add_argument("--quality", type=int, default=None, help="自定义 JPEG 质量 (15-95)")
    p_comp.add_argument("--grayscale", action="store_true", help="将图片转为灰度")
    p_comp.add_argument("--strip-metadata", action="store_true", help="清除 PDF 元数据")
    p_comp.add_argument("--inplace", action="store_true", help="直接原地优化覆盖原文件")
    p_comp.add_argument("--output", default=None, help="非原地模式时的输出目录")
    p_comp.add_argument("--backup", default=None, help="原地模式时的自动备份目录")
    p_comp.add_argument("--workers", type=int, default=default_workers(), help="并行工作进程数")
    p_comp.add_argument("--min-saving", type=float, default=1.0, help="最小节省百分比阈值")
    p_comp.add_argument("--no-recursive", action="store_true", help="不递归扫描子目录")
    p_comp.add_argument("--no-skip-done", action="store_true", help="不跳过历史已优化文件")
    p_comp.add_argument("--limit", type=int, default=None, help="仅处理前 N 个文件（用于试跑）")

    args = parser.parse_args()
    if args.command == "compress":
        cmd_compress(args)
    else:
        if args.command is None:
            args.host = "127.0.0.1"
            args.port = 8765
            args.no_browser = False
        cmd_serve(args)


if __name__ == "__main__":
    main()
