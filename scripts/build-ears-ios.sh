#!/bin/zsh
# The iPhone's ears and voice: sherpa-onnx (static, with TTS) built for iOS from its sources at the pinned commit,
# plus the onnxruntime iOS xcframework its build script fetches. Result: ~/.vera03/build/ears-ios/{sherpa-onnx,
# onnxruntime}.xcframework, linked by phone/VeraPhoneDeps. Needs once and when the version in ears.lock.json
# changes. Build tools live in Vera's own build venv (cmake from PyPI) — nothing from Homebrew.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
B="$HOME/.vera03/build"
SRC="$B/src/sherpa-onnx"
OUT="$B/ears-ios"
read -r TAG COMMIT CMAKE <<<"$(/usr/bin/python3 -c "
import json; i=json.load(open('$ROOT/ears.lock.json'))['ios']; print(i['sherpa_onnx'], i['commit'], i['cmake'])")"

[[ -x "$B/tools-venv/bin/cmake" ]] || {
  "$B/mouth/python/bin/python3" -m venv "$B/tools-venv"
  "$B/tools-venv/bin/pip" install -q "cmake==$CMAKE"
}
# build-ios.sh calls wget; this Mac has curl.
cat > "$B/tools-venv/bin/wget" <<'EOF'
#!/bin/sh
for a in "$@"; do case "$a" in -*) ;; *) url="$a";; esac; done
exec /usr/bin/curl -fL --retry 3 -C - -O "$url"
EOF
chmod +x "$B/tools-venv/bin/wget"

if [[ ! -d "$SRC/.git" ]]; then
  mkdir -p "$B/src"
  git clone -q --depth 1 --branch "$TAG" https://github.com/k2-fsa/sherpa-onnx.git "$SRC"
fi
[[ "$(git -C "$SRC" rev-parse HEAD)" == "$COMMIT" ]] || { echo "ошибка: sherpa-onnx не на $COMMIT" >&2; exit 1; }

cd "$SRC"
PATH="$B/tools-venv/bin:/usr/bin:/bin:/usr/sbin:/sbin" ./build-ios.sh >"$B/ears-ios-build.log" 2>&1 \
  || { echo "ошибка сборки — $B/ears-ios-build.log" >&2; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"
cp -R "$SRC/build-ios/sherpa-onnx.xcframework" "$OUT/"
cp -RL "$SRC/build-ios/ios-onnxruntime/onnxruntime.xcframework" "$OUT/"
echo "$OUT"
