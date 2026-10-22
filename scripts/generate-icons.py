#!/usr/bin/env python3
"""Render the Plume app icon (asset catalog PNGs + AppIcon.icns).

Requires Pillow: pip install pillow
Usage: python3 scripts/generate-icons.py
"""
import json
import math
from pathlib import Path

from PIL import Image, ImageChops, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
RES = ROOT / "Plume" / "Plume" / "Resources"
ICONSET = RES / "Assets.xcassets" / "AppIcon.appiconset"
S = 1024  # master canvas
SS = 2    # supersampling


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(3))


def gradient(size, stops):
    """Diagonal (top-left -> bottom-right) multi-stop gradient."""
    img = Image.new("RGB", (size, size))
    px = img.load()
    for y in range(size):
        for x in range(size):
            t = (x + y) / (2 * (size - 1))
            for i in range(len(stops) - 1):
                t0, c0 = stops[i]
                t1, c1 = stops[i + 1]
                if t <= t1:
                    px[x, y] = lerp(c0, c1, (t - t0) / (t1 - t0))
                    break
    return img


def render_master():
    n = S * SS
    # macOS icon grid: 824px squircle inside a 1024 canvas
    inset = int(100 * SS)
    box = (inset, inset, n - inset, n - inset)
    radius = int(185 * SS)

    mask = Image.new("L", (n, n), 0)
    ImageDraw.Draw(mask).rounded_rectangle(box, radius=radius, fill=255)

    bg = gradient(n // 8, [(0, (99, 102, 241)), (0.55, (139, 92, 246)), (1, (20, 184, 166))])
    bg = bg.resize((n, n), Image.BICUBIC).convert("RGBA")

    # soft top highlight
    hl = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(hl).ellipse((-n * 0.1, -n * 0.55, n * 1.1, n * 0.45), fill=(255, 255, 255, 46))
    bg = Image.alpha_composite(bg, hl.filter(ImageFilter.GaussianBlur(60 * SS)))

    canvas = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    # drop shadow
    shadow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        (box[0], box[1] + 14 * SS, box[2], box[3] + 14 * SS), radius=radius, fill=(10, 10, 40, 110))
    canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(22 * SS)))
    canvas.paste(bg, (0, 0), mask)

    # Waveform bars whose heights trace a feather (plume) silhouette: slim at the
    # quill end, swelling then tapering to a tip, with a diagonal sweep.
    glyph = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    d = ImageDraw.Draw(glyph)
    heights = [0.20, 0.36, 0.56, 0.78, 1.00, 0.74, 0.46, 0.24]
    count = len(heights)
    bar_w = 52 * SS
    gap = 30 * SS
    total = count * bar_w + (count - 1) * gap
    x0 = (n - total) / 2
    max_h = 470 * SS
    cy = n / 2
    for i, h in enumerate(heights):
        bh = max_h * h
        x = x0 + i * (bar_w + gap)
        tilt = (i - (count - 1) / 2) * -14 * SS  # sweep like a feather
        d.rounded_rectangle((x, cy - bh / 2 + tilt, x + bar_w, cy + bh / 2 + tilt),
                            radius=bar_w / 2, fill=(255, 255, 255, 255))
    # glyph glow + shadow
    glow = glyph.filter(ImageFilter.GaussianBlur(26 * SS))
    glow = Image.merge("RGBA", (*glow.split()[:3], glow.split()[3].point(lambda a: int(a * 0.35))))
    gshadow = Image.new("RGBA", (n, n), (0, 0, 0, 0))
    gshadow.paste((30, 20, 90, 90), (0, 10 * SS), glyph.split()[3])
    gshadow = gshadow.filter(ImageFilter.GaussianBlur(14 * SS))
    for layer in (gshadow, glow, glyph):
        clipped = Image.new("RGBA", (n, n), (0, 0, 0, 0))
        clipped.paste(layer, (0, 0), ImageChops.multiply(mask, layer.split()[3]) if layer is glyph else mask)
        canvas = Image.alpha_composite(canvas, clipped)
    return canvas.resize((S, S), Image.LANCZOS)


def main():
    master = render_master()
    ICONSET.mkdir(parents=True, exist_ok=True)
    images = []
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            name = f"icon_{size}x{size}{'@2x' if scale == 2 else ''}.png"
            master.resize((px, px), Image.LANCZOS).save(ICONSET / name)
            images.append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{size}x{size}"})
    (ICONSET / "Contents.json").write_text(
        json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n")
    master.save(RES / "AppIcon.icns", sizes=[(s, s) for s in (16, 32, 64, 128, 256, 512, 1024)])
    master.save(ROOT / "docs" / "icon.png") if (ROOT / "docs").exists() else None
    print("Wrote", ICONSET, "and", RES / "AppIcon.icns")


if __name__ == "__main__":
    main()
