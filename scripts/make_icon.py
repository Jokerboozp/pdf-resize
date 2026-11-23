"""Generate a high-resolution macOS AppIcon.icns using Pillow + iconutil."""

from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

from PIL import Image, ImageDraw, ImageFont


def _draw_master_icon(size: int = 1024) -> Image.Image:
    img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    draw = ImageDraw.Draw(img)

    # macOS Big Sur+ icon inset (~8.5% margin around squircle)
    pad = int(size * 0.09)
    box = (pad, pad, size - pad, size - pad)
    radius = int((size - 2 * pad) * 0.225)

    # Create blue -> cyan gradient matching Web UI brand icon
    grad = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    gpx = grad.load()
    span = max(1, size - 2 * pad)
    for y in range(pad, size - pad):
        fy = (y - pad) / span
        for x in range(pad, size - pad):
            fx = (x - pad) / span
            t = 0.55 * fx + 0.45 * fy
            r = int(59 * (1 - t) + 6 * t)
            g = int(130 * (1 - t) + 182 * t)
            b = int(246 * (1 - t) + 212 * t)
            gpx[x, y] = (r, g, b, 255)

    mask = Image.new("L", (size, size), 0)
    mdraw = ImageDraw.Draw(mask)
    mdraw.rounded_rectangle(box, radius=radius, fill=255)
    img.paste(grad, (0, 0), mask)

    # Subtle glossy inner border
    draw.rounded_rectangle(
        (pad + 4, pad + 4, size - pad - 4, size - pad - 4),
        radius=radius - 4,
        outline=(255, 255, 255, 68),
        width=6,
    )

    # Stylized document card + compression arrows
    doc_w = int(size * 0.44)
    doc_h = int(size * 0.50)
    dx0 = (size - doc_w) // 2
    dy0 = int(size * 0.19)
    dx1 = dx0 + doc_w
    dy1 = dy0 + doc_h
    fold = int(doc_w * 0.24)

    doc_poly = [
        (dx0 + 28, dy0),
        (dx1 - fold, dy0),
        (dx1, dy0 + fold),
        (dx1, dy1 - 28),
        (dx1 - 28, dy1),
        (dx0 + 28, dy1),
        (dx0, dy1 - 28),
        (dx0, dy0 + 28),
    ]
    draw.polygon(doc_poly, fill=(255, 255, 255, 240))
    # Folded corner triangle
    draw.polygon(
        [(dx1 - fold, dy0), (dx1, dy0 + fold), (dx1 - fold, dy0 + fold)],
        fill=(191, 219, 254, 245),
    )

    # Inward compression chevrons (left & right of the document)
    arrow_color = (255, 255, 255, 235)
    cy = (dy0 + dy1) // 2
    aw = int(size * 0.075)
    ah = int(size * 0.085)
    lx = dx0 - int(size * 0.045)
    draw.polygon([(lx, cy), (lx - aw, cy - ah), (lx - aw, cy + ah)], fill=arrow_color)
    rx = dx1 + int(size * 0.045)
    draw.polygon([(rx, cy), (rx + aw, cy - ah), (rx + aw, cy + ah)], fill=arrow_color)

    # Crisp "PDF" badge inside document
    font = None
    for font_path in (
        "/System/Library/Fonts/SFNSRounded.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ):
        if Path(font_path).exists():
            try:
                font = ImageFont.truetype(font_path, int(size * 0.145))
                break
            except Exception:
                continue
    if font is None:
        font = ImageFont.load_default()

    label = "PDF"
    bbox = draw.textbbox((0, 0), label, font=font)
    tw = bbox[2] - bbox[0]
    th = bbox[3] - bbox[1]
    tx = (size - tw) // 2 - bbox[0]
    ty = dy0 + int(doc_h * 0.56) - th // 2 - bbox[1]
    draw.text((tx, ty), label, font=font, fill=(29, 78, 216, 255))

    # Bottom subtitle bar ("RESIZE")
    bar_w = int(size * 0.46)
    bar_h = int(size * 0.095)
    bx0 = (size - bar_w) // 2
    by0 = int(size * 0.745)
    draw.rounded_rectangle(
        (bx0, by0, bx0 + bar_w, by0 + bar_h),
        radius=bar_h // 2,
        fill=(14, 17, 23, 185),
    )
    sub_font = None
    for font_path in (
        "/System/Library/Fonts/SFNSRounded.ttf",
        "/System/Library/Fonts/Supplemental/Arial Bold.ttf",
        "/System/Library/Fonts/Helvetica.ttc",
    ):
        if Path(font_path).exists():
            try:
                sub_font = ImageFont.truetype(font_path, int(size * 0.056))
                break
            except Exception:
                continue
    if sub_font is None:
        sub_font = ImageFont.load_default()
    sub = "RESIZE"
    sb = draw.textbbox((0, 0), sub, font=sub_font)
    stx = (size - (sb[2] - sb[0])) // 2 - sb[0]
    sty = by0 + (bar_h - (sb[3] - sb[1])) // 2 - sb[1]
    draw.text((stx, sty), sub, font=sub_font, fill=(240, 249, 255, 255))

    return img


def build_icons(
    output_icns: Path,
    output_ico: Path | None = None,
    output_png: Path | None = None,
) -> None:
    master = _draw_master_icon(1024)
    output_icns.parent.mkdir(parents=True, exist_ok=True)
    if output_png is not None:
        master.save(str(output_png), format="PNG")

    if output_ico is not None:
        output_ico.parent.mkdir(parents=True, exist_ok=True)
        ico_sizes = [(16, 16), (24, 24), (32, 32), (48, 48), (64, 64), (128, 128), (256, 256)]
        master.save(str(output_ico), format="ICO", sizes=ico_sizes)
        print(f"Generated {output_ico}")

    if sys.platform != "darwin":
        print("Non-macOS platform; skipping .icns generation")
        return

    tmp_dir = Path(tempfile.mkdtemp(prefix="pdfresize_icon_"))
    try:
        iconset = tmp_dir / "AppIcon.iconset"
        iconset.mkdir()
        sizes = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024),
        ]
        for fname, px in sizes:
            resized = master.resize((px, px), Image.Resampling.LANCZOS)
            resized.save(str(iconset / fname), format="PNG")

        subprocess.run(
            ["iconutil", "-c", "icns", str(iconset), "-o", str(output_icns)],
            check=True,
        )
        print(f"Generated {output_icns}")
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)


if __name__ == "__main__":
    root = Path(__file__).resolve().parent.parent
    build_icons(
        root / "assets" / "AppIcon.icns",
        root / "assets" / "AppIcon.ico",
        root / "assets" / "AppIcon.png",
    )
