#!/usr/bin/env python3
"""Fallback art so the game never ships a missing texture.

For every creature / item / villager / building referenced by game/data without a sprite,
writes a simple readable placeholder (type-colored blob, category-colored gem, initials-free bust).
  placeholder.py [--missing-only] [--root .]
"""
import argparse
import json
import os

from PIL import Image, ImageDraw

OUTLINE = (34, 24, 30, 255)
CAT_COLORS = {
    "crop": (120, 190, 90), "seed": (200, 160, 90), "fruit": (230, 110, 90), "tool": (150, 150, 170),
    "material": (160, 120, 80), "ore": (140, 140, 150), "bar": (220, 190, 90), "gem": (120, 200, 230),
    "food": (240, 170, 90), "treat": (240, 140, 170), "charm": (170, 120, 230), "medicine": (230, 90, 110),
    "artisan": (210, 130, 200), "placeable": (170, 130, 90), "key": (250, 220, 90), "gift": (250, 150, 190),
}


def table(path):
    d = json.load(open(path))
    if isinstance(d, dict) and "columns" in d:
        return {r[0]: dict(zip(d["columns"], r)) for r in d["rows"]}
    if isinstance(d, list):
        return {x["id"]: x for x in d}
    return d


def hexc(h, default=(200, 200, 200)):
    try:
        h = h.lstrip("#")
        return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))
    except Exception:
        return default


def blob(size, color):
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    m = size // 8
    d.ellipse((m, m * 2, size - m, size - 1), fill=color + (255,), outline=OUTLINE)
    e = size // 10
    for ex in (size // 2 - size // 6, size // 2 + size // 6 - e):
        d.rectangle((ex, size // 2, ex + e, size // 2 + e), fill=OUTLINE)
    return im


def gem(size, color):
    im = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((1, 1, size - 2, size - 2), radius=size // 4, fill=color + (255,), outline=OUTLINE)
    d.rectangle((3, 3, size // 2 - 1, 4), fill=(255, 255, 255, 160))
    return im


def save(path, im, missing_only):
    if missing_only and os.path.exists(path):
        return 0
    os.makedirs(os.path.dirname(path), exist_ok=True)
    im.save(path)
    return 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    ap.add_argument("--missing-only", action="store_true")
    a = ap.parse_args()
    g = os.path.join(a.root, "game")
    made = 0
    types = table(os.path.join(g, "data/types.json"))
    for sid, sp in table(os.path.join(g, "data/creatures.json")).items():
        t = sp.get("types", sp.get("type", ["normal"]))
        t = t[0] if isinstance(t, list) else str(t).split("/")[0]
        col = hexc(types.get(t, {}).get("color", "#c8c8c8")) if isinstance(types.get(t), dict) else (200, 200, 200)
        made += save(os.path.join(g, f"assets/creatures/{sid}.png"), blob(64, col), a.missing_only)
        made += save(os.path.join(g, f"assets/creatures/small/{sid}.png"), blob(32, col), a.missing_only)
    for iid, it in table(os.path.join(g, "data/items.json")).items():
        col = hexc(it.get("color", ""), CAT_COLORS.get(it.get("cat", ""), (200, 200, 200)))
        made += save(os.path.join(g, f"assets/items/{iid}.png"), gem(16, col), a.missing_only)
    for vid, v in table(os.path.join(g, "data/villagers.json")).items():
        look = v.get("look", {})
        im = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
        d = ImageDraw.Draw(im)
        d.rectangle((14, 44, 50, 63), fill=hexc(look.get("shirt", "#8080a0")) + (255,), outline=OUTLINE)
        d.ellipse((18, 12, 46, 46), fill=hexc(look.get("skin", "#e0b090")) + (255,), outline=OUTLINE)
        d.chord((16, 8, 48, 36), 180, 360, fill=hexc(look.get("hair", "#503020")) + (255,), outline=OUTLINE)
        made += save(os.path.join(g, f"assets/portraits/{vid}.png"), im, a.missing_only)
    print("placeholders written:", made)


if __name__ == "__main__":
    main()
