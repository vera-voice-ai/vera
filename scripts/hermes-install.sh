#!/bin/zsh
# Builder checkout for scripts/build-hermes.sh (not what Vera runs: she runs the payload inside Vera03.app).
#   hermes-install.sh            clone/switch to the tag in hermes.lock.json
#   hermes-install.sh v0.23.4    switch to that tag
# Everything lives under $VERA_HERMES_ROOT (default ~/.vera03/hermes): checkout, its pm toolchain.
# The owner's ~/.hermes and ~/.local/bin/hermes are never touched: HERMES_HOME/HERMES_RUNTIME_DIR point at the root,
# the full setup-hermes.sh (which publishes launchers to ~/.local/bin) is never run — only --runtime-only.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$REPO/hermes.lock.json"
ROOT="${VERA_HERMES_ROOT:-$HOME/.vera03/hermes}"
CHECKOUT="$ROOT/hermes-agent"
lockfield() { /usr/bin/python3 -c "import json; print(json.load(open('$LOCK'))['$1'])"; }
TAG="${1:-$(lockfield tag)}"
SOURCE="$(lockfield source)"
[[ "$TAG" =~ '^v[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "ошибка: нужен stable-тег вида v0.23.3, а не '$TAG'" >&2; exit 2; }
[[ "$ROOT" != "$HOME/.hermes"* ]] || { echo "ошибка: корень Веры не может быть внутри ~/.hermes" >&2; exit 2; }

export HERMES_HOME="$ROOT" HERMES_RUNTIME_DIR="$ROOT/tools" UV_NO_CONFIG=1
mkdir -p "$ROOT"
if [[ ! -d "$CHECKOUT/.git" ]]; then
  echo "→ клонирую $SOURCE @ $TAG в $CHECKOUT"
  git clone --quiet --filter=blob:none --branch "$TAG" "$SOURCE" "$CHECKOUT" 2>&1 | grep -v -i "detached" || true
else
  [[ -z "$(git -C "$CHECKOUT" status --porcelain)" ]] || { echo "ошибка: в $CHECKOUT есть локальные правки — ядро Hermes не правим" >&2; exit 1; }
  echo "→ переключаю $CHECKOUT на $TAG"
  git -C "$CHECKOUT" fetch --quiet --tags origin
  git -C "$CHECKOUT" -c advice.detachedHead=false checkout --quiet "$TAG"
fi

echo "→ зависимости (setup-hermes.sh --runtime-only, лог: $ROOT/../setup.log)"
( cd "$CHECKOUT" && bash setup-hermes.sh --runtime-only ) > "$ROOT/../setup.log" 2>&1 || { tail -20 "$ROOT/../setup.log"; exit 1; }

# Never expose this copy on PATH: `hermes` in the shell stays the owner's.
"$CHECKOUT/.hermes/bin/hermes" config set --force cli.expose_on_path false >/dev/null 2>&1 || true
"$CHECKOUT/.hermes/bin/hermes" --version | head -1
