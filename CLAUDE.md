@AGENTS.md

## Для Claude Code

- Все правила проекта — в `AGENTS.md` выше; они обязательны и для сабагентов.
- Отвечай владельцу по-русски, коротко.
- Проверка экрана: `cd app && swift build && .build/debug/Vera --snapshot "$TMPDIR/vera.png" --snapshot-setup "$TMPDIR/setup.png" --wait 40`, потом смотри PNG.
- Hermes — только внутри Веры (пакет в бандле, данные в `~/Library/Application Support/Vera03`); для отладки `scripts/vhermes`.
  Голый `hermes` и `~/.hermes` — владельца, не трогать. На машине ничего не искать.
- Ключи модели и токены не вводи — их вводит владелец сам (у провайдера «⚙ настроить», у Telegram «⚙ подключить»).
