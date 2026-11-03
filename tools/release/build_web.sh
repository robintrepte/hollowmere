#!/usr/bin/env bash
# Builds the production web export into build/web (there is no GitHub Actions CI any more): Godot
# export, fingerprinted engine files, Brotli/gzip next to them, and the checks the deploy relies on.
# build/web is exactly what goes to the server's site directory (HOSTING.md §8 and §12).
# Runs on Linux and macOS (bash 3.2, BSD tools; HOSTING.md §8 lists the macOS prerequisites).
#
#   tools/release/build_web.sh
#
# Env: GODOT (default `godot`, must be 4.7.2 with the web export templates installed; on macOS
#      e.g. GODOT=/Applications/Godot.app/Contents/MacOS/Godot),
#      HOLLOWMERE_DOMAIN (default hollowmere.tretu.de, the server host the build talks to),
#      TRETU_AUTH_ISSUER (optional, only to override the shipped https://auth.tretu.de, e.g. staging),
#      LEGAL_URL (optional, see fingerprint_web.sh).
# game/project.godot is only changed for the export and restored afterwards. Without nginx the final
# site file test (deploy/nginx/test_site.sh) is skipped with a warning; the build itself is complete.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
GODOT="${GODOT:-godot}"
DOMAIN="${HOLLOWMERE_DOMAIN:-hollowmere.tretu.de}"
ISSUER="${TRETU_AUTH_ISSUER:-}"
PROJECT=game/project.godot

command -v "$GODOT" >/dev/null || { echo "Godot 4.7.2 not found (set GODOT)" >&2; exit 1; }
"$GODOT" --version | grep -q '^4\.7\.2\.' || { echo "Godot 4.7.2 required, found $("$GODOT" --version)" >&2; exit 1; }
command -v brotli >/dev/null || { echo "brotli missing (Linux: apt install brotli, macOS: brew install brotli)" >&2; exit 1; }
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || { echo "HOLLOWMERE_DOMAIN must be a host name" >&2; exit 1; }

REV="$(git rev-parse --short HEAD)$(git diff --quiet HEAD -- game || echo ', with local changes')"
cp "$PROJECT" "$PROJECT.build-bak"
trap 'mv -f "$PROJECT.build-bak" "$PROJECT"' EXIT

# perl -pi instead of sed -i: GNU and BSD (macOS) sed disagree on -i. Values come in through %ENV,
# never through the perl source; both are validated above / below to plain host names.
DOMAIN="$DOMAIN" perl -pi -e 's/%HOLLOWMERE_DOMAIN%/$ENV{DOMAIN}/' "$PROJECT"
if [[ -n "$ISSUER" ]]; then
  [[ "$ISSUER" =~ ^https://[A-Za-z0-9.-]+$ ]] || { echo "TRETU_AUTH_ISSUER must look like https://auth.tretu.de" >&2; exit 1; }
  ISSUER="$ISSUER" perl -pi -e 's{^auth_issuer=".*"$}{auth_issuer="$ENV{ISSUER}"}' "$PROJECT"
  grep -q "^auth_issuer=\"$ISSUER\"\$" "$PROJECT" || { echo "could not set auth_issuer in $PROJECT" >&2; exit 1; }
fi
grep -q "^server/host.release=\"$DOMAIN\"" "$PROJECT"
grep -Eq '^auth_issuer="https://[A-Za-z0-9.-]+"$' "$PROJECT" && grep -q '^client_id="hollowmere"$' "$PROJECT" \
  || { echo "Tretu sign-in is not configured in $PROJECT" >&2; exit 1; }

rm -rf build/web && mkdir -p build/web
"$GODOT" --headless --path game --import >/dev/null 2>&1 || true
set +e
"$GODOT" --headless --path game --export-release "Web"
code=$?
set -e
# 4.7.2 can SIGABRT while tearing down after a successful export; the file decides.
[[ -f build/web/index.html ]] || { echo "export failed (exit $code)" >&2; exit "${code:-1}"; }

tools/release/fingerprint_web.sh build/web
tools/release/precompress_web.sh build/web
test -f build/web/robots.txt && test -f build/web/sitemap.xml
test -f build/web/auth/callback/index.html && test -f build/web/datenschutz/index.html

total=$(( $(cat build/web/*.br | wc -c) ))   # BSD wc pads with spaces
echo "Compressed download: $((total / 1048576)) MB"
[[ "$total" -lt 52428800 ]] || { echo "web download over the 50 MB budget" >&2; exit 1; }

# The site file must serve this build (every location, dummy certificates, no root). Optional on a
# build machine without nginx (e.g. a Mac without `brew install nginx`); tools/ci/check.sh always runs it.
if command -v nginx >/dev/null; then
  deploy/nginx/test_site.sh build/web
else
  echo "WARNING: nginx not installed, skipped the site file test (deploy/nginx/test_site.sh build/web)." >&2
  echo "WARNING: install it (Linux: apt install nginx, macOS: brew install nginx) to check this build against the site file." >&2
fi

echo "Web build for $DOMAIN ($REV) is in build/web"
