#!/usr/bin/env python3
"""Viu Live TV app icon: block red 'VIU' letters with a Liquid Glass
effect (gradient body, specular top gloss, bevel highlight, soft shadow
and glow) on near-black. Renders at 2x and downscales for clean edges."""
from PIL import Image, ImageDraw, ImageFont, ImageFilter

S = 2                      # supersample factor
W = 1024 * S
FONT = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
OUT = "/home/hatch/workspace/viu-live-tv/ViuLiveTV/Assets.xcassets/AppIcon.appiconset"

# --- background: near-black with a very subtle radial glow, top-centre ---
bg = Image.new("RGB", (W, W), (4, 4, 6))
glow = Image.new("L", (W, W), 0)
gd = ImageDraw.Draw(glow)
gd.ellipse([-W * 0.35, -W * 0.75, W * 1.35, W * 0.55], fill=42)
glow = glow.filter(ImageFilter.GaussianBlur(W // 6))
bg = Image.composite(Image.new("RGB", (W, W), (26, 8, 10)), bg, glow)

# --- text mask, fitted to ~80% width ---
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

# --- red glow behind the letters ---
glow_layer = Image.new("RGBA", (W, W), (0, 0, 0, 0))
glow_layer.paste(Image.new("RGBA", (W, W), (255, 30, 20, 90)), (0, 0), mask)
img.alpha_composite(glow_layer.filter(ImageFilter.GaussianBlur(W // 18)))

# --- soft drop shadow ---
shadow = Image.new("RGBA", (W, W), (0, 0, 0, 0))
shadow.paste(Image.new("RGBA", (W, W), (0, 0, 0, 150)), (0, int(W * 0.012)), mask)
img.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(W // 90)))

# --- letter body: vertical red gradient (bright top -> deep bottom) ---
grad = Image.new("RGB", (1, W))
for row in range(W):
    t = row / W
    top = (255, 64, 52)        # vivid red
    mid = (214, 18, 23)        # brand red
    bot = (122, 6, 12)         # deep red
    if t < 0.5:
        k = t / 0.5
        c = tuple(int(top[i] + (mid[i] - top[i]) * k) for i in range(3))
    else:
        k = (t - 0.5) / 0.5
        c = tuple(int(mid[i] + (bot[i] - mid[i]) * k) for i in range(3))
    grad.putpixel((0, row), c)
img.paste(grad.resize((W, W)), (0, 0), mask)

# --- Liquid Glass specular: white gloss over the top half, fading out ---
gloss = Image.new("L", (1, W), 0)
for row in range(W):
    t = row / (W * 0.52)
    gloss.putpixel((0, row), max(0, int(150 * (1 - t))) if t < 1 else 0)
gloss_img = Image.new("RGBA", (W, W), (255, 255, 255, 255))
img.paste(gloss_img, (0, 0), Image.composite(gloss.resize((W, W)), Image.new("L", (W, W), 0), mask))

# --- bevel: bright top edge (mask minus mask shifted down) ---
shifted = Image.new("L", (W, W), 0)
shifted.paste(mask, (0, max(2, W // 340)))
edge = Image.new("L", (W, W), 0)
edge = Image.frombytes("L", (W, W), bytes(
    max(0, a - b) for a, b in zip(mask.tobytes(), shifted.tobytes())))
img.paste(Image.new("RGBA", (W, W), (255, 210, 200, 255)), (0, 0),
          edge.point(lambda v: int(v * 0.85)))

# --- faint floor reflection ---
refl = img.crop((0, 0, W, W)).transpose(Image.FLIP_TOP_BOTTOM)
fade = Image.new("L", (1, W), 0)
for row in range(W):
    fade.putpixel((0, row), max(0, int(46 * (1 - row / (W * 0.35)))) if row < W * 0.35 else 0)
img.paste(Image.new("RGBA", (W, W), (200, 20, 20, 255)), (0, 0),
          Image.composite(fade.resize((W, W)), Image.new("L", (W, W), 0), mask))

final = img.convert("RGB").resize((1024, 1024), Image.LANCZOS)
final.save(f"{OUT}/AppIcon1024.png")
final.save(f"{OUT}/AppIcon1024-Dark.png")
final.convert("L").convert("RGB").save(f"{OUT}/AppIcon1024-Tinted.png")
print("icon written")
