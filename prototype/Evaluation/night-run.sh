#!/bin/zsh
# One safe check of Vera: unit tests and the three TaskBench suites. It builds and reads; it never touches the live app,
# the owner's data or the git history. Results go to ~/Library/Application Support/VeraSensorPrototype/NightLog/.
# Usage: night-run.sh            one run
#        night-run.sh loop       runs at +1 h, +2 h, then every 30 min until 07:00 local time
# Needs OPENCODE_API_KEY in the environment (or the Keychain item) for TaskBench.
setopt no_unset
ROOT=/Users/alex/Projects/vera-v2/prototype
LOG="$HOME/Library/Application Support/VeraSensorPrototype/NightLog"
mkdir -p "$LOG"

run_once() {
  local stamp=$(date +%Y-%m-%dT%H-%M-%S) lock="$LOG/.lock"
  if [ -e "$lock" ] && kill -0 "$(cat "$lock")" 2>/dev/null; then echo "$stamp skipped: previous run still going" >> "$LOG/summary.log"; return; fi
  echo $$ > "$lock"
  cd "$ROOT" || return
  local out="$LOG/$stamp.txt"
  { echo "# git: $(git rev-parse --short HEAD), dirty files: $(git status --porcelain | wc -l | tr -d ' ')"
    swift test 2>&1 | grep -E "✘|Test run with|error:" | head -20
    for suite in basic spoken repo; do echo "## TaskBench $suite"; swift run TaskBench $suite 2>&1 | grep -E "^\| .* \| NO \||^passed|No API key|error:"; done
  } > "$out" 2>&1
  local tests=$(grep -E "Test run with" "$out" | head -1 | sed -E 's/.*Test run with ([0-9]+) tests.*(passed|failed).*/\1 \2/')
  local bench=$(grep -E "^passed" "$out" | sed -E 's/passed ([0-9]+\/[0-9]+) · median ([0-9]+) ms.*/\1 (\2 ms)/' | paste -sd ' ' -)
  local bad=$(grep -cE "✘|\| NO \||error:|No API key" "$out")
  echo "$stamp tests: ${tests:-?} | basic/spoken/repo: ${bench:-?} | problems: $bad" >> "$LOG/summary.log"
  # On a failure, and only then, a headless Claude is asked to find the cause and fix it in the repo (tests must pass, commit on this branch, no push).
  if [ "$bad" != "0" ] && [ "${NIGHT_FIX:-1}" = "1" ] && command -v claude >/dev/null; then
    timeout 1500 claude -p "Ночная проверка Веры упала. Отчёт: $out (в нём провалившиеся тесты и задачи TaskBench). Следуй AGENTS.md репозитория /Users/alex/Projects/vera-v2. Найди причину и исправь минимально в ветке scene-core-prototype; убедись, что swift test проходит, закоммить (без push). Не трогай живое приложение, данные Алексея и ключи. Если причина во внешнем сервисе или ключе, ничего не правь, только объясни в одной строке." \
      --permission-mode acceptEdits --max-turns 40 > "$LOG/$stamp-fix.txt" 2>&1
    echo "$stamp fix attempt finished, see $stamp-fix.txt" >> "$LOG/summary.log"
  fi
  rm -f "$lock"
}

if [ "${1:-}" = "loop" ]; then
  sleep 3600; run_once
  sleep 3600; run_once
  while [ "$(date +%H%M)" -lt 0700 ] || [ "$(date +%H)" -ge 12 ]; do
    run_once; sleep 1800
  done
else
  run_once
fi
