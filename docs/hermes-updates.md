# Hermes внутри Веры: устройство, сборка, обновление

Документ живой: механизм пишем по факту, по мере того как проходим реальные обновления.
Каждое пройденное обновление добавляем в «Журнал обновлений» внизу.

## Самодостаточность (решение от 2026-11-21)

Вера 0.3 несёт Hermes в себе и ничего не берёт с машины: ни `~/.hermes`, ни `hermes` на PATH,
ни переменные окружения пользователя.

```
Vera03.app/Contents/
├── MacOS/Vera
└── Resources/
    ├── hermes/                 пакет Hermes (только чтение): bin/hermes, hermes-agent/ (код без .git),
    │                           tools/ (CPython, node, chromium…), venv/ (зависимости), vera-payload.json
    ├── plugins/vera-pulse/     наш плагин-наблюдатель (пульс)
    ├── plugins/vera-setup/     наш плагин настройки (модель по умолчанию, бот Telegram, лимиты плана)
    ├── plugins/vera-ears/      распознаватель голосовых `gigaam` (TranscriptionProvider → `Vera --transcribe`)
    ├── plugins/vera-phone/     инструменты навигатора iPhone (`ctx.register_tool`, транспорт — файлы `phone-bridge/`)
    ├── plugins/vera-context/   описание каналов (`ctx.register_system_prompt_section` + `pre_llm_call`)
    └── hermes.lock.json
~/Library/Application Support/Vera03/      данные Веры (удалить вместе с приложением = ничего не осталось)
├── hermes/                     HERMES_HOME: config.yaml, .env (ключи), sessions, memories, logs, plugins/vera-pulse →
│   └── vera-pulse/             журнал пульса
└── home/                       HOME процессов Hermes
```

- **Пакет** собирается официальным `pm bundle` Hermes — тем же, что собирает его Desktop-приложение:
  код без `.git`, закреплённый CPython, хэш-проверенные зависимости, переносимые лаунчеры в `bin/`.
- **Штамп** `hermes-agent/install-stamp.json` пишем официальным `scripts/write_install_stamp.py` с
  `updateMechanism: external`: Hermes знает, что его обновляет не `hermes update`, а Вера, и не публикует
  свои команды на PATH. Вдобавок в конфиге `cli.expose_on_path: false`.
- **Окружение процессов Hermes** собирает Вера с нуля (`HermesRuntime.environment`): `HOME`, `HERMES_HOME`,
  `PATH` = `пакет/bin` + системные `/usr/bin:/bin:/usr/sbin:/sbin`, язык, `USER`/`TMPDIR`. Переменные
  пользователя (ключи API, PATH с Homebrew, `HERMES_*`) до Hermes не доходят.
- **Свой HOME** — потому что Hermes сам заглядывает в домашнюю папку (`Path.home()`): мастер настройки ищет
  `~/.claude`, `~/.codex`, `~/.cursor`, первый запуск кладёт лаунчеры в `~/.local/bin`. С подменённым HOME
  он видит и пишет только папку Веры. Это не песочница: по абсолютному пути агент (терминал, файлы) может
  дойти до любых файлов пользователя — так задумано, иначе агент бесполезен.
- **Шлюз** — свой: `hermes gateway attach --recover` под окружением Веры поднимает его из пакета
  (без launchd, гаснет сам после простоя).
- **Настройка** — в окне «Настройка» Веры по сокету шлюза: провайдеры и ключ — штатные методы
  (`model.options`, `model.save_key`, `setup.status`), те же, что у Desktop Hermes. Модель по умолчанию —
  через наш плагин `vera-setup` (RPC `plugin.vera-setup.set_main_model`): штатный `config.set model` работает
  только внутри живой сессии (отвечает 4001), а Desktop пишет её через HTTP `POST /api/model/set`; плагин
  вызывает ту же функцию (`web_server_config._prepare_main_assignment` + `_apply_model_assignment_sync`).
  Это внутренние имена Hermes — они в путях-контрактах замка. Ключ идёт по локальному сокету.
- **Лимиты плана** — `plugin.vera-setup.account_usage`: внутри Hermes `hermes_cli.runtime_provider.resolve_runtime_provider`
  + `agent.account_usage.fetch_account_usage` (тот же путь, что `/usage`); наружу — окна, проценты, сброс. Оба пути — в
  `contract_paths` замка.
- **Инструменты и описание каналов** — `vera-phone` (`ctx.register_tool`, вызов `handler(args, **kw)` → строка JSON) и
  `vera-context` (`ctx.register_system_prompt_section` — `session_info` с `session_id`, `platform`, `client`; хук
  `pre_llm_call` с `session_id`, `platform`). Вера передаёт `client` в `session.create` (`gateway/session_client.py`).
  При смене версии проверь эти сигнатуры.
- **Браузер Веры** — `browser.cdp_url: http://127.0.0.1:9333` (Вера ставит один раз, метка `.vera-browser-1`):
  `browser_exec` работает в окне Веры; хук `pre_tool_call` плагина vera-browser открывает окно, если порт молчит
  (имена `browser_exec`, `browser_cdp`, `browser_dialog` — сверять при обновлении). Chromium берём тот, что Hermes
  поставил себе (`hermes/tools/chromium-*`).
- **Команды в «Вводе»** — маршрут клиента Hermes для сессий общего шлюза (`hermes_cli/gateway_chat_view.py`,
  `gateway_chat_commands.py`, `gateway_mutations.slash_mutation` — в замке), у нас `HermesBridge/GatewayCommands`:
  `/model` `/compress` `/title <имя>` `/undo` `/retry` — `session.mutate` (ревизия и поколение из `session.resume`;
  предупреждение Hermes о модели — `confirmation_required`, согласие — `/model … --yes`, тот же запрос с `confirm`),
  `/stop` — `session.interrupt`, `/yolo` — `config.set`, остальное — `slash.exec`; его отказ `unsupported_command`
  показывается как есть (раньше подменялся ошибкой запасного `command.dispatch`), `4018` (навык) — `command.dispatch`.
  `/new` и `/branch` у Веры не выполняются: разговор один. При обновлении сверить этот маршрут.
- **Сессий в `session.list`** — не больше 200 за страницу (`scope: stored`); больше — `invalid_params` на весь вызов.
- **Опись Hermes на схеме** — `tools.list` (наборы с именами инструментов: наши — `vera_*`) и `cron.manage list`
  (`schedule_display`) для секции «Наше в Hermes»; при смене версии проверь поля.
- **Голосовые сообщения** — `vera-ears` регистрирует распознаватель `gigaam` штатным `ctx.register_transcription_provider`
  (`agent/transcription_provider.py`, `agent/transcription_registry.py` — в замке); его выбирает `stt.provider: gigaam` в
  config.yaml Hermes. Hermes сам качает голосовое и зовёт `transcribe()`; плагин запускает `$VERA_EARS_BIN --transcribe <файл>`.
- **Живой пульс** — `vera-pulse` кроме журнала шлёт каждую строку событием `plugin.vera-pulse.event` через `hermes_cli.plugin_events.broadcast_plugin_event` (контракт — `hermes_cli/plugin_events.py` в замке); Вера берёт её из адаптера, журнал остаётся историей и запасным путём.
- **Bootstrap** при каждом старте (`HermesBootstrap.ensure`): папки, ссылки `plugins/vera-pulse` и
  `plugins/vera-setup` на копии в бандле (переживают перенос приложения), один раз — `expose_on_path: false`
  и `plugins enable` для каждого плагина.

### Размер

Пакет v0.23.3 — 2,4 ГБ (venv 1,3 ГБ, tools 0,8 ГБ: chromium 367 МБ, node 222 МБ, драйвер управления
компьютером 150 МБ, ffmpeg 63 МБ), `.app` — 2,3 ГБ (без uv-cache). Урезать можно отказом от
необязательных возможностей (браузер, управление компьютером) — отдельное решение.

### Какую версию берём

LTS у Hermes нет. Каналы: **stable** (только финальные теги `vX.Y.Z`, их и берём), canary, main.
Две схемы тегов (`v0.23.3` и `v2026.9.24`) — берём семвер-тег последнего stable.

## Сборка

| Шаг | Команда | Где |
|---|---|---|
| сборочная копия на теге | `scripts/hermes-install.sh [тег]` (вызывается из build-hermes) | `~/.vera03/hermes` |
| пакет | `scripts/build-hermes.sh [тег]` (~5–10 мин с нуля) | `~/.vera03/build/payload` |
| приложение | `scripts/bundle.sh release` (~75 с) | `app/.build/Vera03.app` |
| CLI как у Веры (отладка) | `scripts/vhermes …` | — |

Сборочная копия — только инструмент сборки; Вера её не запускает.

## Обновление

Вера зависит от **внутренних** контрактов Hermes (провод шлюза `hermes-gateway-v1`, вывод `attach --json`,
методы `model.*`/`config.set`, хуки и API плагинов), а он их двигает даже в патч-версиях
(`0.23.1 → 0.23.2` — 14 изменённых файлов-контрактов).

1. **Замок — `hermes.lock.json`**: тег, commit, протокол, пути-контракты, хуки vera-pulse.
2. **Вера сверяет на старте** commit пакета (`vera-payload.json`) и `code_sha` шлюза с замком:
   `HERMES v0.23.3 · ПРОВЕРЕН` или `НЕ ПРОВЕРЕН` с причинами.
3. **Процедура:**
   1. `scripts/hermes-check.sh --fetch v<новая>` — дифф путей-контрактов и наличие хуков в кандидате.
   2. Контракты менялись — читаем дифф, правим `HermesBridge` / `SetupModel` / `vera-pulse`.
   3. `scripts/build-hermes.sh v<новая>` → `scripts/bundle.sh release` → снимки доски и настройки.
   4. Обновляем `hermes.lock.json`, запись в журнал, отдельный коммит.
   Откат — пересобрать с прежним тегом. Данные в `Application Support/Vera03` переживают обе стороны.

## Журнал обновлений

| Дата | Hermes | Контракты | Что пришлось поправить |
|---|---|---|---|
| 2026-11-21 | v0.23.3 (`caafe5389ae5`), пакет внутри Vera03.app | исходная точка | — |
| 2026-11-21 | v0.23.3 | — | окно «Настройка» писало модель через `config.set model` без сессии — Hermes отвечает 4001, модель не сохранялась; заменено на плагин `vera-setup` |

Вера показывает на схеме (значок версии в плитке Hermes: «новее нет» / «есть … ↗»), есть ли на GitHub stable новее, чем в замке. Это только подсказка: обновление — по этой процедуре.

Размер кадра шлюза: Вера принимает кадры до того же предела, что и сервер Hermes (`_DESKTOP_ATTACHMENT_WS_MAX_BYTES` в `hermes_cli/web_server_boundary.py`, сейчас 384 МиБ; `GatewayClient.maximumFrame`). При обновлении сверить.

Переписка Telegram: адаптер читает сессию методом `session.transcript` (`tui_gateway/contracts/canonical_stored_reads.py`: `order: latest`, `limit`, строки `rows` того же вида, что `display_messages` у `session.resume`). При обновлении сверить параметры и вид строк.
