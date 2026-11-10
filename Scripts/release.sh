#!/usr/bin/env bash
# Build, sign, notarize and staple Claudroom.app, then zip it for other people.
#
#   ./Scripts/release.sh            -> build/Claudroom-<version>.zip
#   ./Scripts/release.sh --publish  -> also creates a GitHub release v<version>
#
# One-time setup (stores notary credentials in your login Keychain):
#   xcrun notarytool store-credentials claudroom \
#     --apple-id <your Apple ID> --team-id <TEAM ID>
# It asks for an app-specific password: create one at https://account.apple.com
# under Sign-In and Security -> App-Specific Passwords.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/Claudroom.app"
PROFILE="${CLAUDROOM_NOTARY_PROFILE:-claudroom}"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
OUT="$ROOT/build"
ZIP="$OUT/Claudroom-$VERSION.zip"

"$ROOT/Scripts/bundle.sh" release

if ! codesign -dvv "$APP" 2>&1 | grep -q "Authority=Developer ID Application"; then
  echo "error: Claudroom.app is not signed with a Developer ID Application certificate." >&2
  echo "Other Macs will refuse to open it. Install one from Xcode -> Settings -> Accounts." >&2
  exit 1
fi

mkdir -p "$OUT"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "Submitting to Apple notary service (usually 1-5 minutes)..."
xcrun notarytool submit "$ZIP" --keychain-profile "$PROFILE" --wait

xcrun stapler staple "$APP"
spctl --assess --type execute -vv "$APP"

# Re-zip so the download carries the stapled ticket and opens offline too.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "Release ready: $ZIP"

if [ "${1:-}" = "--publish" ]; then
  gh release create "v$VERSION" "$ZIP" --title "Claudroom $VERSION" --generate-notes
fi
