#!/bin/zsh
# Assemble, stamp and sign Vera.app. Usage: bundle.sh debug|release  (prints the app path).
# The bundle id and executable keep their prototype names on purpose: macOS microphone/Keychain grants
# and the data folder ~/Library/Application Support/VeraSensorPrototype follow them.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
CONFIG="${1:-debug}"
VERSION=$(sed -n 's/.*version = "\(.*\)"/\1/p' "$ROOT/SignalBus/VeraRelease.swift")
BUILD=$(sed -n 's/.*build = \([0-9]*\)/\1/p' "$ROOT/SignalBus/VeraRelease.swift")
if [[ "$CONFIG" == release ]]; then swift build -c release --package-path "$ROOT" >&2; else swift build --package-path "$ROOT" >&2; fi
OUT="$ROOT/.build/$CONFIG"
APP="$ROOT/.build/VeraSensorPrototype.app"
rm -rf "$APP"
CONTENTS="$APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$OUT/VeraSensorPrototype" "$CONTENTS/MacOS/VeraSensorPrototype"
cp -R "$OUT/VeraSensorPrototype_Sensors.bundle" "$CONTENTS/Resources/"
cp -R "$OUT/VeraSensorPrototype_SceneAnalyzers.bundle" "$CONTENTS/Resources/"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$CONTENTS/Info.plist"
# A stable identity keeps macOS permissions across rebuilds; override with VERA_SIGN_IDENTITY, else ad-hoc.
IDENTITY="${VERA_SIGN_IDENTITY:-Apple Development}"
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "warning: no signing identity matching '$IDENTITY'; using ad-hoc, permissions will be re-requested" >&2
  IDENTITY="-"
fi
codesign --force --deep --sign "$IDENTITY" --timestamp=none "$APP" >&2
codesign --verify --deep --strict "$APP" >&2
codesign -dr - "$APP" 2>&1 | grep designated >&2 || true
echo "$APP"
