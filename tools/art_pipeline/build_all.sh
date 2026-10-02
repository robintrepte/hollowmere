#!/usr/bin/env bash
# Rebuilds every game asset from the raw AI images in tools/art_pipeline/raw (no network needed).
# Run from the repo root:  tools/art_pipeline/build_all.sh
set -euo pipefail
cd "$(dirname "$0")/../.."
PY="${PY:-.venv/bin/python}"
P="$PY tools/art_pipeline/process.py"
RAW=tools/art_pipeline/raw

while read -r f names; do
  [ -z "$f" ] && continue
  $P sheet "$RAW/creatures/$f" "$names" game/assets/creatures --cols 3 --rows 3
done < tools/art_pipeline/creature_sheets.txt

while read -r f _url names; do
  $P icons "$RAW/icons/$f" "$names" game/assets/items --auto
done < tools/art_pipeline/icon_sheets.txt
# icons_03 drew a second pickaxe in the hoe cell; this single image replaces it.
$P icons "$RAW/icons/hoe_fix.png" hoe game/assets/items --auto
# Cropped from raw/world/adventure.png (the egg cell, without its caption).
$P icons "$RAW/icons/festival_egg.png" festival_egg game/assets/items --auto
$PY tools/art_pipeline/derive_icons.py

while read -r f _url names; do
  extra=()
  # adventure.png has the model's "1 2 3 4" captions under each object.
  [ "$f" = adventure.png ] && extra=(--drop-small 0.05)
  $P sprites "$RAW/world/$f" "$names" game/assets/world ${extra[@]+"${extra[@]}"}
done < tools/art_pipeline/world_sheets.txt

while read -r n w _url; do
  $P single "$RAW/buildings/$n.png" "game/assets/buildings/$n.png" --w $((w * 32)) --colors 40
done < tools/art_pipeline/building_sheets.txt

while read -r f _url names; do
  $P sprites "$RAW/portraits/$f" "$names" game/assets/portraits --colors 28 --trim-caption
done < tools/art_pipeline/portrait_sheets.txt

while read -r n _url; do
  $P backdrop "$RAW/$n.png" "game/assets/$n.png" --colors 64
done < tools/art_pipeline/backdrop_sheets.txt
$P single "$RAW/ui/logo.png" game/assets/ui/logo.png --w 280 --colors 24

$PY tools/art_pipeline/tiles.py
$PY tools/art_pipeline/character.py
$PY tools/art_pipeline/placeholder.py --missing-only
echo "all assets rebuilt"
