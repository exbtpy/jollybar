#!/usr/bin/env python3
"""Rasterize the Jollybar logo SVGs into the macOS icon and the README images.

The SVGs already contain the squircle, the face, and the wordmark outlines.
This script does not need a font.

    pip install cairosvg
    python3 design/logo/render_icon.py

`make icon` runs the same command. `make app` does not: the build uses the
committed `AppIcon.icns` and asset-catalog PNGs.

The icon SVG is the 1024 master on the macOS icon grid (100px margin, 824px
squircle). Each size is rasterized from that SVG, not scaled down from one
bitmap. Outputs:

- macos/Resources/AppIcon.icns (PNG icon types from 16 through 1024)
- macos/Resources/Assets.xcassets/AppIcon.appiconset/*.png
- macos/Resources/icon.png (1024)
- docs/images/logo.png (512, transparent)
- docs/images/wordmark.png
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
ICON_SVG = ROOT / "design" / "logo" / "jollybar-icon.svg"
WORDMARK_SVG = ROOT / "design" / "logo" / "jollybar-wordmark.svg"
ICONSET = ROOT / "macos" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset"
ICNS_PATH = ROOT / "macos" / "Resources" / "AppIcon.icns"
LEGACY_PNG = ROOT / "macos" / "Resources" / "icon.png"
LOGO_PNG = ROOT / "docs" / "images" / "logo.png"
WORDMARK_PNG = ROOT / "docs" / "images" / "wordmark.png"

# Asset catalog filenames already listed in Contents.json.
ASSET_SIZES = {
    "icon_16x16.png": 16,
    "icon_16x16@2x.png": 32,
    "icon_32x32.png": 32,
    "icon_32x32@2x.png": 64,
    "icon_128x128.png": 128,
    "icon_128x128@2x.png": 256,
    "icon_256x256.png": 256,
    "icon_256x256@2x.png": 512,
    "icon_512x512.png": 512,
    "icon_512x512@2x.png": 1024,
}

# PNG chunks inside an icns. Duplicate pixel sizes are the 1x and 2x types.
ICNS_TYPES = (
    ("icp4", 16),
    ("icp5", 32),
    ("ic11", 32),
    ("icp6", 64),
    ("ic12", 64),
    ("ic07", 128),
    ("ic08", 256),
    ("ic13", 256),
    ("ic09", 512),
    ("ic14", 512),
    ("ic10", 1024),
)


def raster(svg: Path, width: int, height: int | None = None) -> bytes:
    import cairosvg

    return cairosvg.svg2png(
        url=str(svg),
        output_width=width,
        output_height=height if height is not None else width,
    )


def icns(chunks: list[tuple[str, bytes]]) -> bytes:
    body = b"".join(
        ostype.encode("ascii") + struct.pack(">I", len(png) + 8) + png
        for ostype, png in chunks
    )
    return b"icns" + struct.pack(">I", len(body) + 8) + body


def main() -> int:
    try:
        import cairosvg  # noqa: F401
    except ImportError:
        print("cairosvg is required: pip install cairosvg", file=sys.stderr)
        return 1

    for path in (ICON_SVG, WORDMARK_SVG):
        if not path.is_file():
            print(f"missing {path}", file=sys.stderr)
            return 1

    rendered: dict[int, bytes] = {}

    def icon_png(pixels: int) -> bytes:
        if pixels not in rendered:
            rendered[pixels] = raster(ICON_SVG, pixels)
        return rendered[pixels]

    ICONSET.mkdir(parents=True, exist_ok=True)
    for name, pixels in ASSET_SIZES.items():
        (ICONSET / name).write_bytes(icon_png(pixels))

    LEGACY_PNG.write_bytes(icon_png(1024))
    LOGO_PNG.parent.mkdir(parents=True, exist_ok=True)
    LOGO_PNG.write_bytes(icon_png(512))
    WORDMARK_PNG.write_bytes(raster(WORDMARK_SVG, 1796, 486))

    ICNS_PATH.write_bytes(icns([(ostype, icon_png(pixels)) for ostype, pixels in ICNS_TYPES]))

    print(f"wrote {ICNS_PATH.relative_to(ROOT)}")
    print(f"wrote {LOGO_PNG.relative_to(ROOT)}")
    print(f"wrote {WORDMARK_PNG.relative_to(ROOT)}")
    print(f"wrote {len(ASSET_SIZES)} asset-catalog icons")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
