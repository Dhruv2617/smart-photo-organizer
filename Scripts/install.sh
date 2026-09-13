#!/bin/sh
# Downloads the latest PhotoOrganizer.dmg from GitHub Releases, installs the
# app into /Applications, and clears the quarantine flag Gatekeeper would
# otherwise attach to an unsigned/unnotarized download (this app ships with
# an ad-hoc signature only, not a paid Apple Developer certificate).
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/Dhruv2617/smart-photo-organizer/main/Scripts/install.sh | sh
set -e

REPO="Dhruv2617/smart-photo-organizer"
DMG_URL="https://github.com/$REPO/releases/latest/download/PhotoOrganizer.dmg"
TMP_DIR=$(mktemp -d)
DMG_PATH="$TMP_DIR/PhotoOrganizer.dmg"
MOUNT_POINT="$TMP_DIR/mount"

cleanup() {
    hdiutil detach "$MOUNT_POINT" >/dev/null 2>&1 || true
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "Downloading PhotoOrganizer…"
curl -fsSL "$DMG_URL" -o "$DMG_PATH"

echo "Mounting disk image…"
hdiutil attach "$DMG_PATH" -nobrowse -mountpoint "$MOUNT_POINT" >/dev/null

echo "Installing to /Applications…"
rm -rf "/Applications/PhotoOrganizer.app"
cp -R "$MOUNT_POINT/PhotoOrganizer.app" /Applications/

xattr -cr "/Applications/PhotoOrganizer.app"

echo "Installed. Launch it with: open -a PhotoOrganizer"
