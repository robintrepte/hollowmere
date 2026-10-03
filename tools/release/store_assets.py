#!/usr/bin/env python3
"""Builds the Steam and itch.io store images from the raw key art and logo.

  .venv/bin/python tools/release/store_assets.py [--out store]

Inputs (tools/art_pipeline/raw/): store/key_wide_a.png (16:9), store/key_tall_a.png (2:3), ui/logo.png.
Each capsule is rendered at 1/k of its size and nearest-upscaled by k, so it keeps the
game's chunky pixel grid instead of looking like a smooth illustration.
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image, ImageDraw

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
sys.path.insert(0, os.path.join(ROOT, "tools", "art_pipeline"))
import process  # noqa: E402

RAW = os.path.join(ROOT, "tools", "art_pipeline", "raw")


def crop_to(im, w, h, fx=0.5, fy=0.5):
    """Crops im to the aspect w:h; fx/fy pick which part survives (0 = left/top, 1 = right/bottom)."""
    sw, sh = im.size
    if sw / sh > w / h:
        nw = round(sh * w / h)
        x = round((sw - nw) * fx)
        return im.crop((x, 0, x + nw, sh))
    nh = round(sw * h / w)
    y = round((sh - nh) * fy)
    return im.crop((0, y, sw, y + nh))


def pixel_art(im, w, h, k, fx=0.5, fy=0.5):
    base = crop_to(im, w, h, fx, fy).resize((w // k, h // k), Image.BOX)
    return base.convert("RGBA")


class Logo:
    def __init__(self):
        a = process.load_rgba(os.path.join(RAW, "ui", "logo.png"))
        self.a, self.bg = a, process.bg_mask(a, "magenta")
        ys, xs = np.where(~self.bg)
        self.w, self.h = xs.max() - xs.min() + 1, ys.max() - ys.min() + 1

    def at(self, w):
        """Pixel logo w base pixels wide (same treatment as the in-game logo)."""
        s = w / self.w
        h = int(round(self.h * s)) + 2
        return process.sprite_from_region(self.a, self.bg, (w, h), s, anchor="center", colors=24, pad=0, fit=True)


def shade(base, top, bottom, alpha):
    """Darkens a horizontal band so the logo reads on busy art."""
    ov = Image.new("RGBA", base.size, (0, 0, 0, 0))
    d = ImageDraw.Draw(ov)
    h = bottom - top
    for i in range(h):
        t = 1 - abs((i - h / 2) / (h / 2))
        d.line([(0, top + i), (base.width, top + i)], fill=(34, 24, 30, int(alpha * t)))
    return Image.alpha_composite(base, ov)


def capsule(art, logo, w, h, k, logo_frac, logo_pos, fx=0.5, fy=0.5, band=0):
    base = pixel_art(art, w, h, k, fx, fy)
    bw, bh = base.size
    if logo is not None:
        lg = logo.at(int(bw * logo_frac))
        lx = int(bw * logo_pos[0] - lg.width / 2)
        ly = int(bh * logo_pos[1] - lg.height / 2)
        if band:
            base = shade(base, max(0, ly - band), min(bh, ly + lg.height + band), 110)
        base.alpha_composite(lg, (max(0, lx), max(0, ly)))
    return base.resize((bw * k, bh * k), Image.NEAREST).convert("RGB")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(ROOT, "store"))
    a = ap.parse_args()
    wide = Image.open(os.path.join(RAW, "store", "key_wide_a.png")).convert("RGB")
    tall = Image.open(os.path.join(RAW, "store", "key_tall_a.png")).convert("RGB")
    logo = Logo()
    steam, itch = os.path.join(a.out, "steam"), os.path.join(a.out, "itch")
    os.makedirs(steam, exist_ok=True)
    os.makedirs(itch, exist_ok=True)

    out = {
        # Steam store
        (steam, "header_capsule_920x430.png"): capsule(wide, logo, 920, 430, 2, 0.5, (0.3, 0.24), fy=0.35),
        (steam, "small_capsule_462x174.png"): capsule(wide, logo, 462, 174, 2, 0.82, (0.5, 0.5), fy=0.55, band=10),
        (steam, "main_capsule_1232x706.png"): capsule(wide, logo, 1232, 706, 2, 0.46, (0.29, 0.2)),
        (steam, "vertical_capsule_748x896.png"): capsule(tall, logo, 748, 896, 2, 0.86, (0.5, 0.15), fy=0.3),
        # Steam library
        (steam, "library_capsule_600x900.png"): capsule(tall, logo, 600, 900, 2, 0.86, (0.5, 0.16)),
        (steam, "library_header_920x430.png"): capsule(wide, logo, 920, 430, 2, 0.5, (0.3, 0.24), fy=0.35),
        (steam, "library_hero_3840x1240.png"): capsule(wide, None, 3840, 1240, 4, 0, (0, 0), fy=0.62),
        # itch.io
        (itch, "cover_630x500.png"): capsule(wide, logo, 630, 500, 2, 0.7, (0.5, 0.17), fx=0.55),
        (itch, "banner_960x300.png"): capsule(wide, logo, 960, 300, 2, 0.42, (0.27, 0.3), fy=0.3),
    }
    for (d, name), im in out.items():
        im.save(os.path.join(d, name), optimize=True)
        print("wrote", os.path.relpath(os.path.join(d, name), ROOT), im.size)

    # Library logo: transparent, at most 1280x720.
    lg = logo.at(640)
    lg = lg.resize((lg.width * 2, lg.height * 2), Image.NEAREST)
    lg.save(os.path.join(steam, "library_logo_1280.png"), optimize=True)
    print("wrote store/steam/library_logo_1280.png", lg.size)

    icon = Image.open(os.path.join(ROOT, "game", "assets", "icon_512.png")).convert("RGBA")
    icon.resize((184, 184), Image.LANCZOS).save(os.path.join(steam, "community_icon_184.png"))
    icon.resize((32, 32), Image.LANCZOS).save(os.path.join(steam, "client_icon_32.png"))
    print("wrote store/steam/community_icon_184.png, client_icon_32.png")


if __name__ == "__main__":
    main()
