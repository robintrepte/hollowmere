#!/usr/bin/env python3
"""Hollowmere art pipeline: turns AI-generated images into game-ready pixel sprites.

Commands:
  sheet    <img> <names,comma,sep> <out_dir> [--cols N --rows N --size 64 --small 32]
           Slice a grid sheet of creatures into battle (size) + overworld (small) sprites.
  icons    <img> <names,...> <out_dir> [--cols N --rows N --size 16]
  single   <img> <out_png> --w W [--h H] [--colors N] [--anchor bottom|center]
  portrait <img> <out_png> [--size 64]

Backgrounds are keyed out (flat magenta / white / green) before downsampling.
Downsampling uses per-block majority vote, so edges stay crisp and halos vanish.
"""
import argparse
import os
import sys

import numpy as np
from PIL import Image

BG_KEYS = {
    "magenta": (255, 0, 255),
    "green": (0, 255, 0),
    "white": (255, 255, 255),
}


def load_rgba(path):
    return np.asarray(Image.open(path).convert("RGBA")).astype(np.int32)


def bg_mask(a, key="auto"):
    """True where pixel is background."""
    r, g, b, al = a[..., 0], a[..., 1], a[..., 2], a[..., 3]
    if key == "auto":
        q = (a[::4, ::4, :3] // 32).reshape(-1, 3)
        vals, counts = np.unique(q, axis=0, return_counts=True)
        med = vals[np.argmax(counts)] * 32 + 16
        if med[0] > 180 and med[2] > 180 and med[1] < 120:
            key = "magenta"
        elif med[1] > 180 and med[0] < 120 and med[2] < 120:
            key = "green"
        else:
            key = "white"
    if key == "magenta":
        m = (r > 150) & (b > 150) & (g < 140) & ((r + b) / 2 - g > 90)
        shade = (np.abs(r - b) < 45) & (np.minimum(r, b) - g > 55) & (np.minimum(r, b) > 70)
        for _ in range(24):
            grown = m.copy()
            grown[1:, :] |= m[:-1, :]
            grown[:-1, :] |= m[1:, :]
            grown[:, 1:] |= m[:, :-1]
            grown[:, :-1] |= m[:, 1:]
            grown &= shade | m
            if (grown == m).all():
                break
            m = grown
    elif key == "green":
        m = (g > 150) & (r < 140) & (b < 140) & (g - (r + b) / 2 > 80)
    else:
        m = (r > 238) & (g > 238) & (b > 238)
    return m | (al < 20)


def grid_lines(fg, axis, n):
    """Finds n-1 separator positions along an axis (rows of mostly-dark lines), else equal splits."""
    size = fg.shape[axis]
    prof = fg.mean(axis=1 - axis)
    seps = []
    for i in range(1, n):
        guess = int(size * i / n)
        lo, hi = max(0, guess - size // (n * 4)), min(size, guess + size // (n * 4))
        window = prof[lo:hi]
        if len(window) and window.max() > 0.6:
            seps.append(lo + int(np.argmax(window)))
        else:
            seps.append(guess)
    return [0] + seps + [size]


def downsample(a, mask, out_w, out_h, fg_thresh=0.45):
    """Majority-vote downsample of an RGBA region with a background mask."""
    h, w = mask.shape
    out = np.zeros((out_h, out_w, 4), dtype=np.uint8)
    ys = np.linspace(0, h, out_h + 1).astype(int)
    xs = np.linspace(0, w, out_w + 1).astype(int)
    for oy in range(out_h):
        for ox in range(out_w):
            y0, y1, x0, x1 = ys[oy], max(ys[oy + 1], ys[oy] + 1), xs[ox], max(xs[ox + 1], xs[ox] + 1)
            blk_m = ~mask[y0:y1, x0:x1]
            if blk_m.size == 0 or blk_m.mean() < fg_thresh:
                continue
            px = a[y0:y1, x0:x1, :3][blk_m]
            # Prefer the darkest quartile if the block is an outline edge, else median.
            lum = px @ np.array([0.299, 0.587, 0.114])
            if lum.std() > 40 and blk_m.mean() < 0.85:
                sel = px[lum <= np.percentile(lum, 35)]
                col = np.median(sel, axis=0)
            else:
                col = np.median(px, axis=0)
            out[oy, ox, :3] = col.astype(np.uint8)
            out[oy, ox, 3] = 255
    return out


def quantize(img_arr, colors=24):
    im = Image.fromarray(img_arr, "RGBA")
    alpha = im.getchannel("A")
    rgb = im.convert("RGB")
    q = rgb.quantize(colors=colors, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).convert("RGB")
    out = q.convert("RGBA")
    out.putalpha(alpha.point(lambda v: 255 if v > 127 else 0))
    return out


def clean_islands(mask_fg, min_px):
    """Removes tiny foreground specks (flood fill labelling, no scipy)."""
    h, w = mask_fg.shape
    seen = np.zeros_like(mask_fg, dtype=bool)
    keep = np.zeros_like(mask_fg, dtype=bool)
    for y in range(h):
        for x in range(w):
            if mask_fg[y, x] and not seen[y, x]:
                stack = [(y, x)]
                comp = []
                seen[y, x] = True
                while stack:
                    cy, cx = stack.pop()
                    comp.append((cy, cx))
                    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        ny, nx = cy + dy, cx + dx
                        if 0 <= ny < h and 0 <= nx < w and mask_fg[ny, nx] and not seen[ny, nx]:
                            seen[ny, nx] = True
                            stack.append((ny, nx))
                if len(comp) >= min_px:
                    for cy, cx in comp:
                        keep[cy, cx] = True
    return keep


def sprite_from_region(a, bg, canvas, scale, anchor="bottom", colors=24, pad=1, fit=True):
    """Crops the foreground of a region and places it, downsampled by `scale`, on a canvas."""
    fg = ~bg
    ys, xs = np.where(fg)
    if len(xs) == 0:
        return Image.new("RGBA", canvas, (0, 0, 0, 0))
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    crop, cmask = a[y0:y1, x0:x1], bg[y0:y1, x0:x1]
    cw, ch = canvas
    tw, th = max(1, round((x1 - x0) * scale)), max(1, round((y1 - y0) * scale))
    if fit and (tw > cw - 2 * pad or th > ch - 2 * pad):
        f = min((cw - 2 * pad) / tw, (ch - 2 * pad) / th)
        tw, th = max(1, int(tw * f)), max(1, int(th * f))
    small = downsample(crop, cmask, tw, th)
    keep = clean_islands(small[..., 3] > 0, max(2, (tw * th) // 400))
    small[~keep] = 0
    spr = quantize(small, colors)
    out = Image.new("RGBA", canvas, (0, 0, 0, 0))
    ox = (cw - tw) // 2
    oy = ch - th - pad if anchor == "bottom" else (ch - th) // 2
    out.paste(spr, (ox, oy), spr)
    return out


def cmd_sheet(args):
    a = load_rgba(args.img)
    bg = bg_mask(a, args.key)
    names = [n.strip() for n in args.names.split(",")]
    dark = (a[..., :3].sum(axis=2) < 200) & ~bg
    rows = grid_lines(dark, 0, args.rows)
    cols = grid_lines(dark, 1, args.cols)
    os.makedirs(args.out_dir, exist_ok=True)
    os.makedirs(os.path.join(args.out_dir, "small"), exist_ok=True)
    i = 0
    for r in range(args.rows):
        for c in range(args.cols):
            if i >= len(names):
                break
            name = names[i]
            i += 1
            if name in ("", "-"):
                continue
            y0, y1, x0, x1 = rows[r], rows[r + 1], cols[c], cols[c + 1]
            ins = int(min(y1 - y0, x1 - x0) * 0.035)
            reg, rbg = a[y0 + ins:y1 - ins, x0 + ins:x1 - ins], bg[y0 + ins:y1 - ins, x0 + ins:x1 - ins].copy()
            # Kill leftover grid line pixels along the borders.
            rbg[:3, :] = True
            rbg[-3:, :] = True
            rbg[:, :3] = True
            rbg[:, -3:] = True
            cell = min(y1 - y0, x1 - x0)
            big = sprite_from_region(reg, rbg, (args.size, args.size), args.size / cell * args.zoom, colors=args.colors)
            small = sprite_from_region(reg, rbg, (args.small, args.small), args.small / cell * args.zoom * 1.25, colors=min(args.colors, 16))
            big.save(os.path.join(args.out_dir, f"{name}.png"))
            small.save(os.path.join(args.out_dir, "small", f"{name}.png"))
            print("wrote", name)


def find_objects(bg, down=4, dilate=1, min_frac=0.0002, drop_small=0.0):
    """Detects separate objects on a keyed background; returns bboxes in reading order."""
    fg = ~bg
    h, w = fg.shape
    sh, sw = h // down, w // down
    small = fg[:sh * down, :sw * down].reshape(sh, down, sw, down).mean(axis=(1, 3)) > 0.2
    grown = small.copy()
    for _ in range(dilate):
        g2 = grown.copy()
        g2[1:, :] |= grown[:-1, :]
        g2[:-1, :] |= grown[1:, :]
        g2[:, 1:] |= grown[:, :-1]
        g2[:, :-1] |= grown[:, 1:]
        grown = g2
    labels = np.zeros(grown.shape, dtype=np.int32)
    boxes = []
    n = 0
    for y in range(sh):
        for x in range(sw):
            if grown[y, x] and labels[y, x] == 0:
                n += 1
                stack = [(y, x)]
                labels[y, x] = n
                ys, xs = [], []
                while stack:
                    cy, cx = stack.pop()
                    ys.append(cy)
                    xs.append(cx)
                    for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                        ny, nx = cy + dy, cx + dx
                        if 0 <= ny < sh and 0 <= nx < sw and grown[ny, nx] and labels[ny, nx] == 0:
                            labels[ny, nx] = n
                            stack.append((ny, nx))
                if len(ys) >= min_frac * sh * sw:
                    boxes.append([min(ys) * down, (max(ys) + 1) * down, min(xs) * down, (max(xs) + 1) * down])
    if not boxes:
        return []
    areas = sorted((b[1] - b[0]) * (b[3] - b[2]) for b in boxes)
    med_a = areas[len(areas) // 2]
    big = [b for b in boxes if (b[1] - b[0]) * (b[3] - b[2]) >= med_a * 0.3]
    if drop_small > 0:
        top = max((b[1] - b[0]) * (b[3] - b[2]) for b in boxes)
        boxes = [b for b in boxes if (b[1] - b[0]) * (b[3] - b[2]) >= top * drop_small]
        big = [b for b in big if b in boxes]
    med_h = sorted(b[1] - b[0] for b in big)[len(big) // 2]
    med_w = sorted(b[3] - b[2] for b in big)[len(big) // 2]

    def centers(vals, gap):
        vals = sorted(vals)
        groups = [[vals[0]]]
        for v in vals[1:]:
            if v - groups[-1][-1] > gap:
                groups.append([])
            groups[-1].append(v)
        return [sum(g) / len(g) for g in groups]

    row_c = centers([(b[0] + b[1]) / 2 for b in big], med_h * 0.5)
    col_c = centers([(b[2] + b[3]) / 2 for b in big], med_w * 0.5)
    cells = {}
    for b in boxes:
        cy, cx = (b[0] + b[1]) / 2, (b[2] + b[3]) / 2
        r = min(range(len(row_c)), key=lambda i: abs(row_c[i] - cy))
        c = min(range(len(col_c)), key=lambda i: abs(col_c[i] - cx))
        if (r, c) in cells:
            u = cells[(r, c)]
            cells[(r, c)] = [min(u[0], b[0]), max(u[1], b[1]), min(u[2], b[2]), max(u[3], b[3])]
        else:
            cells[(r, c)] = list(b)
    return [cells[k] for k in sorted(cells)]


def cmd_icons_auto(args):
    a = load_rgba(args.img)
    bg = bg_mask(a, args.key)
    names = [n.strip() for n in args.names.split(",")]
    boxes = find_objects(bg)
    os.makedirs(args.out_dir, exist_ok=True)
    print(f"found {len(boxes)} objects for {len(names)} names")
    for name, (y0, y1, x0, x1) in zip(names, boxes):
        if name in ("", "-"):
            continue
        m = 2
        y0, x0 = max(0, y0 - m), max(0, x0 - m)
        reg, rbg = a[y0:y1 + m, x0:x1 + m], bg[y0:y1 + m, x0:x1 + m]
        fg = ~rbg
        ys, xs = np.where(fg)
        if len(xs) == 0:
            continue
        ext = max(ys.max() - ys.min(), xs.max() - xs.min()) + 1
        spr = sprite_from_region(reg, rbg, (args.size, args.size), (args.size - 1) / ext, anchor="center", colors=args.colors, pad=0)
        spr.save(os.path.join(args.out_dir, f"{name}.png"))


def cmd_sprites(args):
    """Auto-detected sheet of world objects; names are `name:WxH[:anchor[:FWxFH]]` (canvas, fit box)."""
    a = load_rgba(args.img)
    bg = bg_mask(a, args.key)
    specs = [n.strip() for n in args.names.split(",")]
    boxes = find_objects(bg, drop_small=args.drop_small)
    os.makedirs(args.out_dir, exist_ok=True)
    print(f"found {len(boxes)} objects for {len(specs)} names")
    for spec, (y0, y1, x0, x1) in zip(specs, boxes):
        if spec in ("", "-"):
            continue
        parts = spec.split(":")
        name = parts[0]
        cw, ch = (int(v) for v in parts[1].split("x"))
        anchor = parts[2] if len(parts) > 2 and parts[2] else "bottom"
        fw, fh = (int(v) for v in parts[3].split("x")) if len(parts) > 3 else (cw - 1, ch - 1)
        reg, rbg = a[y0:y1, x0:x1], bg[y0:y1, x0:x1]
        if args.trim_caption:
            rows = (~rbg).any(axis=1)
            hh = len(rows)
            for yy in range(int(hh * 0.65), hh):
                if not rows[yy]:
                    reg, rbg = reg[:yy], rbg[:yy]
                    break
        ys, xs = np.where(~rbg)
        if len(xs) == 0:
            continue
        w, h = xs.max() - xs.min() + 1, ys.max() - ys.min() + 1
        scale = min(fw / w, fh / h)
        spr = sprite_from_region(reg, rbg, (cw, ch), scale, anchor=anchor, colors=args.colors, pad=0)
        spr.save(os.path.join(args.out_dir, f"{name}.png"))


def cmd_icons(args):
    if args.auto:
        return cmd_icons_auto(args)
    a = load_rgba(args.img)
    bg = bg_mask(a, args.key)
    names = [n.strip() for n in args.names.split(",")]
    dark = (a[..., :3].sum(axis=2) < 200) & ~bg
    rows = grid_lines(dark, 0, args.rows)
    cols = grid_lines(dark, 1, args.cols)
    os.makedirs(args.out_dir, exist_ok=True)
    i = 0
    for r in range(args.rows):
        for c in range(args.cols):
            if i >= len(names):
                break
            name = names[i]
            i += 1
            if name in ("", "-"):
                continue
            y0, y1, x0, x1 = rows[r], rows[r + 1], cols[c], cols[c + 1]
            ins = int(min(y1 - y0, x1 - x0) * 0.04)
            reg, rbg = a[y0 + ins:y1 - ins, x0 + ins:x1 - ins], bg[y0 + ins:y1 - ins, x0 + ins:x1 - ins].copy()
            rbg[:3, :] = True
            rbg[-3:, :] = True
            rbg[:, :3] = True
            rbg[:, -3:] = True
            fg = ~rbg
            ys, xs = np.where(fg)
            if len(xs) == 0:
                continue
            ext = max(ys.max() - ys.min(), xs.max() - xs.min()) + 1
            spr = sprite_from_region(reg, rbg, (args.size, args.size), (args.size - 1) / ext, anchor="center", colors=args.colors, pad=0)
            spr.save(os.path.join(args.out_dir, f"{name}.png"))
            print("wrote", name)


def cmd_single(args):
    a = load_rgba(args.img)
    bg = bg_mask(a, args.key)
    fg = ~bg
    ys, xs = np.where(fg)
    if len(xs) == 0:
        sys.exit("empty image")
    w = xs.max() - xs.min() + 1
    h = ys.max() - ys.min() + 1
    scale = args.w / w
    out_h = args.h if args.h else int(round(h * scale)) + 2
    spr = sprite_from_region(a, bg, (args.w, out_h), scale, anchor=args.anchor, colors=args.colors, pad=0, fit=True)
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    spr.save(args.out)
    print("wrote", args.out, spr.size)


def cmd_backdrop(args):
    """Full-frame scenes (battle backgrounds, title art): box-downsample to the logical resolution."""
    im = Image.open(args.img).convert("RGB")
    sw, sh = im.size
    tr = args.w / args.h
    if sw / sh > tr:
        nw = int(sh * tr)
        im = im.crop(((sw - nw) // 2, 0, (sw - nw) // 2 + nw, sh))
    else:
        nh = int(sw / tr)
        im = im.crop((0, (sh - nh) // 2, sw, (sh - nh) // 2 + nh))
    small = im.resize((args.w, args.h), Image.BOX)
    small = small.quantize(colors=args.colors, method=Image.Quantize.MEDIANCUT, dither=Image.Dither.NONE).convert("RGB")
    os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
    small.save(args.out)
    print("wrote", args.out, small.size)


def cmd_portrait(args):
    a = load_rgba(args.img)
    bg = bg_mask(a, args.key)
    fg = ~bg
    ys, xs = np.where(fg)
    ext = max(ys.max() - ys.min(), xs.max() - xs.min()) + 1
    spr = sprite_from_region(a, bg, (args.size, args.size), args.size / ext, anchor="bottom", colors=args.colors, pad=0)
    spr.save(args.out)
    print("wrote", args.out)


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("sheet")
    s.add_argument("img"), s.add_argument("names"), s.add_argument("out_dir")
    s.add_argument("--cols", type=int, default=3), s.add_argument("--rows", type=int, default=3)
    s.add_argument("--size", type=int, default=64), s.add_argument("--small", type=int, default=32)
    s.add_argument("--zoom", type=float, default=1.0), s.add_argument("--colors", type=int, default=24)
    s.add_argument("--key", default="auto")
    i = sub.add_parser("icons")
    i.add_argument("img"), i.add_argument("names"), i.add_argument("out_dir")
    i.add_argument("--cols", type=int, default=6), i.add_argument("--rows", type=int, default=6)
    i.add_argument("--size", type=int, default=16), i.add_argument("--colors", type=int, default=12)
    i.add_argument("--key", default="auto"), i.add_argument("--auto", action="store_true")
    g = sub.add_parser("single")
    g.add_argument("img"), g.add_argument("out")
    g.add_argument("--w", type=int, required=True), g.add_argument("--h", type=int, default=0)
    g.add_argument("--colors", type=int, default=32), g.add_argument("--anchor", default="bottom")
    g.add_argument("--key", default="auto")
    sp = sub.add_parser("sprites")
    sp.add_argument("img"), sp.add_argument("names"), sp.add_argument("out_dir")
    sp.add_argument("--colors", type=int, default=20), sp.add_argument("--key", default="auto")
    sp.add_argument("--drop-small", type=float, default=0.0)
    sp.add_argument("--trim-caption", action="store_true")
    bd = sub.add_parser("backdrop")
    bd.add_argument("img"), bd.add_argument("out")
    bd.add_argument("--w", type=int, default=320), bd.add_argument("--h", type=int, default=180)
    bd.add_argument("--colors", type=int, default=48)
    o = sub.add_parser("portrait")
    o.add_argument("img"), o.add_argument("out")
    o.add_argument("--size", type=int, default=64), o.add_argument("--colors", type=int, default=28)
    o.add_argument("--key", default="auto")
    args = p.parse_args()
    {"sheet": cmd_sheet, "icons": cmd_icons, "single": cmd_single, "portrait": cmd_portrait, "sprites": cmd_sprites, "backdrop": cmd_backdrop}[args.cmd](args)


if __name__ == "__main__":
    main()
