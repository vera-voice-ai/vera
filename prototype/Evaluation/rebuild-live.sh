#!/bin/zsh
set -euo pipefail

ROOT=/Users/alex/Projects/vera-v2/prototype
swift build --package-path "$ROOT"
APP="$ROOT/.build/VeraSensorPrototype.app"
CONTENTS="$APP/Contents"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"
cp "$ROOT/.build/debug/VeraSensorPrototype" "$CONTENTS/MacOS/VeraSensorPrototype"
cp -R "$ROOT/.build/debug/VeraSensorPrototype_Sensors.bundle" "$CONTENTS/Resources/"
cp "$ROOT/Info.plist" "$CONTENTS/Info.plist"
# Sign with a stable identity so macOS keeps the microphone/Keychain grants across
# rebuilds: the designated requirement is then "bundle id + certificate", not the
# hash of this particular build (which is what ad-hoc "-" signing gives).
# Override with VERA_SIGN_IDENTITY; falls back to ad-hoc (re-prompts every build).
IDENTITY="${VERA_SIGN_IDENTITY:-Apple Development}"
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "warning: no signing identity matching '$IDENTITY'; using ad-hoc, permissions will be re-requested" >&2
  IDENTITY="-"
fi
codesign --force --deep --sign "$IDENTITY" --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"
codesign -dr - "$APP" 2>&1 | grep designated
