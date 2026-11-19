#!/usr/bin/env python3
"""Compare Russian speech recognizers on the clips of the owner's own corpus.

There is no hand-made ground truth yet, so the current recognizer (GigaAM v3 through ONNX, the text stored in the
manifest) is the reference only for AGREEMENT and speed; this is not an accuracy score. Prints a short numbers-only
summary and writes the full texts to Evaluation/runs/ (git-ignored, they are the owner's speech).

Run with the dedicated venv:
  ~/Library/Application Support/VeraSensorPrototype/Python/AsrCompare/venv/bin/python asr_compare.py [--clips 80]
"""
import argparse, json, re, statistics, sys, time, wave
from pathlib import Path
import numpy as np

CORPUS = Path.home() / "Library/Application Support/VeraSensorPrototype/Corpus/voice-tasks"
OUT = Path(__file__).parent / "runs"

def norm(text: str) -> list[str]:
    return re.sub(r"[^\w\s]", " ", text.lower().replace("ё", "е")).split()

def wer(ref: list[str], hyp: list[str]) -> float:
    """Word error rate of hyp against ref (edit distance over words)."""
    if not ref:
        return 0.0 if not hyp else 1.0
    prev = list(range(len(hyp) + 1))
    for i, r in enumerate(ref, 1):
        cur = [i]
        for j, h in enumerate(hyp, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (r != h)))
        prev = cur
    return prev[-1] / len(ref)

def load_wav(path: Path) -> np.ndarray:
    with wave.open(str(path), "rb") as f:
        assert f.getframerate() == 16000 and f.getnchannels() == 1, "expects 16 kHz mono"
        return np.frombuffer(f.readframes(f.getnframes()), dtype=np.int16).astype(np.float32) / 32768.0

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--clips", type=int, default=80)
    args = ap.parse_args()
    rows = [json.loads(l) for l in (CORPUS / "manifest.jsonl").read_text().splitlines()]
    rows = [r for r in rows if r["seconds"] >= 2.0 and len(norm(r["asr_text"])) >= 3]
    rows.sort(key=lambda r: r["id"])
    step = max(1, len(rows) // args.clips)
    rows = rows[::step][: args.clips]
    print(f"{len(rows)} clips, {sum(r['seconds'] for r in rows):.0f} s of audio", file=sys.stderr)

    systems = {}
    import mlx_whisper
    from gigaam_mlx import load_model, transcribe
    ctc, ctc_tok = load_model()
    systems["gigaam-mlx ctc"] = lambda p, a: transcribe(ctc, ctc_tok, str(p))
    try:
        rnnt, rnnt_tok = load_model(model_type="rnnt")
        systems["gigaam-mlx rnnt"] = lambda p, a: transcribe(rnnt, rnnt_tok, str(p))
    except Exception as e:  # the RNNT variant is optional for the comparison
        print("rnnt unavailable:", type(e).__name__, file=sys.stderr)
    systems["whisper large-v3-turbo"] = lambda p, a: mlx_whisper.transcribe(
        a, path_or_hf_repo="mlx-community/whisper-large-v3-turbo", language="ru", condition_on_previous_text=False)["text"]

    results = {name: [] for name in systems}
    for name, fn in systems.items():          # warm-up so that the first call does not carry the model load
        first = rows[0]; fn(CORPUS / first["file"], load_wav(CORPUS / first["file"]))
    for r in rows:
        audio = load_wav(CORPUS / r["file"])
        for name, fn in systems.items():
            t = time.perf_counter()
            text = fn(CORPUS / r["file"], audio)
            results[name].append({"id": r["id"], "seconds": r["seconds"], "text": text.strip(), "ms": (time.perf_counter() - t) * 1000})

    print(f"\n{'system':26} {'agree with current':>20} {'median ms':>10} {'x realtime':>11} {'empty':>6}")
    for name, items in results.items():
        w = [wer(norm(r["asr_text"]), norm(i["text"])) for r, i in zip(rows, items)]
        ms = [i["ms"] for i in items]
        rt = sum(i["seconds"] for i in items) / (sum(ms) / 1000)
        empty = sum(1 for i in items if not norm(i["text"]))
        print(f"{name:26} {100 * (1 - statistics.mean(w)):>19.1f}% {statistics.median(ms):>10.0f} {rt:>10.1f}x {empty:>6}")
    OUT.mkdir(exist_ok=True)
    (OUT / "asr-compare.json").write_text(json.dumps({"reference": [{"id": r["id"], "text": r["asr_text"]} for r in rows], "systems": results}, ensure_ascii=False))
    print(f"\nfull texts: {OUT / 'asr-compare.json'}")

if __name__ == "__main__":
    main()
