#!/usr/bin/env python3
"""Renders MiliShip's app icon into MiliShip/Assets.xcassets/AppIcon.appiconset.

Requires Pillow:  pip3 install pillow
Usage:            python3 scripts/generate_icon.py
"""
import json
import os
from PIL import Image, ImageDraw, ImageFilter

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, "MiliShip", "Assets.xcassets", "AppIcon.appiconset")
SS = 4            # supersampling for smooth edges
S = 1024 * SS


def lerp(a, b, t):
    return tuple(int(a[i] + (b[i] - a[i]) * t) for i in range(len(a)))


def gradient(size, top_left, bottom_right):
    """Diagonal gradient, rendered small and scaled up (fast and smooth)."""
    small = 256
    img = Image.new("RGBA", (small, small))
    px = img.load()
    for y in range(small):
        for x in range(small):
            t = (x + y) / (2 * (small - 1))
            px[x, y] = lerp(top_left, bottom_right, t) + (255,)
    return img.resize((size, size), Image.BICUBIC)


def p(x, y):
    return (x * SS, y * SS)


def render():
    canvas = Image.new("RGBA", (S, S), (0, 0, 0, 0))

    # macOS icon grid: 824pt tile centred in the 1024 canvas.
    inset, radius = 100, 185
    tile_box = [inset * SS, inset * SS, (1024 - inset) * SS, (1024 - inset) * SS]

    # Drop shadow under the tile
    shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rounded_rectangle(
        [tile_box[0], tile_box[1] + 14 * SS, tile_box[2], tile_box[3] + 14 * SS],
        radius=radius * SS, fill=(0, 0, 0, 90))
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(18 * SS)))

    # Tile: cyan → indigo gradient with a soft top highlight
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).rounded_rectangle(tile_box, radius=radius * SS, fill=255)
    tile = gradient(S, (34, 211, 238), (79, 70, 229))
    # Soft top-down sheen
    sheen = Image.new("L", (1, 256))
    for y in range(256):
        sheen.putpixel((0, y), int(max(0, 1 - y / 150) * 46))
    sheen = sheen.resize((S, S), Image.BICUBIC)
    white = Image.new("RGBA", (S, S), (255, 255, 255, 0))
    white.putalpha(sheen)
    tile.alpha_composite(white)
    canvas.paste(tile, (0, 0), mask)

    art = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    d = ImageDraw.Draw(art)

    # Soft shadow under the package
    glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(glow).ellipse(p(318, 800) + p(706, 880), fill=(18, 16, 80, 110))
    art.alpha_composite(glow.filter(ImageFilter.GaussianBlur(22 * SS)))

    # Isometric package
    top, right, bottom, left = (512, 452), (716, 566), (512, 680), (308, 566)
    depth = 206
    d.polygon([p(*top), p(*right), p(*bottom), p(*left)], fill=(255, 255, 255, 255))
    d.polygon([p(*left), p(*bottom), p(bottom[0], bottom[1] + depth), p(left[0], left[1] + depth)],
              fill=(226, 232, 255, 255))
    d.polygon([p(*bottom), p(*right), p(right[0], right[1] + depth), p(bottom[0], bottom[1] + depth)],
              fill=(190, 200, 250, 255))

    # Packing tape across the lid and down the front edge
    tape = (99, 102, 241, 255)
    w = 34
    k = 114 / 204  # isometric slope
    d.polygon([p(410 - w, 509 + w * k), p(410 + w, 509 - w * k),
               p(614 + w, 623 - w * k), p(614 - w, 623 + w * k)], fill=tape)
    d.polygon([p(614 - w, 623 + w * k), p(614 + w, 623 - w * k),
               p(614 + w, 623 - w * k + depth), p(614 - w, 623 + w * k + depth)], fill=(79, 70, 229, 255))

    # Upward "ship it" arrow
    d.polygon([p(512, 178), p(596, 286), p(546, 286), p(546, 404), p(478, 404), p(478, 286), p(428, 286)],
              fill=(255, 255, 255, 255))
    # Motion ticks either side of the arrow
    for x in (380, 644):
        d.rounded_rectangle(p(x - 14, 300) + p(x + 14, 392), radius=14 * SS, fill=(255, 255, 255, 150))

    canvas.alpha_composite(art)
    return canvas.resize((1024, 1024), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    master = render()
    images = []
    for points in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = points * scale
            name = f"icon_{points}x{points}{'@2x' if scale == 2 else ''}.png"
            master.resize((pixels, pixels), Image.LANCZOS).save(os.path.join(OUT, name))
            images.append({"idiom": "mac", "scale": f"{scale}x", "size": f"{points}x{points}", "filename": name})
    with open(os.path.join(OUT, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}}, f, indent=2)
    docs = os.path.join(ROOT, "docs", "images")
    os.makedirs(docs, exist_ok=True)
    master.resize((256, 256), Image.LANCZOS).save(os.path.join(docs, "icon.png"))
    print("Wrote", OUT)


if __name__ == "__main__":
    main()
