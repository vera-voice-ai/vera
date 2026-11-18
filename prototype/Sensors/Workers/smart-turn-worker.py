#!/usr/bin/env python3
"""Smart Turn v3.2 (Pipecat) end-of-turn worker: audio in, probability that the speaker has finished.

JSONL over stdio. Request {"wav_base64": ...}: any WAV; it is mixed to mono, resampled to 16 kHz and the LAST
8 s are used (shorter audio is padded with zeros at the FRONT, as the model's authors do). Response
{"probability": p, "elapsed_ms": n}, p = probability that the turn is complete (not calibrated by us).
The Whisper log-mel features are computed with numpy so that `transformers` is not needed; they were
checked against transformers' WhisperFeatureExtractor(chunk_length=8) (see Evaluation/check_smart_turn_features.py).
"""
import base64, io, json, math, os, sys, time
from pathlib import Path
import numpy as np
import onnxruntime as ort
import soundfile as sf
from scipy.signal import resample_poly

MODEL = Path(os.environ["VERA_SMART_TURN_MODEL"])
FILTERS = Path(__file__).parent / "smart-turn-mel-filters.npy"
SR, N_FFT, HOP, MAX_SECONDS = 16000, 400, 160, 8
MAX_SAMPLES = SR * MAX_SECONDS


def write(value):
    sys.stdout.write(json.dumps(value) + "\n"); sys.stdout.flush()


def log_mel(audio: np.ndarray, filters: np.ndarray) -> np.ndarray:
    """Whisper features for 8 s: (80, 800), float32. Matches WhisperFeatureExtractor with do_normalize=True."""
    audio = audio.astype(np.float64)
    audio = (audio - audio.mean()) / math.sqrt(audio.var() + 1e-7)           # zero-mean unit-variance
    padded = np.pad(audio, N_FFT // 2, mode="reflect")                        # centre=True frames
    window = np.hanning(N_FFT + 1)[:-1]                                       # periodic Hann
    n_frames = 1 + (padded.size - N_FFT) // HOP
    index = np.arange(N_FFT)[None, :] + HOP * np.arange(n_frames)[:, None]
    power = np.abs(np.fft.rfft(padded[index] * window, axis=1)) ** 2          # (frames, 201)
    mel = np.maximum(1e-10, filters.T.astype(np.float64) @ power.T)           # (80, frames)
    spec = np.log10(mel)[:, :-1]                                              # Whisper drops the last frame
    spec = np.maximum(spec, spec.max() - 8.0)
    return ((spec + 4.0) / 4.0).astype(np.float32)


def to_16k_mono(raw: bytes) -> np.ndarray:
    data, rate = sf.read(io.BytesIO(raw), dtype="float32", always_2d=True)
    mono = data.mean(axis=1).astype(np.float32)
    if rate != SR:
        g = math.gcd(int(rate), SR); mono = resample_poly(mono, SR // g, int(rate) // g).astype(np.float32)
    return mono


def fit_8s(audio: np.ndarray) -> np.ndarray:
    if audio.size >= MAX_SAMPLES:
        return audio[-MAX_SAMPLES:]
    return np.concatenate([np.zeros(MAX_SAMPLES - audio.size, dtype=np.float32), audio])


try:
    filters = np.load(FILTERS)
    session = ort.InferenceSession(str(MODEL), providers=["CPUExecutionProvider"])
    input_name = session.get_inputs()[0].name
    session.run(None, {input_name: log_mel(np.zeros(MAX_SAMPLES, dtype=np.float32) + 1e-4, filters)[None]})
    write({"ready": True, "model": MODEL.name})
except Exception as error:
    write({"ready": False, "error": f"{type(error).__name__}: {error}"})
    raise SystemExit(1)

for line in sys.stdin:
    try:
        started = time.perf_counter()
        raw = base64.b64decode(json.loads(line)["wav_base64"])
        audio = fit_8s(to_16k_mono(raw))
        out = session.run(None, {input_name: log_mel(audio, filters)[None]})
        write({"probability": float(np.asarray(out[0]).reshape(-1)[0]),
               "elapsed_ms": round((time.perf_counter() - started) * 1000)})
    except Exception as error:
        write({"error": f"{type(error).__name__}: {error}"})
