#!/usr/bin/env python3
"""Generates sample screenshot images for the BoomPrint screenshot gallery.

Run:  python3 tools/seed_demo_screenshots.py

This creates placeholder PNGs with gradient backgrounds and timestamps so
the gallery UI looks populated. Useful for staging marketing screenshots.

After running, copy the generated PNGs from build/demo_screenshots/ to
screenshots/ for use in the README.
"""

import os
import sys
from pathlib import Path

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    print("Error: Pillow is required. Install with: pip install Pillow")
    sys.exit(1)


DEMO_SCREENS = [
    {
        "name": "screenshot_front_view.png",
        "width": 1920,
        "height": 1080,
        "label": "Front view • 240°C PLA",
        "colors": ["#06b6d4", "#1d4ed8"],  # cyan -> blue
    },
    {
        "name": "screenshot_side_angle.png",
        "width": 1920,
        "height": 1080,
        "label": "Side angle • PETG layer 47/120",
        "colors": ["#f97316", "#c2410c"],  # orange -> deep orange
    },
    {
        "name": "screenshot_top_down.png",
        "width": 1920,
        "height": 1080,
        "label": "Top-down • ABS infill pattern",
        "colors": ["#a855f7", "#7e22ce"],  # purple -> deep purple
    },
    {
        "name": "screenshot_closeup_nozzle.png",
        "width": 1920,
        "height": 1080,
        "label": "Close-up nozzle • TPU flex",
        "colors": ["#22c55e", "#15803d"],  # green -> deep green
    },
    {
        "name": "screenshot_bed_adhesion.png",
        "width": 1920,
        "height": 1080,
        "label": "Bed adhesion test • 60°C",
        "colors": ["#f59e0b", "#b45309"],  # amber -> deep amber
    },
]


def create_gradient_image(
    width: int,
    height: int,
    colors: tuple[str, str],
) -> Image.Image:
    """Create a linear gradient image."""
    color1 = _hex_to_rgb(colors[0])
    color2 = _hex_to_rgb(colors[1])

    img = Image.new("RGB", (width, height))
    pixels = img.load()

    for y in range(height):
        for x in range(width):
            r = int(color1[0] + (color2[0] - color1[0]) * x / width)
            g = int(color1[1] + (color2[1] - color1[1]) * x / width)
            b = int(color1[2] + (color2[2] - color1[2]) * x / width)
            pixels[x, y] = (r, g, b)

    return img


def _hex_to_rgb(hex_color: str) -> tuple[int, int, int]:
    """Convert hex color (#RRGGBB) to RGB tuple."""
    hex_color = hex_color.lstrip("#")
    return (
        int(hex_color[0:2], 16),
        int(hex_color[2:4], 16),
        int(hex_color[4:6], 16),
    )


def render_demo_screenshot(
    img: Image.Image,
    label: str,
    width: int,
    height: int,
) -> Image.Image:
    """Add overlay, label text, and watermark to the screenshot image."""
    draw = ImageDraw.Draw(img)

    # Dark overlay (video-like appearance, 35% opacity)
    overlay = Image.new("RGBA", (width, height), (0, 0, 0, 89))  # 0.35 * 255 ≈ 89
    img = Image.alpha_composite(img.convert("RGBA"), overlay)

    # Try to load a decent font
    font_large = None
    font_small = None
    try:
        font_large = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf", 36)
        font_small = ImageFont.truetype("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf", 18)
    except (OSError, IOError):
        try:
            font_large = ImageFont.load_default(size=36)
            font_small = ImageFont.load_default(size=18)
        except TypeError:
            font_large = ImageFont.load_default()
            font_small = ImageFont.load_default()

    # Center the label text
    bbox = draw.textbbox((0, 0), label, font=font_large)
    text_width = bbox[2] - bbox[0]
    text_height = bbox[3] - bbox[1]
    text_x = (width - text_width) // 2
    text_y = (height - text_height) // 2

    # Draw text shadow
    draw.text(
        (text_x + 2, text_y + 2),
        label,
        fill=(0, 0, 0, 153),  # semi-transparent black shadow
        font=font_large,
    )

    # Draw white text
    draw.text(
        (text_x, text_y),
        label,
        fill=(255, 255, 255, 255),
        font=font_large,
    )

    # Watermark (bottom-right)
    watermark = "BoomPrint • Demo"
    bbox = draw.textbbox((0, 0), watermark, font=font_small)
    wm_width = bbox[2] - bbox[0]
    wm_x = width - wm_width - 16
    wm_y = height - 40
    draw.text(
        (wm_x, wm_y),
        watermark,
        fill=(255, 255, 255, 178),  # 0.7 * 255 ≈ 178
        font=font_small,
    )

    return img


def main():
    repo_root = Path(__file__).resolve().parent.parent
    output_dir = repo_root / "build" / "demo_screenshots"
    output_dir.mkdir(parents=True, exist_ok=True)

    print(f"[Seed] Output directory: {output_dir}")

    for demo in DEMO_SCREENS:
        # Create gradient base
        img = create_gradient_image(
            demo["width"],
            demo["height"],
            demo["colors"],
        )

        # Render overlays
        img = render_demo_screenshot(
            img,
            demo["label"],
            demo["width"],
            demo["height"],
        )

        # Save
        output_path = output_dir / demo["name"]
        img.save(str(output_path), "PNG")
        print(f"[Seed] Created {demo['name']} ({demo['width']}x{demo['height']})")

    print(f"\n[Seed] Done! {len(DEMO_SCREENS)} screenshots in {output_dir}")
    print("[Seed] Copy to screenshots/ for README:")
    print(f"  cp {output_dir}/*.png screenshots/\n")


if __name__ == "__main__":
    main()
