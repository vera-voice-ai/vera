#!/usr/bin/env python3
"""CAM++ embedding adapter. Model weights are read from Vera 1; no writes there."""
import base64
import io
import json
import os
import sys
import traceback
from pathlib import Path

import numpy as np
import soundfile as sf
import sherpa_onnx
from scipy.signal import resample_poly

MODEL = Path(os.environ["VERA_SPEAKER_MODEL"])
TARGET_SR = 16000
try:
    config = sherpa_onnx.SpeakerEmbeddingExtractorConfig(
        model=str(MODEL), num_threads=2, debug=False, provider="cpu"
    )
    extractor = sherpa_onnx.SpeakerEmbeddingExtractor(config)
    stream = extractor.create_stream()
    stream.accept_waveform(TARGET_SR, np.zeros(TARGET_SR, dtype=np.float32))
    stream.input_finished()
    dimension = len(extractor.compute(stream))
    print(json.dumps({"ready": True, "dim": dimension, "model": MODEL.name}), flush=True)
except Exception as error:
    print(json.dumps({"ready": False, "error": str(error) + "\n" + traceback.format_exc()}), flush=True)
    raise SystemExit(1)

for line in sys.stdin:
    try:
        request = json.loads(line)
        raw = base64.b64decode(request["wav_base64"])
        samples, rate = sf.read(io.BytesIO(raw), dtype="float32", always_2d=True)
        mono = samples.mean(axis=1).astype(np.float32)
        if rate != TARGET_SR:
            import math
            divisor = math.gcd(int(rate), TARGET_SR)
            mono = resample_poly(mono, TARGET_SR // divisor, int(rate) // divisor).astype(np.float32)
        if mono.size < 8000:
            raise ValueError("Для голосового отпечатка нужно не менее 0,5 с аудио")
        stream = extractor.create_stream()
        stream.accept_waveform(TARGET_SR, mono)
        stream.input_finished()
        embedding = np.asarray(extractor.compute(stream), dtype=np.float64)
        norm = float((embedding * embedding).sum() ** 0.5)
        if norm <= 0:
            raise ValueError("Модель вернула пустой голосовой вектор")
        print(json.dumps({"embedding": (embedding / norm).astype(float).tolist(), "dim": len(embedding)}), flush=True)
    except Exception as error:
        print(json.dumps({"error": str(error)}), flush=True)
