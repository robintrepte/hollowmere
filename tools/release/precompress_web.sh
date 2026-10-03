#!/usr/bin/env bash
# Writes .br and .gz next to the big web build files so Caddy can serve them precompressed.
#   tools/release/precompress_web.sh build/web
set -euo pipefail
DIR="${1:-build/web}"
for f in "$DIR"/*.wasm "$DIR"/*.pck "$DIR"/*.js; do
  [[ -f "$f" ]] || continue
  brotli -f -k -q 11 "$f"
  gzip -f -k -9 "$f"
done
du -ch "$DIR"/*.br | tail -1 | awk '{print "brotli total: " $1}'
