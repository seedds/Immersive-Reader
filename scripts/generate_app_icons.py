#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path

from PIL import Image, ImageOps


ICON_SPECS = [
    ("AppIcon-iOS-1024.png", 1024, "base"),
    ("AppIcon-iOS-1024-dark.png", 1024, "dark"),
    ("AppIcon-iOS-1024-tinted.png", 1024, "tinted"),
    ("AppIcon-mac-16.png", 16, "base"),
    ("AppIcon-mac-16@2x.png", 32, "base"),
    ("AppIcon-mac-32.png", 32, "base"),
    ("AppIcon-mac-32@2x.png", 64, "base"),
    ("AppIcon-mac-128.png", 128, "base"),
    ("AppIcon-mac-128@2x.png", 256, "base"),
    ("AppIcon-mac-256.png", 256, "base"),
    ("AppIcon-mac-256@2x.png", 512, "base"),
    ("AppIcon-mac-512.png", 512, "base"),
    ("AppIcon-mac-512@2x.png", 1024, "base"),
]

CONTENTS_JSON = {
    "images": [
        {"filename": "AppIcon-iOS-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {
            "appearances": [{"appearance": "luminosity", "value": "dark"}],
            "filename": "AppIcon-iOS-1024-dark.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        },
        {
            "appearances": [{"appearance": "luminosity", "value": "tinted"}],
            "filename": "AppIcon-iOS-1024-tinted.png",
            "idiom": "universal",
            "platform": "ios",
            "size": "1024x1024",
        },
        {"filename": "AppIcon-mac-16.png", "idiom": "mac", "scale": "1x", "size": "16x16"},
        {"filename": "AppIcon-mac-16@2x.png", "idiom": "mac", "scale": "2x", "size": "16x16"},
        {"filename": "AppIcon-mac-32.png", "idiom": "mac", "scale": "1x", "size": "32x32"},
        {"filename": "AppIcon-mac-32@2x.png", "idiom": "mac", "scale": "2x", "size": "32x32"},
        {"filename": "AppIcon-mac-128.png", "idiom": "mac", "scale": "1x", "size": "128x128"},
        {"filename": "AppIcon-mac-128@2x.png", "idiom": "mac", "scale": "2x", "size": "128x128"},
        {"filename": "AppIcon-mac-256.png", "idiom": "mac", "scale": "1x", "size": "256x256"},
        {"filename": "AppIcon-mac-256@2x.png", "idiom": "mac", "scale": "2x", "size": "256x256"},
        {"filename": "AppIcon-mac-512.png", "idiom": "mac", "scale": "1x", "size": "512x512"},
        {"filename": "AppIcon-mac-512@2x.png", "idiom": "mac", "scale": "2x", "size": "512x512"},
    ],
    "info": {"author": "xcode", "version": 1},
}

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = REPO_ROOT / "Immersive Reader/Assets.xcassets/AppIcon.appiconset"

try:
    RESAMPLE = Image.Resampling.LANCZOS
except AttributeError:
    RESAMPLE = Image.LANCZOS


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Generate the Xcode AppIcon.appiconset PNGs from a source image."
    )
    parser.add_argument("source", type=Path, help="Base source image file.")
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help=f"Output appiconset directory. Defaults to {DEFAULT_OUTPUT}",
    )
    parser.add_argument(
        "--dark-source",
        type=Path,
        help="Optional dedicated source image for AppIcon-iOS-1024-dark.png.",
    )
    parser.add_argument(
        "--tinted-source",
        type=Path,
        help="Optional dedicated source image for AppIcon-iOS-1024-tinted.png.",
    )
    parser.add_argument(
        "--skip-contents-json",
        action="store_true",
        help="Do not write Contents.json.",
    )
    return parser.parse_args()


def load_square_png(image_path: Path, size: int) -> Image.Image:
    with Image.open(image_path) as image:
        image = ImageOps.exif_transpose(image).convert("RGBA")
        return ImageOps.fit(image, (size, size), method=RESAMPLE, centering=(0.5, 0.5))


def resolve_source(kind: str, base: Path, dark: Path | None, tinted: Path | None) -> Path:
    if kind == "dark" and dark is not None:
        return dark
    if kind == "tinted" and tinted is not None:
        return tinted
    return base


def write_contents_json(output_dir: Path) -> None:
    contents_path = output_dir / "Contents.json"
    contents_path.write_text(json.dumps(CONTENTS_JSON, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    args = parse_args()

    for source_path in [args.source, args.dark_source, args.tinted_source]:
        if source_path is not None and not source_path.is_file():
            raise FileNotFoundError(f"Source image not found: {source_path}")

    args.output.mkdir(parents=True, exist_ok=True)

    for filename, size, kind in ICON_SPECS:
        source_path = resolve_source(kind, args.source, args.dark_source, args.tinted_source)
        image = load_square_png(source_path, size)
        image.save(args.output / filename, format="PNG", optimize=True)

    if not args.skip_contents_json:
        write_contents_json(args.output)

    print(f"Generated {len(ICON_SPECS)} icons in {args.output}")


if __name__ == "__main__":
    main()
