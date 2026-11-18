#!/usr/bin/env python3
"""Read-only Vera 1 GigaAM model adapter; all runtime caches stay outside Vera 1."""
import base64
import io
import json
import os
import sys
import traceback
import wave
from pathlib import Path

import numpy as np

MODEL_NAME = "gigaam-v3-e2e-ctc"
MODEL_DIR = Path(os.environ["VERA_GIGAAM_MODEL_DIR"])
os.environ["HF_HOME"] = os.environ["VERA_MODEL_CACHE"]
os.environ["HF_HUB_CACHE"] = os.environ["VERA_MODEL_CACHE"]

import onnx_asr


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def decode_wav(data):
    with wave.open(io.BytesIO(data), "rb") as source:
        channels, width, rate = source.getnchannels(), source.getsampwidth(), source.getframerate()
        if width != 2:
            raise ValueError("Ожидается WAV PCM 16-bit")
        values = np.frombuffer(source.readframes(source.getnframes()), dtype="<i2").astype(np.float32) / 32768.0
    if channels > 1:
        values = values.reshape(-1, channels).mean(axis=1)
    return values, rate


try:
    model = onnx_asr.load_model(MODEL_NAME, str(MODEL_DIR), providers=["CPUExecutionProvider"])
    emit({"ready": True, "model": MODEL_NAME})
except Exception as error:
    emit({"ready": False, "error": str(error) + "\n" + traceback.format_exc()})
    raise SystemExit(1)

for line in sys.stdin:
    try:
        request = json.loads(line)
        samples, rate = decode_wav(base64.b64decode(request["wav_base64"]))
        result = model.recognize(samples, sample_rate=rate)
        emit({"text": (result if isinstance(result, str) else str(result)).strip()})
    except Exception as error:
        emit({"error": str(error)})
