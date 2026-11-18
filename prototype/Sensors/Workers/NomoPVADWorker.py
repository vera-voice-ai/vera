#!/usr/bin/env python3
"""Local Nomo-PVAD streaming adapter for Vera Sensor Prototype."""
import base64
import hashlib
import json
import os
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
import torch
import torchaudio

WORKER_DIR = Path(__file__).parent
sys.path.insert(0, str(WORKER_DIR / "nomo_pvad"))
from nomo_pvad import NomoPVAD, NomoPVADSession

MODEL_DIR = Path(os.environ["VERA_NOMO_MODEL_DIR"])
ENROLLMENT_WAV = Path(os.environ["VERA_NOMO_ENROLLMENT_WAV"])
EXPECTED = {
    "nomo_pvad.pt": "0acf2f3e75409b172771663fd1bee31af2760dba4e25b1353d2c26726b6412d1",
    "pretrained_eres2netv2.ckpt": "0eb4057106b2573dd7b132cf0c36273ab29afd192c1610f80baa9c556dbb963c",
}
SR = 16000


def emit(value):
    print(json.dumps(value, ensure_ascii=False), flush=True)


def load_enrollment(path: Path):
    samples, rate = sf.read(str(path), dtype="float32", always_2d=True)
    mono = samples.mean(axis=1).astype(np.float32)
    if rate != SR:
        mono = torchaudio.functional.resample(torch.from_numpy(mono), rate, SR).numpy()
    if mono.size < SR * 10:
        raise ValueError("Nomo-PVAD требует эталон не короче 10 секунд")
    return mono


try:
    for name, digest in EXPECTED.items():
        path = MODEL_DIR / name
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise RuntimeError(f"Проверенная модель не найдена: {name}")
    torch.set_num_threads(2)
    model = NomoPVAD(str(MODEL_DIR / "nomo_pvad.pt"), str(MODEL_DIR), device="cpu")
    session = NomoPVADSession(model)
    session.set_enrollment(load_enrollment(ENROLLMENT_WAV))
    emit({"ready": True, "model": "Nomo-PVAD · CPU", "sample_rate": SR, "chunk_ms": 160})
except Exception as error:
    emit({"ready": False, "error": str(error)})
    raise SystemExit(1)

for line in sys.stdin:
    try:
        request = json.loads(line)
        raw = base64.b64decode(request["pcm_f32le_base64"])
        samples = np.frombuffer(raw, dtype="<f4").copy()
        probability = session.process_chunk(samples)
        emit({"probability": probability})
    except Exception as error:
        emit({"error": str(error)})
