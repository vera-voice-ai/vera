#!/usr/bin/env python3
"""VoxLock adapter using already-installed, read-only Vera 1 model files."""
import base64
import hashlib
import io
import json
import os
import sys
import tempfile
import time
import wave
from pathlib import Path

import numpy as np
import sherpa_onnx
import soundfile as sf
from scipy.signal import resample_poly

TARGET_SR = 16000
MODEL_DIR = Path(os.environ["VERA_VOXLOCK_MODEL_DIR"])
OWNER_SAMPLE = Path(os.environ["VERA_OWNER_VOICE_SAMPLE"])
FILES = {
    "voxlock_enroll.onnx": "5d06048c156bb8cd422d29848e6d38fb26a7b39f6f7fd92eccf2a6ed1ce003c6",
    "voxlock_chunk_int8.onnx": "df61a9d0062b0adbcf1182302b1eb8b815f15ac47ea4923e8e164c1aff64121d",
}


def normalize_wav(path):
    samples, rate = sf.read(str(path), dtype="float32", always_2d=True)
    mono = samples.mean(axis=1).astype(np.float32)
    if rate != TARGET_SR:
        import math
        divisor = math.gcd(int(rate), TARGET_SR)
        mono = resample_poly(mono, TARGET_SR // divisor, int(rate) // divisor).astype(np.float32)
    if mono.size < TARGET_SR * 3:
        raise ValueError("Для образца голоса нужно не менее 3 секунд")
    handle = tempfile.NamedTemporaryFile(prefix="vera-proto-owner-", suffix=".wav", delete=False)
    prepared = Path(handle.name)
    handle.close()
    sf.write(str(prepared), mono, TARGET_SR, subtype="PCM_16")
    return prepared


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


try:
    for filename, expected in FILES.items():
        path = MODEL_DIR / filename
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"Нет проверенной модели VoxLock: {path}")
    prepared_sample = normalize_wav(OWNER_SAMPLE)
    try:
        voxlock = sherpa_onnx.OfflineSpeechDenoiserVoxLockModelConfig(
            enroll_model=str(MODEL_DIR / "voxlock_enroll.onnx"),
            chunk_model=str(MODEL_DIR / "voxlock_chunk_int8.onnx"),
            voice_sample=str(prepared_sample),
        )
        model_config = sherpa_onnx.OfflineSpeechDenoiserModelConfig(
            voxlock=voxlock, num_threads=2, debug=False, provider="cpu"
        )
        config = sherpa_onnx.OfflineSpeechDenoiserConfig(model=model_config)
        if not config.validate():
            raise RuntimeError("Sherpa-ONNX отклонил конфигурацию VoxLock")
        denoiser = sherpa_onnx.OfflineSpeechDenoiser(config)
    finally:
        prepared_sample.unlink(missing_ok=True)
    emit({"ready": True, "model": "VoxLock · CPU", "sample_rate": TARGET_SR})
except Exception as error:
    emit({"ready": False, "error": str(error)})
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
        started = time.monotonic()
        result = denoiser.run(mono, TARGET_SR)
        output = np.clip(np.asarray(result.samples, dtype=np.float32), -1.0, 1.0)
        buffer = io.BytesIO()
        with wave.open(buffer, "wb") as target:
            target.setnchannels(1)
            target.setsampwidth(2)
            target.setframerate(TARGET_SR)
            target.writeframes((output * 32767).astype("<i2").tobytes())
        emit({"wav_base64": base64.b64encode(buffer.getvalue()).decode("ascii"),
              "duration_ms": int((time.monotonic() - started) * 1000),
              "sample_rate": TARGET_SR})
    except Exception as error:
        emit({"error": str(error)})
