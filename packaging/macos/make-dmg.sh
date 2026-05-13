#!/usr/bin/env bash
# make-dmg.sh — Build a distributable DMG for Desgrana.
#
# Usage:
#   make-dmg.sh <app-path> <cli-path> <version> <output-dmg>
#
# Window layout (700 × 440 content area):
#   [Desgrana.app]   →   [Applications]     (drag to install)
#              [desgrana]                    (CLI binary)
#
# Background image: place dmg-background.png in the same folder as this script.
# Size must be 1400 × 880 px (2× the 700 × 440 pt window — Retina/HiDPI).
# The DMG works without it (plain white background).

set -euo pipefail

APP_PATH="$1"
CLI_PATH="$2"
VERSION="$3"
OUTPUT_DMG="$4"

VOL_NAME="Desgrana $VERSION"
STAGING=$(mktemp -d)
RW_DMG="${OUTPUT_DMG%.dmg}-rw.dmg"

cleanup() {
    hdiutil detach "$MOUNTPT" -quiet 2>/dev/null || true
    rm -rf "$STAGING" "$RW_DMG" 2>/dev/null || true
}
trap cleanup EXIT

# ── 1. Staging folder ─────────────────────────────────────────────

cp -r "$APP_PATH" "$STAGING/Desgrana.app"
cp    "$CLI_PATH" "$STAGING/desgrana"
ln -s /Applications "$STAGING/Applications"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [ -f "$SCRIPT_DIR/dmg-background.png" ]; then
    mkdir -p "$STAGING/.background"
    cp "$SCRIPT_DIR/dmg-background.png" "$STAGING/.background/background.png"
    # Force 144dpi so Finder treats the 1400×880 px image as 700×440 pts on Retina.
    # sips -s dpiWidth 144 -s dpiHeight 144 "$STAGING/.background/background.png" &>/dev/null
fi

# ── 2. Read-write DMG ─────────────────────────────────────────────

rm -f "$RW_DMG"
hdiutil create -fs HFS+ \
    -srcfolder "$STAGING" \
    -volname   "$VOL_NAME" \
    -format    UDRW \
    -ov        "$RW_DMG"

# ── 3. Mount ──────────────────────────────────────────────────────

MOUNTPT=$(hdiutil attach "$RW_DMG" -noautoopen -nobrowse \
    | sed -n 's|.*\t\(/Volumes/.*\)|\1|p' \
    | head -1)

# ── 4. Finder layout via AppleScript ──────────────────────────────
# Window bounds {left, top, right, bottom} → 700 × 440 content area.
# Icon positions are (x, y) from the content area's top-left corner.

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
    try
      set bg to POSIX file "$MOUNTPT/.background/background.png"
      set background picture of opts to bg
    end try
    set position of item "Desgrana.app" to {175, 200}
    set position of item "Applications" to {525, 200}
    set position of item "desgrana"     to {350, 370}
    update without registering applications
    delay 3
    close
  end tell
end tell
APPLESCRIPT

# ── 5. Flush and detach ───────────────────────────────────────────

sync
hdiutil detach "$MOUNTPT" -quiet
MOUNTPT=""   # prevent double-detach in cleanup

# ── 6. Compress to final DMG ──────────────────────────────────────

rm -f "$OUTPUT_DMG"
hdiutil convert "$RW_DMG" -format UDZO -o "$OUTPUT_DMG"

echo "DMG → $OUTPUT_DMG"
