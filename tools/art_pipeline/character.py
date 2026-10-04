#!/usr/bin/env python3
"""Procedural paper-doll character sheets for Hollowmere.

Every layer is grayscale (light 240 / mid 196 / shade 150 / outline 70) so Godot can tint it
with `modulate` (multiply) - one sheet serves every skin, hair and outfit color.
Sheet layout: 15 columns (idle, walk0..3, tool0..1, then the emote poses cheer, wave0..1, bow, sit, doze, clap, palm) x 3 rows (down, up, side-facing-right). Frames are 32x48.

Outputs game/assets/characters/{body,face,shirt,pants,shoes,pack,hair_<style>,hat_<style>}.png
"""
import argparse
import os

import numpy as np
from PIL import Image

FW, FH = 32, 48
LIGHT, MID, SHADE, LINE = 240, 196, 150, 70
DIRS = ["down", "up", "side"]
FRAMES = ["idle", "walk0", "walk1", "walk2", "walk3", "tool0", "tool1", "cheer", "wave0", "wave1", "bow", "sit", "doze", "clap", "palm"]
HAIR = ["short", "long", "ponytail", "spiky", "bob", "buzz", "curly", "bun"]
HATS = ["cap", "straw", "top", "crown", "flowers", "beret", "visor", "fedora"]


class Layer:
    def __init__(self):
        self.v = np.zeros((FH, FW), dtype=np.int32)

    def rect(self, x0, y0, x1, y1, shade=True):
        for y in range(max(0, y0), min(FH, y1 + 1)):
            for x in range(max(0, x0), min(FW, x1 + 1)):
                c = MID
                if shade:
                    if x == x0 or y == y0:
                        c = LIGHT
                    elif x == x1 or y == y1:
                        c = SHADE
                self.v[y, x] = c

    def ellipse(self, cx, cy, rx, ry, clip=None, rim=False):
        """rim: shade only the outer edge (faces), so no dark band crosses the middle."""
        for y in range(FH):
            for x in range(FW):
                d = ((x + 0.5 - cx) / rx) ** 2 + ((y + 0.5 - cy) / ry) ** 2
                if d <= 1 and (clip is None or clip(x, y)):
                    lx, ly = (x + 0.5 - cx) / rx, (y + 0.5 - cy) / ry
                    light = -0.6 * lx - 0.8 * ly
                    dark = light < -0.45 and (not rim or d > 0.62)
                    self.v[y, x] = LIGHT if light > (0.6 if rim else 0.45) else (SHADE if dark else MID)

    def px(self, x, y, c=MID):
        if 0 <= x < FW and 0 <= y < FH:
            self.v[y, x] = c

    def erase(self, x0, y0, x1, y1):
        self.v[max(0, y0):y1 + 1, max(0, x0):x1 + 1] = 0

    def raw(self):
        out = np.zeros((FH, FW, 4), dtype=np.uint8)
        g = self.v.clip(0, 255).astype(np.uint8)
        out[..., 0] = out[..., 1] = out[..., 2] = g
        out[..., 3] = np.where(self.v > 0, 255, 0)
        return out

    def outlined(self):
        out = np.zeros((FH, FW, 4), dtype=np.uint8)
        filled = self.v > 0
        edge = np.zeros_like(filled)
        edge[1:, :] |= filled[:-1, :]
        edge[:-1, :] |= filled[1:, :]
        edge[:, 1:] |= filled[:, :-1]
        edge[:, :-1] |= filled[:, 1:]
        edge &= ~filled
        g = np.where(filled, self.v, np.where(edge, LINE, 0)).astype(np.uint8)
        out[..., 0] = out[..., 1] = out[..., 2] = g
        out[..., 3] = np.where(filled | edge, 255, 0)
        return out


def hand_on_face(lay, x0, y0, x1, y1):
    """A hand over skin needs its own outline; the layer outline only traces the silhouette."""
    lay.rect(x0, y0, x1, y1)
    for x in range(x0, x1 + 1):
        lay.px(x, y0 - 1, LINE)
        lay.px(x, y1 + 1, LINE)
    for y in range(y0, y1 + 1):
        lay.px(x0 - 1, y, LINE)


def frame(direction, fr):
    L = {k: Layer() for k in ["body", "face", "shirt", "pants", "shoes", "pack"] + [f"hair_{h}" for h in HAIR] + [f"hat_{h}" for h in HATS]}
    walk = fr.startswith("walk")
    step = int(fr[-1]) if walk else -1
    tool = fr.startswith("tool")
    bob = -1 if step in (1, 3) else 0
    lf = {0: -2, 2: 1}.get(step, 0)
    rf = {0: 1, 2: -2}.get(step, 0)
    arm_l = {0: 1, 2: -1}.get(step, 0)
    arm_r = -arm_l
    if tool:
        arm_l = arm_r = -5 if fr == "tool0" else 2
    seated = fr in ("sit", "doze")
    drop = 7 if seated else 0
    hy = 18 + bob + drop + (3 if fr == "bow" else 0)
    ty = 27 + bob + drop
    side = direction == "side"
    up = direction == "up"
    late = []

    # legs + shoes
    if seated:
        if side:
            L["pants"].rect(12, ty + 8, 26, ty + 11)
            L["shoes"].rect(26, ty + 7, 28, ty + 11, shade=False)
        else:
            L["pants"].rect(9, ty + 8, 22, ty + 11)
            if not up:
                L["shoes"].rect(8, ty + 11, 12, ty + 12, shade=False)
                L["shoes"].rect(19, ty + 11, 23, ty + 12, shade=False)
    elif side:
        back = 15 + (lf // 2)
        front = 15 - (lf // 2)
        L["pants"].rect(back - 1, ty + 9, back + 2, 43 + min(0, rf))
        L["shoes"].rect(back - 1, 44 + min(0, rf), back + 3, 45 + min(0, rf), shade=False)
        L["pants"].rect(front - 1, ty + 9, front + 2, 43 + min(0, lf))
        L["shoes"].rect(front - 1, 44 + min(0, lf), front + 3, 45 + min(0, lf), shade=False)
    else:
        L["pants"].rect(11, ty + 9, 14, 43 + lf)
        L["pants"].rect(17, ty + 9, 20, 43 + rf)
        L["shoes"].rect(10, 44 + lf, 14, 45 + lf, shade=False)
        L["shoes"].rect(17, 44 + rf, 21, 45 + rf, shade=False)

    # torso + arms
    if side:
        L["shirt"].rect(12, ty, 20, ty + 10)
        L["pants"].rect(12, ty + 8, 20, ty + 10)
        if fr in ("cheer", "wave0", "wave1"):
            reach = 2 if fr == "wave1" else 0
            L["shirt"].rect(19, ty, 23, ty + 2)
            L["shirt"].rect(23 + reach // 2, ty - 10 + reach, 25 + reach // 2, ty + 1)
            L["body"].rect(24 + reach, ty - 13 + reach, 26 + reach, ty - 11 + reach)
        elif fr == "clap":
            L["shirt"].rect(16, ty + 2, 21, ty + 4)
            L["body"].rect(22, ty + 1, 24, ty + 4)
        elif fr == "palm":
            L["shirt"].rect(18, ty - 2, 21, ty + 3)
            late.append(lambda: hand_on_face(L["body"], 20, hy, 24, hy + 3))
        else:
            ay = ty + 1 + arm_l
            ax = 15 + (2 if tool and fr == "tool1" else 0)
            L["shirt"].rect(ax, ay, ax + 3, ay + 5)
            L["body"].rect(ax, ay + 6, ax + 3, ay + 8)
    else:
        L["shirt"].rect(10, ty, 21, ty + 10)
        L["pants"].rect(10, ty + 8, 21, ty + 10)
        raised = {"cheer": (True, True), "wave0": (False, True), "wave1": (False, True)}.get(fr, (False, False))
        if up:
            raised = (raised[1], raised[0])
        for i, (ax, off) in enumerate(((7, arm_l), (22, arm_r))):
            right = i == 1
            if raised[i]:
                tilt = (2 if right else -2) if fr == "wave1" else 0
                sx = 25 if right else 4
                L["shirt"].rect(22 if right else 6, ty, 25 if right else 9, ty + 2)
                L["shirt"].rect(sx + tilt // 2, ty - 10 + abs(tilt), sx + 2 + tilt // 2, ty + 1)
                L["body"].rect(sx + tilt, ty - 13 + abs(tilt), sx + 2 + tilt, ty - 11 + abs(tilt))
            elif fr == "clap":
                L["shirt"].rect(8 if not right else 21, ty + 1, 10 if not right else 23, ty + 5)
                if not up:
                    L["body"].rect(12 if not right else 16, ty + 4, 15 if not right else 19, ty + 6)
            elif fr == "palm" and right != up:
                L["shirt"].rect(21 if right else 8, ty - 3, 23 if right else 10, ty + 3)
                if not up:
                    late.append(lambda: hand_on_face(L["body"], 17, hy, 21, hy + 3))
            else:
                L["shirt"].rect(ax, ty + 1 + off, ax + 2, ty + 5 + off)
                L["body"].rect(ax, ty + 6 + off, ax + 2, ty + 8 + off)

    # backpack: full pack from behind, a side profile, straps from the front
    if direction == "up":
        L["pack"].rect(10, ty - 1, 21, ty + 9)
        L["pack"].rect(12, ty + 4, 19, ty + 7)
    elif side:
        L["pack"].rect(7, ty, 11, ty + 9)
    else:
        L["pack"].rect(11, ty, 12, ty + 6, shade=False)
        L["pack"].rect(19, ty, 20, ty + 6, shade=False)

    # head
    L["body"].ellipse(16, hy, 8.5, 8.2, rim=True)
    if side:
        L["body"].px(24, hy + 1, MID)
    for draw in late:
        draw()
    # face
    shut = fr in ("bow", "doze")
    if direction == "down":
        for ex in (12, 18):
            if fr == "palm" and ex == 18:
                continue
            if shut:
                L["face"].v[hy + 2, ex:ex + 2] = 40
                continue
            L["face"].rect(ex, hy + 1, ex + 1, hy + 2, shade=False)
            L["face"].v[hy + 1:hy + 3, ex:ex + 2] = 40
            L["face"].px(ex + 1, hy + 1, 250)
    elif side and fr != "palm":
        if shut:
            L["face"].v[hy + 2, 20:22] = 40
        else:
            L["face"].v[hy + 1:hy + 3, 20:22] = 40
            L["face"].px(21, hy + 1, 250)

    # hair styles
    top = hy - 8
    for h in HAIR:
        lay = L[f"hair_{h}"]
        if h == "buzz":
            lay.ellipse(16, hy - 1, 8.6, 7.6, clip=lambda x, y: y <= hy - 4)
            continue
        cover = (lambda x, y: y <= hy - 2) if direction != "up" else (lambda x, y: y <= hy + 6)
        lay.ellipse(16, hy - 1, 9.2, 8.4, clip=cover)
        if direction == "down":
            lay.erase(11, hy - 3, 20, hy - 2)
            for x in range(9, 23, 3):
                lay.px(x, hy - 2, MID)
                lay.px(x + 1, hy - 2, SHADE)
        if side:
            lay.erase(20, hy - 3, 26, hy - 1)
            lay.rect(8, hy - 3, 11, hy + 3)
        if h == "long":
            if direction == "up":
                lay.rect(8, hy, 23, ty + 6)
            elif side:
                lay.rect(8, hy - 2, 12, ty + 5)
            else:
                lay.rect(7, hy - 2, 9, ty + 5)
                lay.rect(22, hy - 2, 24, ty + 5)
        elif h == "ponytail":
            if direction == "up":
                lay.rect(14, hy, 18, ty + 4)
            elif side:
                lay.rect(5, hy - 3, 8, hy + 6)
            else:
                lay.ellipse(23.5, hy - 5, 2.5, 3)
        elif h == "spiky":
            for i, x in enumerate(range(8, 25, 4)):
                for k in range(4):
                    lay.px(x + (k // 2), top - k + 1, MID if k < 3 else LIGHT)
        elif h == "bob":
            if direction == "up":
                lay.rect(8, hy, 23, hy + 7)
            elif side:
                lay.rect(8, hy - 2, 13, hy + 6)
            else:
                lay.rect(7, hy - 2, 9, hy + 6)
                lay.rect(22, hy - 2, 24, hy + 6)
        elif h == "curly":
            for cx, cy in ((9, hy - 3), (23, hy - 3), (12, top + 1), (20, top + 1), (16, top - 0.5), (8, hy + 1), (24, hy + 1)):
                if direction == "down" or direction == "up" or cx < 20:
                    lay.ellipse(cx, cy, 2.6, 2.6)
        elif h == "bun":
            lay.ellipse(16, top - 1, 3.4, 3.0)
    draw_hats(L, direction, hy)
    return {k: (v.raw() if k == "face" else v.outlined()) for k, v in L.items()}


def draw_hats(L, direction, hy):
    """Hats sit on the head ellipse (center 16, hy; radius about 8.5). Side view faces right, so brims reach right."""
    side = direction == "side"
    front = direction == "down"
    for h in HATS:
        lay = L[f"hat_{h}"]
        if h == "cap":
            lay.ellipse(16, hy - 3, 9.0, 6.4, clip=lambda x, y: y <= hy - 3)
            if side:
                lay.rect(20, hy - 4, 27, hy - 3, shade=False)
            elif front:
                lay.rect(9, hy - 4, 22, hy - 3, shade=False)
                lay.px(16, hy - 9, LIGHT)
        elif h == "visor":
            lay.rect(7, hy - 6, 24, hy - 4, shade=False)
            if side:
                lay.rect(20, hy - 4, 27, hy - 3, shade=False)
            elif front:
                lay.rect(8, hy - 4, 23, hy - 2, shade=True)
        elif h == "straw":
            lay.rect(10, hy - 11, 21, hy - 5)
            lay.v[hy - 7:hy - 5, 10:22] = SHADE
            lay.rect(3 if not side else 6, hy - 5, 28 if not side else 29, hy - 3, shade=True)
        elif h == "top":
            lay.rect(10, hy - 18, 21, hy - 6)
            lay.v[hy - 9:hy - 6, 10:22] = SHADE
            lay.rect(6, hy - 6, 25, hy - 4, shade=True)
        elif h == "fedora":
            lay.rect(9, hy - 12, 22, hy - 6)
            lay.v[hy - 8:hy - 6, 9:23] = SHADE
            for x in range(13, 19):
                lay.px(x, hy - 12, 0)
            lay.rect(5 if not side else 8, hy - 6, 26 if not side else 28, hy - 4, shade=True)
        elif h == "beret":
            lay.ellipse(15 if not side else 14, hy - 7, 10.0, 4.0)
            lay.px(16, hy - 12, MID)
            lay.px(16, hy - 11, MID)
        elif h == "crown":
            lay.rect(9, hy - 9, 22, hy - 6)
            for x in (9, 13, 18, 22) if not side else (10, 15, 20):
                lay.px(x, hy - 10, LIGHT)
                lay.px(x, hy - 11, LIGHT)
                lay.px(x, hy - 12, MID)
            if front:
                lay.px(15, hy - 8, SHADE)
                lay.px(16, hy - 8, SHADE)
        elif h == "flowers":
            spots = [(8, hy - 5), (11, hy - 7), (16, hy - 8), (21, hy - 7), (24, hy - 5)]
            if side:
                spots = [(9, hy - 6), (13, hy - 8), (18, hy - 8), (22, hy - 6)]
            elif direction == "up":
                spots = [(8, hy - 4), (12, hy - 7), (16, hy - 8), (20, hy - 7), (24, hy - 4)]
            for cx, cy in spots:
                lay.ellipse(cx + 0.5, cy + 0.5, 2.2, 2.2)
                lay.px(cx, cy, LIGHT)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    args = ap.parse_args()
    out_dir = os.path.join(args.root, "game/assets/characters")
    os.makedirs(out_dir, exist_ok=True)
    sheets = {}
    for r, d in enumerate(DIRS):
        for c, f in enumerate(FRAMES):
            for name, img in frame(d, f).items():
                sheet = sheets.setdefault(name, np.zeros((FH * len(DIRS), FW * len(FRAMES), 4), dtype=np.uint8))
                sheet[r * FH:(r + 1) * FH, c * FW:(c + 1) * FW] = img
    for name, sheet in sheets.items():
        Image.fromarray(sheet, "RGBA").save(os.path.join(out_dir, f"{name}.png"))
    print("wrote", len(sheets), "layers to", out_dir)


if __name__ == "__main__":
    main()
