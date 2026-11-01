#!/usr/bin/env bash
# Renames the engine files of a Godot web export to a content-hash stem (hm-<hash>.wasm/.pck/.js/...)
# and points index.html at them, so a deploy can never be served from a stale browser cache and the
# big files can be cached forever. Also adds the home-screen manifest and icons (game/web/pwa), redirect
# pages to the legal pages on tretu.de (game/web/legal; LEGAL_URL, default https://tretu.de), the
# Tretu-Konto sign-in callback (game/web/auth -> /auth/callback/) and robots.txt + sitemap.xml (game/web/seo).
# Run before precompress_web.sh.
#   tools/release/fingerprint_web.sh build/web
set -euo pipefail
DIR="${1:-build/web}"
PWA="$(cd "$(dirname "$0")/../../game/web/pwa" && pwd)"
LEGAL="$(cd "$(dirname "$0")/../../game/web/legal" && pwd)"
SEO="$(cd "$(dirname "$0")/../../game/web/seo" && pwd)"
AUTH="$(cd "$(dirname "$0")/../../game/web/auth" && pwd)"
LEGAL_URL="${LEGAL_URL:-https://tretu.de}"
LEGAL_URL="${LEGAL_URL%/}"
[[ "$LEGAL_URL" =~ ^https?://[A-Za-z0-9.:-]+(/[A-Za-z0-9._/-]*)?$ ]] || { echo "bad LEGAL_URL: $LEGAL_URL" >&2; exit 1; }
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
cp "$PWA"/manifest.webmanifest "$PWA"/icon-*.png .
# Old /privacy and /terms links keep working; /datenschutz, /agb, /impressum match tretu.de.
legal_page() { # dir title target-path
  mkdir -p "$1"
  sed -e "s|__TITLE__|$2|g" -e "s|__TARGET__|$LEGAL_URL/$3|g" "$LEGAL/redirect.html" > "$1/index.html"
}
legal_page privacy "Datenschutz" datenschutz
legal_page datenschutz "Datenschutz" datenschutz
legal_page terms "AGB" agb
legal_page agb "AGB" agb
legal_page impressum "Impressum" impressum
mkdir -p auth/callback
cp "$AUTH/callback/index.html" auth/callback/index.html
cp "$SEO"/robots.txt "$SEO"/sitemap.xml .
echo "$STEM"
