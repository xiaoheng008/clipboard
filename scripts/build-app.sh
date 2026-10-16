#!/bin/zsh
# 7A: builds ClipVault.app from a clean build directory (C23: never from a stale tree).
# Version comes only from Sources/ClipCore/Version.swift (single source).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist"
BUILD="$ROOT/.build-release-clean"
VERSION=$(sed -n 's/.*marketing = "\(.*\)".*/\1/p' "$ROOT/Sources/ClipCore/Version.swift")
BUILDNO=$(sed -n 's/.*build = "\(.*\)".*/\1/p' "$ROOT/Sources/ClipCore/Version.swift")
[[ -n "$VERSION" && -n "$BUILDNO" ]] || { echo "cannot read version"; exit 1; }

rm -rf "$BUILD" "$OUT"
mkdir -p "$OUT"
swift build -c release --package-path "$ROOT" --scratch-path "$BUILD" --product ClipVault

APP="$OUT/ClipVault.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BUILD/release/ClipVault" "$APP/Contents/MacOS/ClipVault"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>local.clipvault.app</string>
  <key>CFBundleName</key><string>ClipVault</string>
  <key>CFBundleDisplayName</key><string>ClipVault</string>
  <key>CFBundleExecutable</key><string>ClipVault</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILDNO</string>
  <key>LSMinimumSystemVersion</key><string>15.4</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.productivity</string>
</dict></plist>
PLIST
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --verbose=2 "$APP"
rm -rf "$BUILD"
SIZE=$(du -sk "$APP" | cut -f1)
echo "built $APP  version $VERSION ($BUILDNO)  size ${SIZE} KB"
