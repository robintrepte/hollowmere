#!/usr/bin/env python3
"""Builds derived item icons (seeds, saplings, juice, jam, frozen) by compositing base art.

Usage: derive_icons.py [--root .]
Reads game/data/crops.json + trees.json, writes into game/assets/items/.
"""
import argparse
import json
import os

from PIL import Image


def mini(img, size):
    """Shrinks a 16px icon to `size` px keeping hard alpha."""
    small = img.resize((size, size), Image.BOX)
    px = small.load()
    for y in range(size):
        for x in range(size):
            r, g, b, a = px[x, y]
            px[x, y] = (r, g, b, 255) if a > 110 else (0, 0, 0, 0)
    return outline(small)


def outline(img, color=(34, 24, 30, 255)):
    w, h = img.size
    out = Image.new("RGBA", (w + 2, h + 2), (0, 0, 0, 0))
    src = img.load()
    dst = out.load()
    for y in range(h):
        for x in range(w):
            if src[x, y][3]:
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        if dst[x + 1 + dx, y + 1 + dy][3] == 0:
                            dst[x + 1 + dx, y + 1 + dy] = color
    for y in range(h):
        for x in range(w):
            if src[x, y][3]:
                dst[x + 1, y + 1] = src[x, y]
    return out


def tint(img, hex_color, amount=0.55):
    c = tuple(int(hex_color.lstrip("#")[i:i + 2], 16) for i in (0, 2, 4))
    out = img.copy()
    px = out.load()
    w, h = out.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if not a:
                continue
            lum = (r * 0.3 + g * 0.59 + b * 0.11) / 255
            if max(r, g, b) - min(r, g, b) < 40 and lum > 0.82:
                continue
            px[x, y] = (
                int(r * (1 - amount) + c[0] * lum * amount * 1.25),
                int(g * (1 - amount) + c[1] * lum * amount * 1.25),
                int(b * (1 - amount) + c[2] * lum * amount * 1.25),
                a,
            )
    return out


def frosty(img):
    out = img.copy()
    px = out.load()
    w, h = out.size
    for y in range(h):
        for x in range(w):
            r, g, b, a = px[x, y]
            if a:
                px[x, y] = (int(r * 0.55 + 90), int(g * 0.6 + 100), min(255, int(b * 0.5 + 140)), a)
    for x, y in ((2, 2), (12, 3), (4, 12), (13, 11)):
        if px[x, y][3] == 0:
            px[x, y] = (230, 248, 255, 255)
    return out


def overlay(base, badge, corner="br"):
    out = base.copy()
    bw, bh = badge.size
    pos = {"br": (16 - bw, 16 - bh), "tr": (16 - bw, 0), "c": ((16 - bw) // 2, (16 - bh) // 2 + 2)}[corner]
    out.alpha_composite(badge, pos)
    return out


def table(path):
    d = json.load(open(path))
    if "columns" in d:
        cols = d["columns"]
        return {r[0]: dict(zip(cols, r)) for r in d["rows"]}
    return d


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    args = ap.parse_args()
    items = os.path.join(args.root, "game/assets/items")
    load = lambda n: Image.open(os.path.join(items, n + ".png")).convert("RGBA")
    packet, sapling, juice, jam = load("_seed_packet"), load("_sapling"), load("_juice"), load("_jam")
    crops = table(os.path.join(args.root, "game/data/crops.json"))
    trees = table(os.path.join(args.root, "game/data/trees.json"))
    made = 0
    for cid, c in list(crops.items()) + list(trees.items()):
        path = os.path.join(items, cid + ".png")
        if not os.path.exists(path):
            print("missing base icon", cid)
            continue
        icon = load(cid)
        badge = mini(icon, 8)
        color = c.get("color", "#ffffff")
        if cid in crops:
            overlay(tint(packet, color, 0.35), badge, "c").save(os.path.join(items, cid + "_seeds.png"))
        else:
            overlay(sapling, mini(icon, 6), "tr").save(os.path.join(items, cid + "_sapling.png"))
        overlay(tint(juice, color), badge).save(os.path.join(items, "juice__" + cid + ".png"))
        overlay(tint(jam, color), badge).save(os.path.join(items, "jam__" + cid + ".png"))
        frosty(icon).save(os.path.join(items, "preserved__" + cid + ".png"))
        made += 1
    egg = os.path.join(args.root, "game/assets/creatures/small/egg.png")
    if os.path.exists(egg):
        e = Image.open(egg).convert("RGBA")
        bbox = e.getbbox()
        e = e.crop(bbox)
        s = 15 / max(e.size)
        e = e.resize((max(1, round(e.size[0] * s)), max(1, round(e.size[1] * s))), Image.NEAREST)
        out = Image.new("RGBA", (16, 16), (0, 0, 0, 0))
        out.alpha_composite(e, ((16 - e.size[0]) // 2, 16 - e.size[1]))
        out.save(os.path.join(items, "wildling_egg.png"))
    # The purple label of the VIP record keys out against magenta, so it is the gold record relabeled.
    gold = os.path.join(items, "record_casino.png")
    if os.path.exists(gold):
        rec = load("record_casino")
        px = rec.load()
        for y in range(rec.size[1]):
            for x in range(rec.size[0]):
                r, g, b, a = px[x, y]
                if a and r > 90 and r - b > 40:
                    lum = (r * 0.3 + g * 0.59 + b * 0.11) / 255
                    px[x, y] = (int(150 * lum + 40), int(70 * lum + 20), int(210 * lum + 40), a)
        rec.save(os.path.join(items, "record_vip.png"))
    print("derived icons for", made, "crops/trees")


if __name__ == "__main__":
    main()
