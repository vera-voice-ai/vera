#!/bin/zsh
# Build the Hermes payload that goes inside Vera03.app (official `pm bundle`: source without .git,
# pinned CPython, ready dependencies, relocatable launchers in bin/).
#   build-hermes.sh            tag from hermes.lock.json
#   build-hermes.sh v0.23.4    another stable tag (candidate; see docs/hermes-updates.md)
#   build-hermes.sh --stamp    only (re)write the stamps of the existing payload
# Workspace: ~/.vera03 (builder checkout ~/.vera03/hermes, output ~/.vera03/build/payload).
# Never touches ~/.hermes or ~/.local/bin.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$REPO/hermes.lock.json"
WORK="${VERA_BUILD_ROOT:-$HOME/.vera03}"
BUILDER="$WORK/hermes"                 # HERMES_HOME of the builder checkout
SRC="$BUILDER/hermes-agent"
OUT="$WORK/build/payload"
lockfield() { /usr/bin/python3 -c "import json; print(json.load(open('$LOCK'))['$1'])"; }
STAMP_ONLY=0
if [[ "${1:-}" == "--stamp" ]]; then STAMP_ONLY=1; shift; fi
TAG="${1:-$(lockfield tag)}"
[[ "$TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "ошибка: нужен stable-тег вида v0.23.3" >&2; exit 2; }

export HERMES_HOME="$BUILDER" HERMES_RUNTIME_DIR="$BUILDER/tools" UV_NO_CONFIG=1
if (( ! STAMP_ONLY )); then
  # 1. Builder checkout on the tag, with its own pm toolchain (runtime-only: no launchers on PATH).
  VERA_HERMES_ROOT="$BUILDER" "$REPO/scripts/hermes-install.sh" "$TAG"
  # 2. The payload, into a temp folder first so a failed build never leaves half a payload.
  PY=$(ls -d "$BUILDER"/tools/python-*/bin/python3 | head -1)
  rm -rf "$OUT.tmp"; mkdir -p "$(dirname "$OUT")"
  echo "→ pm bundle $TAG (лог: $WORK/build/bundle.log)"
  ( cd "$SRC" && "$PY" -m pm.cli bundle --out "$OUT.tmp" --ref "$TAG" ) > "$WORK/build/bundle.log" 2>&1 \
    || { tail -20 "$WORK/build/bundle.log"; exit 1; }
  rm -rf "$OUT"; mv "$OUT.tmp" "$OUT"
fi
[[ -x "$OUT/bin/hermes" ]] || { echo "ошибка: пакета нет в $OUT" >&2; exit 1; }

# 3. Stamps: Hermes' own (version, and that Vera — not `hermes update` — replaces this tree)
#    and Vera's (what she shows and checks against the lock).
COMMIT=$(git -C "$SRC" rev-parse "$TAG^{commit}")
DATE=$(git -C "$SRC" log -1 --format=%ct "$COMMIT")
VERSION="${TAG#v}"
( cd "$SRC" && "$(ls -d "$BUILDER"/tools/python-*/bin/python3 | head -1)" -I scripts/write_install_stamp.py \
    --output "$OUT/hermes-agent/install-stamp.json" --commit "$COMMIT" --base-version "$VERSION" \
    --display-version "$VERSION" --distance 0 --commit-date "$DATE" --source build \
    --update-mechanism external --runtime-dir ../tools ) >/dev/null
/usr/bin/python3 - "$OUT/vera-payload.json" "$TAG" "$COMMIT" <<'PY'
import json, sys, datetime
path, tag, commit = sys.argv[1:]
json.dump({"tag": tag, "commit": commit,
           "built_at": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")},
          open(path, "w"), indent=2)
PY
du -sh "$OUT" | awk '{print "пакет: " $1}'
env -i HOME="$WORK/build/probe-home" HERMES_HOME="$WORK/build/probe-hermes" PATH="$OUT/bin:/usr/bin:/bin" \
  LANG=en_US.UTF-8 "$OUT/bin/hermes" --version | head -1
rm -rf "$WORK/build/probe-home" "$WORK/build/probe-hermes"
