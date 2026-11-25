"""Smart Turn v3.2 (Pipecat): has the speaker finished the turn? Audio in, probability out — from sound alone
(prosody, pauses), no text. A long-lived worker in the mouth's Python (numpy + onnxruntime), started by Vera.

in:  {"id": 1, "pcm": "<base64 float32 little-endian mono 16 kHz>"}   (the phrase so far; the last 8 s are used)
out: {"id": 1, "probability": 0.87, "ms": 31}  |  {"id": 1, "error": "..."}
The first line out is {"ready": true}. Whisper log-mel features in numpy (as in Vera 2, checked there against
transformers' WhisperFeatureExtractor(chunk_length=8)); the filters are smart-turn-mel-filters.npy next to this file.
"""
import base64, json, math, sys, time
from pathlib import Path

import numpy as np
import onnxruntime as ort

SR, N_FFT, HOP, MAX_SAMPLES = 16000, 400, 160, 16000 * 8


def log_mel(audio, filters):
    audio = audio.astype(np.float64)
    audio = (audio - audio.mean()) / math.sqrt(audio.var() + 1e-7)
    padded = np.pad(audio, N_FFT // 2, mode="reflect")
    window = np.hanning(N_FFT + 1)[:-1]
    n_frames = 1 + (padded.size - N_FFT) // HOP
    index = np.arange(N_FFT)[None, :] + HOP * np.arange(n_frames)[:, None]
    power = np.abs(np.fft.rfft(padded[index] * window, axis=1)) ** 2
    mel = np.maximum(1e-10, filters.T.astype(np.float64) @ power.T)
    spec = np.log10(mel)[:, :-1]
    spec = np.maximum(spec, spec.max() - 8.0)
    return ((spec + 4.0) / 4.0).astype(np.float32)


def fit_8s(audio):
    if audio.size >= MAX_SAMPLES:
        return audio[-MAX_SAMPLES:]
    return np.concatenate([np.zeros(MAX_SAMPLES - audio.size, dtype=np.float32), audio])


def main():
    model = sys.argv[1]
    filters = np.load(Path(__file__).with_name("smart-turn-mel-filters.npy"))
    opts = ort.SessionOptions(); opts.intra_op_num_threads = 2
    session = ort.InferenceSession(model, opts, providers=["CPUExecutionProvider"])
    name = session.get_inputs()[0].name
    session.run(None, {name: log_mel(np.zeros(MAX_SAMPLES, dtype=np.float32) + 1e-4, filters)[None]})
    print(json.dumps({"ready": True}), flush=True)
    for line in sys.stdin:
        req = {}
        try:
            req = json.loads(line)
            t0 = time.monotonic()
            audio = np.frombuffer(base64.b64decode(req["pcm"]), dtype="<f4")
            out = session.run(None, {name: log_mel(fit_8s(audio), filters)[None]})
            print(json.dumps({"id": req.get("id"), "probability": float(np.asarray(out[0]).reshape(-1)[0]),
                              "ms": int((time.monotonic() - t0) * 1000)}), flush=True)
        except Exception as e:  # one bad request must not stop the worker
            print(json.dumps({"id": req.get("id"), "error": f"{type(e).__name__}: {e}"}), flush=True)


if __name__ == "__main__":
    main()
