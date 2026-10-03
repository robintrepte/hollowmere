#!/usr/bin/env python3
"""Front-facing fence autotiles composited from Nano Banana 2 sheets.

Raw sheets (magenta background, straight-on, not isometric):
  raw/world/fence_kit.png    post, horizontal rails, vertical boards, assembled segment
  raw/world/picket_kit.png   picket, horizontal run, vertical slats, corner

Each game tile is 32x32 and numbered by neighbor mask N=1 E=2 S=4 W=8.
Rails are stamped from one repeating strip, so a neighbor continues the same pixels.

  fences.py [out_dir]
"""
import os
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from process import bg_mask, downsample, load_rgba, quantize

T = 32
RAW = os.path.join(os.path.dirname(os.path.abspath(__file__)), "raw", "world")


def blank():
    return np.zeros((T, T, 4), np.uint8)


def keyed(path):
    a = load_rgba(path)
    bg = bg_mask(a, "magenta")
    out = a.copy()
    out[bg] = 0
    return out.astype(np.uint8)


def x_segments(img, thresh=0.012):
    fg = img[..., 3] > 0
    col = fg.mean(axis=0)
    segs = []
    start = None
    for i, on in enumerate(col > thresh):
        if on and start is None:
            start = i
        elif not on and start is not None:
            segs.append((start, i - 1))
            start = None
    if start is not None:
        segs.append((start, len(col) - 1))
    return segs


def crop_box(img, x0, x1):
    sub = img[:, x0:x1 + 1]
    fg = sub[..., 3] > 0
    ys, xs = np.where(fg)
    if len(xs) == 0:
        return sub
    return sub[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def chunks_along(img, vertical):
    """Split on the empty gaps. vertical=True separates left/right pieces."""
    fg = img[..., 3] > 0
    occ = fg.any(axis=0) if vertical else fg.any(axis=1)
    parts = []
    start = None
    for i, on in enumerate(occ):
        if on and start is None:
            start = i
        elif not on and start is not None:
            parts.append((start, i))
            start = None
    if start is not None:
        parts.append((start, len(occ)))
    crops = []
    for a, b in parts:
        if vertical:
            crops.append(img[:, a:b])
        else:
            crops.append(img[a:b])
    return crops


def trim_ends(img, vertical, frac=0.12):
    """Drop the end caps so a rail can continue into the next tile."""
    n = img.shape[1] if vertical else img.shape[0]
    cut = max(1, int(n * frac))
    if vertical:
        return img[:, cut:n - cut]
    return img[cut:n - cut]


def fit(img, w, h):
    bg = img[..., 3] == 0
    small = downsample(img.astype(np.int32), bg, w, h, fg_thresh=0.3)
    return np.asarray(quantize(small, 12))


def repeat(img, length, vertical):
    """Repeat a strip. The sample at 0 and at `length` share a phase, and the
    last pixel is a copy of the first so neighboring tiles meet on the same column."""
    axis = 0 if vertical else 1
    src_n = img.shape[axis]
    out_shape = (length, img.shape[1], 4) if vertical else (img.shape[0], length, 4)
    out = np.zeros(out_shape, np.uint8)
    for i in range(length):
        src_i = i % src_n
        if vertical:
            out[i] = img[src_i]
        else:
            out[:, i] = img[:, src_i]
    if vertical:
        out[-1] = out[0]
    else:
        out[:, -1] = out[:, 0]
    return out


def blit(dst, src, x, y):
    if src is None or src.size == 0:
        return
    h, w = src.shape[:2]
    x0, y0 = max(0, x), max(0, y)
    x1, y1 = min(dst.shape[1], x + w), min(dst.shape[0], y + h)
    if x1 <= x0 or y1 <= y0:
        return
    patch = src[y0 - y:y0 - y + (y1 - y0), x0 - x:x0 - x + (x1 - x0)]
    region = dst[y0:y1, x0:x1]
    mask = patch[..., 3:4] > 140
    region[:] = np.where(mask, patch, region)


def blit_span(dst, src, x0, x1, y):
    """Stamp a horizontal strip, but only between x0 and x1 (inclusive)."""
    if x1 < x0:
        return
    full = np.zeros((src.shape[0], T, 4), np.uint8)
    blit(full, src, 0, 0)
    blit(dst, full[:, x0:x1 + 1], x0, y)


def blit_column(dst, src, x, y0, y1):
    if y1 < y0:
        return
    full = np.zeros((T, src.shape[1], 4), np.uint8)
    blit(full, src, 0, 0)
    blit(dst, full[y0:y1 + 1], x, y0)


def load_kits():
    wood = keyed(os.path.join(RAW, "fence_kit.png"))
    pick = keyed(os.path.join(RAW, "picket_kit.png"))
    wseg = [crop_box(wood, a, b) for a, b in x_segments(wood)]
    pseg = [crop_box(pick, a, b) for a, b in x_segments(pick)]
    if len(wseg) < 4 or len(pseg) < 4:
        sys.exit(f"expected 4 objects on each sheet, got wood {len(wseg)} picket {len(pseg)}")
    return wseg, pseg


def wood_parts(segs):
    post = fit(segs[0], 10, 22)
    rails = chunks_along(segs[1], vertical=False)
    rails = [r for r in rails if r.shape[0] > 8 and r[..., 3].mean() > 0.05]
    rails.sort(key=lambda r: -r.shape[0] * r.shape[1])
    top = repeat(fit(trim_ends(rails[0], vertical=True), 16, 4), T, vertical=False)
    bot = repeat(fit(trim_ends(rails[1] if len(rails) > 1 else rails[0], vertical=True), 16, 4), T, vertical=False)
    boards = chunks_along(segs[2], vertical=True)
    boards = [b for b in boards if b.shape[1] > 20]
    boards.sort(key=lambda b: b.shape[1] * b.shape[0], reverse=True)
    left = repeat(fit(trim_ends(boards[0], vertical=False), 5, 8), T, vertical=True)
    right_src = boards[1] if len(boards) > 1 else boards[0]
    right = repeat(fit(trim_ends(right_src, vertical=False), 5, 8), T, vertical=True)
    return post, top, bot, left, right


def picket_parts(segs):
    # One picket-to-picket period, repeated so a long run stays even.
    run = segs[1]
    period = _picket_period(run)
    tile = fit(period, 8, 22)
    row = repeat(tile, T, vertical=False)
    slat = segs[2]
    if slat.shape[1] > 80:
        x = (slat.shape[1] - 80) // 2
        slat = slat[:, x:x + 80]
    slats = repeat(fit(slat, 12, 8), T, vertical=True)
    post = fit(segs[0], 6, 24)
    return row, slats, post


def _picket_period(run):
    """Crop one full picket, from the gap before it to the gap after it."""
    fg = run[..., 3] > 0
    ys, xs = np.where(fg)
    body = run[ys.min():ys.max() + 1, xs.min():xs.max() + 1]
    tips = body[:max(8, body.shape[0] // 6), ..., 3] > 0
    col = tips.mean(axis=0) > 0.25
    spans = []
    start = None
    for i, on in enumerate(col):
        if on and start is None:
            start = i
        elif not on and start is not None:
            spans.append((start, i - 1))
            start = None
    if start is not None:
        spans.append((start, len(col) - 1))
    # Full pickets only; the sheet cuts one off at the right edge.
    spans = [s for s in spans if s[1] - s[0] > 20]
    if len(spans) < 2:
        return body
    gap = spans[1][0] - spans[0][1]
    left = max(0, spans[0][0] - gap // 2)
    right = min(body.shape[1], spans[0][1] + gap // 2 + 1)
    return body[:, left:right]


def _h_span(mask, post_x, post_w):
    west, east = mask & 8, mask & 2
    if west and east:
        return 0, T - 1
    if west:
        return 0, post_x + post_w // 2
    if east:
        return post_x + post_w // 2, T - 1
    return None


def wood_tile(mask, parts):
    post, top, bot, left, right = parts
    im = blank()
    north_on, south_on = mask & 1, mask & 4
    px, py = 11, 6
    # Two boards, full height on a straight north-south run so the planks continue.
    if north_on or south_on:
        if north_on and south_on and not (mask & 2 or mask & 8):
            y0, y1 = 0, T - 1
        elif north_on and south_on:
            y0, y1 = 0, T - 1
        elif north_on:
            y0, y1 = 0, py + 6
        else:
            y0, y1 = py + post.shape[0] - 6, T - 1
        blit_column(im, left, 10, y0, y1)
        blit_column(im, right, 17, y0, y1)
    span = _h_span(mask, px, post.shape[1])
    if span:
        blit_span(im, top, span[0], span[1], 11)
        blit_span(im, bot, span[0], span[1], 18)
    # The post is the joint. A pure vertical run is just the two boards.
    if mask != 5:
        blit(im, post, px, py)
    return im


def picket_tile(mask, parts):
    row, slats, post = parts
    im = blank()
    north_on, south_on = mask & 1, mask & 4
    px, py = 13, 4
    if north_on or south_on:
        if north_on and south_on:
            y0, y1 = 0, T - 1
        elif north_on:
            y0, y1 = 0, 18
        else:
            y0, y1 = 14, T - 1
        blit_column(im, slats, 10, y0, y1)
    span = _h_span(mask, px, post.shape[1])
    if span:
        blit_span(im, row, span[0], span[1], 6)
    # Even pickets on a straight run. A post marks an end, a corner or a crossing.
    if mask not in (10, 5):
        blit(im, post, px, py)
    return im


def sign():
    """A blank board on a post, square to the camera. No letters."""
    im = blank()
    ink = (34, 24, 30, 255)
    hi = (212, 156, 96, 255)
    mid = (176, 116, 68, 255)
    wood = (148, 90, 52, 255)
    dk = (108, 64, 42, 255)
    deep = (72, 42, 36, 255)
    x0, x1, y0, y1 = 3, 28, 3, 16
    im[y0:y1 + 1, x0:x1 + 1] = ink
    im[y0 + 1:y1, x0 + 1:x1] = wood
    im[y0 + 1:y0 + 3, x0 + 1:x1] = hi
    im[y0 + 2, x0 + 2:x1 - 1] = mid
    im[y0 + 6, x0 + 1:x1] = ink
    im[y0 + 7, x0 + 1:x1] = dk
    im[y1 - 2, x0 + 1:x1 - 1] = dk
    im[y1 - 1, x0:x1 + 1] = ink
    for x in (6, 11, 18, 23):
        im[y0 + 4, x] = dk
        im[y0 + 10, x + 1] = mid
    for x in (8, 23):
        im[y0 + 3, x] = deep
        im[y0 + 3, x + 1] = ink
        im[y0 + 9, x] = deep
        im[y0 + 9, x + 1] = ink
    for y in range(y1, 31):
        for x in range(14, 18):
            if x in (14, 17) or y == 30:
                im[y, x] = ink
            elif x == 15:
                im[y, x] = hi
            elif x == 16:
                im[y, x] = dk
            else:
                im[y, x] = wood
    return im


def save(im, path):
    Image.fromarray(im, "RGBA").save(path)


def preview(pieces, path):
    grass = (95, 166, 75, 255)
    dark = (53, 108, 50, 255)
    layout = [
        "....h...",
        "..v.h--.",
        "..v.|+--",
        "..L-+.|.",
        "....|.|.",
        "....L-J.",
    ]
    rows, cols = len(layout), len(layout[0])
    canvas = np.zeros((rows * T, cols * T, 4), np.uint8)
    for y in range(rows * T):
        for x in range(cols * T):
            canvas[y, x] = grass if (x // 4 + y // 4) % 2 == 0 else dark
    cells = {}
    for r, row in enumerate(layout):
        for c, ch in enumerate(row):
            if ch != ".":
                cells[(c, r)] = ch
    for (c, r), _ch in cells.items():
        m = 0
        if (c, r - 1) in cells:
            m |= 1
        if (c + 1, r) in cells:
            m |= 2
        if (c, r + 1) in cells:
            m |= 4
        if (c - 1, r) in cells:
            m |= 8
        spr = pieces[m]
        blk = canvas[r * T:(r + 1) * T, c * T:(c + 1) * T]
        a = spr[..., 3:4] > 0
        blk[:] = np.where(a, spr, blk)
    big = Image.fromarray(canvas, "RGBA").resize((cols * T * 4, rows * T * 4), Image.NEAREST)
    big.save(path)


def check_seams(pieces):
    def col(im, x):
        return im[:, x].tobytes()

    def row(im, y):
        return im[y].tobytes()

    assert col(pieces[10], 0) == col(pieces[10], T - 1)
    assert col(pieces[2], T - 1) == col(pieces[8], 0)
    assert row(pieces[5], 0) == row(pieces[5], T - 1)
    assert row(pieces[4], T - 1) == row(pieces[1], 0)
    assert col(pieces[6], T - 1) == col(pieces[10], T - 1)
    assert row(pieces[6], T - 1) == row(pieces[5], T - 1)


def icon_from(tile):
    bg = tile[..., 3] == 0
    return downsample(tile.astype(np.int32), bg, 16, 16, fg_thresh=0.25)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "game/assets/world"
    os.makedirs(out, exist_ok=True)
    wseg, pseg = load_kits()
    wood_p = wood_parts(wseg)
    pick_p = picket_parts(pseg)
    wood = [wood_tile(m, wood_p) for m in range(16)]
    pick = [picket_tile(m, pick_p) for m in range(16)]
    check_seams(wood)
    check_seams(pick)
    for m in range(16):
        save(wood[m], os.path.join(out, f"fence_{m}.png"))
        save(pick[m], os.path.join(out, f"picket_{m}.png"))
    save(wood[10], os.path.join(out, "fence.png"))
    save(pick[10], os.path.join(out, "picket_fence.png"))
    save(sign(), os.path.join(out, "sign.png"))
    if out.rstrip("/").endswith("world"):
        save(icon_from(pick[10]), os.path.join(os.path.dirname(out), "items", "picket_fence.png"))
    preview(wood, "/tmp/fence_preview.png")
    preview(pick, "/tmp/picket_preview.png")
    print("wrote fence and picket sprites to", out)


if __name__ == "__main__":
    main()
