#!/usr/bin/env python3
"""Silero VAD v5 (MIT) speech-probability worker for 16 kHz mono audio.

JSONL over stdio. Request {"pcm_f32le_base64": ...}: little-endian float32 samples at 16 kHz, length a multiple
of 512 (the protocol chunk is 2560 samples = 160 ms = 5 windows). Each 512-sample window is fed to the model with
the last 64 samples of the previous window prepended (input length 576), and the recurrent state is carried across
windows and across requests, so one worker serves one audio stream. Response
{"probabilities": [p per window], "max": p, "mean": p, "elapsed_ms": n}, p = speech probability (not calibrated).

Request {"reset": true} clears the recurrent state and the context (start of a new stream); response {"ok": true}.
"""
import base64, json, os, sys, time
from pathlib import Path
import numpy as np
import onnxruntime as ort

MODEL = Path(os.environ["VERA_SILERO_VAD_MODEL"])
SR, WINDOW, CONTEXT, STATE_DIM = 16000, 512, 64, 128


def write(value):
    sys.stdout.write(json.dumps(value) + "\n"); sys.stdout.flush()


class SileroStream:
    def __init__(self, session):
        self.session = session
        self.sr = np.array(SR, dtype=np.int64)
        self.reset()

    def reset(self):
        self.state = np.zeros((2, 1, STATE_DIM), dtype=np.float32)
        self.context = np.zeros((1, CONTEXT), dtype=np.float32)

    def probabilities(self, samples: np.ndarray) -> list:
        out = []
        for start in range(0, samples.size, WINDOW):
            window = samples[start:start + WINDOW].reshape(1, WINDOW)
            model_input = np.concatenate([self.context, window], axis=1)
            probability, self.state = self.session.run(
                None, {"input": model_input, "state": self.state, "sr": self.sr})[:2]
            self.context = window[:, -CONTEXT:].copy()
            out.append(float(np.asarray(probability).reshape(-1)[0]))
        return out


try:
    session = ort.InferenceSession(str(MODEL), providers=["CPUExecutionProvider"])
    stream = SileroStream(session)
    # Warm-up on silence, then reset so the warm-up does not leak into the first real stream.
    stream.probabilities(np.zeros(WINDOW * 5, dtype=np.float32))
    stream.reset()
    write({"ready": True, "model": MODEL.name})
except Exception as error:
    write({"ready": False, "error": f"{type(error).__name__}: {error}"})
    raise SystemExit(1)

for line in sys.stdin:
    try:
        request = json.loads(line)
        if request.get("reset"):
            stream.reset()
            write({"ok": True})
            continue
        started = time.perf_counter()
        samples = np.frombuffer(base64.b64decode(request["pcm_f32le_base64"]), dtype="<f4").astype(np.float32)
        if samples.size == 0 or samples.size % WINDOW:
            raise ValueError(f"sample count {samples.size} is not a positive multiple of {WINDOW}")
        probabilities = stream.probabilities(samples)
        write({"probabilities": probabilities,
               "max": max(probabilities),
               "mean": sum(probabilities) / len(probabilities),
               "elapsed_ms": round((time.perf_counter() - started) * 1000, 3)})
    except Exception as error:
        write({"error": f"{type(error).__name__}: {error}"})
