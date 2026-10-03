#!/usr/bin/env python3
"""Procedural, seamless 32x32 ground tiles for Hollowmere, with seasonal variants.

Outputs (in game/assets/tiles/):
  ground_<season>.png   4 variant columns x 20 rows (row = ground tile id, see core/world/tiles.gd)
  soil.png              16 columns (4-bit neighbor mask N=1 E=2 S=4 W=8) x 2 rows (dry, watered)
  water_edge.png        16 columns of edge overlays drawn over water (mask = sides that face land)
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
                "flowers", "ash", "marsh", "twilight", "canyon", "lava", "wood", "darkgrass", "deepwater"]
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


def make_tile(name, season, variant):
    rng = np.random.default_rng(zlib.crc32(f"{name}:{season}:{variant}".encode()))
    shared = fbm(np.random.default_rng(zlib.crc32(f"{name}:{season}".encode())))
    n = shared + (fbm(rng) - shared) * EDGE_W
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


def soil_atlas():
    """Tilled soil autotile. Mask bit set => neighbor in that direction is also tilled."""
    out = np.zeros((T * 2, T * 16, 4), dtype=np.uint8)
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
        for m in range(16):
            tile = np.zeros((T, T, 4), dtype=np.uint8)
            tile[..., :3] = base.astype(np.uint8)
            tile[..., 3] = 255
            inset = 2
            alpha = np.ones((T, T), dtype=bool)
            if not m & 1:
                alpha[:inset, :] = False
            if not m & 2:
                alpha[:, T - inset:] = False
            if not m & 4:
                alpha[T - inset:, :] = False
            if not m & 8:
                alpha[:, :inset] = False
            edge = alpha.copy()
            inner = alpha.copy()
            inner[1:, :] &= alpha[:-1, :]
            inner[:-1, :] &= alpha[1:, :]
            inner[:, 1:] &= alpha[:, :-1]
            inner[:, :-1] &= alpha[:, 1:]
            border = edge & ~inner
            for (ok, sl) in ((m & 1, np.s_[0, :]), (m & 2, np.s_[:, T - 1]), (m & 4, np.s_[T - 1, :]), (m & 8, np.s_[:, 0])):
                if ok:
                    border[sl] = False
            tile[border, :3] = hexc("#2e1c12").astype(np.uint8)
            hi = inner.copy()
            hi[1:, :] = inner[1:, :] & ~inner[:-1, :]
            hi[0, :] = False
            tile[hi & ~border, :3] = np.clip(base[hi & ~border] * 1.18, 0, 255).astype(np.uint8)
            tile[..., 3] = np.where(alpha, 255, 0)
            out[wet * T:(wet + 1) * T, m * T:(m + 1) * T] = tile
    return Image.fromarray(out, "RGBA")


def water_edges():
    """Overlay for water tiles; mask bit set => that side borders land (N=1 E=2 S=4 W=8)."""
    out = np.zeros((T, T * 16, 4), dtype=np.uint8)
    bank, lip, foam = hexc("#5a4a32"), hexc("#7a6444"), hexc("#d8f0fa")
    for m in range(16):
        tile = np.zeros((T, T, 4), dtype=np.uint8)
        for side in range(4):
            if not m & (1 << side):
                continue
            for d, col in ((0, bank), (1, bank), (2, lip), (3, foam)):
                if side == 0:
                    sl = np.s_[d, :]
                elif side == 1:
                    sl = np.s_[:, T - 1 - d]
                elif side == 2:
                    sl = np.s_[T - 1 - d, :]
                else:
                    sl = np.s_[:, d]
                if col is foam:
                    seg = tile[sl]
                    keep = np.arange(T) % 5 != 0
                    seg[keep & (seg[..., 3] == 0), :3] = col.astype(np.uint8)
                    seg[keep & (seg[..., 3] == 0), 3] = 200
                    tile[sl] = seg
                else:
                    tile[sl] = np.append(col, 255).astype(np.uint8)
        out[:, m * T:(m + 1) * T] = tile
    return Image.fromarray(out, "RGBA")


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


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    args = ap.parse_args()
    out = os.path.join(args.root, "game/assets/tiles")
    world = os.path.join(args.root, "game/assets/world")
    os.makedirs(out, exist_ok=True)
    for s in SEASONS:
        ground_atlas(s).save(os.path.join(out, f"ground_{s}.png"))
        grass_edges(s).save(os.path.join(out, f"grass_edge_{s}.png"))
    soil_atlas().save(os.path.join(out, "soil.png"))
    water_edges().save(os.path.join(out, "water_edge.png"))
    wall(GRASS["summer"], ["#6a5a4a", "#7c6a56", "#8c7a62", "#9a8870"], "#3a2e24", "#4a6a32", 5).save(os.path.join(world, "cliff.png"))
    wall(["#3a3240", "#463c4c", "#524658"], ["#2a2430", "#363040", "#433b4e", "#4e465a"], "#16121c", "#5e5264", 6).save(os.path.join(world, "cavewall.png"))
    print("tiles written to", out)


if __name__ == "__main__":
    main()
