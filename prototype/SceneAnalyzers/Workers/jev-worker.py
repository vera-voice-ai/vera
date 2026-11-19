#!/usr/bin/env python3
"""Local Jev-Style turn-completion worker (copied from Vera 1, unchanged logic). JSONL over stdio; no server or CLI."""

from __future__ import annotations

import contextlib
import json
import sys
import time

MODEL = "chaoliangUNSW/Jev-Style-2B-Decision-v4-MLX"


def write(value: dict) -> None:
    sys.stdout.write(json.dumps(value, ensure_ascii=False) + "\n")
    sys.stdout.flush()


def main() -> None:
    try:
        from jev_style import JevStyle, choice

        # Jev-Style and MLX may print loader diagnostics. Keep stdout reserved
        # for the machine-readable protocol consumed by Swift.
        with contextlib.redirect_stdout(sys.stderr):
            engine = JevStyle.from_pretrained(
                MODEL, backend="mlx", release="2b-v4", precision="8bit"
            )
        write({"ready": True, "model": MODEL})
    except Exception as error:  # report startup failures through the protocol
        write({"ready": False, "error": f"{type(error).__name__}: {error}"})
        return

    question = {
        "turn_complete": choice(
            "Has the user finished this turn and handed control to the assistant now? "
            "Select complete only when the current utterance is a complete request, "
            "answer, command, or thought. Select continue when it is grammatically "
            "unfinished, trails off, or clearly signals that more speech is coming. "
            "Use the conversation context to interpret short answers. The text is "
            "Russian; judge meaning, not punctuation alone.",
            {
                "complete": "The user has finished speaking for now; send the accumulated utterance to the main assistant.",
                "continue": "The utterance is incomplete or the user signals they are continuing; wait for more speech.",
            },
        )
    }

    for line in sys.stdin:
        try:
            request = json.loads(line)
            context = str(request.get("context", ""))[:5000]
            transcript = str(request.get("transcript", ""))[:2000]
            started = time.perf_counter()
            with contextlib.redirect_stdout(sys.stderr):
                result = engine.decide(
                    {
                        "Conversation context": context,
                        "Latest user speech transcription": transcript,
                    },
                    question,
                )
            answer = result["answers"]["turn_complete"]
            probabilities = answer.get("probabilities") or {}
            try:
                confidence = float(probabilities.get(answer.get("choice"), 0.0))
            except (TypeError, ValueError):
                confidence = 0.0

            # The model's temporary Metal allocations must not grow across a
            # long-running listening session. The loaded weights remain live.
            try:
                import mlx.core as mx

                mx.clear_cache()
            except Exception:
                pass

            write(
                {
                    "choice": answer.get("choice"),
                    "confidence": confidence,
                    "elapsed_ms": round((time.perf_counter() - started) * 1000),
                }
            )
        except Exception as error:
            write({"error": f"{type(error).__name__}: {error}"})


if __name__ == "__main__":
    main()
