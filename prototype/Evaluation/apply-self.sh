#!/bin/zsh
# Builds Vera's own changed copy into an app bundle and starts it after the running one has quit.
# Called by Core only after the owner said "применяй". Arg 1: the worktree. Exit 0 means the bundle is ready and a start is scheduled.
set -euo pipefail
WT="$1"
SUPPORT="$HOME/Library/Application Support/VeraSensorPrototype/Self"
APP="$SUPPORT/App/VeraSensorPrototype.app"
cd "$WT/prototype"
swift build --product VeraSensorPrototype
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/debug/VeraSensorPrototype "$APP/Contents/MacOS/VeraSensorPrototype"
rm -rf "$APP/Contents/Resources/VeraSensorPrototype_Sensors.bundle"
cp -R .build/debug/VeraSensorPrototype_Sensors.bundle "$APP/Contents/Resources/"
cp Info.plist "$APP/Contents/Info.plist"
IDENTITY="${VERA_SIGN_IDENTITY:-Apple Development}"
security find-identity -v -p codesigning | grep -q "$IDENTITY" || IDENTITY="-"
codesign --force --deep --sign "$IDENTITY" --timestamp=none "$APP"
nohup /bin/zsh -c "sleep 6; exec '$APP/Contents/MacOS/VeraSensorPrototype' --listen --agent" >/dev/null 2>&1 &
