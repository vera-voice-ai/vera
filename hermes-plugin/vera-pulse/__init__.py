"""vera-pulse: Hermes lifecycle hooks → sanitized JSON Lines for the Vera 0.3 board.

Observer only: every callback returns None and swallows its own errors, so the agent never notices it.
Privacy rule: no message text, tool arguments, tool results, prompts or model output leave Hermes through
this plugin — only names, opaque ids, durations, statuses and token counts (see AGENTS.md of Vera 0.3).

Live path: each line is also broadcast as `plugin.vera-pulse.event` (`hermes_cli.plugin_events`), so Vera gets
it through the gateway; the journal file stays the history and the fallback.

Schema v1, one object per line (keys absent when unknown):
    v, ts (unix seconds), kind, session, turn, call_id, name, model, provider, platform,
    status, duration_ms, tokens_in, tokens_out, detail
"""
from __future__ import annotations

import collections
import functools
import datetime as _dt
import json
import os
import threading
import time
from pathlib import Path
from typing import Any

SCHEMA = 1
_RECENT: collections.deque[dict[str, Any]] = collections.deque(maxlen=500)
_LOCK = threading.Lock()
# Starts of in-flight calls, to measure what a hook does not time itself.
_STARTED: dict[str, float] = {}


def pulse_dir() -> Path:
    """``VERA_PULSE_DIR``, else ``$HERMES_HOME/vera-pulse`` (Vera runs Hermes with its own home), else the
    profile's home as Hermes resolves it."""
    override = os.environ.get("VERA_PULSE_DIR")
    if override:
        return Path(override).expanduser()
    home = os.environ.get("HERMES_HOME")
    if not home:
        try:
            from hermes_constants import get_hermes_home
            home = str(get_hermes_home())
        except Exception:  # noqa: BLE001
            home = str(Path.home() / ".hermes")
    return Path(home).expanduser() / "vera-pulse"


def _short(value: Any, limit: int = 80) -> str | None:
    if value is None:
        return None
    text = str(value).replace("\n", " ").strip()
    return text[:limit] or None


def _broadcast(event: dict[str, Any]) -> None:
    """Push the same sanitized event to Vera live, over the gateway (`plugin.vera-pulse.event`).

    The journal stays the history and the fallback; this is the live path. Outside Hermes (tests, CLI tooling)
    there is no `hermes_cli`, and then nothing is sent.
    """
    try:
        from hermes_cli.plugin_events import broadcast_plugin_event
    except Exception:  # noqa: BLE001 — no Hermes in this process
        return
    try:
        broadcast_plugin_event("vera-pulse", "event", event)
    except Exception:  # noqa: BLE001 — an observer never breaks the agent
        pass


def _write(kind: str, **fields: Any) -> None:
    event: dict[str, Any] = {"v": SCHEMA, "ts": round(time.time(), 3), "kind": kind}
    for key, value in fields.items():
        if value is None or value == "":
            continue
        event[key] = value
    line = json.dumps(event, ensure_ascii=False, separators=(",", ":")) + "\n"
    with _LOCK:
        _RECENT.append(event)
        try:
            directory = pulse_dir()
            directory.mkdir(parents=True, exist_ok=True)
            with open(directory / f"{_dt.date.today():%Y-%m-%d}.jsonl", "a", encoding="utf-8") as fh:
                fh.write(line)
        except OSError:
            pass  # the board is optional; Hermes must not care
    _broadcast(event)


def _guard(fn):
    @functools.wraps(fn)
    def wrapper(*args: Any, **kwargs: Any) -> None:
        try:
            fn(*args, **kwargs)
        except Exception:  # noqa: BLE001 — an observer never breaks the agent
            pass
        return None
    return wrapper


def _usage_tokens(usage: Any) -> tuple[int | None, int | None]:
    if usage is None:
        return None, None

    def get(*names: str) -> int | None:
        for name in names:
            value = usage.get(name) if isinstance(usage, dict) else getattr(usage, name, None)
            if isinstance(value, (int, float)):
                return int(value)
        return None

    return (get("input_tokens", "prompt_tokens"), get("output_tokens", "completion_tokens"))


# --- sessions -------------------------------------------------------------------------------

@_guard
def on_session_open(session_id: str = "", platform: str = "", reason: str = "", **_: Any) -> None:
    _write("session.open", session=session_id, platform=platform, detail=_short(reason))


@_guard
def on_session_start(session_id: str = "", model: str = "", platform: str = "", **_: Any) -> None:
    _write("session.start", session=session_id, model=model, platform=platform)


@_guard
def on_session_end(session_id: str = "", turn_id: str = "", completed: Any = None, failed: Any = None,
                   interrupted: Any = None, turn_exit_reason: str = "", model: str = "", platform: str = "",
                   **_: Any) -> None:
    status = "failed" if failed else "interrupted" if interrupted else "ok" if completed else None
    _write("session.end", session=session_id, turn=turn_id, model=model, platform=platform, status=status,
           detail=_short(turn_exit_reason))


# --- model ----------------------------------------------------------------------------------

@_guard
def pre_api_request(session_id: str = "", turn_id: str = "", api_request_id: str = "", model: str = "",
                    provider: str = "", platform: str = "", approx_input_tokens: Any = None, **_: Any) -> None:
    _write("llm.start", session=session_id, turn=turn_id, call_id=api_request_id, model=model,
           provider=provider, platform=platform,
           tokens_in=int(approx_input_tokens) if isinstance(approx_input_tokens, (int, float)) else None)


@_guard
def post_api_request(session_id: str = "", turn_id: str = "", api_request_id: str = "", model: str = "",
                     provider: str = "", platform: str = "", api_duration: Any = None, finish_reason: str = "",
                     usage: Any = None, assistant_tool_call_count: Any = None, **_: Any) -> None:
    tokens_in, tokens_out = _usage_tokens(usage)
    detail = _short(finish_reason)
    if isinstance(assistant_tool_call_count, int) and assistant_tool_call_count:
        detail = f"{detail or ''} · инстр. {assistant_tool_call_count}".strip(" ·")
    _write("llm.end", session=session_id, turn=turn_id, call_id=api_request_id, model=model, provider=provider,
           platform=platform, status="ok",
           duration_ms=round(api_duration * 1000, 1) if isinstance(api_duration, (int, float)) else None,
           tokens_in=tokens_in, tokens_out=tokens_out, detail=detail)


@_guard
def api_request_error(session_id: str = "", turn_id: str = "", api_request_id: str = "", model: str = "",
                      provider: str = "", platform: str = "", api_duration: Any = None, status_code: Any = None,
                      reason: Any = None, retryable: Any = None, **_: Any) -> None:
    _write("llm.error", session=session_id, turn=turn_id, call_id=api_request_id, model=model, provider=provider,
           platform=platform, status=f"http {status_code}" if status_code else "error",
           duration_ms=round(api_duration * 1000, 1) if isinstance(api_duration, (int, float)) else None,
           detail=_short(f"{reason or ''}{' · retry' if retryable else ''}", 60))


# --- tools ----------------------------------------------------------------------------------

@_guard
def pre_tool_call(tool_name: str = "", session_id: str = "", turn_id: str = "", tool_call_id: str = "",
                  **_: Any) -> None:
    if tool_call_id:
        _STARTED[tool_call_id] = time.time()
    _write("tool.start", session=session_id, turn=turn_id, call_id=tool_call_id, name=tool_name)


@_guard
def post_tool_call(tool_name: str = "", session_id: str = "", turn_id: str = "", tool_call_id: str = "",
                   duration_ms: Any = None, status: str = "", error_type: str = "", **_: Any) -> None:
    started = _STARTED.pop(tool_call_id, None) if tool_call_id else None
    if not isinstance(duration_ms, (int, float)) and started:
        duration_ms = (time.time() - started) * 1000
    _write("tool.end", session=session_id, turn=turn_id, call_id=tool_call_id, name=tool_name,
           status=_short(status) or "ok",
           duration_ms=round(duration_ms, 1) if isinstance(duration_ms, (int, float)) else None,
           detail=_short(error_type))


# --- subagents, people, compaction ----------------------------------------------------------

@_guard
def subagent_start(parent_session_id: str = "", child_session_id: str = "", child_role: str = "", **_: Any) -> None:
    _write("subagent.start", session=parent_session_id, call_id=child_session_id, name=_short(child_role) or "сабагент")


@_guard
def subagent_stop(parent_session_id: str = "", child_session_id: str = "", child_role: str = "",
                  child_status: str = "", duration_ms: Any = None, **_: Any) -> None:
    _write("subagent.stop", session=parent_session_id, call_id=child_session_id, name=_short(child_role) or "сабагент",
           status=_short(child_status),
           duration_ms=round(duration_ms, 1) if isinstance(duration_ms, (int, float)) else None)


@_guard
def on_human_input_request(kind: str = "", request_id: str = "", session_id: str = "", platform: str = "",
                           **_: Any) -> None:
    _write("human.wait", session=session_id, call_id=request_id, name=kind or "вопрос", platform=platform)


@_guard
def on_human_input_resolved(kind: str = "", request_id: str = "", session_id: str = "", platform: str = "",
                            outcome: str = "", **_: Any) -> None:
    _write("human.done", session=session_id, call_id=request_id, name=kind or "вопрос", platform=platform,
           status=_short(outcome))


@_guard
def post_compaction(session_id: str = "", kind: str = "", reason: str = "", before_tokens: Any = None,
                    after_tokens: Any = None, **_: Any) -> None:
    _write("compaction", session=session_id, name=_short(kind), detail=_short(reason),
           tokens_in=before_tokens if isinstance(before_tokens, int) else None,
           tokens_out=after_tokens if isinstance(after_tokens, int) else None)


HOOKS = {fn.__name__: fn for fn in (
    on_session_open, on_session_start, on_session_end,
    pre_api_request, post_api_request, api_request_error,
    pre_tool_call, post_tool_call,
    subagent_start, subagent_stop,
    on_human_input_request, on_human_input_resolved,
    post_compaction,
)}


def recent(params: Any = None, **_: Any) -> dict[str, Any]:
    """RPC `plugin.vera-pulse.recent`: the last events (`limit`, default 100)."""
    limit = 100
    if isinstance(params, dict) and isinstance(params.get("limit"), int):
        limit = max(1, min(500, params["limit"]))
    with _LOCK:
        events = list(_RECENT)[-limit:]
    return {"schema": SCHEMA, "events": events}


def register(ctx: Any) -> None:
    for name, fn in HOOKS.items():
        ctx.register_hook(name, fn)
    register_rpc = getattr(ctx, "register_rpc", None)
    if callable(register_rpc):
        register_rpc("recent", recent)
