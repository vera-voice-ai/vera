#!/bin/zsh
# Compare the installed Hermes (and optionally a candidate ref) with hermes.lock.json.
# Usage: hermes-check.sh [--fetch] [ref]     ref defaults to the installed HEAD.
# Read-only: never checks out, never updates. --fetch only downloads tags into Vera's clean copy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOCK="$ROOT/hermes.lock.json"
DIR="${VERA_HERMES_ROOT:-$HOME/.vera03/hermes}/hermes-agent"
FETCH=0
if [[ "${1:-}" == "--fetch" ]]; then FETCH=1; shift; fi
REF="${1:-HEAD}"

field() { /usr/bin/python3 -c "import json,sys; d=json.load(open('$LOCK')); v=d['$1']; print('\n'.join(v) if isinstance(v,list) else v)"; }
LOCK_COMMIT=$(field commit); LOCK_TAG=$(field tag)
G() { git -C "$DIR" "$@"; }

if (( FETCH )); then
  echo "→ забираю теги с origin…"
  G fetch --tags --quiet origin
fi

HEAD_COMMIT=$(G rev-parse HEAD)
TARGET=$(G rev-parse "$REF^{commit}")
STABLE=$(G tag --points-at "$TARGET" | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true)
# Hermes has two tag schemes (v0.23.2 and v2026.9.24): the newest stable is the newest by date.
LATEST=$(G tag --list 'v*' --sort=-creatordate | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | head -1)

echo "замок:         $LOCK_TAG  ${LOCK_COMMIT:0:12}"
echo "установлено:   $(G describe --tags --always HEAD)  ${HEAD_COMMIT:0:12}"
echo "кандидат:      $REF -> ${STABLE:-не stable-тег}  ${TARGET:0:12}"
echo "последний stable в локальных тегах: $LATEST"
echo

if [[ "$TARGET" == "$LOCK_COMMIT" ]]; then
  echo "✓ кандидат совпадает с замком"
else
  echo "── изменения в путях-контрактах ${LOCK_COMMIT:0:12}..${TARGET:0:12}"
  PATHS=("${(@f)$(field contract_paths)}")
  if G diff --quiet "$LOCK_COMMIT" "$TARGET" -- "${PATHS[@]}"; then
    echo "✓ контракты не менялись — для Веры обновление безопасно"
  else
    G diff --stat "$LOCK_COMMIT" "$TARGET" -- "${PATHS[@]}"
    echo "! контракты менялись: прочитай дифф (git -C $DIR diff ${LOCK_COMMIT:0:12} ${TARGET:0:12} -- <путь>)"
  fi
fi
echo
echo "── хуки vera-pulse в кандидате"
VALID=$(G show "${TARGET}:hermes_cli/plugins.py")
MISSING=0
for hook in "${(@f)$(field hooks_used)}"; do
  if print -r -- "$VALID" | grep -q "\"$hook\""; then echo "  ✓ $hook"; else echo "  ✗ $hook — нет в VALID_HOOKS"; MISSING=1; fi
done
exit $MISSING
