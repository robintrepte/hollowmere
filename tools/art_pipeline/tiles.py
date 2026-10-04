#!/usr/bin/env python3
"""Procedural, seamless 32x32 ground tiles for Hollowmere, with seasonal variants.

Outputs (in game/assets/tiles/):
  ground_<season>.png   4 variant columns x 20 rows (row = ground tile id, see core/world/tiles.gd)
  soil.png              16 columns (neighbor mask, bit set = that side is also tilled, N=1 E=2 S=4 W=8)
                        x 32 rows (inner-corner mask + 16 if watered). Open sides are ragged; outer
                        corners are rounded off, inner corners nicked, so a plot is not a hard rectangle.
  water_edge.png        shore ribbon on water. 16 columns (sides facing land) x 64 rows
                        (diagonal land corners + variant * 16). Corners are quarter-ellipses, a
                        different radius per corner and per variant. Straight edges match across variants.
  shore_cap_<season>.png  land color filling the outside of a rounded corner, under the ribbon.
                        16 columns x 384 rows (6 shore terrains x 64). Same bit layout as water_edge.
  shore_fringe.png      dirt bank spilling onto the land tile. 16 columns (sides facing water)
                        x 16 rows (diagonal water). Same bank color as water_edge where the tiles meet.
  grass_edge_<season>.png  grass spilling onto bare ground: 16 columns (sides that touch grass,
                        N=1 E=2 S=4 W=8) x 16 rows (diagonal-only grass, NE=1 SE=2 SW=4 NW=8)
  cliff.png, cavewall.png  32x48 blocking deco
"""
import argparse
import os
import zlib

import numpy as np
from PIL import Image

T = 32
SEASONS = ["spring", "summer", "fall", "winter"]
GROUND_ORDER = ["grass", "tallgrass", "path", "sand", "water", "plaza", "cave", "snow", "ice", "dirt", "bridge",
                "flowers", "ash", "marsh", "twilight", "canyon", "lava", "wood", "darkgrass", "deepwater", "marble", "carpet"]
OUTLINE = (34, 24, 30)


def hexc(h):
    h = h.lstrip("#")
    return np.array([int(h[i:i + 2], 16) for i in (0, 2, 4)], dtype=np.float64)


def periodic_noise(rng, size, cells):
    """Tileable value noise in [0,1]."""
    lat = rng.random((cells, cells))
    ys, xs = np.mgrid[0:size, 0:size] / size * cells
    x0, y0 = np.floor(xs).astype(int), np.floor(ys).astype(int)
    fx, fy = xs - x0, ys - y0
    fx, fy = fx * fx * (3 - 2 * fx), fy * fy * (3 - 2 * fy)
    x1, y1 = (x0 + 1) % cells, (y0 + 1) % cells
    x0, y0 = x0 % cells, y0 % cells
    a = lat[y0, x0] * (1 - fx) + lat[y0, x1] * fx
    b = lat[y1, x0] * (1 - fx) + lat[y1, x1] * fx
    return a * (1 - fy) + b * fy


def fbm(rng, size=T, octaves=(4, 8, 16), weights=(0.55, 0.3, 0.15)):
    n = sum(w * periodic_noise(rng, size, c) for c, w in zip(octaves, weights))
    return (n - n.min()) / max(1e-6, n.max() - n.min())


def _edge_weight(keep):
    """0 at the tile border rising to 1 inside; `keep` of each variant's own noise survives at the border."""
    c = np.arange(T) + 0.5
    d = np.minimum(np.minimum.outer(c, c), np.minimum.outer(T - c, T - c))
    w = np.clip((d - 0.5) / 5.0, 0.0, 1.0)
    return keep + (1.0 - keep) * w * w * (3 - 2 * w)


# Variants share one noise field near their borders so neighbors blend; part of each
# variant's own pattern stays at the seam so the grid still reads faintly.
EDGE_W = _edge_weight(0.35)


def ramp(n, colors, steps=None):
    """Posterize noise into a palette ramp (dark -> light)."""
    cols = [hexc(c) for c in colors]
    steps = steps or len(cols)
    idx = np.clip((n * steps).astype(int), 0, len(cols) - 1)
    out = np.zeros((n.shape[0], n.shape[1], 3))
    for i, c in enumerate(cols):
        out[idx == i] = c
    return out


def spot(rng, margin=3):
    """Random pixel kept off the border, so details never wrap and cut at a seam."""
    return rng.integers(margin, T - margin, 2)


def put(img, x, y, color):
    img[y % T, x % T] = hexc(color) if isinstance(color, str) else color


def tufts(img, rng, n, dark, light):
    for _ in range(n):
        x, y = spot(rng)
        put(img, x, y, dark)
        put(img, x - 1, y - 1, dark)
        put(img, x + 1, y - 1, dark)
        put(img, x, y - 1, light)


def specks(img, rng, n, colors):
    for _ in range(n):
        x, y = spot(rng)
        put(img, x, y, colors[rng.integers(0, len(colors))])


def pebbles(img, rng, n, base, hi, shadow):
    for _ in range(n):
        x, y = spot(rng)
        put(img, x, y, base)
        put(img, x + 1, y, base)
        put(img, x, y - 1, hi)
        put(img, x, y + 1, shadow)
        put(img, x + 1, y + 1, shadow)


def flowers(img, rng, n, petals):
    for _ in range(n):
        x, y = spot(rng)
        c = petals[rng.integers(0, len(petals))]
        for dx, dy in ((0, -1), (-1, 0), (1, 0), (0, 1)):
            put(img, x + dx, y + dy, c)
        put(img, x, y, "#f8e070")


GRASS = {
    "spring": ["#3f7a3a", "#4f9142", "#5fa64b", "#73b856"],
    "summer": ["#356c32", "#43803a", "#529443", "#63a64c"],
    "fall": ["#6c6a32", "#86803a", "#9c8f42", "#b39c4c"],
    "winter": ["#a9b8cc", "#c4d0de", "#dbe4ee", "#eef3f8"],
}
DARK = {
    "spring": ["#2b5a32", "#356a39", "#41793f", "#4d8846"],
    "summer": ["#264f2c", "#2f5e33", "#3a6c3a", "#467b41"],
    "fall": ["#5a4a2a", "#6c5830", "#7e6636", "#90733e"],
    "winter": ["#94a4ba", "#aebcce", "#c6d2e0", "#dde6ef"],
}
PETALS = {
    "spring": ["#f0a0c0", "#f8f0f8", "#a0c0f0", "#f8d060"],
    "summer": ["#f06060", "#f8d040", "#f8f8f8", "#c070e0"],
    "fall": ["#e07030", "#c04030", "#f0b040", "#a05030"],
    "winter": ["#f8f8ff", "#d0e8ff", "#e8f0ff", "#c8d8f0"],
}


def make_tile(name, season, variant, shared_only=False):
    rng = np.random.default_rng(zlib.crc32(f"{name}:{season}:{variant}".encode()))
    shared = fbm(np.random.default_rng(zlib.crc32(f"{name}:{season}".encode())))
    # Shores use the shared field alone so they meet the neighboring ground tile.
    n = shared if shared_only else shared + (fbm(rng) - shared) * EDGE_W
    if name in ("grass", "flowers", "tallgrass"):
        g = GRASS[season]
        img = ramp(n * 0.55 + 0.25, g)
        if season == "winter":
            specks(img, rng, 6, ["#ffffff", "#b8c8dc"])
        else:
            tufts(img, rng, 7 if name == "grass" else 10, g[0], g[3])
        if name == "flowers":
            flowers(img, rng, 5, PETALS[season])
        if name == "tallgrass":
            dark = DARK[season]
            for _ in range(16):
                x, y = spot(rng)
                y = max(y, 11)
                h = rng.integers(4, 8)
                for i in range(h):
                    put(img, x + (i // 3) * (1 if variant % 2 else -1), y - i, dark[1] if i < h - 1 else dark[3])
                put(img, x + 1, y, dark[0])
    elif name == "darkgrass":
        img = ramp(n * 0.55 + 0.25, DARK[season])
        tufts(img, rng, 8, DARK[season][0], DARK[season][3])
    elif name == "path":
        img = ramp(n * 0.5 + 0.25, ["#8a6a48", "#a07c55", "#b38d62", "#c29d70"])
        pebbles(img, rng, 4, "#9a8a78", "#c8b8a0", "#6a5a48")
    elif name == "dirt":
        img = ramp(n * 0.5 + 0.25, ["#6a4a30", "#7c5838", "#8d6640", "#9c7349"])
        specks(img, rng, 10, ["#5a3e28", "#a8805a"])
    elif name == "sand":
        img = ramp(n * 0.45 + 0.3, ["#d0b078", "#dcc088", "#e8d098", "#f2dca8"])
        specks(img, rng, 12, ["#c09a68", "#f8e8c0"])
        if variant == 2:
            pebbles(img, rng, 1, "#f0e0e0", "#ffffff", "#c0a090")
    elif name in ("water", "deepwater"):
        cols = ["#2e6aa8", "#3a7cbc", "#4a90cc", "#5ea4da"] if name == "water" else ["#1c4478", "#24528c", "#2e62a0", "#3a72b2"]
        img = ramp(n * 0.6 + 0.2, cols)
        for _ in range(3):
            x, y = spot(rng)
            x = min(x, T - 9)
            for i in range(rng.integers(3, 6)):
                put(img, x + i, y, "#a8d8f0" if name == "water" else "#5a8ac0")
    elif name == "plaza":
        img = np.zeros((T, T, 3)) + hexc("#b8b0a0")
        n2 = ramp(n * 0.4 + 0.3, ["#a8a090", "#b8b0a0", "#c8c0b0"])
        img[:] = n2
        for k in range(0, T, 16):
            img[k, :] = hexc("#8a8270")
            img[:, (k + (8 if (k // 16) % 2 else 0)) % T] = hexc("#8a8270")
        for y in range(T):
            off = 8 if (y // 16) % 2 else 0
            img[y, (off) % T] = hexc("#8a8270")
            img[y, (off + 16) % T] = hexc("#8a8270")
    elif name == "cave":
        img = ramp(n * 0.5 + 0.2, ["#3a3240", "#463c4c", "#524658", "#5e5264"])
        pebbles(img, rng, 3, "#6a5e70", "#847890", "#2a2430")
    elif name == "snow":
        img = ramp(n * 0.5 + 0.35, ["#b8c8dc", "#cfdbe8", "#e2eaf3", "#f4f8fc"])
        specks(img, rng, 5, ["#ffffff"])
    elif name == "ice":
        img = ramp(n * 0.6 + 0.2, ["#8ab8d8", "#a0cae4", "#b8daee", "#d0eaf8"])
        for _ in range(2):
            x, y = spot(rng)
            x, y = min(x, T - 12), min(y, T - 8)
            for i in range(rng.integers(4, 9)):
                put(img, x + i, y + i // 2, "#f0faff")
    elif name == "bridge":
        img = np.zeros((T, T, 3))
        for x in range(T):
            plank = x // 8
            base = hexc(["#9a6a40", "#a87648", "#8e6038", "#a27044"][plank % 4])
            img[:, x] = base * (0.92 + 0.12 * n[:, x:x + 1].mean())
            if x % 8 == 7:
                img[:, x] = hexc("#5a3a20")
        for y in (5, 26):
            for x in range(T):
                if x % 8 in (3, 4):
                    img[y, x] = hexc("#3a2a1a")
    elif name == "wood":
        img = np.zeros((T, T, 3))
        for y in range(T):
            row = y // 8
            img[y, :] = hexc(["#b07a48", "#a06c40", "#b88250", "#a87444"][row % 4])
            if y % 8 == 7:
                img[y, :] = hexc("#6a4426")
        img *= (0.94 + 0.1 * n)[..., None]
        for y in range(0, T, 8):
            xo = (y * 5) % T
            img[y:y + 7, xo] = hexc("#6a4426")
    elif name == "ash":
        img = ramp(n * 0.5 + 0.25, ["#3c3434", "#4a4040", "#584c4a", "#665856"])
        specks(img, rng, 6, ["#e06030", "#7a6a66"])
    elif name == "marsh":
        img = ramp(n * 0.55 + 0.2, ["#3c5032", "#4a5e38", "#566a40", "#64784a"])
        for _ in range(2):
            x, y = spot(rng)
            for dx in range(-2, 3):
                put(img, x + dx, y, "#3a5a5a")
                if abs(dx) < 2:
                    put(img, x + dx, y + 1, "#2e4a4a")
        tufts(img, rng, 5, "#2e4026", "#7a8a50")
    elif name == "twilight":
        img = ramp(n * 0.55 + 0.25, ["#3a3a6a", "#46467c", "#54548e", "#6464a0"])
        specks(img, rng, 4, ["#a0f0ff", "#f0c0ff"])
        tufts(img, rng, 5, "#2e2e58", "#7a7ab8")
    elif name == "canyon":
        img = ramp(n * 0.5 + 0.25, ["#a05a38", "#b46a42", "#c47a4c", "#d28a58"])
        for y in range(0, T, 11):
            img[y, :] = img[y, :] * 0.85
        pebbles(img, rng, 2, "#c88a60", "#e0a878", "#804830")
    elif name == "marble":
        img = np.zeros((T, T, 3))
        for y in range(T):
            for x in range(T):
                light = ((x // 16) + (y // 16)) % 2 == 0
                img[y, x] = hexc("#f2ece0" if light else "#d8cfc0")
        img *= (0.95 + 0.08 * n)[..., None]
        for _ in range(2):
            x, y = spot(rng)
            for i in range(rng.integers(5, 10)):
                put(img, x + i, y + (i // 3) * (1 if variant % 2 else -1), "#b8ae9e")
        img[0, :] = img[0, :] * 0.93
        img[:, 0] = img[:, 0] * 0.93
    elif name == "carpet":
        img = ramp(n * 0.3 + 0.35, ["#7a1a24", "#8a2028", "#96262e", "#a02c34"])
        for y in range(T):
            for x in range(T):
                d = abs((x % 16) - 7.5) + abs((y % 16) - 7.5)
                if 6.5 < d < 7.6:
                    img[y, x] = hexc("#c89a40")
                elif d < 1.6:
                    img[y, x] = hexc("#d8aa50")
    elif name == "lava":
        img = ramp(n * 0.7 + 0.15, ["#a02010", "#d04010", "#f07020", "#f8b040"])
        specks(img, rng, 4, ["#fff0a0"])
    else:
        img = np.zeros((T, T, 3)) + 128
    return np.clip(img, 0, 255).astype(np.uint8)


def ground_atlas(season):
    atlas = np.zeros((T * len(GROUND_ORDER), T * 4, 4), dtype=np.uint8)
    for r, name in enumerate(GROUND_ORDER):
        for v in range(4):
            atlas[r * T:(r + 1) * T, v * T:(v + 1) * T, :3] = make_tile(name, season, v)
            atlas[r * T:(r + 1) * T, v * T:(v + 1) * T, 3] = 255
    return Image.fromarray(atlas, "RGBA")


def _wave(base, harmonics, lo, hi):
    """Periodic depth along one tile edge. Sample 0 and sample T-1 are neighbors, so tiles join."""
    k = np.arange(T) * 2 * np.pi / T
    d = np.full(T, float(base))
    for amp, freq, phase in harmonics:
        d += amp * np.sin(freq * k + phase)
    return np.clip(d, lo, hi)


# Shared by every autotile of that terrain, so a long edge undulates instead of stepping.
SHORE_D = _wave(3.5, [(1.05, 1, 0.6), (0.7, 2, 2.0), (0.45, 3, 4.2), (0.28, 5, 1.1), (0.16, 8, 3.3)], 2.2, 5.6)
SOIL_D = _wave(3.3, [(1.0, 1, 0.35), (0.65, 3, 1.9), (0.4, 5, 3.7), (0.22, 8, 0.8)], 1.7, 5.4)
FRINGE_D = _wave(2.7, [(0.85, 1, 1.4), (0.55, 3, 0.5), (0.32, 5, 2.6), (0.18, 8, 4.4)], 1.5, 4.4)

# Corner order matches world.gd DIAGONALS: NE, SE, SW, NW. Each value is how far (in pixels) the
# rounded corner runs along the two shores. They differ so a pond is not the same curve four times.
# Clamped inside the tile so the far edge stays a straight shore and still meets the next tile.
WATER_CORNER_EXTRA = np.array([22.0, 16.0, 26.0, 19.0])
WATER_CORNER_PHASE = np.array([5.15, 0.55, 3.40, 1.90])
WATER_DIAG_EXTRA = np.array([13.0, 10.0, 15.0, 11.5])
WATER_VARIANTS = (
    {"scale": 0.88, "phase": 0.2, "power": 2.0},
    {"scale": 1.0, "phase": 1.7, "power": 2.0},
    {"scale": 1.06, "phase": 3.3, "power": 2.15},
    {"scale": 1.14, "phase": 4.9, "power": 1.9},
)
SOIL_OUTER_EXTRA = np.array([5.8, 3.8, 7.2, 4.6])
SOIL_OUTER_PHASE = np.array([0.5, 2.0, 3.7, 5.2])
SOIL_INNER_EXTRA = np.array([3.2, 2.0, 3.8, 2.4])
SOIL_INNER_PHASE = np.array([1.1, 2.8, 4.4, 0.2])
# A small round cap on the grass side. Larger than this and the corner sticks into the grass as a point.
FRINGE_CORNER_EXTRA = np.array([8.0, 6.0, 9.0, 7.0])
FRINGE_CORNER_PHASE = np.array([0.4, 2.1, 3.6, 5.2])
FRINGE_DIAG_EXTRA = np.array([6.2, 4.8, 7.0, 5.4])
# Sides that meet at each corner: N=0 E=1 S=2 W=3.
_CORNER_SIDES = ((0, 1), (1, 2), (2, 3), (3, 0))

# Sunlit dry bank, in the same range as path and dirt. The old #5a4a32 read as a black outline.
BANK_DARK = hexc("#9a7048")
BANK_DEEP = hexc("#b08a58")
BANK = hexc("#c6a36e")
LIP = hexc("#e4c898")
FOAM = hexc("#d4eef8")
SOIL_RIM = (hexc("#3a2818"), hexc("#2a1c12"))
SOIL_HI = (1.12, 1.08)


def _corner_uv(corner, xs, ys):
    """Distances from a tile corner, plus the depth-array index of each adjacent edge at that corner."""
    if corner == 0:  # NE
        return T - 0.5 - xs, ys + 0.5, 0, T - 1
    if corner == 1:  # SE
        return T - 0.5 - xs, T - 0.5 - ys, T - 1, T - 1
    if corner == 2:  # SW
        return xs + 0.5, T - 0.5 - ys, T - 1, 0
    return xs + 0.5, ys + 0.5, 0, 0


def _fillet(corner, depth, extra, phase, power, xs, ys):
    """Wobbly quarter-disk used by soil. Radius on each axis equals that edge's depth, so seams stay put;
    the extra radius lives in the middle of the arc and is lumpy rather than circular."""
    u, v, ui, vi = _corner_uv(corner, xs, ys)
    ang = np.clip(np.arctan2(v, np.maximum(u, 1e-6)), 0.0, np.pi / 2)
    window = np.clip(np.sin(ang * 2), 0.0, 1.0) ** power
    # Mild wobble only. A stronger lump turns the corner into a spike instead of a round.
    lumps = np.clip(1.0 + 0.18 * np.sin(ang * 2 + phase) + 0.12 * np.sin(ang * 5 + phase * 1.4), 0.78, 1.28)
    t = ang / (np.pi / 2)
    r = np.minimum((1 - t) * depth[ui] + t * depth[vi] + extra * window * lumps, 20.0)
    return np.hypot(u, v) < r


def _round_fillet(corner, depth, extra, phase, power, xs, ys):
    """Quarter-ellipse that meets both straight shores on a tangent, so a pond corner is a curve.

    `extra` is how far the curve runs along each edge. The wobble is zero at both ends of the
    arc, so it never steps away from the straight shore or reaches the far tile seam.
    """
    u, v, ui, vi = _corner_uv(corner, xs, ys)
    du = depth[ui]
    dv = depth[vi]
    ru = np.minimum(np.maximum(float(extra), du + 2.0), 26.0)
    rv = np.minimum(np.maximum(float(extra), dv + 2.0), 26.0)
    in_corner = (u < ru) & (v < rv)
    eu = max(ru - float(du), 1.0)
    ev = max(rv - float(dv), 1.0)
    x = np.clip(ru - u, 0.0, None)
    y = np.clip(rv - v, 0.0, None)
    ang = np.arctan2(y, np.maximum(x, 1e-6))
    # sin(2*ang) is 0 at both ends of the quarter-arc. Phase only changes how strong the wobble is.
    amp = 0.05 + 0.04 * (0.5 + 0.5 * np.sin(phase))
    wob = 1.0 + amp * np.sin(ang * 2.0)
    n = 2.0 if power < 1.5 or power > 2.4 else power
    nx = x / (eu * wob)
    ny = y / (ev * wob)
    outside = np.power(nx, n) + np.power(ny, n) >= 0.96
    return in_corner & outside


def _side_bands(depth, sides_mask):
    """Straight shore strips. Bits are N E S W."""
    ys, xs = np.mgrid[0:T, 0:T]
    xf, yf = xs.astype(np.float64), ys.astype(np.float64)
    bands = (
        yf + 0.5 < depth[xs],
        (T - xf) - 0.5 < depth[ys],
        (T - yf) - 0.5 < depth[xs],
        xf + 0.5 < depth[ys],
    )
    on = np.zeros((T, T), dtype=bool)
    for i in range(4):
        if sides_mask & (1 << i):
            on |= bands[i]
    return on


def _coverage(depth, sides_mask, corners_mask, side_extra, side_phase, corner_extra, corner_phase, power=1.0, rounded=False):
    """Pixels a shore or a cut occupies. `sides_mask` bits are N E S W. `corners_mask` bits are
    diagonal-only contacts (NE SE SW NW), used when the two adjacent sides are not both set."""
    ys, xs = np.mgrid[0:T, 0:T]
    xf, yf = xs.astype(np.float64), ys.astype(np.float64)
    on = _side_bands(depth, sides_mask)
    fillet = _round_fillet if rounded else _fillet
    for c, (a, b) in enumerate(_CORNER_SIDES):
        if (sides_mask & (1 << a)) and (sides_mask & (1 << b)):
            on |= fillet(c, depth, side_extra[c], side_phase[c], power, xf, yf)
        elif corners_mask & (1 << c):
            on |= fillet(c, depth, corner_extra[c], corner_phase[c], power if rounded else 1.0, xf, yf)
    return on


def _dist_inside(mask):
    """How many steps a covered pixel is from the nearest uncovered one. Outside the tile does not count."""
    d = np.where(mask, np.int16(99), np.int16(0))
    for _ in range(14):
        p = np.pad(d, 1, constant_values=99)
        neigh = (
            p[:-2, 1:-1], p[2:, 1:-1], p[1:-1, :-2], p[1:-1, 2:],
            p[:-2, :-2], p[:-2, 2:], p[2:, :-2], p[2:, 2:],
        )
        d = np.where(mask, np.minimum(d, np.minimum.reduce(neigh) + 1), 0)
    return d


def _corner_boxes(depth, sides_mask, corners_mask, side_extra, corner_extra):
    """Pixels inside a rounded corner. Empty on a straight shore, so those edges stay a full bank."""
    ys, xs = np.mgrid[0:T, 0:T]
    xf, yf = xs.astype(np.float64), ys.astype(np.float64)
    boxes = np.zeros((T, T), dtype=bool)
    for c, (a, b) in enumerate(_CORNER_SIDES):
        if (sides_mask & (1 << a)) and (sides_mask & (1 << b)):
            extra = float(side_extra[c])
        elif corners_mask & (1 << c):
            extra = float(corner_extra[c])
        else:
            continue
        u, v, ui, vi = _corner_uv(c, xf, yf)
        du = float(depth[ui])
        dv = float(depth[vi])
        ru = min(max(extra, du + 2.0), 26.0)
        rv = min(max(extra, dv + 2.0), 26.0)
        boxes |= (u < ru) & (v < rv)
    return boxes


def _shore_parts(mask, boxes):
    """Bank is a ribbon along the water. Farther out, inside a corner, the land color shows through."""
    if boxes is None or not mask.any() or not np.any(boxes):
        return mask, np.zeros(mask.shape, dtype=bool)
    d = _dist_inside(mask)
    cap = mask & boxes & (d >= 5)
    return mask & ~cap, cap


def _paint_shore(mask, boxes=None):
    """Foam along the waterline only. The shore body is the neighbor's ground, drawn as a cap."""
    del boxes
    tile = np.zeros((T, T, 4), dtype=np.uint8)
    if not mask.any():
        return tile
    ys, xs = np.mgrid[0:T, 0:T]
    d = _dist_inside(mask)
    wave = np.sin(xs * 2 * np.pi / T * 2 + 0.4) * 0.55 + np.sin(ys * 2 * np.pi / T * 3 + 1.2) * 0.45
    foam = (d == 1) & (wave > 0.05)
    tile[foam, :3] = FOAM.astype(np.uint8)
    tile[foam, 3] = 210
    water = ~mask
    wp = np.pad(mask, 1, constant_values=False)
    adj = wp[:-2, 1:-1] | wp[2:, 1:-1] | wp[1:-1, :-2] | wp[1:-1, 2:]
    spark = water & adj & (np.sin(xs * 2 * np.pi / T * 5 + ys * 2 * np.pi / T * 3 + 2.0) > 0.45)
    tile[spark, :3] = FOAM.astype(np.uint8)
    tile[spark, 3] = 150
    return tile


def _paint_fringe(mask):
    """Shallow dirt spill onto a land tile. The ragged lip faces the grass; the tile border
    matches the water overlay's bank."""
    tile = np.zeros((T, T, 4), dtype=np.uint8)
    if not mask.any():
        return tile
    ys, xs = np.mgrid[0:T, 0:T]
    pad = np.pad(mask, 1, constant_values=True)
    interior = pad[:-2, 1:-1] & pad[2:, 1:-1] & pad[1:-1, :-2] & pad[1:-1, 2:]
    rim = mask & ~interior
    tile[mask, :3] = BANK.astype(np.uint8)
    tile[mask, 3] = 255
    tile[rim, :3] = LIP.astype(np.uint8)
    border = np.zeros((T, T), dtype=bool)
    border[0, :] = border[-1, :] = border[:, 0] = border[:, -1] = True
    tile[mask & border, :3] = BANK.astype(np.uint8)
    below = np.zeros_like(mask)
    below[1:, :] = mask[:-1, :] & ~mask[1:, :]
    below &= ~border
    tile[below, :3] = np.array([120, 96, 64], dtype=np.uint8)
    tile[below, 3] = 40
    crumbs = ~mask & ~border & ~below
    cp = np.pad(mask, 1, constant_values=False)
    adj = cp[:-2, 1:-1] | cp[2:, 1:-1] | cp[1:-1, :-2] | cp[1:-1, 2:]
    crumbs &= adj & (((xs * 5 + ys * 3) % 3) == 0)
    tile[crumbs, :3] = LIP.astype(np.uint8)
    tile[crumbs, 3] = 140
    return tile


def _water_mask(sides, corners, variant):
    v = WATER_VARIANTS[variant]
    extra = WATER_CORNER_EXTRA * v["scale"]
    phase = WATER_CORNER_PHASE + v["phase"]
    return _coverage(SHORE_D, sides, corners, extra, phase, WATER_DIAG_EXTRA, WATER_CORNER_PHASE + v["phase"], v["power"], True)


def _water_boxes(sides, corners, variant):
    v = WATER_VARIANTS[variant]
    extra = WATER_CORNER_EXTRA * v["scale"]
    return _corner_boxes(SHORE_D, sides, corners, extra, WATER_DIAG_EXTRA)


def _water_tile(sides, corners, variant):
    return _paint_shore(_water_mask(sides, corners, variant), _water_boxes(sides, corners, variant))


# Row blocks in shore_cap_<season>.png. Neighbors that are not listed fall back to grass.
CAP_TERRAINS = ["grass", "darkgrass", "sand", "dirt", "marsh", "canyon", "cave"]


def _cap_tile(sides, corners, variant, fill):
    """The whole shore, in the neighboring ground color, so grass meets grass instead of a dark ring."""
    mask = _water_mask(sides, corners, variant)
    tile = np.zeros((T, T, 4), dtype=np.uint8)
    if mask.any():
        tile[mask, :3] = fill[mask]
        tile[mask, 3] = 255
    return tile


def _fringe_tile(sides, corners):
    mask = _coverage(FRINGE_D, sides, corners, FRINGE_CORNER_EXTRA, FRINGE_CORNER_PHASE, FRINGE_DIAG_EXTRA, FRINGE_CORNER_PHASE, 2.0, True)
    return _paint_fringe(mask)


def _soil_alpha(connected, inner_corners):
    """`connected` bits are tilled neighbors. Open sides and the two kinds of corner eat into the tile."""
    open_sides = (~np.uint8(connected)) & 15
    cut = _coverage(SOIL_D, int(open_sides), inner_corners, SOIL_OUTER_EXTRA, SOIL_OUTER_PHASE, SOIL_INNER_EXTRA, SOIL_INNER_PHASE, 1.0)
    return ~cut


def soil_atlas():
    """Tilled soil. Column = connected-neighbor mask. Row = inner-corner mask, plus 16 when watered."""
    out = np.zeros((T * 32, T * 16, 4), dtype=np.uint8)
    alphas = [[_soil_alpha(m, c) for m in range(16)] for c in range(16)]
    for wet in (0, 1):
        rng = np.random.default_rng(77 + wet)
        n = fbm(rng)
        cols = ["#5a3a24", "#6a4630", "#7a523a", "#86603f"] if not wet else ["#3a2418", "#462c1e", "#523426", "#5c3c2c"]
        base = ramp(n * 0.5 + 0.25, cols)
        for y in range(3, T, 8):
            for x in range(T):
                if (x * 7 + y * 3) % 5:
                    base[y, x] = hexc(cols[0])
                    base[y + 1, x] = hexc(cols[3]) if (x % 3) else base[y + 1, x]
        rim = SOIL_RIM[wet]
        hi = SOIL_HI[wet]
        for c in range(16):
            for m in range(16):
                alpha = alphas[c][m]
                tile = np.zeros((T, T, 4), dtype=np.uint8)
                tile[alpha, :3] = base[alpha].astype(np.uint8)
                tile[alpha, 3] = 255
                # Outside the tile counts as soil, so a side that connects to the next plot
                # stays the plain furrow color and the seam disappears. The lip only appears
                # where this tile actually gives way to grass.
                pad = np.pad(alpha, 1, constant_values=True)
                top = alpha & ~pad[:-2, 1:-1]
                bottom = alpha & ~pad[2:, 1:-1]
                west = alpha & ~pad[1:-1, :-2]
                east = alpha & ~pad[1:-1, 2:]
                rim_px = top | bottom | west | east
                tile[rim_px, :3] = np.clip(base[rim_px] * 0.84, 0, 255).astype(np.uint8)
                tile[bottom | east, :3] = rim.astype(np.uint8)
                tile[top, :3] = np.clip(base[top] * hi, 0, 255).astype(np.uint8)
                below = np.zeros_like(alpha)
                below[1:, :] = alpha[:-1, :] & ~alpha[1:, :]
                tile[below, :3] = rim.astype(np.uint8)
                tile[below, 3] = 60
                ys, xs = np.mgrid[0:T, 0:T]
                cp = np.pad(alpha, 1, constant_values=False)
                adj = cp[:-2, 1:-1] | cp[2:, 1:-1] | cp[1:-1, :-2] | cp[1:-1, 2:]
                crumbs = ~alpha & adj & ~below & (((xs * 5 + ys * 3) % 3) == 0)
                tile[crumbs, :3] = base[crumbs].astype(np.uint8)
                tile[crumbs, 3] = 145
                out[(wet * 16 + c) * T:(wet * 16 + c + 1) * T, m * T:(m + 1) * T] = tile
    return Image.fromarray(out, "RGBA")


def water_edges():
    """16 side-masks by 64 rows (16 diagonal masks x 4 corner variants)."""
    out = np.zeros((T * 64, T * 16, 4), dtype=np.uint8)
    for v in range(4):
        for c in range(16):
            for m in range(16):
                tile = _water_tile(m, c, v)
                row = v * 16 + c
                out[row * T:(row + 1) * T, m * T:(m + 1) * T] = tile
    return Image.fromarray(out, "RGBA")


def shore_caps(season):
    """Neighbor ground color for every shore, including straight edges. One 64-row block per terrain."""
    fills = [make_tile(name, season, 0, True) for name in CAP_TERRAINS]
    out = np.zeros((T * 64 * len(CAP_TERRAINS), T * 16, 4), dtype=np.uint8)
    for ti, fill in enumerate(fills):
        for v in range(4):
            for c in range(16):
                for m in range(16):
                    if m == 0 and c == 0:
                        continue
                    tile = _cap_tile(m, c, v, fill)
                    row = ti * 64 + v * 16 + c
                    out[row * T:(row + 1) * T, m * T:(m + 1) * T] = tile
    return Image.fromarray(out, "RGBA")


def shore_fringe():
    """Dirt reaching from the water onto the neighboring land tile. 16 x 16, same bit order as grass edges."""
    out = np.zeros((T * 16, T * 16, 4), dtype=np.uint8)
    for c in range(16):
        for m in range(16):
            out[c * T:(c + 1) * T, m * T:(m + 1) * T] = _fringe_tile(m, c)
    return Image.fromarray(out, "RGBA")


def _check_tile_seams():
    """Straight shores must survive corner variants, and a corner fillet must not reach the far seam."""
    north = [_water_tile(1, 0, v) for v in range(4)]
    for v in range(1, 4):
        if not np.array_equal(north[0], north[v]):
            raise SystemExit("water variant changed a straight shore")
    corner = _water_tile(1 | 8, 0, 3)  # largest NW fillet
    if not np.array_equal(corner[:, 31], north[0][:, 31]):
        raise SystemExit("NW water fillet reached the east seam")
    west = _water_tile(8, 0, 0)
    if not np.array_equal(corner[31, :], west[31, :]):
        raise SystemExit("NW water fillet reached the south seam")
    ne = _water_tile(1 | 2, 0, 2)
    if not np.array_equal(ne[:, 0], north[0][:, 0]):
        raise SystemExit("NE water fillet reached the west seam")
    if np.array_equal(_water_tile(1 | 2, 0, 0), _water_tile(1 | 2, 0, 3)):
        raise SystemExit("water corner variants are identical")
    soil_n = _soil_alpha(2 | 4 | 8, 0)  # only north open
    soil_nw = _soil_alpha(2 | 4, 0)  # north and west open
    if not np.array_equal(soil_n[:, 31], soil_nw[:, 31]):
        raise SystemExit("soil corner cut reached the east seam")
    if soil_nw[16, 16] != True or soil_n[0, 16] != False:
        raise SystemExit("soil mask ate the middle or missed the open edge")


def grass_edges(season):
    """Grass creeping a few ragged pixels onto bare ground (path, dirt, sand, plaza...).

    The fill reuses the grass tiles' shared noise, so it continues the neighboring grass without a seam,
    and the ragged depth profile is periodic per tile, so fringes on adjacent tiles join up.
    """
    g = GRASS[season]
    shared = fbm(np.random.default_rng(zlib.crc32(f"grass:{season}".encode())))
    fill = ramp(shared * 0.55 + 0.25, g)
    k = np.arange(T) * 2 * np.pi / T
    depth = 2.8 + 0.9 * np.sin(k + 0.6) + 0.8 * np.sin(3 * k + 2.1) + 0.6 * np.sin(5 * k + 4.0) + 0.5 * np.sin(8 * k + 1.3)
    ys, xs = np.mgrid[0:T, 0:T]
    sides = [ys < depth[xs], (T - 1 - xs) < depth[ys], (T - 1 - ys) < depth[xs], xs < depth[ys]]
    r = depth[0] + 0.6
    corners = [np.hypot(T - 0.5 - xs, ys + 0.5) < r, np.hypot(T - 0.5 - xs, T - 0.5 - ys) < r,
               np.hypot(xs + 0.5, T - 0.5 - ys) < r, np.hypot(xs + 0.5, ys + 0.5) < r]
    rim, shade = hexc(g[0]) * 0.92, np.array([24, 30, 18])
    out = np.zeros((T * 16, T * 16, 4), dtype=np.uint8)
    for cm in range(16):
        for em in range(16):
            on = np.zeros((T, T), dtype=bool)
            for i in range(4):
                if em & (1 << i):
                    on |= sides[i]
                if cm & (1 << i):
                    on |= corners[i]
            if not on.any():
                continue
            # Neighbors outside the tile count as grass so the rim only traces the ragged inner edge.
            pad = np.pad(on, 1, constant_values=True)
            interior = pad[:-2, 1:-1] & pad[2:, 1:-1] & pad[1:-1, :-2] & pad[1:-1, 2:]
            edge = on & ~interior
            below = np.zeros_like(on)
            below[1:, :] = on[:-1, :] & ~on[1:, :]
            tile = np.zeros((T, T, 4))
            tile[on, :3] = fill[on]
            tile[on, 3] = 255
            tile[edge, :3] = rim
            tile[below, :3] = shade
            tile[below, 3] = 70
            out[cm * T:(cm + 1) * T, em * T:(em + 1) * T] = np.clip(tile, 0, 255).astype(np.uint8)
    return Image.fromarray(out, "RGBA")


def wall(top, face, dark, rim, seed):
    rng = np.random.default_rng(seed)
    h = 48
    img = np.zeros((h, T, 4), dtype=np.uint8)
    n = fbm(rng)
    big = np.vstack([n, n[:16]])
    face_img = ramp(big * 0.6 + 0.2, face)
    for y in range(16, h, 9):
        face_img[y, :] = hexc(face[0])
    img[..., :3] = face_img.astype(np.uint8)
    img[..., 3] = 255
    top_img = ramp(n[:14] * 0.5 + 0.25, top)
    img[:14, :, :3] = top_img.astype(np.uint8)
    img[14:16, :, :3] = hexc(rim).astype(np.uint8)
    img[h - 2:, :, :3] = hexc(dark).astype(np.uint8)
    return Image.fromarray(img, "RGBA")


def wallpaper():
    """Casino interior wall: burgundy top, cream and gold striped wallpaper, dark wood wainscot."""
    h = 48
    img = np.zeros((h, T, 4), dtype=np.uint8)
    img[..., 3] = 255
    for x in range(T):
        stripe = (x // 4) % 2 == 0
        img[16:h, x, :3] = hexc("#efe2c4" if stripe else "#e2cf9e")
        if x % 8 == 2:
            for y in range(20, 34, 5):
                img[y, x, :3] = hexc("#c89a40")
    img[:14, :, :3] = hexc("#6a1e28")
    img[2:12, 2:30, :3] = hexc("#7a2630")
    img[14:16, :, :3] = hexc("#c89a40")
    img[34:36, :, :3] = hexc("#c89a40")
    img[36:h, :, :3] = hexc("#6a4426")
    for x in range(0, T, 8):
        img[38:h - 3, x + 3, :3] = hexc("#55361e")
    img[h - 2:, :, :3] = hexc("#2a1a12")
    return Image.fromarray(img, "RGBA")


MINE_BLOCKS = {
    "block_dirt": (["#8a6444", "#9a7250", "#a8805c"], ["#5a3e2a", "#6a4a32", "#7a5638", "#885f40"], "#2e2016", "#b08a62", 11),
    "block_stone": (["#7c7688", "#8a8496", "#9892a4"], ["#4e4a5a", "#5a5666", "#686474", "#747082"], "#24202c", "#a8a2b4", 12),
    "block_deep": (["#4a4a66", "#56567a", "#62628a"], ["#2e2e44", "#383852", "#42425e", "#4c4c6a"], "#14141e", "#7070a0", 13),
    "block_basalt": (["#4a4246", "#564c50", "#62585c"], ["#2a2426", "#342c30", "#3e363a", "#4a4044"], "#120e10", "#7a3a2a", 14),
    "block_obsidian": (["#2a2040", "#34284e", "#40325e"], ["#16101e", "#1e1628", "#281e36", "#342848"], "#08060c", "#8a6ad0", 15),
}


def mine_blocks(world):
    for name, spec in MINE_BLOCKS.items():
        wall(*spec).save(os.path.join(world, f"{name}.png"))
    fossil = np.array(wall(*MINE_BLOCKS["block_stone"]))
    bone = hexc("#e8dcc0")
    shade = hexc("#a89878")
    cx, cy = 16, 31
    for i in range(70):
        a = i * 0.32
        r = 1.0 + i * 0.11
        x, y = int(round(cx + np.cos(a) * r)), int(round(cy + np.sin(a) * r * 0.8))
        if 0 <= x < T and 17 <= y < 46:
            fossil[y, x, :3] = bone if i % 9 else shade
    Image.fromarray(fossil, "RGBA").save(os.path.join(world, "block_fossil.png"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    args = ap.parse_args()
    out = os.path.join(args.root, "game/assets/tiles")
    world = os.path.join(args.root, "game/assets/world")
    os.makedirs(out, exist_ok=True)
    _check_tile_seams()
    for s in SEASONS:
        ground_atlas(s).save(os.path.join(out, f"ground_{s}.png"))
        grass_edges(s).save(os.path.join(out, f"grass_edge_{s}.png"))
    soil_atlas().save(os.path.join(out, "soil.png"))
    water_edges().save(os.path.join(out, "water_edge.png"))
    for s in SEASONS:
        shore_caps(s).save(os.path.join(out, f"shore_cap_{s}.png"))
    shore_fringe().save(os.path.join(out, "shore_fringe.png"))
    wall(GRASS["summer"], ["#6a5a4a", "#7c6a56", "#8c7a62", "#9a8870"], "#3a2e24", "#4a6a32", 5).save(os.path.join(world, "cliff.png"))
    wall(["#3a3240", "#463c4c", "#524658"], ["#2a2430", "#363040", "#433b4e", "#4e465a"], "#16121c", "#5e5264", 6).save(os.path.join(world, "cavewall.png"))
    mine_blocks(world)
    wallpaper().save(os.path.join(world, "wallpaper.png"))
    print("tiles written to", out)


if __name__ == "__main__":
    main()
