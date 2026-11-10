#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Claudroom.app"
CONFIG="${1:-release}"

swift build -c "$CONFIG" --package-path "$ROOT"
BIN="$(swift build -c "$CONFIG" --package-path "$ROOT" --show-bin-path)/ClaudroomApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/Claudroom.icns" "$APP/Contents/Resources/Claudroom.icns"
cp "$BIN" "$APP/Contents/MacOS/ClaudroomApp"

# Sign with a real identity if one exists, and fall back to ad-hoc only if not.
#
# This matters more than it looks. An ad-hoc signature has no certificate, so the
# app's designated requirement becomes `cdhash H"..."` — literally the hash of the
# binary. macOS Keychain ACLs key on that requirement, so every rebuild that
# changes a single byte is a different application, and "Always Allow" has to be
# granted again. Signing with a certificate makes the requirement
# `identifier "..." and certificate leaf = H"..."`, which survives rebuilds.
IDENTITY="${CLAUDROOM_SIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  # Prefer Developer ID Application: it is the only certificate that lets the app
  # run on someone else's Mac (after notarization, see Scripts/release.sh). Fall
  # back to Apple Development, then to whatever else is in the keychain.
  IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"[^"]*"' | tr -d '"')"
  for prefix in "Developer ID Application:" "Apple Development:" ""; do
    IDENTITY="$(printf '%s\n' "$IDENTITIES" | grep -m1 "^$prefix" || true)"
    [ -n "$IDENTITY" ] && break
  done
fi

if [ -n "$IDENTITY" ]; then
  echo "Signing as: $IDENTITY"
  if [[ "$IDENTITY" == "Developer ID Application:"* ]]; then
    # Hardened runtime and a secure timestamp are both required for notarization.
    codesign --force --options runtime --timestamp --sign "$IDENTITY" "$APP"
  else
    codesign --force --sign "$IDENTITY" "$APP"
  fi
else
  echo "No signing identity found — falling back to ad-hoc."
  echo "The Keychain will re-prompt after every rebuild."
  codesign --force --sign - "$APP"
fi

echo "Built $APP"
