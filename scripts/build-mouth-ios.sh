#!/bin/zsh
# Vera's voice for the iPhone: the Mac mouth's Silero model (scripts/build-mouth.sh, ears.lock.json → mouth) turned
# into three ONNX networks plus the data of its text side, checked against the original sentence by sentence.
#   build-mouth-ios.sh            → ~/.vera03/build/mouth-ios/out (scripts/phone-assets.sh copies it into the app)
#   build-mouth-ios.sh --golden   the same, and rewrite app/Tests/SileroVoiceTests/golden.json from the original
# Export tools (onnx, onnxscript; ears.lock.json → mouth → ios) live in a venv of the mouth's own Python, under
# ~/.vera03/build — nothing from the machine. Needs once and when the model or the export changes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="${VERA_BUILD_ROOT:-$HOME/.vera03}/build"
MOUTH="$B/mouth"; WORK="$B/mouth-ios"; OUT="$WORK/out"; TMP="$WORK/out.tmp"
MODEL=$(ls "$MOUTH"/models/*.pt 2>/dev/null | head -1)
[[ -x "$MOUTH/python/bin/python3" && -n "$MODEL" ]] || { echo "ошибка: нет рта в $MOUTH — сначала scripts/build-mouth.sh" >&2; exit 1; }
PKGS=($(/usr/bin/python3 -c "import json; print(' '.join(json.load(open('$ROOT/ears.lock.json'))['mouth']['ios']['pip']))"))
VENV="$WORK/venv"
if ! "$VENV/bin/python" -c "import onnx, onnxscript" 2>/dev/null; then
  rm -rf "$VENV"
  "$MOUTH/python/bin/python3" -m venv --system-site-packages "$VENV"
fi
echo "→ pip: ${PKGS[*]}"
env -i HOME="$WORK" PATH=/usr/bin:/bin PIP_CACHE_DIR="$B/../downloads/pip" PYTHONNOUSERSITE=1 \
  "$VENV/bin/python" -m pip install --quiet --disable-pip-version-check --only-binary :all: "${PKGS[@]}"
GOLDEN=()
[[ "${1:-}" == "--golden" ]] && GOLDEN=("$ROOT/scripts/mouth-ios/golden-text.txt" "$ROOT/app/Tests/SileroVoiceTests/golden.json")
rm -rf "$TMP"; mkdir -p "$TMP"
echo "→ экспорт $(basename "$MODEL")"
(cd "$WORK" && env -i HOME="$WORK" PATH=/usr/bin:/bin PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 OMP_NUM_THREADS=4 \
  "$VENV/bin/python" -I "$ROOT/scripts/mouth-ios/export.py" "$MODEL" "$TMP" "${GOLDEN[@]}" 2>&1 \
  | grep -v "torchvision is not installed\|TypedStorage is deprecated\|storage_type.dtype\|^\[torch.onnx\]")
env -i HOME="$WORK" PATH=/usr/bin:/bin "$VENV/bin/python" -m pip freeze --disable-pip-version-check > "$TMP/requirements.lock"
/usr/bin/python3 -c "
import json, sys; l = json.load(open('$ROOT/ears.lock.json'))['mouth']
json.dump({'model': l['model']['name'], 'model_sha256': l['model']['sha256'], 'speaker': l['speaker'],
           'sample_rate': l['sample_rate'], 'opset': l['ios']['opset'], 'pip': l['ios']['pip']},
          open('$TMP/mouth-ios.stamp.json', 'w'), indent=2)"
rm -rf "$OUT"; mv "$TMP" "$OUT"
du -sh "$OUT"
echo "$OUT"
