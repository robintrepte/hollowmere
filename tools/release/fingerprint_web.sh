#!/usr/bin/env bash
# Renames the engine files of a Godot web export to a content-hash stem (hm-<hash>.wasm/.pck/.js/...)
# and points index.html at them, so a deploy can never be served from a stale browser cache and the
# big files can be cached forever. Run before precompress_web.sh.
#   tools/release/fingerprint_web.sh build/web
set -euo pipefail
DIR="${1:-build/web}"
cd "$DIR"
[[ -f index.wasm && -f index.pck ]] || { echo "no fresh export in $DIR" >&2; exit 1; }
rm -f hm-*
HASH=$(cat index.wasm index.pck index.js | shasum -a 256 | cut -c1-10)
STEM="hm-$HASH"
for ext in js wasm pck audio.worklet.js audio.position.worklet.js; do
  [[ -f "index.$ext" ]] && mv "index.$ext" "$STEM.$ext"
done
rm -f index.*.br index.*.gz
perl -pi -e "s/\"executable\":\"index\"/\"executable\":\"$STEM\"/; s/\"index\\.(pck|wasm)\"/\"$STEM.\$1\"/g; s/src=\"index\\.js\"/src=\"$STEM.js\"/" index.html
grep -q "\"executable\":\"$STEM\"" index.html && grep -q "src=\"$STEM.js\"" index.html || { echo "index.html rewrite failed" >&2; exit 1; }
echo "$STEM"
