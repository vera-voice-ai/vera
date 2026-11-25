#!/bin/zsh
# Build and sign a self-contained Vera03.app: the Swift app + the Hermes payload + vera-pulse + the ears + the mouth.
# Usage: bundle.sh [debug|release]   (prints the app path); VERA_FULL=1 forces a full rebuild of the bundle
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG="${1:-debug}"
PKG="$ROOT/app"
if [[ "$CONFIG" == release ]]; then swift build -c release --package-path "$PKG" >&2; else swift build --package-path "$PKG" >&2; fi
FINAL="$PKG/.build/Vera03.app"
# Quit Vera first: the running app's gateway executes from this bundle.
if pgrep -f "$FINAL/Contents/MacOS/Vera" >/dev/null 2>&1; then
  echo "ошибка: Vera03.app запущена — закрой её (⌘Q) и повтори" >&2; exit 1
fi
# Quick path: only Vera's own code changed — the app already holds Hermes, the ears and the mouth from the same
# builds, so swap the executable, Info.plist, icon and plugins in place and re-seal (~25 s instead of a full copy).
VOICE="${VERA_MOUTH_IOS:-$HOME/.vera03/build/mouth-ios/out}"
quick_ok() {
  [[ -d "$FINAL/Contents/Resources/hermes" && -d "$FINAL/Contents/Resources/ears" && -d "$FINAL/Contents/Resources/mouth" ]] || return 1
  # The Swift voice, when it is built, must already be in the app.
  [[ ! -f "$VOICE/silero-decoder.onnx" || -f "$FINAL/Contents/Resources/voice/silero-decoder.onnx" ]] || return 1
  local c
  for c in hermes-payload-copy ears-copy mouth-copy; do
    [[ -f "$PKG/.build/$c/.vera-signed" && ! "$PKG/.build/$c/.vera-signed" -nt "$FINAL/Contents/MacOS/Vera" ]] || return 1
  done
  [[ -z "$(find "${VERA_HERMES_PAYLOAD:-$HOME/.vera03/build/payload}" "${VERA_EARS:-$HOME/.vera03/build/ears}" "${VERA_MOUTH:-$HOME/.vera03/build/mouth}" \
            $( [[ -d "$VOICE" ]] && print -r -- "$VOICE" ) \
            -newer "$FINAL/Contents/MacOS/Vera" -print -quit 2>/dev/null)" ]]
}
if [[ "${VERA_FULL:-0}" != 1 ]] && quick_ok; then
  IDENTITY="${VERA_SIGN_IDENTITY:-Apple Development}"
  security find-identity -v -p codesigning | grep -q "$IDENTITY" || IDENTITY="-"
  echo "→ быстрая сборка: только код Веры" >&2
  cp "$PKG/.build/$CONFIG/Vera" "$FINAL/Contents/MacOS/Vera"
  cp "$PKG/Info.plist" "$FINAL/Contents/Info.plist"
  cp "$PKG/Resources/AppIcon.icns" "$FINAL/Contents/Resources/AppIcon.icns"
  cp "$ROOT/hermes.lock.json" "$FINAL/Contents/Resources/hermes.lock.json"
  cp "$ROOT/ears.lock.json" "$FINAL/Contents/Resources/ears.lock.json"
  for plugin in "$ROOT"/hermes-plugin/*/; do
    rsync -a --delete --exclude '__pycache__' --exclude 'tests' "$plugin" "$FINAL/Contents/Resources/plugins/$(basename "$plugin")/" >&2
  done
  codesign --force --sign "$IDENTITY" --timestamp=none "$FINAL" >&2
  echo "$FINAL"
  exit 0
fi
# Built aside and swapped in at the end: a half-built app can never be launched (the Dock does that sometimes).
APP="$PKG/.build/Vera03.app.building"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$PKG/.build/$CONFIG/Vera" "$APP/Contents/MacOS/Vera"
cp "$PKG/Info.plist" "$APP/Contents/Info.plist"
cp "$PKG/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"   # scripts/make-icon.sh
cp "$ROOT/hermes.lock.json" "$APP/Contents/Resources/hermes.lock.json"
# A stable identity keeps macOS permissions across rebuilds; override with VERA_SIGN_IDENTITY, else ad-hoc.
IDENTITY="${VERA_SIGN_IDENTITY:-Apple Development}"
if ! security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
  echo "warning: no signing identity matching '$IDENTITY'; signing ad-hoc" >&2
  IDENTITY="-"
fi
# The big parts (Hermes, ears, mouth) are copied into caches next to the build and their Mach-O files signed there —
# only when the source changed (or the identity did). The app then gets APFS clones: seconds, not minutes.
cached() {   # cached <source> <cache> [rsync excludes…]
  local src="$1" cache="$2"; shift 2
  mkdir -p "$cache"
  # Signing changes the copied files, so rsync would see them as changed every time: skip it while nothing in the
  # source is newer than the last signing (and the identity is the same).
  if [[ "$(cat "$cache/.vera-signed" 2>/dev/null)" == "$IDENTITY" && -z "$(find "$src" -newer "$cache/.vera-signed" -print -quit)" ]]; then
    return
  fi
  local changed
  # The whole list is read: cutting it short (`| head`) kills rsync with SIGPIPE under pipefail mid-copy.
  changed=$(rsync -a --delete --itemize-changes "$@" --exclude '.vera-signed' "$src/" "$cache/")
  if [[ -n "$changed" || "$(cat "$cache/.vera-signed" 2>/dev/null)" != "$IDENTITY" ]]; then
    echo "→ подпись $(basename "$cache")" >&2
    find "$cache" -type f \( -perm -u+x -o -name '*.so' -o -name '*.dylib' \) -print0 \
      | xargs -0 file 2>/dev/null | grep -E 'Mach-O' | cut -d: -f1 \
      | tr '\n' '\0' | xargs -0 -n 200 codesign --force --sign "$IDENTITY" --timestamp=none --preserve-metadata=entitlements >/dev/null 2>&1 || true
    print -r -- "$IDENTITY" > "$cache/.vera-signed"
  fi
}
clone() { cp -Rc "$1" "$2" 2>/dev/null || cp -R "$1" "$2"; rm -f "$2/.vera-signed"; }
# Hermes inside the app: the payload from scripts/build-hermes.sh (read-only at runtime) and Vera's plugins.
PAYLOAD="${VERA_HERMES_PAYLOAD:-$HOME/.vera03/build/payload}"
[[ -x "$PAYLOAD/bin/hermes" ]] || { echo "ошибка: нет пакета Hermes в $PAYLOAD — сначала scripts/build-hermes.sh" >&2; exit 1; }
cached "$PAYLOAD" "$PKG/.build/hermes-payload-copy" --exclude 'uv-cache/'
clone "$PKG/.build/hermes-payload-copy" "$APP/Contents/Resources/hermes"
mkdir -p "$APP/Contents/Resources/plugins"
for plugin in "$ROOT"/hermes-plugin/*/; do
  rsync -a --exclude '__pycache__' --exclude 'tests' "$plugin" "$APP/Contents/Resources/plugins/$(basename "$plugin")/" >&2
done
# The ears: sherpa-onnx and the speech models from scripts/build-ears.sh (pinned in ears.lock.json).
EARS="${VERA_EARS:-$HOME/.vera03/build/ears}"
[[ -f "$EARS/lib/lib/libsherpa-onnx-c-api.dylib" ]] || { echo "ошибка: нет ушей в $EARS — сначала scripts/build-ears.sh" >&2; exit 1; }
cp "$ROOT/ears.lock.json" "$APP/Contents/Resources/ears.lock.json"
cached "$EARS" "$PKG/.build/ears-copy" --exclude 'test_wavs' --exclude '*.wav' --exclude '*.py' --exclude '*.sh'
clone "$PKG/.build/ears-copy" "$APP/Contents/Resources/ears"
# The mouth: Silero TTS in its own Python, from scripts/build-mouth.sh.
MOUTH="${VERA_MOUTH:-$HOME/.vera03/build/mouth}"
[[ -x "$MOUTH/python/bin/python3" ]] || { echo "ошибка: нет рта в $MOUTH — сначала scripts/build-mouth.sh" >&2; exit 1; }
cached "$MOUTH" "$PKG/.build/mouth-copy" --exclude '__pycache__'
clone "$PKG/.build/mouth-copy" "$APP/Contents/Resources/mouth"
# Vera's voice without Python: Silero as ONNX with its text side's data (scripts/build-mouth-ios.sh), spoken by the
# Swift mouth on the ears' onnxruntime. Without it the mouth falls back to the Python worker above.
if [[ -f "$VOICE/silero-decoder.onnx" ]]; then
  rsync -a --delete --exclude 'reference.*' --exclude 'requirements.lock' "$VOICE/" "$APP/Contents/Resources/voice/"
fi
codesign --force --sign "$IDENTITY" --timestamp=none "$APP" >&2
pkill -TERM -f "$FINAL/Contents/MacOS/Vera" 2>/dev/null || true
rm -rf "$FINAL"
mv "$APP" "$FINAL"
echo "$FINAL"
