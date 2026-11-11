#!/usr/bin/env bash
# dmg-layout.sh - Generate the DMG window layout (.DS_Store) with Finder.
#
# Usage:
#   dmg-layout.sh <volume-name> <output-ds-store>
#
# Run only when the layout or dmg-background.png changes, then commit the
# output. make-dmg.sh copies it as is, so building a DMG needs no Finder.
# The layout references the background through the volume name: keep
# <volume-name> identical to the one given to make-dmg.sh.
#
# Window layout (700 × 440 content area):
#   [Desgrana.app]   →   [Applications]     (drag to install)
#              [desgrana]                    (CLI binary)
#
# Background: 1400 × 880 px (2× the 700 × 440 pt window, Retina).

set -euo pipefail

VOL_NAME="$1"
OUTPUT="$2"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STAGING=$(mktemp -d)
RW_DMG="$STAGING.dmg"
MOUNTPT=""

cleanup() {
    [ -n "$MOUNTPT" ] && hdiutil detach "$MOUNTPT" -quiet 2>/dev/null || true
    rm -rf "$STAGING" "$RW_DMG" 2>/dev/null || true
}
trap cleanup EXIT

attach() {
    hdiutil attach "$RW_DMG" -noautoopen -nobrowse "$@" \
        | sed -n 's|.*\t\(/Volumes/.*\)|\1|p' \
        | head -1
}

if [ -d "/Volumes/$VOL_NAME" ]; then
    echo "✗ /Volumes/$VOL_NAME is already mounted: eject it first." >&2
    exit 1
fi

# Positions are stored per file name: placeholders are enough.
mkdir "$STAGING/Desgrana.app"
touch "$STAGING/desgrana"
ln -s /Applications "$STAGING/Applications"
mkdir "$STAGING/.background"
cp "$SCRIPT_DIR/dmg-background.png" "$STAGING/.background/background.png"

hdiutil create -fs HFS+ \
    -srcfolder "$STAGING" \
    -volname   "$VOL_NAME" \
    -format    UDRW \
    -ov        "$RW_DMG"

MOUNTPT=$(attach)

osascript << APPLESCRIPT
tell application "Finder"
  tell disk "$VOL_NAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {200, 120, 900, 560}
    set opts to icon view options of container window
    set arrangement of opts to not arranged
    set icon size of opts to 96
    set bg to POSIX file "$MOUNTPT/.background/background.png"
    set background picture of opts to bg
    set position of item "Desgrana.app" to {175, 200}
    set position of item "Applications" to {525, 200}
    set position of item "desgrana"     to {350, 370}
    update without registering applications
    delay 3
    close
  end tell
end tell
APPLESCRIPT

# Finder writes .DS_Store lazily: detach to flush, then read it back.
sync
hdiutil detach "$MOUNTPT" -quiet
MOUNTPT=$(attach -readonly)

[ -f "$MOUNTPT/.DS_Store" ] || { echo "✗ Finder wrote no .DS_Store." >&2; exit 1; }
cp "$MOUNTPT/.DS_Store" "$OUTPUT"

echo "Layout → $OUTPUT"
