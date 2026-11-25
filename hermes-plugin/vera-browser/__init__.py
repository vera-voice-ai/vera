"""vera-browser: Hermes opens, hides and closes Vera's browser window on the Mac.

The browser itself is Vera's (Vera03.app launches Hermes' own Chromium with a lasting profile and Vera's colours, the
DevTools port on loopback only); Hermes' browser_exec works in it through `browser.cdp_url`. This tool only moves the
window: it runs Vera's executable (`VERA_EARS_BIN` — the same binary) as `Vera --browser <action>`, which answers with
one sentence. No pages, no form data pass through here.

Hermes' browser tools reach the browser only through its DevTools port. When the window is closed they fail with
«launch Chrome with --remote-debugging-port…», and the model then starts some other browser (the Mac's own Chrome with
a throwaway profile, Safari). So before a browser tool runs (`pre_tool_call`) the window is opened if its port is
silent — mechanics, not a decision: the tools have exactly one browser to work in.
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
from typing import Any

ACTIONS = ("open", "show", "hide", "close", "status")
TIMEOUT_SECONDS = 30
PORT = 9333                       # MacBrowser.port; Hermes' browser.cdp_url points here
# Hermes' tools that drive the page through the DevTools port (browser_vault is the password store — not these).
PAGE_TOOLS = frozenset({"browser_exec", "browser_cdp", "browser_dialog"})
OPEN_TIMEOUT_SECONDS = 20         # under Hermes' pre_tool_call budget (30 s), which blocks the tool when exceeded

SCHEMA = {
    "name": "mac_browser",
    "description": (
        "Vera's browser window on the owner's Mac — the window your browser tools (browser_exec) work in, which he sees. "
        "It is your only browser: never open Safari or the Mac's Google Chrome, never start another Chromium. "
        "open: start it or bring it forward (the browser tools also open it themselves when it is closed); "
        "show: bring it forward; hide: minimize it, tabs stay; close: quit it (logins stay in its profile); "
        "status: open or closed and which tabs. Use open when you prepared something for him to finish (a CAPTCHA, "
        "the final submit button), hide/close when he asks to put it away."
    ),
    "parameters": {
        "type": "object",
        "properties": {"action": {"type": "string", "enum": list(ACTIONS)}},
        "required": ["action"],
    },
}


def _out(ok: bool, text: str) -> str:
    return json.dumps({"ok": ok, "text": text}, ensure_ascii=False)


def available() -> bool:
    return bool(os.environ.get("VERA_EARS_BIN"))


def run(action: str, binary: str | None = None, data: str | None = None, timeout: float = TIMEOUT_SECONDS) -> dict[str, Any]:
    """Never raises."""
    if action not in ACTIONS:
        return {"ok": False, "text": f"действие одно из: {', '.join(ACTIONS)}"}
    binary = binary or os.environ.get("VERA_EARS_BIN", "")
    if not binary or not os.access(binary, os.X_OK):
        return {"ok": False, "text": "Вера не передала путь к себе (VERA_EARS_BIN) — шлюз запущен не Верой"}
    env = dict(os.environ)
    data = data or os.environ.get("VERA_DATA", "")
    if data:
        env["VERA_DATA_ROOT"] = data
    try:
        done = subprocess.run([binary, "--browser", action], capture_output=True, text=True, timeout=timeout, env=env)
    except subprocess.TimeoutExpired:
        return {"ok": False, "text": f"браузер не ответил за {int(timeout)} с"}
    except OSError as e:
        return {"ok": False, "text": f"не запустилась Вера: {e}"}
    text = (done.stdout or done.stderr or "").strip().splitlines()
    return {"ok": done.returncode == 0, "text": text[-1] if text else ("готово" if done.returncode == 0 else "ошибка")}


def handle(args: dict, **_: Any) -> str:
    r = run(str((args or {}).get("action") or ""))
    return _out(r["ok"], r["text"])


def port_open(port: int = PORT, timeout: float = 0.5) -> bool:
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=timeout):
            return True
    except OSError:
        return False


def pre_tool_call(tool_name: str = "", **_: Any) -> None:
    """A page tool is about to run and Vera's browser is closed: open it first. Returns nothing (no veto, no change)."""
    try:
        if tool_name in PAGE_TOOLS and available() and not port_open():
            run("open", timeout=OPEN_TIMEOUT_SECONDS)
    except Exception:  # never break a tool call over the window
        pass
    return None


def register(ctx: Any) -> None:
    ctx.register_hook("pre_tool_call", pre_tool_call)
    ctx.register_tool(name="mac_browser", toolset="vera_browser", schema=SCHEMA, handler=handle, check_fn=available, emoji="🌐")
