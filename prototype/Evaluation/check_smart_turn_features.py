"""Checks the numpy Whisper features of smart-turn-worker.py against transformers' WhisperFeatureExtractor.
Run with an environment that has transformers + numpy (Vera 1's Jev venv works)."""
import importlib.util, math, sys
import numpy as np
from pathlib import Path
from transformers import WhisperFeatureExtractor

workers = Path(__file__).resolve().parent.parent / "Sensors" / "Workers"
source = (workers / "smart-turn-worker.py").read_text().split("try:\n    filters")[0]
source = source.replace('MODEL = Path(os.environ["VERA_SMART_TURN_MODEL"])', 'MODEL = None').replace('import onnxruntime as ort', '').replace('import soundfile as sf', '').replace('from scipy.signal import resample_poly', '')
ns = {"__file__": str(workers / "smart-turn-worker.py")}
exec(compile(source, "worker", "exec"), ns)
filters = np.load(workers / "smart-turn-mel-filters.npy")
fe = WhisperFeatureExtractor(chunk_length=8)
rng = np.random.default_rng(0)
worst = 0.0
for n in (16000 * 8, 16000 * 8):
    audio = (rng.standard_normal(n) * 0.1 * np.sin(np.linspace(0, 400, n))).astype(np.float32)
    ref = fe(audio, sampling_rate=16000, return_tensors="np", padding="max_length", max_length=16000 * 8,
             truncation=True, do_normalize=True).input_features[0]
    mine = ns["log_mel"](audio, filters)
    worst = max(worst, float(np.abs(ref - mine).max()))
    print("shape ref", ref.shape, "mine", mine.shape, "max abs diff", worst)
sys.exit(0 if worst < 1e-3 else 1)
