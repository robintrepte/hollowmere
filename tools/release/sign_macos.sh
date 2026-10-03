#!/usr/bin/env bash
# Signs Hollowmere.app with a Developer ID, notarizes it with Apple and staples the ticket.
# Runs on macOS (a CI macos runner or your Mac).
#
#   tools/release/sign_macos.sh build/macos/Hollowmere.zip
#
# Environment:
#   MACOS_SIGN_IDENTITY   "Developer ID Application: Your Name (TEAMID)"
#   MACOS_CERT_P12_BASE64 + MACOS_CERT_PASSWORD   optional: imports the certificate into a temp keychain (CI)
#   APPLE_API_KEY_ID, APPLE_API_ISSUER, APPLE_API_KEY_BASE64   App Store Connect API key (.p8) for notarytool
set -euo pipefail

ZIP="${1:?usage: sign_macos.sh path/to/Hollowmere.zip}"
: "${MACOS_SIGN_IDENTITY:?set MACOS_SIGN_IDENTITY}"
: "${APPLE_API_KEY_ID:?set APPLE_API_KEY_ID}"
: "${APPLE_API_ISSUER:?set APPLE_API_ISSUER}"
: "${APPLE_API_KEY_BASE64:?set APPLE_API_KEY_BASE64}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [[ -n "${KEYCHAIN:-}" ]] && security delete-keychain "$KEYCHAIN" 2>/dev/null || true' EXIT

if [[ -n "${MACOS_CERT_P12_BASE64:-}" ]]; then
  KEYCHAIN="$WORK/signing.keychain-db"
  KC_PASS="$(uuidgen)"
  echo "$MACOS_CERT_P12_BASE64" | base64 --decode > "$WORK/cert.p12"
  security create-keychain -p "$KC_PASS" "$KEYCHAIN"
  security set-keychain-settings -lut 3600 "$KEYCHAIN"
  security unlock-keychain -p "$KC_PASS" "$KEYCHAIN"
  security import "$WORK/cert.p12" -k "$KEYCHAIN" -P "${MACOS_CERT_PASSWORD:-}" -T /usr/bin/codesign
  security set-key-partition-list -S apple-tool:,apple: -s -k "$KC_PASS" "$KEYCHAIN" >/dev/null
  security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | tr -d '"')
fi

echo "$APPLE_API_KEY_BASE64" | base64 --decode > "$WORK/AuthKey.p8"

ditto -x -k "$ZIP" "$WORK/app"
APP="$(find "$WORK/app" -maxdepth 2 -name '*.app' -print -quit)"
[[ -d "$APP" ]] || { echo "no .app inside $ZIP"; exit 1; }

echo "Signing $APP"
codesign --force --deep --timestamp --options runtime \
  --entitlements "$(dirname "$0")/entitlements.plist" \
  --sign "$MACOS_SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

echo "Notarizing (this usually takes a few minutes)"
ditto -c -k --keepParent "$APP" "$WORK/upload.zip"
xcrun notarytool submit "$WORK/upload.zip" \
  --key "$WORK/AuthKey.p8" --key-id "$APPLE_API_KEY_ID" --issuer "$APPLE_API_ISSUER" --wait

xcrun stapler staple "$APP"
spctl --assess --type execute --verbose "$APP"

rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Signed and notarized: $ZIP"
