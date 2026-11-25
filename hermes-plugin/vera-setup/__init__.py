"""vera-setup: what Vera's settings window needs and the gateway's sessionless methods do not offer.

`config.set model` only works inside a live session (4001 otherwise). Hermes Desktop sets the profile
default through POST /api/model/set; this plugin exposes the same two steps over the gateway socket Vera
already holds, so no second auth channel is needed:
    hermes_cli.web_server_config._prepare_main_assignment  (validation, catalog/endpoint probes)
    hermes_cli.web_server_config._apply_model_assignment_sync("main", …)  (writes config.yaml)
Those are internal names: they are listed in Vera's hermes.lock.json contract paths and checked on
every Hermes update.

Telegram: Hermes keeps the bot token and the allowed users in its .env (TELEGRAM_BOT_TOKEN,
TELEGRAM_ALLOWED_USERS — see website/docs/user-guide/messaging/telegram.md). The owner types them in Vera's window;
this plugin saves them with Hermes' own hermes_cli.config.save_env_value_secure / save_env_value and reports only
whether a token is set — never its value.
"""
from __future__ import annotations

import re
from typing import Any


def _detail(exc: Exception) -> str:
    return str(getattr(exc, "detail", None) or exc)[:300]


def set_main_model(params: Any = None, **_: Any) -> dict[str, Any]:
    """RPC `plugin.vera-setup.set_main_model` {provider, model, confirm?} →
    {ok, provider, model} | {ok: false, confirm_required, confirm_message} | {ok: false, error}."""
    params = params if isinstance(params, dict) else {}
    provider = str(params.get("provider") or "").strip()
    model = str(params.get("model") or "").strip()
    if not provider or not model:
        return {"ok": False, "error": "provider and model required"}
    try:
        from hermes_cli.config import load_config
        from hermes_cli.config_backend import CONFIG_MUTATION_LOCK
        from hermes_cli.web_server_config import _apply_model_assignment_sync, _prepare_main_assignment

        if not params.get("confirm"):
            try:
                from hermes_cli.model_selection_guards import combined_selection_warning
                warning = combined_selection_warning(model, provider=provider, base_url="")
            except Exception:  # noqa: BLE001 — pricing lookup is advisory, as in /api/model/set
                warning = None
            if warning is not None:
                return {"ok": False, "provider": provider, "model": model,
                        "confirm_required": True, "confirm_message": warning.message}

        prepared = _prepare_main_assignment(load_config(), provider, model, "", "")
        with CONFIG_MUTATION_LOCK:
            result = _apply_model_assignment_sync("main", provider, model, "", "", "", prepared=prepared)
        out: dict[str, Any] = {"ok": True, "provider": provider, "model": model}
        if isinstance(result, dict):
            out.update({k: v for k, v in result.items() if isinstance(v, (str, int, float, bool)) or v is None})
            out["ok"] = bool(result.get("ok", True))
        return out
    except Exception as exc:  # noqa: BLE001 — HTTPException from validation, or anything else: report, never raise
        return {"ok": False, "provider": provider, "model": model, "error": _detail(exc)}


_TOKEN_RE = re.compile(r"^\d+:[A-Za-z0-9_-]{30,}$")   # as hermes_cli.setup_platforms._is_valid_telegram_bot_token
_IDS_RE = re.compile(r"^\s*\d+(\s*,\s*\d+)*\s*$")


def telegram_status(params: Any = None, **_: Any) -> dict[str, Any]:
    """RPC `plugin.vera-setup.telegram_status` → {ok, token_set, allowed_users}. Never the token itself: only
    whether one is set, and how many user ids are allowed (an empty list means DM pairing approves new users)."""
    try:
        from hermes_cli.config import get_env_value
        token = get_env_value("TELEGRAM_BOT_TOKEN") or ""
        ids = [x for x in (get_env_value("TELEGRAM_ALLOWED_USERS") or "").split(",") if x.strip()]
        return {"ok": True, "token_set": bool(token.strip()), "allowed_users": len(ids)}
    except Exception as exc:  # noqa: BLE001 — report, never raise
        return {"ok": False, "error": _detail(exc)}


def telegram_save(params: Any = None, **_: Any) -> dict[str, Any]:
    """RPC `plugin.vera-setup.telegram_save` {token?, allowed_users?} → {ok} | {ok: false, error}. Saves the bot
    token (typed by the owner in Vera's window) and the allowed Telegram user ids into Hermes' own .env through
    Hermes' own functions; the gateway picks them up on restart. Nothing is logged or returned back."""
    params = params if isinstance(params, dict) else {}
    token = str(params.get("token") or "").strip()
    ids = str(params.get("allowed_users") or "").strip()
    if token and not _TOKEN_RE.match(token):
        return {"ok": False, "error": "это не похоже на токен бота от @BotFather (число:строка)"}
    if ids and not _IDS_RE.match(ids):
        return {"ok": False, "error": "id пользователей — числа через запятую"}
    if not token and not ids:
        return {"ok": False, "error": "нечего сохранять"}
    try:
        from hermes_cli.config import save_env_value, save_env_value_secure
        if token:
            save_env_value_secure("TELEGRAM_BOT_TOKEN", token)
        if ids:
            save_env_value("TELEGRAM_ALLOWED_USERS", ",".join(x.strip() for x in ids.split(",")))
        return {"ok": True}
    except Exception as exc:  # noqa: BLE001
        return {"ok": False, "error": _detail(exc)}


def _usage_wire(snapshot: Any) -> dict[str, Any]:
    """An ``agent.account_usage.AccountUsageSnapshot`` as plain data: labels, percents, resets — no raw body."""
    windows = []
    for w in getattr(snapshot, "windows", ()) or ():
        reset = getattr(w, "reset_at", None)
        used = getattr(w, "used_percent", None)
        windows.append({"label": str(getattr(w, "label", "") or ""),
                        "used_percent": float(used) if isinstance(used, (int, float)) else None,
                        "reset_at": reset.isoformat() if hasattr(reset, "isoformat") else None,
                        "scope": str(getattr(w, "scope", "") or "account")})
    return {"ok": True, "provider": str(getattr(snapshot, "provider", "") or ""),
            "plan": getattr(snapshot, "plan", None), "windows": windows,
            "details": [str(d) for d in (getattr(snapshot, "details", ()) or ())][:6],
            "unavailable_reason": getattr(snapshot, "unavailable_reason", None)}


def account_usage(params: Any = None, **_: Any) -> dict[str, Any]:
    """RPC `plugin.vera-setup.account_usage` → {ok, provider, plan, windows: [{label, used_percent, reset_at}], …}
    | {ok: true, provider, windows: []} when the provider has no plan limits | {ok: false, error}.

    The plan limits `/usage` shows (OpenCode Go 5 h / week / month, Codex, Claude, OpenRouter…), as data: the
    profile's default route (``resolve_runtime_provider``) and Hermes' own ``fetch_account_usage``. The key is
    resolved and used inside Hermes; only percents and reset times come back."""
    try:
        from agent.account_usage import fetch_account_usage
        from hermes_cli.runtime_provider import resolve_runtime_provider
        route = resolve_runtime_provider() or {}
        provider = str(route.get("provider") or "")
        if not provider:
            return {"ok": False, "error": "нет провайдера"}
        snapshot = fetch_account_usage(provider, base_url=route.get("base_url") or None, api_key=route.get("api_key"))
        if snapshot is None:
            return {"ok": True, "provider": provider, "windows": []}
        return _usage_wire(snapshot)
    except Exception as exc:  # noqa: BLE001 — report, never raise; the message never carries the key
        return {"ok": False, "error": type(exc).__name__}


def home_channels(params: Any = None, **_: Any) -> dict[str, Any]:
    """RPC `plugin.vera-setup.home_channels` → {ok, homes: [{platform, name, thread}]} | {ok: false, error}.

    Where Hermes delivers cron results and cross-platform messages (`/sethome`), per platform, as Hermes itself reads
    it (``gateway.config.load_gateway_config`` — config.yaml and the env overlay). Chat ids stay inside Hermes: only the
    platform, the home's name and whether it is a topic come back."""
    try:
        from gateway.config import load_gateway_config
        cfg = load_gateway_config()
        homes = []
        for platform, pc in (getattr(cfg, "platforms", None) or {}).items():
            home = getattr(pc, "home_channel", None)
            if home is None:
                continue
            homes.append({"platform": getattr(platform, "value", str(platform)), "name": str(getattr(home, "name", "") or ""),
                          "thread": bool(getattr(home, "thread_id", None))})
        return {"ok": True, "homes": homes}
    except Exception as exc:  # noqa: BLE001 — report, never raise
        return {"ok": False, "error": type(exc).__name__}


def register(ctx: Any) -> None:
    ctx.register_rpc("set_main_model", set_main_model)
    ctx.register_rpc("telegram_status", telegram_status)
    ctx.register_rpc("telegram_save", telegram_save)
    ctx.register_rpc("account_usage", account_usage)
    ctx.register_rpc("home_channels", home_channels)
