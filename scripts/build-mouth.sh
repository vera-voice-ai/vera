#!/bin/zsh
# Vera's mouth for the box: Silero TTS (voice from ears.lock.json → mouth) in a Python of its own.
#   build-mouth.sh          copy the builder's CPython, install the pinned packages, fetch and check the model
#   build-mouth.sh --pin    the same, and write the model's sha256 into the lock (only when changing versions)
# Output: ~/.vera03/build/mouth (python/, models/, worker.py, mouth.stamp.json). Touches nothing outside ~/.vera03.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${VERA_BUILD_ROOT:-$HOME/.vera03}"
PIN=0; [[ "${1:-}" == "--pin" ]] && PIN=1
PYSRC=$(ls -d "$WORK"/hermes/tools/python-*/ 2>/dev/null | head -1)
[[ -x "$PYSRC/bin/python3" ]] || { echo "ошибка: нет сборочного Python в $WORK/hermes/tools — сначала scripts/build-hermes.sh" >&2; exit 1; }
OUT="$WORK/build/mouth"; TMP="$OUT.tmp"
rm -rf "$TMP"; mkdir -p "$TMP/models" "$WORK/downloads/pip"
echo "→ Python: $(basename "$PYSRC")"
cp -R "$PYSRC" "$TMP/python"
PY="$TMP/python/bin/python3"
PKGS=($(/usr/bin/python3 -c "import json; print(' '.join(json.load(open('$REPO/ears.lock.json'))['mouth']['pip']))"))
echo "→ pip: ${PKGS[*]}"
env -i HOME="$WORK" PATH=/usr/bin:/bin PIP_CACHE_DIR="$WORK/downloads/pip" PYTHONNOUSERSITE=1 \
  "$PY" -m pip install --quiet --disable-pip-version-check --only-binary :all: "${PKGS[@]}"
env -i HOME="$WORK" PATH=/usr/bin:/bin "$PY" -m pip freeze --disable-pip-version-check > "$TMP/requirements.lock"
cp "$REPO/scripts/mouth-worker.py" "$TMP/worker.py"
cp "$REPO/scripts/smart-turn-worker.py" "$TMP/smart-turn-worker.py"
cp "$REPO/scripts/smart-turn-mel-filters.npy" "$TMP/smart-turn-mel-filters.npy"
/usr/bin/python3 -I - "$REPO/ears.lock.json" "$WORK" "$TMP" "$PIN" <<'PY'
import hashlib, json, os, subprocess, sys
lock_path, work, out, pin = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
lock = json.load(open(lock_path))
for m in [lock["mouth"]["model"], lock["mouth"]["smart_turn"]]:
  cached = os.path.join(work, "downloads", os.path.basename(m["url"]))
  if not os.path.exists(cached):
      print(f"→ модель {m['name']}", flush=True)
      subprocess.run(["/usr/bin/curl", "-fsSL", "--retry", "3", "-o", cached + ".part", m["url"]], check=True)
      os.replace(cached + ".part", cached)
  h = hashlib.sha256()
  with open(cached, "rb") as f:
      for block in iter(lambda: f.read(1 << 20), b""): h.update(block)
  if m["sha256"] != h.hexdigest():
      if pin and not m["sha256"]:
          m["sha256"] = h.hexdigest()
          with open(lock_path, "w") as f: json.dump(lock, f, indent=2, ensure_ascii=False); f.write("\n")
          print("замок обновлён: sha256 модели записан")
      else:
          sys.exit(f"ошибка: {m['name']}: sha256 {h.hexdigest()}, в замке {m['sha256'] or 'пусто (нужен --pin)'}")
  os.link(cached, os.path.join(out, m["dest"])) if not os.path.exists(os.path.join(out, m["dest"])) else None
json.dump({"python": os.path.basename(os.path.realpath(os.path.join(out, "python"))), "pip": lock["mouth"]["pip"],
           "model": lock["mouth"]["model"]["name"], "smart_turn": lock["mouth"]["smart_turn"]["name"], "speaker": lock["mouth"]["speaker"], "sample_rate": lock["mouth"]["sample_rate"]},
          open(os.path.join(out, "mouth.stamp.json"), "w"), indent=2)
PY
rm -rf "$OUT"; mv "$TMP" "$OUT"
du -sh "$OUT"
echo "$OUT"
