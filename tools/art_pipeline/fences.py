#!/usr/bin/env python3
"""Front-facing sign and autotile fences.

Fence pieces are one 32x32 cell per neighbor mask (N=1, E=2, S=4, W=8), the same
order soil tiles use. Rails run to the tile edge with no end cap, so a neighbor's
rail continues the same pixels. Posts stay upright. Nothing is drawn in perspective.

  fences.py [out_dir]
"""
import os
import sys

import numpy as np
from PIL import Image

T = 32
# Style bible ink + the warm wood used on the bench, chest, and shipping crate.
INK = (34, 24, 30, 255)
HI = (212, 156, 96, 255)
MID = (176, 116, 68, 255)
WOOD = (148, 90, 52, 255)
DK = (108, 64, 42, 255)
DEEP = (72, 42, 36, 255)

WHITE_HI = (255, 250, 240, 255)
WHITE = (236, 230, 214, 255)
WHITE_MID = (214, 206, 188, 255)
WHITE_DK = (176, 166, 150, 255)
WHITE_DEEP = (132, 120, 108, 255)

# Upright post. Horizontal rails cross it; vertical rails tuck into its top and bottom.
POST = (12, 19, 8, 25)  # x0, x1, y0, y1 inclusive
RAIL_TOP = (11, 14)     # two horizontal planks
RAIL_BOT = (19, 22)
# Two vertical planks inside the post's width, with a gap between them, so a
# north-south run reads as rails leaving the post rather than a solid pole.
V_LEFT = (12, 14)
V_RIGHT = (17, 19)


def blank():
    return np.zeros((T, T, 4), np.uint8)


def px(im, x, y, c):
    if 0 <= x < T and 0 <= y < T and c[3]:
        im[y, x] = c


def fill_rect(im, x0, x1, y0, y1, c):
    im[y0:y1 + 1, x0:x1 + 1] = c


def h_plank(im, x0, x1, y0, y1, palette):
    """Horizontal plank. Top and bottom are outline; the ends are open so tiles meet."""
    hi, mid, wood, dk = palette
    h = y1 - y0 + 1
    for y in range(y0, y1 + 1):
        if y == y0 or y == y1:
            c = INK
        elif y == y0 + 1:
            c = hi
        elif y >= y1 - 1 and h > 3:
            c = dk
        else:
            c = mid if (y - y0) % 2 == 0 else wood
        for x in range(x0, x1 + 1):
            px(im, x, y, c)


def v_plank(im, x0, x1, y0, y1, palette):
    """Vertical plank. Left and right are outline; the ends are open so tiles meet."""
    hi, mid, wood, dk = palette
    for x in range(x0, x1 + 1):
        if x == x0 or x == x1:
            c = INK
        elif x == x0 + 1:
            c = hi
        elif x == x1 - 1:
            c = dk
        else:
            c = mid
        for y in range(y0, y1 + 1):
            px(im, x, y, c)
            if c not in (INK, hi, dk) and (y % 8 == 5):
                px(im, x, y, wood)


def post(im, palette, cap=False):
    x0, x1, y0, y1 = POST
    hi, mid, wood, dk = palette
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            if x == x0 or x == x1 or y == y0 or y == y1:
                c = INK
            elif x == x0 + 1 or y == y0 + 1:
                c = hi
            elif x >= x1 - 2:
                c = DEEP if x == x1 - 1 else dk
            elif x == x0 + 2:
                c = mid
            else:
                c = wood
            # A knot, so a row of posts isn't a rubber stamp. Stays off the outline.
            if (x, y) in ((x0 + 3, y0 + 7), (x0 + 4, y0 + 7), (x0 + 4, y0 + 8)):
                c = dk
            px(im, x, y, c)
    if cap:
        cx = (x0 + x1) // 2
        px(im, cx, y0 - 3, INK)
        for x in range(cx - 1, cx + 2):
            px(im, x, y0 - 2, INK)
        px(im, cx, y0 - 2, WHITE_HI if hi == WHITE_HI else hi)
        for x in range(cx - 2, cx + 3):
            px(im, x, y0 - 1, INK)
        for x in range(cx - 1, cx + 2):
            px(im, x, y0 - 1, hi)


def pickets(im, left_edges):
    """Pointed pickets on the top rail. Positions repeat every tile, two on each side of the post."""
    yb = RAIL_TOP[0]
    for x0 in left_edges:
        px(im, x0 + 1, yb - 6, INK)
        for y in range(yb - 5, yb):
            px(im, x0, y, INK)
            px(im, x0 + 1, y, WHITE_HI if y < yb - 3 else WHITE)
            px(im, x0 + 2, y, INK)


def fence(mask, palette, picket=False):
    im = blank()
    hi, mid, wood, dk = palette
    pal = (hi, mid, wood, dk)
    north, east, south, west = mask & 1, mask & 2, mask & 4, mask & 8
    # Vertical planks first, then the front-facing rails, then the post.
    if north:
        v_plank(im, *V_LEFT, 0, POST[2] - 1, pal)
        v_plank(im, *V_RIGHT, 0, POST[2] - 1, pal)
    if south:
        v_plank(im, *V_LEFT, POST[3] + 1, T - 1, pal)
        v_plank(im, *V_RIGHT, POST[3] + 1, T - 1, pal)
    if west:
        h_plank(im, 0, POST[0] + 2, *RAIL_TOP, pal)
        h_plank(im, 0, POST[0] + 2, *RAIL_BOT, pal)
    if east:
        h_plank(im, POST[1] - 2, T - 1, *RAIL_TOP, pal)
        h_plank(im, POST[1] - 2, T - 1, *RAIL_BOT, pal)
    if picket and (east or west):
        edges = []
        if west:
            edges += [1, 6]
        if east:
            edges += [23, 28]
        pickets(im, edges)
    post(im, pal, cap=picket)
    return im


def sign():
    """A blank board on a post, square to the camera. No letters."""
    im = blank()
    x0, x1, y0, y1 = 3, 28, 3, 16
    fill_rect(im, x0, x1, y0, y1, INK)
    fill_rect(im, x0 + 1, x1 - 1, y0 + 1, y1 - 1, WOOD)
    fill_rect(im, x0 + 1, x1 - 1, y0 + 1, y0 + 2, HI)
    fill_rect(im, x0 + 2, x1 - 2, y0 + 2, y0 + 2, MID)
    # Two planks.
    im[y0 + 6, x0 + 1:x1] = INK
    im[y0 + 7, x0 + 1:x1] = DK
    im[y1 - 2, x0 + 1:x1 - 1] = DK
    im[y1 - 1, x0:x1 + 1] = INK
    # Grain, kept off the outline.
    for x in (6, 11, 18, 23):
        im[y0 + 4, x] = DK
        im[y0 + 10, x + 1] = MID
    # Bolts.
    for x in (8, 23):
        im[y0 + 3, x] = DEEP
        im[y0 + 3, x + 1] = INK
        im[y0 + 9, x] = DEEP
        im[y0 + 9, x + 1] = INK
    # Post, tucked behind the board.
    px0, px1 = 14, 17
    for y in range(y1, 31):
        for x in range(px0, px1 + 1):
            if x == px0 or x == px1 or y == 30:
                c = INK
            elif x == px0 + 1:
                c = HI
            elif x == px1 - 1:
                c = DK
            else:
                c = WOOD
            im[y, x] = c
    return im


def icon_picket():
    """16x16 shop icon: three pickets, front view."""
    im = np.zeros((16, 16, 4), np.uint8)
    def p(x, y, c):
        if 0 <= x < 16 and 0 <= y < 16:
            im[y, x] = c
    for x0 in (2, 7, 12):
        p(x0 + 1, 2, INK)
        for x in range(x0, x0 + 3):
            p(x, 3, INK)
        for y in range(4, 12):
            p(x0, y, INK)
            p(x0 + 1, y, WHITE_HI if y < 7 else WHITE)
            p(x0 + 2, y, INK)
        p(x0 + 1, 4, WHITE_HI)
    for y, c in ((8, INK), (9, WHITE_HI), (10, WHITE_DK), (11, INK)):
        for x in range(1, 15):
            p(x, y, c)
    return im


WOOD_PAL = (HI, MID, WOOD, DK)
PICKET_PAL = (WHITE_HI, WHITE, WHITE_MID, WHITE_DK)


def save(im, path):
    Image.fromarray(im, "RGBA").save(path)


def preview(pieces, path):
    """A short run, a corner, a T, a crossing, and a closed pen, on grass."""
    grass = (95, 166, 75, 255)
    dark = (53, 108, 50, 255)
    # 8 x 6 tiles
    layout = [
        "s..h....",
        "..v.h--.",
        "..v.|+--",
        "..L-+.|.",
        "....|.|.",
        "....L-J.",
    ]
    # Characters are resolved by scanning neighbors in this picture, not by the glyph.
    # Glyphs only mark where a fence sits. 's' is the sign. 'h' is a lone post.
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
    for (c, r), ch in cells.items():
        if ch == "s":
            spr = sign()
        else:
            m = 0
            if (c, r - 1) in cells and cells[(c, r - 1)] != "s":
                m |= 1
            if (c + 1, r) in cells and cells[(c + 1, r)] != "s":
                m |= 2
            if (c, r + 1) in cells and cells[(c, r + 1)] != "s":
                m |= 4
            if (c - 1, r) in cells and cells[(c - 1, r)] != "s":
                m |= 8
            spr = pieces[m]
        y0, x0 = r * T, c * T
        blk = canvas[y0:y0 + T, x0:x0 + T]
        a = spr[..., 3:4] > 0
        blk[:] = np.where(a, spr, blk)
    big = Image.fromarray(canvas, "RGBA").resize((canvas.shape[1] * 4, canvas.shape[0] * 4), Image.NEAREST)
    big.save(path)


def check_seams(pieces):
    """Rails that leave a tile must match the rail that arrives on the next tile."""
    def col(im, x):
        return im[:, x].tobytes()

    def row(im, y):
        return im[y].tobytes()

    # Straight horizontal: mask E+W (10). The open ends are the same pixels.
    assert col(pieces[10], 0) == col(pieces[10], T - 1)
    # East end (mask 2) meets west end (mask 8).
    assert col(pieces[2], T - 1) == col(pieces[8], 0)
    # Straight vertical: mask N+S (5). South end (4) meets north end (1).
    assert row(pieces[5], 0) == row(pieces[5], T - 1)
    assert row(pieces[4], T - 1) == row(pieces[1], 0)
    # Corner (S+E = 6) uses the same edge rails as the straight pieces.
    assert col(pieces[6], T - 1) == col(pieces[10], T - 1)
    assert row(pieces[6], T - 1) == row(pieces[5], T - 1)


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "game/assets/world"
    os.makedirs(out, exist_ok=True)
    wood = [fence(m, WOOD_PAL, picket=False) for m in range(16)]
    pick = [fence(m, PICKET_PAL, picket=True) for m in range(16)]
    check_seams(wood)
    check_seams(pick)
    for m in range(16):
        save(wood[m], os.path.join(out, f"fence_{m}.png"))
        save(pick[m], os.path.join(out, f"picket_{m}.png"))
    # Straight stand-ins so a lookup of the old single names is never the slanted sheet art.
    save(wood[10], os.path.join(out, "fence.png"))
    save(pick[10], os.path.join(out, "picket_fence.png"))
    save(sign(), os.path.join(out, "sign.png"))
    icon_dir = os.path.join(os.path.dirname(out), "items") if out.endswith("world") else out
    if out.endswith("world"):
        save(icon_picket(), os.path.join(icon_dir, "picket_fence.png"))
    preview(wood, "/tmp/fence_preview.png")
    preview(pick, "/tmp/picket_preview.png")
    print("wrote fence, picket, and sign sprites to", out)


if __name__ == "__main__":
    main()
