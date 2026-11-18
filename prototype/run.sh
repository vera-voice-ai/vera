#!/bin/zsh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
swift build --package-path "$ROOT"
APP="$ROOT/.build/VeraSensorPrototype.app"
CONTENTS="$APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/.build/debug/VeraSensorPrototype" "$CONTENTS/MacOS/VeraSensorPrototype"
cp -R "$ROOT/.build/debug/VeraSensorPrototype_Sensors.bundle" "$CONTENTS/Resources/"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
# The executable is copied into the app bundle after SwiftPM builds it. Re-sign
# the assembled bundle so macOS validates the final executable and resources.
codesign --force --deep --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
open -n "$APP"
