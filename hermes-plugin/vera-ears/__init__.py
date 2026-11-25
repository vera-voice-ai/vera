"""vera-ears: Hermes transcribes voice messages with the ears from Vera's box.

Hermes' own STT seam (website/docs, agent/transcription_provider.py): a plugin registers a TranscriptionProvider and
`stt.provider: gigaam` in config.yaml selects it. Hermes still owns the flow — it downloads the voice note, calls
transcribe(), puts the transcript into the turn. This plugin only turns audio into text: it runs Vera's executable
(`VERA_EARS_BIN`, set by Vera in the gateway's environment) as `Vera --transcribe <file>`, which reads the file with
macOS (Ogg/Opus included), cuts it into phrases with Silero VAD and decodes each with GigaAM. Offline, no keys.
"""
from __future__ import annotations

import os
import subprocess
from typing import Any, Optional

try:  # inside Hermes; the offline tests run without it
    from agent.transcription_provider import TranscriptionProvider
except Exception:  # pragma: no cover - only outside Hermes
    TranscriptionProvider = object  # type: ignore[assignment,misc]

NAME = "gigaam"
TIMEOUT_SECONDS = 180


def _binary() -> Optional[str]:
    path = os.environ.get("VERA_EARS_BIN", "").strip()
    return path if path and os.access(path, os.X_OK) else None


def _error(message: str) -> dict[str, Any]:
    return {"success": False, "transcript": "", "provider": NAME, "error": message}


def transcribe_file(file_path: str, binary: Optional[str] = None, timeout: float = TIMEOUT_SECONDS) -> dict[str, Any]:
    """The Hermes envelope {success, transcript, provider, error?}; never raises."""
    binary = binary or _binary()
    if not binary:
        return _error("Vera's ears are not reachable (VERA_EARS_BIN is not set — the gateway was not started by Vera)")
    try:
        done = subprocess.run([binary, "--transcribe", file_path], capture_output=True, text=True, timeout=timeout)
    except subprocess.TimeoutExpired:
        return _error(f"GigaAM did not finish in {timeout:g}s")
    except OSError as exc:
        return _error(f"Vera's ears failed to start: {exc}")
    if done.returncode != 0:
        return _error(f"Vera's ears exited with {done.returncode}: {(done.stderr or '').strip()[:300]}")
    text = (done.stdout or "").strip()
    if not text:
        return _error("no speech found in the voice message")
    return {"success": True, "transcript": text, "provider": NAME}


class GigaAMProvider(TranscriptionProvider):  # type: ignore[misc,valid-type]
    @property
    def name(self) -> str:
        return NAME

    @property
    def display_name(self) -> str:
        return "GigaAM (Vera)"

    def is_available(self) -> bool:
        return _binary() is not None

    def list_models(self) -> list[dict[str, Any]]:
        return [{"id": "gigaam-v3-ctc-punct", "display": "GigaAM v3 CTC (Russian, punctuation)"}]

    def transcribe(self, file_path: str, *, model: Optional[str] = None, language: Optional[str] = None,
                   **extra: Any) -> dict[str, Any]:
        return transcribe_file(file_path)


def register(ctx: Any) -> None:
    ctx.register_transcription_provider(GigaAMProvider())
