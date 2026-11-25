#!/bin/zsh
# What the iPhone app carries inside but git does not: sherpa-onnx + onnxruntime for iOS (scripts/build-ears-ios.sh)
# the speech models from the Mac's ears (scripts/build-ears.sh, pinned in ears.lock.json): Silero VAD, GigaAM v3, and
# Vera's voice — Silero baya as ONNX with its text side's data (scripts/build-mouth-ios.sh).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/phone"
IOS="${VERA_EARS_IOS:-$HOME/.vera03/build/ears-ios}"
EARS="${VERA_EARS:-$HOME/.vera03/build/ears}"
VOICE="${VERA_MOUTH_IOS:-$HOME/.vera03/build/mouth-ios/out}"
[[ -d "$IOS/sherpa-onnx.xcframework" ]] || { echo "ошибка: нет $IOS — сначала scripts/build-ears-ios.sh" >&2; exit 1; }
[[ -f "$EARS/models/gigaam/model.int8.onnx" ]] || { echo "ошибка: нет ушей в $EARS — сначала scripts/build-ears.sh" >&2; exit 1; }
[[ -f "$VOICE/silero-decoder.onnx" ]] || { echo "ошибка: нет голоса в $VOICE — сначала scripts/build-mouth-ios.sh" >&2; exit 1; }
mkdir -p "$APP/VeraPhoneDeps/Frameworks" "$APP/Models/gigaam" "$APP/Models/vad" "$APP/Models/silero"
rsync -a --delete "$IOS/sherpa-onnx.xcframework/" "$APP/VeraPhoneDeps/Frameworks/sherpa-onnx.xcframework/"
rsync -a --delete "$IOS/onnxruntime.xcframework/" "$APP/VeraPhoneDeps/Frameworks/onnxruntime.xcframework/"
rsync -a "$EARS/models/gigaam/model.int8.onnx" "$EARS/models/gigaam/tokens.txt" "$APP/Models/gigaam/"
rsync -a "$EARS/models/vad/silero_vad.onnx" "$APP/Models/vad/"
rsync -a --delete --exclude reference.f32 --exclude reference.txt --exclude requirements.lock "$VOICE/" "$APP/Models/silero/"
cp "$ROOT/ears.lock.json" "$APP/Models/ears.lock.json"
