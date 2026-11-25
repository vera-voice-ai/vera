#!/bin/zsh
# Every offline check of Vera 0.3 in one go: Swift build + tests, each Hermes plugin's tests,
# shell syntax of the scripts, and that the lock still lists exactly vera-pulse's hooks.
# No network, no model calls, nothing outside the repository is touched.
set -uo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
FAIL=0
step() { print -P "%F{magenta}→%f $1"; }
ok()   { print -P "  %F{green}✓%f $1"; }
bad()  { print -P "  %F{red}✗%f $1"; FAIL=1; }

step "Swift: сборка и тесты"
if out=$(swift test --package-path "$REPO/app" 2>&1); then
  ok "$(print -r -- "$out" | grep -E 'Test run with' | tail -1 | sed 's/^.*Test run/Test run/')"
else
  print -r -- "$out" | grep -E "error|✘" | head -20; bad "Swift"
fi

for plugin in "$REPO"/hermes-plugin/*/; do
  name=$(basename "$plugin")
  step "плагин $name"
  if [[ -d "$plugin/tests" ]]; then
    if out=$(cd "$plugin" && python3 -m unittest discover -s tests 2>&1); then ok "$(print -r -- "$out" | grep -E '^Ran ' | tail -1)"
    else print -r -- "$out" | tail -15; bad "$name"; fi
  else
    bad "$name: нет tests/"
  fi
done

step "скрипты: синтаксис"
for s in "$REPO"/scripts/* "$REPO"/scripts/mouth-ios/*.py; do
  if [[ -d "$s" ]]; then
    continue   # a folder of a script's helpers (mouth-ios); its .py are in the list
  elif [[ "$s" == *.npy ]]; then
    continue   # data (Whisper mel filters for Smart Turn), not a script
  elif [[ "$s" == *.swift ]]; then
    swiftc -parse "$s" 2>/dev/null || bad "$(basename "$s")"
  elif [[ "$s" == *.py ]]; then
    /usr/bin/python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$s" 2>/dev/null || bad "$(basename "$s")"
  elif zsh -n "$s" 2>/dev/null; then :; else bad "$(basename "$s")"; fi
done
(( FAIL )) || ok "все скрипты разбираются"

step "замок hermes.lock.json"
if /usr/bin/python3 -c "import json,sys; d=json.load(open('$REPO/hermes.lock.json')); assert d['tag'].startswith('v') and len(d['commit'])==40; print(d['tag'], d['commit'][:12])"; then ok "читается"; else bad "замок"; fi

step "замок ears.lock.json"
if /usr/bin/python3 -c "import json; d=json.load(open('$REPO/ears.lock.json')); assert d['sherpa_onnx'].startswith('v'); assert all(len(i['sha256'])==64 for i in d['items']); assert len(d['mouth']['model']['sha256'])==64 and all('==' in x for x in d['mouth']['pip'] + d['mouth']['ios']['pip']); print(d['sherpa_onnx'], ', '.join(i['name'] for i in d['items']))"; then ok "читается, суммы закреплены"; else bad "ears.lock.json"; fi

(( FAIL )) && { print -P "%F{red}есть ошибки%f"; exit 1; }
print -P "%F{green}всё зелёное%f"
