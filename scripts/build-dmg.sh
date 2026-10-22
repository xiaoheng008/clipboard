#!/bin/zsh
# Builds dist/ClipVault-<version>.dmg: a clean app build (build-app.sh), then a drag-to-Applications disk image.
# The app inside is ad-hoc signed: fine on this Mac; other Macs need right-click → Open (no Developer ID / notarization).
# Afterwards the image is mounted read-only and checked: the app is there, its version matches, its signature verifies.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist"
VERSION=$(sed -n 's/.*marketing = "\(.*\)".*/\1/p' "$ROOT/Sources/ClipCore/Version.swift")
BUILDNO=$(sed -n 's/.*build = "\(.*\)".*/\1/p' "$ROOT/Sources/ClipCore/Version.swift")
[[ -n "$VERSION" && -n "$BUILDNO" ]] || { echo "cannot read version"; exit 1; }

"$ROOT/scripts/build-app.sh"

STAGE="$OUT/dmg"
DMG="$OUT/ClipVault-$VERSION.dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$OUT/ClipVault.app" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "ClipVault $VERSION" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG" >/dev/null
rm -rf "$STAGE"

# Check what was actually packed, not the staging folder.
hdiutil verify "$DMG" >/dev/null
MNT=$(mktemp -d)
trap 'hdiutil detach "$MNT" -quiet 2>/dev/null || true; rmdir "$MNT" 2>/dev/null || true' EXIT
diskutil image attach --readOnly --mountOptions nobrowse --mountPoint "$MNT" "$DMG" >/dev/null
PLIST="$MNT/ClipVault.app/Contents/Info.plist"
[[ -f "$PLIST" ]] || { echo "dmg has no ClipVault.app"; exit 1; }
[[ -L "$MNT/Applications" ]] || { echo "dmg has no Applications link"; exit 1; }
GOT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST") ($(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST"))"
[[ "$GOT" == "$VERSION ($BUILDNO)" ]] || { echo "dmg app version $GOT != $VERSION ($BUILDNO)"; exit 1; }
codesign --verify --strict "$MNT/ClipVault.app"

SIZE=$(du -k "$DMG" | cut -f1)
echo "built $DMG  version $GOT  size ${SIZE} KB"
echo "sha256 $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
