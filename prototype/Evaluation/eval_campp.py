#!/usr/bin/env python3
"""Leave-one-clip-out CAM++ evaluation on ~/Documents/Голоса. Prints only aggregates."""
import glob, hashlib, json, math, os, sys
import numpy as np, soundfile as sf, sherpa_onnx
from scipy.signal import resample_poly

ROOT = os.path.expanduser("~/Documents/Голоса")
MODEL = "/Users/alex/Projects/vera/Support/silero-tts/models/sherpa/3dspeaker_speech_campplus_sv_zh_en_16k-common_advanced.onnx"
SR = 16000
FOLDERS = {"01_aleksey": "Алексей", "02_natasha": "Наташа", "03_vera_self": "Вера",
           "04_valera": "Валера", "05_elya": "Эля", "06_polina": "Полина"}

def load16k(path):
    x, rate = sf.read(path, dtype="float32", always_2d=True)
    m = x.mean(axis=1).astype(np.float32)
    if rate != SR:
        g = math.gcd(int(rate), SR); m = resample_poly(m, SR // g, int(rate) // g).astype(np.float32)
    return m

ext = sherpa_onnx.SpeakerEmbeddingExtractor(sherpa_onnx.SpeakerEmbeddingExtractorConfig(
    model=MODEL, num_threads=4, debug=False, provider="cpu"))

def embed(m):
    s = ext.create_stream(); s.accept_waveform(SR, m); s.input_finished()
    e = np.asarray(ext.compute(s), dtype=np.float64); return e / np.linalg.norm(e)

# ---- collect corpus (reviewed clips only), dedupe by audio content
clips, seen = [], {}
def add(person, path):
    m = load16k(path)
    h = hashlib.sha1(np.round(m[:SR*2] * 32767).astype(np.int16).tobytes()).hexdigest()
    if h in seen or m.size < 8000: return
    seen[h] = path; clips.append({"person": person, "path": path, "pcm": m})
for folder, person in FOLDERS.items():
    for p in sorted(glob.glob(f"{ROOT}/{folder}/samples/*.wav")): add(person, p)
for d in sorted(glob.glob(f"{ROOT}/Разобранные/*/")):
    person = os.path.basename(d.rstrip("/"))
    for p in sorted(glob.glob(d + "*.wav")): add(person, p)

people = sorted({c["person"] for c in clips})
print("clips:", len(clips), {p: sum(c["person"] == p for c in clips) for p in people})
print("seconds:", {p: round(sum(c["pcm"].size for c in clips if c["person"] == p) / SR, 1) for p in people})
for i, c in enumerate(clips): c["id"] = i; c["emb"] = embed(c["pcm"])

def score(probe_emb, exclude_id):
    """best cosine per person over other clips' embeddings (probe's own clip excluded)."""
    out = {}
    for p in people:
        vals = [float(probe_emb @ c["emb"]) for c in clips if c["person"] == p and c["id"] != exclude_id]
        if vals: out[p] = max(vals)
    return out

def probes(window_s):
    for c in clips:
        if window_s is None: yield c, c["emb"]; continue
        w, hop = int(window_s * SR), int(0.8 * SR)
        for s in range(0, max(1, c["pcm"].size - w + 1), hop):
            seg = c["pcm"][s:s + w]
            if seg.size == w: yield c, embed(seg)

def evaluate(window_s, label):
    rows = []
    for c, e in probes(window_s):
        sc = score(e, c["id"])
        if c["person"] not in sc: continue
        ranked = sorted(sc.items(), key=lambda kv: -kv[1])
        rows.append({"true": c["person"], "top": ranked[0][0], "top_s": ranked[0][1],
                     "margin": ranked[0][1] - ranked[1][1] if len(ranked) > 1 else None,
                     "true_s": sc[c["person"]],
                     "best_other": max([v for k, v in sc.items() if k != c["person"]], default=None)})
    n = len(rows); acc = sum(r["top"] == r["true"] for r in rows) / n
    print(f"\n=== {label}: {n} probes, top-1 accuracy {acc:.3f}")
    for p in people:
        rp = [r for r in rows if r["true"] == p]
        if not rp: continue
        gen = np.array([r["true_s"] for r in rp]); imp = np.array([r["best_other"] for r in rp if r["best_other"] is not None])
        a = sum(r["top"] == p for r in rp) / len(rp)
        wrong = {}
        for r in rp:
            if r["top"] != p: wrong[r["top"]] = wrong.get(r["top"], 0) + 1
        print(f"{p:8s} n={len(rp):3d} acc={a:.2f} same-person cos mean={gen.mean():.2f} min={gen.min():.2f} | best-other mean={imp.mean():.2f} max={imp.max():.2f} | confused with {wrong}")
    # decision rule from the corpus README: known if top>=0.55 and margin>=0.07
    ok = [r for r in rows if r["top_s"] >= 0.55 and (r["margin"] or 0) >= 0.07]
    right = sum(r["top"] == r["true"] for r in ok)
    print(f"rule top>=0.55 & margin>=0.07: answers {len(ok)}/{n} ({len(ok)/n:.0%}), correct among answered {right}/{len(ok)} ({right/max(1,len(ok)):.0%})")
    # owner verification: Алексей vs everyone else, sweep on top score for 'Алексей'
    al = [r for r in rows if r["true"] == "Алексей"]
    if al:
        # genuine: Алексей probes, score vs Алексей; impostor: other probes, score vs Алексей (excluding self irrelevant)
        gen = np.array([r["true_s"] for r in al]); imp = []
        for c, e in probes(window_s):
            if c["person"] == "Алексей": continue
            sc = score(e, c["id"])
            if "Алексей" in sc: imp.append(sc["Алексей"])
        imp = np.array(imp)
        best = None
        for t in np.linspace(0.2, 0.9, 71):
            far = (imp >= t).mean(); frr = (gen < t).mean()
            if best is None or abs(far - frr) < best[0]: best = (abs(far - frr), t, far, frr)
        print(f"owner (Алексей) vs others: genuine n={len(gen)} mean={gen.mean():.2f} | impostor n={len(imp)} mean={imp.mean():.2f} p95={np.percentile(imp,95):.2f} max={imp.max():.2f} | EER≈{(best[2]+best[3])/2:.2f} at cos {best[1]:.2f}")

evaluate(None, "full clips (leave-one-clip-out)")
evaluate(1.6, "1.6 s windows, hop 0.8 s (live window size)")
