from __future__ import annotations

import os
from typing import Literal, Optional
from pydantic import BaseModel, Field


PresetName = Literal["lossless", "light", "balanced", "extreme", "custom"]
OutputMode = Literal["inplace", "output_dir"]


def default_workers() -> int:
    cpu = os.cpu_count() or 4
    return max(1, min(cpu - 2 if cpu > 4 else cpu, 8))


class CompressionConfig(BaseModel):
    preset: PresetName = "balanced"
    compress_images: bool = True
    target_dpi: int = Field(default=150, ge=50, le=600)
    downsample_images: bool = True
    jpeg_quality: int = Field(default=70, ge=15, le=95)
    grayscale: bool = False
    optimize_transparent: bool = True
    subset_fonts: bool = True
    strip_metadata: bool = False
    clean_streams: bool = True
    use_qpdf: bool = True
    min_saving_percent: float = Field(default=1.0, ge=0.0, le=90.0)
    skip_smaller_than_kb: int = Field(default=0, ge=0)
    skip_already_optimized: bool = True
    preserve_mtime: bool = True
    workers: int = Field(default_factory=default_workers, ge=1, le=32)


PRESETS: dict[str, dict] = {
    "lossless": {
        "label": "无损优化",
        "description": "不降低图片画质，仅清理冗余对象、重复流、字体子集化与深度流压缩（约省 5%–25%）",
        "config": {
            "preset": "lossless",
            "compress_images": False,
            "downsample_images": False,
            "target_dpi": 300,
            "jpeg_quality": 90,
            "grayscale": False,
            "optimize_transparent": False,
            "subset_fonts": True,
            "strip_metadata": False,
            "clean_streams": True,
            "use_qpdf": True,
            "min_saving_percent": 0.5,
        },
    },
    "light": {
        "label": "轻度压缩（高清打印）",
        "description": "200 DPI + 高品质 JPEG(82)，肉眼几乎无差异，适合高清存档与打印（约省 25%–50%）",
        "config": {
            "preset": "light",
            "compress_images": True,
            "downsample_images": True,
            "target_dpi": 200,
            "jpeg_quality": 82,
            "grayscale": False,
            "optimize_transparent": True,
            "subset_fonts": True,
            "strip_metadata": False,
            "clean_streams": True,
            "use_qpdf": True,
            "min_saving_percent": 1.0,
        },
    },
    "balanced": {
        "label": "均衡压缩（推荐）",
        "description": "150 DPI + 质量 70，清晰度与体积最佳平衡，最适合海量文档归档（约省 45%–75%）",
        "config": {
            "preset": "balanced",
            "compress_images": True,
            "downsample_images": True,
            "target_dpi": 150,
            "jpeg_quality": 70,
            "grayscale": False,
            "optimize_transparent": True,
            "subset_fonts": True,
            "strip_metadata": False,
            "clean_streams": True,
            "use_qpdf": True,
            "min_saving_percent": 1.0,
        },
    },
    "extreme": {
        "label": "强力压缩（极致瘦身）",
        "description": "100 DPI + 质量 50 + 清除元数据，适合扫描件大幅缩减空间（约省 65%–88%）",
        "config": {
            "preset": "extreme",
            "compress_images": True,
            "downsample_images": True,
            "target_dpi": 100,
            "jpeg_quality": 50,
            "grayscale": False,
            "optimize_transparent": True,
            "subset_fonts": True,
            "strip_metadata": True,
            "clean_streams": True,
            "use_qpdf": True,
            "min_saving_percent": 1.0,
        },
    },
}


def apply_preset(preset_name: str, overrides: Optional[dict] = None) -> CompressionConfig:
    base = dict(PRESETS.get(preset_name, PRESETS["balanced"])["config"])
    if overrides:
        base.update(overrides)
    return CompressionConfig(**base)


class ScanDirRequest(BaseModel):
    path: str
    recursive: bool = True
    skip_smaller_than_kb: int = 0
    skip_already_optimized: bool = True


class CreateLocalJobRequest(BaseModel):
    name: Optional[str] = None
    source_dir: str
    recursive: bool = True
    output_mode: OutputMode = "inplace"
    output_dir: Optional[str] = None
    backup_dir: Optional[str] = None
    config: CompressionConfig = Field(default_factory=CompressionConfig)
    limit_files: Optional[int] = Field(default=None, ge=1)


class CreateUploadJobRequest(BaseModel):
    name: Optional[str] = None
    output_dir: Optional[str] = None
    config: CompressionConfig = Field(default_factory=CompressionConfig)


class PreviewRequest(BaseModel):
    file_path: str
    page: int = Field(default=0, ge=0)
    config: CompressionConfig = Field(default_factory=CompressionConfig)
