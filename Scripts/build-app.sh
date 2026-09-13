#!/bin/sh
# Builds a release PhotoOrganizer.app bundle and packages it into
# PhotoOrganizer.dmg, both written to the repo root (gitignored — these are
# rebuilt locally / attached to GitHub Releases, never committed).
#
# Usage: ./Scripts/build-app.sh
set -e

cd "$(dirname "$0")/.."

APP="PhotoOrganizer.app"
DMG="PhotoOrganizer.dmg"
BIN_NAME="PhotoOrganizer"

echo "Building release binary…"
swift build -c release

rm -rf "$APP" "$DMG"
mkdir -p "$APP/Contents/MacOS"

cp ".build/release/$BIN_NAME" "$APP/Contents/MacOS/$BIN_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>PhotoOrganizer</string>
    <key>CFBundleDisplayName</key>
    <string>PhotoOrganizer</string>
    <key>CFBundleIdentifier</key>
    <string>com.dhruvanand.photoorganizer</string>
    <key>CFBundleVersion</key>
    <string>1.0</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleExecutable</key>
    <string>$BIN_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signature — no paid Apple Developer account behind this build.
# Gatekeeper will still flag the app as from an "unidentified developer";
# install.sh clears the quarantine attribute so it opens without that prompt.
codesign --force --deep --sign - "$APP"

echo "Packaging $DMG…"
hdiutil create -volname "PhotoOrganizer" -srcfolder "$APP" -ov -format UDZO "$DMG" >/dev/null

echo "Done: $APP ($(du -sh "$APP" | cut -f1)), $DMG ($(du -sh "$DMG" | cut -f1))"
