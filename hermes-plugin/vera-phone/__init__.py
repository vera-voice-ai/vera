"""vera-phone: Hermes reaches the navigator and the music player of Vera's iPhone app.

The tools only carry requests; the phone does the work (Apple's search finds the place, Google's Navigation SDK builds
the route and guides). A request is a file `<VERA_DATA>/phone-bridge/commands/<id>.json`; Vera (Vera03.app) hands it to
the paired phone over its WebSocket and writes the phone's answer to `results/<id>.json`. The navigator's state, sent by
the phone on every change, is in `nav.json`. No network, no keys here.
"""
from __future__ import annotations

import json
import os
import time
import uuid
from pathlib import Path
from typing import Any, Optional

WAIT_SECONDS = 30.0
POLL_SECONDS = 0.25

ROUTE_SCHEMA = {
    "name": "phone_route",
    "description": (
        "Build a route in the navigator of the owner's iPhone (Vera's phone app, Google Maps navigation) to a place "
        "named in words — an address, a place name or a business, in Russian or English, e.g. \"Ленина 5, Новосибирск\" "
        "or \"ближайшая заправка\". The phone finds the place near its own location, builds the route and shows it on "
        "the «Карта» tab. With start=true it also starts turn-by-turn guidance at once (use when the owner says "
        "\"поехали\" / \"веди\"). Returns what the phone did: the place found, its address, travel time and distance — "
        "or why it could not."
    ),
    "parameters": {
        "type": "object",
        "properties": {
            "destination": {"type": "string", "description": "Where to go, as the owner said it (address or place)."},
            "start": {"type": "boolean", "description": "Start the guidance right away (default false: route only)."},
        },
        "required": ["destination"],
    },
}

STATUS_SCHEMA = {
    "name": "phone_route_status",
    "description": (
        "Where the trip on the owner's iPhone navigator stands: phase (idle, routing, ready, guiding, arrived, failed, "
        "unavailable), destination, remaining time and distance, arrival time, the next maneuver. Use for \"сколько "
        "ехать\", \"когда приедем\", \"где поворот\"."
    ),
    "parameters": {"type": "object", "properties": {}},
}

MUSIC_PLAY_SCHEMA = {
    "name": "phone_music_play",
    "description": (
        "Play music on the owner's iPhone (Vera's phone app, his own library: «Моё любимое», artists, albums). Say what "
        "to play as he said it — an artist (\"Miyagi\"), an album (\"NARRATIVE\"), a track (\"Таблетки\") — and the "
        "phone finds it in its library: an artist plays all of theirs, an album in order, a track with similar ones "
        "after it. Empty query — the whole «Моё любимое». Returns what started playing, or that it is not in the library. "
        "Volume cannot be changed from here (iOS allows only the phone's or the headset's buttons)."
    ),
    "parameters": {
        "type": "object",
        "properties": {"query": {"type": "string", "description": "Artist, album or track; empty for «Моё любимое»."}},
        "required": [],
    },
}

MUSIC_CONTROL_SCHEMA = {
    "name": "phone_music_control",
    "description": "Control the music on the owner's iPhone: pause, resume, next (next track), previous.",
    "parameters": {
        "type": "object",
        "properties": {"action": {"type": "string", "enum": ["pause", "resume", "next", "previous"]}},
        "required": ["action"],
    },
}

MUSIC_STATUS_SCHEMA = {
    "name": "phone_music_status",
    "description": "What plays on the owner's iPhone now (track, artist, quality, playing or paused) and how big the library is.",
    "parameters": {"type": "object", "properties": {}},
}

STOP_SCHEMA = {
    "name": "phone_route_stop",
    "description": "End the guidance on the owner's iPhone navigator and clear the route.",
    "parameters": {"type": "object", "properties": {}},
}


def _bridge() -> Optional[Path]:
    data = os.environ.get("VERA_DATA", "").strip()
    return Path(data) / "phone-bridge" if data else None


def available() -> bool:
    """The tools exist only in a gateway started by Vera (it sets VERA_DATA)."""
    return _bridge() is not None


def _out(payload: dict[str, Any]) -> str:
    return json.dumps(payload, ensure_ascii=False)


def request(action: str, destination: Optional[str] = None, start: bool = False,
            bridge: Optional[Path] = None, wait: float = WAIT_SECONDS, query: Optional[str] = None) -> dict[str, Any]:
    """Drop a request for the phone and wait for its answer; never raises."""
    bridge = bridge or _bridge()
    if bridge is None:
        return {"ok": False, "text": "Вера не передала путь к своим данным (VERA_DATA) — шлюз запущен не Верой"}
    rid = uuid.uuid4().hex
    commands, results = bridge / "commands", bridge / "results"
    try:
        commands.mkdir(parents=True, exist_ok=True)
        tmp = commands / f".{rid}.tmp"
        body = {"id": rid, "action": action, "destination": destination, "start": bool(start)}
        if query is not None:
            body["query"] = query
        tmp.write_text(json.dumps(body, ensure_ascii=False), encoding="utf-8")
        tmp.rename(commands / f"{rid}.json")
    except OSError as e:
        return {"ok": False, "text": f"не смог передать запрос Вере: {e}"}
    answer = results / f"{rid}.json"
    deadline = time.monotonic() + wait
    while time.monotonic() < deadline:
        if answer.exists():
            try:
                got = json.loads(answer.read_text(encoding="utf-8"))
            except (OSError, ValueError):
                time.sleep(POLL_SECONDS)
                continue
            answer.unlink(missing_ok=True)
            return {"ok": bool(got.get("ok")), "text": str(got.get("text", ""))}
        time.sleep(POLL_SECONDS)
    (commands / f"{rid}.json").unlink(missing_ok=True)
    return {"ok": False, "text": "Вера не ответила — приложение Vera03 на Маке, похоже, не запущено"}


def status(bridge: Optional[Path] = None, now: Optional[float] = None) -> dict[str, Any]:
    """The phone's last navigator state, with its age."""
    bridge = bridge or _bridge()
    if bridge is None:
        return {"ok": False, "text": "нет VERA_DATA — шлюз запущен не Верой"}
    try:
        nav = json.loads((bridge / "nav.json").read_text(encoding="utf-8"))
    except FileNotFoundError:
        return {"ok": False, "text": "телефон ещё не присылал состояние навигатора"}
    except (OSError, ValueError) as e:
        return {"ok": False, "text": f"не прочитал состояние навигатора: {e}"}
    now = time.time() if now is None else now
    at = nav.get("at")
    out: dict[str, Any] = {"ok": True, **{k: v for k, v in nav.items() if v is not None and k != "at"}}
    if isinstance(at, (int, float)):
        out["updated_seconds_ago"] = max(0, round(now - at))
        secs = nav.get("remainingSeconds")
        if isinstance(secs, (int, float)) and nav.get("phase") in ("ready", "guiding"):
            out["arrival_local_time"] = time.strftime("%H:%M", time.localtime(at + secs))
    return out


def handle_route(args: dict, **_: Any) -> str:
    dest = str((args or {}).get("destination") or "").strip()
    if not dest:
        return _out({"ok": False, "text": "не сказано, куда ехать"})
    return _out(request("route", destination=dest, start=bool((args or {}).get("start"))))


def handle_status(args: dict, **_: Any) -> str:
    return _out(status())


def handle_stop(args: dict, **_: Any) -> str:
    return _out(request("stop"))


MUSIC_ACTIONS = ("pause", "resume", "next", "previous")


def handle_music_play(args: dict, **_: Any) -> str:
    return _out(request("music.play", query=str((args or {}).get("query") or "").strip()))


def handle_music_control(args: dict, **_: Any) -> str:
    action = str((args or {}).get("action") or "")
    if action not in MUSIC_ACTIONS:
        return _out({"ok": False, "text": f"действие одно из: {', '.join(MUSIC_ACTIONS)}"})
    return _out(request("music." + action))


def handle_music_status(args: dict, **_: Any) -> str:
    return _out(request("music.status"))


def register(ctx: Any) -> None:
    for name, schema, handler, emoji in (
        ("phone_route", ROUTE_SCHEMA, handle_route, "🧭"),
        ("phone_route_status", STATUS_SCHEMA, handle_status, "🛣️"),
        ("phone_route_stop", STOP_SCHEMA, handle_stop, "🏁"),
        ("phone_music_play", MUSIC_PLAY_SCHEMA, handle_music_play, "🎵"),
        ("phone_music_control", MUSIC_CONTROL_SCHEMA, handle_music_control, "⏯️"),
        ("phone_music_status", MUSIC_STATUS_SCHEMA, handle_music_status, "🎧"),
    ):
        ctx.register_tool(name=name, toolset="vera_phone", schema=schema, handler=handler, check_fn=available, emoji=emoji)
