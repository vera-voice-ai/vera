#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
swift build --package-path "$ROOT"
BIN="$(swift build --package-path "$ROOT" --show-bin-path)"
APP="$ROOT/.build/SmartAnalyzer.app"
mkdir -p "$APP/Contents/MacOS"
cp "$ROOT/Info.plist" "$APP/Contents/Info.plist"
cp "$BIN/SmartAnalyzer" "$APP/Contents/MacOS/SmartAnalyzer"
codesign --force --sign - "$APP"
codesign --verify --strict "$APP"

# Run the packaged executable so the app inherits this shell's provider environment.
exec "$APP/Contents/MacOS/SmartAnalyzer" "$@"
