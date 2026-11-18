#!/bin/zsh
# Overnight work on Vera. Each run: safe checks (unit tests, TaskBench), then one headless Claude session that makes a
# small, tested improvement and commits it on the branch (never pushes). Safety rules are in the prompt below.
# Usage: night-run.sh          one run
#        night-run.sh loop     runs at +1 h, +2 h, then every 30 min until 01:00 local time
# Needs OPENCODE_API_KEY in the environment for TaskBench. NIGHT_DEV=0 turns the development session off (checks only).
setopt no_unset
ROOT=/Users/alex/Projects/vera-v2
LOG="$HOME/Library/Application Support/VeraSensorPrototype/NightLog"
mkdir -p "$LOG"

with_timeout() { local seconds=$1; shift; perl -e 'alarm shift; exec @ARGV' "$seconds" "$@"; }

run_once() {
  local stamp=$(date +%Y-%m-%dT%H-%M-%S) lock="$LOG/.lock"
  if [ -e "$lock" ] && kill -0 "$(cat "$lock")" 2>/dev/null; then echo "$stamp skipped: previous run still going" >> "$LOG/summary.log"; return; fi
  echo $$ > "$lock"
  cd "$ROOT/prototype" || return
  local out="$LOG/$stamp.txt"
  { echo "# git: $(git rev-parse --short HEAD), dirty files: $(git status --porcelain | wc -l | tr -d ' ')"
    swift test 2>&1 | grep -E "✘|Test run with|error:" | head -20
    for suite in basic spoken repo; do echo "## TaskBench $suite"; swift run TaskBench $suite 2>&1 | grep -E "^\| .* \| NO \||^passed|No API key|error:"; done
  } > "$out" 2>&1
  local tests=$(grep -E "Test run with" "$out" | head -1 | sed -E 's/.*Test run with ([0-9]+) tests.*(passed|failed).*/\1 \2/')
  local bench=$(grep -E "^passed" "$out" | sed -E 's/passed ([0-9]+\/[0-9]+) · median ([0-9]+) ms.*/\1 (\2 ms)/' | paste -sd ' ' -)
  local bad=$(grep -cE "✘|\| NO \||error:|No API key" "$out")
  echo "$stamp tests: ${tests:-?} | basic/spoken/repo: ${bench:-?} | problems: $bad" >> "$LOG/summary.log"

  if [ "${NIGHT_DEV:-1}" = "1" ] && command -v claude >/dev/null; then
    cd "$ROOT"
    local now=$(date +%H:%M)
    with_timeout 2400 claude -p "Ты ведёшь ночную доработку Веры 2 (личный голосовой помощник Алексея; он спит). Сейчас $now. Ты запущен скриптом каждые 30–60 минут; контекста между запусками нет, поэтому читай AGENTS.md, docs/index.html (единственная документация; раздел «Ночной журнал проверок» и ADR-009) и git log, а также память проекта.
ЦЕЛЬ: к утру Вера должна работать качественно и решать конкретные задачи голосом так, чтобы быть не менее полезной, чем Claude, а для задач Алексея полезнее. Отчёт последней проверки: $out (строки с NO — проваленные задачи TaskBench; ✘ — тесты). Сначала почини всё упавшее. Если всё зелёное, сделай ОДНУ небольшую доработку с тестами, по приоритету: (1) качество на устных задачах и скорость ответа; (2) новые честные TaskBench-задачи, в том числе где Вера правит КОПИЮ своего кода в песочнице и проверка смотрит результат и что остальное не тронуто; (3) надёжность ядра: ошибки инструментов, длинные выводы, отмена, режим тишины; (4) согласованность документации. Не записывай в документацию таксономию задач V0.1.
БЕЗОПАСНОСТЬ (нарушать нельзя): все проверки только в временных песочницах; не трогай данные Алексея в ~/Library/Application Support/VeraSensorPrototype (кроме NightLog), Keychain, ключи, живое приложение (не убивай и не перезапускай; исключение: последний запуск после 06:00, когда тесты и все наборы TaskBench зелёные — тогда можно выполнить prototype/Evaluation/rebuild-live.sh и запустить .build/VeraSensorPrototype.app/Contents/MacOS/VeraSensorPrototype --listen --agent в фоне через nohup, оставив ключ из окружения); никаких push, удалений вне песочниц, новых моделей или загрузок, сетевых запросов кроме эндпоинта OpenCode Go через TaskBench; владелец-только правило сцены (без Алексея в сцене запросы в ядро не идут) не ослаблять; инструменты Веры остаются в рабочей папке. Работай на ветке scene-core-prototype, коммить каждую завершённую задачу после зелёных swift test и TaskBench (строка Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com> в конце сообщения). Архитектурные решения записывай в docs/index.html только черновиками ADR (не принятыми), синхронизируй диаграммы, события и примеры. В конце добавь одну строку в раздел «Ночной журнал проверок» (id night-entries) и закоммить. Если провалы вызваны внешним сервисом или ключом, ничего не правь, только запиши причину." \
      --permission-mode acceptEdits --max-turns 60 --allowedTools "Read" "Edit" "Write" "Bash(swift *)" "Bash(git add *)" "Bash(git commit *)" "Bash(git status*)" "Bash(git log*)" "Bash(git diff*)" "Bash(ls*)" "Bash(cat *)" "Bash(grep *)" "Bash(sed *)" "Bash(python3 *)" "Bash(zsh prototype/Evaluation/*)" "Bash(prototype/Evaluation/*)" "Bash(nohup *)" "Bash(date*)" > "$LOG/$stamp-dev.txt" 2>&1
    echo "$stamp dev session finished (see $stamp-dev.txt)" >> "$LOG/summary.log"
  fi
  rm -f "$lock"
}

if [ "${1:-}" = "loop" ]; then
  run_once; sleep 3600; run_once; sleep 3600; run_once
  # Until 01:00 local (Moscow) time: the owner wakes at about 01:30 Moscow time.
  end=$(date -j -f "%Y-%m-%d %H:%M" "$(date +%Y-%m-%d) 01:00" +%s)
  [ "$(date +%s)" -gt "$end" ] && end=$(( end + 86400 ))
  while [ "$(date +%s)" -lt "$end" ]; do
    run_once; sleep 1800
  done
else
  run_once
fi
