#!/bin/zsh
# Builds app/Resources/AppIcon.icns from scripts/make-icon.swift (system tools only: swift, sips, iconutil).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
swift "$ROOT/scripts/make-icon.swift" "$TMP/icon.png"
SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s "$TMP/icon.png" --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) "$TMP/icon.png" --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
mkdir -p "$ROOT/app/Resources"
iconutil -c icns "$SET" -o "$ROOT/app/Resources/AppIcon.icns"
cp "$TMP/icon.png" "$ROOT/app/Resources/AppIcon.png"
echo "$ROOT/app/Resources/AppIcon.icns"
