#!/usr/bin/env bash
# Draws the app icon and builds AppIcon.icns.
#
# The asset catalog kept only four sizes and stopped at 256 points, so the icns is built here
# instead. iconutil writes every size that macOS asks for.
set -euo pipefail
cd "$(dirname "$0")/.."

ICONSET="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET"

swift Scripts/make-icon.swift "$ICONSET"
iconutil --convert icns "$ICONSET" --output Sources/Rowset/Resources/AppIcon.icns

echo "Wrote Sources/Rowset/Resources/AppIcon.icns"
