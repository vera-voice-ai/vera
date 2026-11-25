"""vera-context: each of Vera's channels knows the others and itself.

Facts, not rules: what Vera 0.3 is, which three channels the owner talks through, and — in detail — how the
session's own channel is run (how the owner's words reach Hermes and how the answer reaches the owner).

The channel is told apart by what Vera and Hermes already know:
- a local session Vera created names its client on `session.create` (`vera-mac`, `vera-phone`);
- Vera's pinned-session files (`$VERA_DATA/main-session.json`, `phone-session.json`) name the sessions made before that;
- a messaging chat has its platform (`telegram`).

New sessions get the text as a cache-safe system prompt section. A session that existed before the plugin gets it
once, with its next turn (`pre_llm_call`). When the text changes (a new tool, a new part of Vera), every session that
has an older one gets the new text the same way, once — a session's system prompt is frozen at its start, so without
this a long-lived channel (the Mac's «Вера» lives for weeks) never learns what was added. `$VERA_DATA/vera-context-seen.json`
keeps, for each session, a digest of the text it has.
"""
from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
from typing import Any, Mapping, Optional

SECTION_ID = "vera-context.channels"

OVERVIEW = """\
Вера 0.3 — приложение на MacBook владельца (Vera03.app). Внутри него живёт этот Hermes: свой пакет в приложении, данные в \
~/Library/Application Support/Vera03, шлюз запускает Вера. Думает и отвечает только Hermes; Вера — обвязка: окна, уши \
(распознавание речи), голос, связь, наблюдение за работой.
У владельца три постоянных канала к тебе. У каждого своя сессия и своя история — истории не общие (сказанное в другом \
канале можно найти через session_search):
• «Вера» — MacBook: окно Веры со схемой и разговором голосом или текстом.
• «iPhone» — приложение Вера на iPhone: голосовой собеседник в дороге (часто владелец за рулём мотоцикла, в шлеме), там же \
навигатор Google и музыка.
• Telegram — бот Hermes: переписка и голосовые, сюда приходят результаты cron-задач (домашний канал).
Подробно о Вере и её версиях — навык vera."""

CHANNELS = {
    "mac": """\
Эта сессия — «Вера» на MacBook, главная сессия окна Веры.
Как идут слова: владелец пишет в окне или говорит; уши Веры на Маке (Silero VAD + GigaAM, конец фразы по тишине) \
присылают тебе распознанный текст. Если говорит не владелец, в начале фразы стоит пометка ([говорит: имя] или \
[голос не узнан]). Твой ответ Вера показывает в окне и озвучивает голосом Silero.
Доска Веры показывает твою работу вживую: шаги модели и инструменты (плагин vera-pulse только наблюдает). Модель, \
провайдер и ключи владелец настраивает в окне Веры. Мак держится бодрым, пока Вера запущена.
Браузер: у тебя один браузер — окно «Браузер Веры» на Маке (Chromium в цветах Веры, свой профиль, вход на сайты \
сохраняется), владелец его видит. «Открой / покажи / спрячь / закрой браузер» — это инструмент mac_browser \
(open / show / hide / close / status); browser_exec работает в этом окне и сам открывает его, если оно закрыто. \
Safari и Google Chrome владельца — не твои, другие браузеры не запускай. Капчу и последнюю кнопку отправки оставляй владельцу.""",
    "phone": """\
Эта сессия — «iPhone»: приложение Вера на iPhone владельца.
Как идут слова: владелец говорит, телефон сам распознаёт речь (Silero VAD + GigaAM v3 прямо на iPhone) и присылает тебе \
текст фразы. Твой ответ телефон зачитывает вслух системным русским голосом iOS, по предложениям, и владелец может \
перебить голосом — экран он обычно не видит. Поэтому markdown, таблицы, ссылки и эмодзи до него не доходят, а длинный \
ответ слушать долго.
Связь: iPhone → туннель владельца → Вера на Маке → шлюз Hermes. Если Мак выключен или у \
телефона нет сети, телефон тебя не слышит; уши и голос при этом работают на телефоне.
Навигатор телефона (Google Navigation SDK): phone_route — найти место и построить маршрут (start=true — сразу вести), \
phone_route_status — сколько ехать, когда приезд, следующий манёвр, phone_route_stop — закончить. Музыка на телефоне — \
своя медиатека владельца («Моё любимое», исполнители, альбомы): phone_music_play (исполнитель, альбом или трек), \
phone_music_control (пауза, дальше, назад), phone_music_status; громкость — только кнопками телефона или гарнитуры.""",
    "telegram": """\
Эта сессия — чат Telegram с владельцем: бот Hermes, его шлюз работает на Маке внутри Веры.
Голосовые сообщения приходят уже расшифрованными: их распознаёт GigaAM из коробки Веры (плагин vera-ears). Ответ \
Владелец читает в Telegram — разметка Telegram работает. Это домашний канал: сюда доставляются результаты cron-задач.
Владелец пишет сюда, когда он не у Мака. Навигатор и музыка его iPhone доступны и отсюда (phone_route*, phone_music*), \
если приложение Вера на телефоне на связи.""",
}


def _data() -> Optional[Path]:
    d = os.environ.get("VERA_DATA", "").strip()
    return Path(d) if d else None


def _pinned(name: str, data: Optional[Path]) -> Optional[str]:
    if data is None:
        return None
    try:
        return json.loads((data / name).read_text(encoding="utf-8")).get("session_id")
    except (OSError, ValueError, AttributeError):
        return None


def channel(session_id: str = "", platform: str = "", client: str = "", data: Optional[Path] = None) -> Optional[str]:
    """`mac`, `phone`, `telegram`, or None for any other session (cron, CLI, subagents)."""
    if client == "vera-phone":
        return "phone"
    if client == "vera-mac":
        return "mac"
    if platform == "telegram":
        return "telegram"
    data = data if data is not None else _data()
    if session_id and session_id == _pinned("phone-session.json", data):
        return "phone"
    if session_id and session_id == _pinned("main-session.json", data):
        return "mac"
    return None


def owner(data: Optional[Path] = None) -> Optional[str]:
    """The owner's name from `$VERA_DATA/local.json` (`{"owner": "Имя"}`) — the owner's own setting, not in the code."""
    data = data if data is not None else _data()
    if data is None:
        return None
    try:
        name = json.loads((data / "local.json").read_text(encoding="utf-8")).get("owner")
    except (OSError, ValueError, AttributeError):
        return None
    return name.strip() if isinstance(name, str) and name.strip() else None


def text(ch: Optional[str], data: Optional[Path] = None) -> str:
    name = owner(data)
    head = OVERVIEW + (f"\nВладельца зовут {name}." if name else "")
    return head if ch is None else f"{head}\n\n{CHANNELS[ch]}"


# MARK: which sessions have it

def _seen_file(data: Optional[Path]) -> Optional[Path]:
    return data / "vera-context-seen.json" if data is not None else None


def digest(body: str) -> str:
    return hashlib.sha256(body.encode("utf-8")).hexdigest()[:16]


def _seen(data: Optional[Path]) -> dict[str, str]:
    """session id → digest of the text it has ("" — an older file that kept only ids: some earlier text)."""
    f = _seen_file(data)
    try:
        raw = json.loads(f.read_text(encoding="utf-8")) if f else {}
    except (OSError, ValueError, TypeError):
        return {}
    if isinstance(raw, list):
        return {str(i): "" for i in raw}
    return {str(k): str(v) for k, v in raw.items()} if isinstance(raw, dict) else {}


def _mark(session_id: str, body: str, data: Optional[Path]) -> None:
    f = _seen_file(data)
    if f is None or not session_id:
        return
    seen = _seen(data)
    seen.pop(session_id, None)
    seen[session_id] = digest(body)          # newest last: the file keeps the latest 500
    try:
        tmp = f.with_suffix(".tmp")
        tmp.write_text(json.dumps(dict(list(seen.items())[-500:]), ensure_ascii=False), encoding="utf-8")
        tmp.replace(f)
    except OSError:
        pass


# MARK: Hermes hooks

def section(info: Mapping[str, Any]) -> str:
    """Rendered once for a new session (Hermes freezes it with the system prompt)."""
    data = _data()
    sid = str(info.get("session_id") or "")
    body = text(channel(sid, str(info.get("platform") or ""), str(info.get("client") or ""), data), data)
    _mark(sid, body, data)
    return body


def pre_llm_call(session_id: str = "", platform: str = "", **_: Any) -> Optional[dict]:
    """A session without this text — from before the plugin, or with an older version of it: the current text once,
    with this turn."""
    try:
        data = _data()
        if not session_id:
            return None
        ch = channel(session_id, platform or "", "", data)
        if ch is None:
            return None
        body = text(ch, data)
        seen = _seen(data)
        if seen.get(session_id) == digest(body):
            return None
        _mark(session_id, body, data)
        head = "о каналах — справка обновилась, действует эта" if session_id in seen else "о каналах — справка"
        return {"context": f"[Вера: {head}, не сообщение владельца]\n" + body}
    except Exception:  # never break a turn over a description
        return None


def register(ctx: Any) -> None:
    ctx.register_system_prompt_section(SECTION_ID, section, position="after_memory", max_chars=4000)
    ctx.register_hook("pre_llm_call", pre_llm_call)
