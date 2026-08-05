#!/usr/bin/env python3
"""从 Resources/AppIcon-1024.png 导出 macOS 应用图标与菜单栏图标。"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent
MASTER = ROOT / "AppIcon-1024.png"
ICONSET = ROOT / "AppIcon.iconset"
ICNS = ROOT / "AppIcon.icns"

# macOS AppIcon.iconset 标准尺寸
ICONSET_SIZES = [
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

# 菜单栏状态项（NSStatusBar）：18pt @1x / @2x
MENUBAR_SIZES = [
    ("MenuBarIcon.png", 18),
    ("MenuBarIcon@2x.png", 36),
]


def load_master() -> Image.Image:
    if not MASTER.exists():
        print(f"error: 未找到主图标 {MASTER}", file=sys.stderr)
        print("请将 1024×1024 的 PNG 保存为 Resources/AppIcon-1024.png", file=sys.stderr)
        sys.exit(1)
    img = Image.open(MASTER).convert("RGBA")
    if img.size != (1024, 1024):
        print(f"提示: 主图标为 {img.size[0]}×{img.size[1]}，将缩放至 1024×1024")
        img = img.resize((1024, 1024), Image.Resampling.LANCZOS)
    return img


def export_pngs(master: Image.Image, specs: list[tuple[str, int]], out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    for name, px in specs:
        master.resize((px, px), Image.Resampling.LANCZOS).save(out_dir / name, "PNG")


def build_icns() -> None:
    subprocess.run(["iconutil", "-c", "icns", str(ICONSET), "-o", str(ICNS)], check=True)


def main() -> int:
    print(f"从 {MASTER.name} 导出图标…")
    master = load_master()
    export_pngs(master, ICONSET_SIZES, ICONSET)
    export_pngs(master, MENUBAR_SIZES, ROOT)
    build_icns()
    print(f"✅ 已生成: {ICNS.name}, {ICONSET.name}/, MenuBarIcon.png, MenuBarIcon@2x.png")
    return 0


if __name__ == "__main__":
    sys.exit(main())
