#!/usr/bin/env bash
# Regenerate AppIcon.icns + PlateDocument.icns from the source SVGs.
#
# We don't commit the intermediate .iconset/ directories or preview PNGs —
# they're cheap to regenerate from the canonical SVGs under Branding/ — but
# the final .icns files DO get committed into PlateApp/PlateApp/ because
# xcodegen wires them into the app bundle's Resources at build time.
#
# Run this whenever logo-*.svg or document-icon.svg changes, then commit the
# updated .icns alongside the SVG edit.
#
# Requires:
#   - rsvg-convert (brew install librsvg)
#   - iconutil    (ships with macOS)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/.." && pwd)"
BRANDING="$REPO/Branding"
TARGET="$REPO/PlateApp/PlateApp"

if ! command -v rsvg-convert >/dev/null 2>&1; then
    echo "Error: rsvg-convert not found. brew install librsvg" >&2
    exit 1
fi

# Apple's canonical iconset layout — 5 logical sizes × @1x + @2x = 10 PNGs.
SIZES=(
    "16:icon_16x16.png"
    "32:icon_16x16@2x.png"
    "32:icon_32x32.png"
    "64:icon_32x32@2x.png"
    "128:icon_128x128.png"
    "256:icon_128x128@2x.png"
    "256:icon_256x256.png"
    "512:icon_256x256@2x.png"
    "512:icon_512x512.png"
    "1024:icon_512x512@2x.png"
)

build_icns() {
    local svg="$1"
    local out_icns="$2"
    local iconset="${svg%.svg}.iconset"

    rm -rf "$iconset"
    mkdir -p "$iconset"

    for pair in "${SIZES[@]}"; do
        local size="${pair%%:*}"
        local name="${pair##*:}"
        rsvg-convert -w "$size" -h "$size" "$svg" -o "$iconset/$name"
    done

    iconutil -c icns "$iconset" -o "$out_icns"
    echo "  → $out_icns ($(stat -f %z "$out_icns") bytes)"
}

echo "Building AppIcon.icns..."
build_icns "$BRANDING/logo-f-italic-p.svg" "$TARGET/AppIcon.icns"

echo "Building PlateDocument.icns..."
build_icns "$BRANDING/document-icon.svg" "$TARGET/PlateDocument.icns"

echo "Done."
