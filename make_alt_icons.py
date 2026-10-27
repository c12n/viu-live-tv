#!/usr/bin/env python3
"""Alternate app icons for Viu Live TV: the same Liquid Glass 'VIU'
letters as the primary (red) icon, rendered in each accent color.
One .appiconset per color; the app switches icons when the user picks
an accent color in Settings."""
import json
import os

from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 2
W = 1024 * S
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
BASE_DIR = "/home/hatch/workspace/viu-live-tv/ViuLiveTV/Assets.xcassets"

# Accent name -> gradient mid (brand) color.
COLORS = {
    "Blue":   (10, 100, 255),
    "Purple": (142, 78, 198),
    "Pink":   (244, 63, 94),
    "Orange": (255, 149, 0),
    "Green":  (23, 163, 74),
    "Teal":   (18, 165, 180),
}


def lighten(c, f):
    return tuple(int(v + (255 - v) * f) for v in c)


def darken(c, f):
    return tuple(int(v * (1 - f)) for v in c)


def render(base):
    top = lighten(base, 0.30)
    mid = base
    bot = darken(base, 0.45)

    bg = Image.new("RGB", (W, W), (4, 4, 6))
    glow = Image.new("L", (W, W), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([-W * 0.35, -W * 0.75, W * 1.35, W * 0.55], fill=42)
    glow = glow.filter(ImageFilter.GaussianBlur(W // 6))
    tint_bg = tuple(min(28, int(v * 0.12) + 6) for v in base)
    bg = Image.composite(Image.new("RGB", (W, W), tint_bg), bg, glow)

    font = ImageFont.truetype(FONT, 100)
    tmp = ImageDraw.Draw(Image.new("L", (10, 10)))
    bbox = tmp.textbbox((0, 0), "VIU", font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    scale = (W * 0.80) / tw
    font = ImageFont.truetype(FONT, int(100 * scale))
    bbox = tmp.textbbox((0, 0), "VIU", font=font)
    tw, th = bbox[2] - bbox[0], bbox[3] - bbox[1]
    x = (W - tw) // 2 - bbox[0]
    y = (W - th) // 2 - bbox[1] - int(W * 0.01)

    mask = Image.new("L", (W, W), 0)
    ImageDraw.Draw(mask).text((x, y), "VIU", font=font, fill=255)

    img = bg.convert("RGBA")

    glow_layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    glow_layer.paste(Image.new("RGBA", (W, W), base + (90,)), (0, 0), mask)
    img.alpha_composite(glow_layer.filter(ImageFilter.GaussianBlur(W // 18)))

    shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
    shadow.paste(Image.new("RGBA", (W, W), (0, 0, 0, 150)), (0, int(W * 0.012)), mask)
    img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(W // 90)))

    grad = Image.new("RGB", (1, W))
    for row in range(W):
        t = row / W
        if t < 0.5:
            k = t / 0.5
            c = tuple(int(top[i] + (mid[i] - top[i]) * k) for i in range(3))
        else:
            k = (t - 0.5) / 0.5
            c = tuple(int(mid[i] + (bot[i] - mid[i]) * k) for i in range(3))
        grad.putpixel((0, row), c)
    img.paste(grad.resize((W, W)), (0, 0), mask)

    gloss = Image.new("L", (1, W), 0)
    for row in range(W):
        t = row / (W * 0.52)
        gloss.putpixel((0, row), max(0, int(150 * (1 - t))) if t < 1 else 0)
    gloss_img = Image.new("RGBA", (W, W), (255, 255, 255, 255))
    img.paste(gloss_img, (0, 0), Image.composite(gloss.resize((W, W)), Image.new("L", (W, W), 0), mask))

    shifted = Image.new("L", (W, W), 0)
    shifted.paste(mask, (0, max(2, W // 340)))
    edge = Image.frombytes("L", (W, W), bytes(
        max(0, a - b) for a, b in zip(mask.tobytes(), shifted.tobytes())))
    img.paste(Image.new("RGBA", (W, W), lighten(base, 0.75) + (255,)), (0, 0),
              edge.point(lambda v: int(v * 0.85)))

    fade = Image.new("L", (1, W), 0)
    for row in range(W):
        fade.putpixel((0, row), max(0, int(46 * (1 - row / (W * 0.35)))) if row < W * 0.35 else 0)
    img.paste(Image.new("RGBA", (W, W), darken(base, 0.2) + (255,)), (0, 0),
              Image.composite(fade.resize((W, W)), Image.new("L", (W, W), 0), mask))

    return img.convert("RGB").resize((1024, 1024), Image.LANCZOS)


CONTENTS = {
    "images": [
        {"filename": "AppIcon1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "dark"}],
         "filename": "AppIcon1024-Dark.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
        {"appearances": [{"appearance": "luminosity", "value": "tinted"}],
         "filename": "AppIcon1024-Tinted.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"},
    ],
    "info": {"author": "xcode", "version": 1},
}

for name, base in COLORS.items():
    out = os.path.join(BASE_DIR, f"AppIcon{name}.appiconset")
    os.makedirs(out, exist_ok=True)
    final = render(base)
    final.save(f"{out}/AppIcon1024.png")
    final.save(f"{out}/AppIcon1024-Dark.png")
    final.convert("L").convert("RGB").save(f"{out}/AppIcon1024-Tinted.png")
    with open(f"{out}/Contents.json", "w") as f:
        json.dump(CONTENTS, f)
    print(f"{name}: written")
print("done")
