# Hollowmere art style bible

## Look
- Cozy, chunky pixel art in the spirit of Stardew Valley and Farm Story: bold dark outlines (`#22181e`), soft 3-step shading, light from the top-left, saturated but warm colors.
- Top-down 3/4 view. World grid is **32x32 px**; the game renders at 640x360 logical pixels with integer scaling and nearest filtering.
- Never use anti-aliased edges in game sprites. The pipeline enforces hard alpha and a limited palette per sprite.

## Sizes
| Asset | Canvas | Notes |
|---|---|---|
| Ground tile | 32x32 | procedural (`tiles.py`), 4 variants, 4 seasons |
| Deco / tree | 32x32 to 48x64 | bottom-center anchored on its tile |
| Building | footprint x 32 wide | height is natural (roof overhang) |
| Creature, battle | 64x64 | shown at 2x in battle |
| Creature, overworld | 32x32 | |
| Item icon | 16x16 | drawn at 2x in the inventory grid |
| Character | 32x48 frame | paper-doll grayscale layers, tinted in engine |
| Portrait | 64x64 | dialogue box at 2x |
| Backdrop | 320x180 | battle / title, shown at 2x |

## Core palette (UI + procedural art)
```
outline   #22181e   ink       #3a2a2e   parchment #f4e4c4   cream   #fff4dc
wood      #8a5a3a   wood-lt   #b07a48   leaf      #5fa64b   leaf-dk #356c32
sky       #8ccfe8   water     #3a7cbc   sun       #f8d060   rose    #f0a0c0
coin      #f0c040   heart     #e05060   energy    #70d050   frost   #b8daee
```
Type colors live in `game/data/types.json`.

## Generation rules (Replicate)
- Default model: `google/nano-banana-2-lite` (fast and cheap, good enough for sheets). Use `google/nano-banana-2` for hero art: buildings, portraits, title, logo.
- Always request: *"The ENTIRE background is one single uniform flat magenta #FF00FF: no grid lines, no borders, no ground, no shadows. NO TEXT."*
- Sheets: ask for exact rows x columns *"evenly spaced, not touching"*; the pipeline auto-detects objects, so layout drift is tolerated, but order must be reading order.
- Magenta is keyed with region growing (catches the model's darker magenta drop shadows). Only fall back to a background-removal model (`851-labs/background-remover`, `bria/remove-background`) if keying fails, since soft alpha hurts pixel edges.

## Prompt templates
**Sheet of objects**
> Sprite sheet of N separate game objects for a top-down 3/4 view cozy farming RPG, arranged in exactly R rows and C columns, evenly spaced with generous empty space between them... Style: chunky pixel art exactly like Stardew Valley, bold dark outline, soft shading, lit from top-left... Objects in reading order: 1 ..., 2 ...

**Creature sheet**
> 3x3 sheet of cute creature monsters for a cozy creature-collecting farming game, Pokemon-like but original, chunky pixel art, bold outline, front 3/4 view, full body, each in its own cell... magenta background... 1 name: description...

**Building**
> A single building sprite for a top-down 3/4 view cozy farming RPG, chunky pixel art exactly in the style of Stardew Valley buildings... <description, roof color hex>, door at the bottom center... Background: one single flat uniform magenta #FF00FF color. No ground, no grass, no shadow, no text, no letters.

## Rebuilding
- Everything is reproducible from `raw/`: run `tools/art_pipeline/build_all.sh`.
- Manifests (`*_sheets.txt`) map raw files to sprite names and canvas specs (`name:WxH[:anchor[:FWxFH]]`).
- New art: `generate.py raw/<dir>/<file>.png "<prompt>"`, add a manifest line, then rebuild.
