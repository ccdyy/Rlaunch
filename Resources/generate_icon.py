#!/usr/bin/env python3
"""从 Resources/AppIcon-1024.png 导出 macOS 应用图标与菜单栏图标。

用法：
    python3 generate_icon.py          # 从现有 AppIcon-1024.png（用户主图）导出全套资源
    python3 generate_icon.py --draw   # 用内置矢量火箭重绘主图后再导出
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parent
MASTER = ROOT / "AppIcon-1024.png"
ICONSET = ROOT / "AppIcon.iconset"
ICNS = ROOT / "AppIcon.icns"
SS = 4  # 矢量绘制时的超采样倍数

ICONSET_SIZES = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
MENUBAR_SIZES = [("MenuBarIcon.png", 18), ("MenuBarIcon@2x.png", 36)]


# MARK: - 内置矢量火箭（--draw 时使用）

def lerp(a: float, b: float, t: float) -> float:
    return a + (b - a) * t


def vertical_gradient(size: tuple[int, int], top: tuple, bottom: tuple) -> Image.Image:
    w, h = size
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        t = y / max(h - 1, 1)
        c = tuple(int(lerp(top[i], bottom[i], t)) for i in range(3))
        for x in range(w):
            px[x, y] = c
    return img


def draw_rocket_layer(s: int) -> Image.Image:
    """在 s×s 画布上绘制朝右上 45° 的火箭图层（透明背景）。"""
    layer = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)
    cx, cy = s / 2, s / 2
    body_len = s * 0.60
    body_w = s * 0.185
    x0, x1 = cx - body_len / 2, cx + body_len / 2
    y0, y1 = cy - body_w / 2, cy + body_w / 2

    fin_w = body_w * 0.72
    fin_h = body_len * 0.28
    fin_color = (20, 30, 56, 255)
    d.polygon([(x0 + body_w * 0.5, y0), (x0 + body_w * 0.1, y0 - fin_h), (x0 - fin_w, y0)], fill=fin_color)
    d.polygon([(x0 + body_w * 0.5, y1), (x0 + body_w * 0.1, y1 + fin_h), (x0 - fin_w, y1)], fill=fin_color)

    d.rounded_rectangle([x0, y0, x1, y1], radius=body_w / 2, fill=(30, 42, 74, 255))
    d.ellipse([x1 - body_w * 0.55, y0, x1 + body_w * 0.15, y1], fill=(52, 70, 112, 255))

    wr = body_w * 0.38
    d.ellipse([cx - wr, cy - wr, cx + wr, cy + wr], fill=(74, 158, 228, 255))
    d.ellipse([cx - wr * 0.64, cy - wr * 0.64, cx + wr * 0.64, cy + wr * 0.64], fill=(126, 192, 246, 255))

    fx0 = x0 - body_w * 0.15
    fx1 = x0 - body_len * 0.52
    fy0, fy1 = cy - body_w * 0.28, cy + body_w * 0.28
    d.polygon([(fx0, fy0), (fx1, cy), (fx0, fy1)], fill=(255, 96, 48, 255))
    fy0i, fy1i = cy - body_w * 0.15, cy + body_w * 0.15
    d.polygon([(fx0, fy0i), (fx1 * 0.90, cy), (fx0, fy1i)], fill=(255, 196, 80, 255))

    return layer.rotate(45, resample=Image.Resampling.BICUBIC, center=(cx, cy))


def draw_master() -> Image.Image:
    s = 1024 * SS
    img = vertical_gradient((s, s), (248, 250, 253), (222, 230, 242))
    rocket = draw_rocket_layer(s)
    img.paste(rocket, (0, 0), rocket)
    img = img.resize((1024, 1024), Image.Resampling.LANCZOS)
    mask = Image.new("L", (1024, 1024), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, 1023, 1023], radius=229, fill=255)
    img.putalpha(mask)
    return img


# MARK: - 导出

def load_master() -> Image.Image:
    if not MASTER.exists():
        print(f"error: 未找到主图标 {MASTER}", file=sys.stderr)
        sys.exit(1)
    img = Image.open(MASTER).convert("RGBA")
    if img.size != (1024, 1024):
        print(f"提示: 主图标为 {img.size[0]}×{img.size[1]}，将缩放至 1024×1024")
        img = img.resize((1024, 1024), Image.Resampling.LANCZOS)
    return img


def export(master: Image.Image, specs: list[tuple[str, int]], out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, px in specs:
        master.resize((px, px), Image.Resampling.LANCZOS).save(out_dir / name, "PNG")


def main() -> int:
    if "--draw" in sys.argv:
        print("用内置矢量火箭重绘主图标…")
        draw_master().save(MASTER, "PNG")
    else:
        print(f"从 {MASTER.name} 导出图标…")
    master = load_master()
    export(master, ICONSET_SIZES, ICONSET)
    export(master, MENUBAR_SIZES, ROOT)
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)
    print(f"✅ 已生成: {ICNS.name}, {ICONSET.name}/, MenuBarIcon.png, MenuBarIcon@2x.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
