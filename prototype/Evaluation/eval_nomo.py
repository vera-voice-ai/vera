import glob, hashlib, math, os, sys
import numpy as np, soundfile as sf, torch, torchaudio
APP = os.path.expanduser("~/Library/Application Support/VeraSensorPrototype")
sys.path.insert(0, "/Users/alex/Projects/vera-v2/prototype/Sensors/Workers/nomo_pvad")
from nomo_pvad import NomoPVAD, NomoPVADSession
ROOT = os.path.expanduser("~/Documents/Голоса"); SR = 16000
FOLDERS = {"01_aleksey": "Алексей", "02_natasha": "Наташа", "03_vera_self": "Вера",
           "04_valera": "Валера", "05_elya": "Эля", "06_polina": "Полина"}
def load(p):
    x, r = sf.read(p, dtype="float32", always_2d=True); m = x.mean(axis=1).astype(np.float32)
    if r != SR: m = torchaudio.functional.resample(torch.from_numpy(m), r, SR).numpy()
    return m
torch.set_num_threads(4)
model = NomoPVAD(f"{APP}/Models/NomoPVAD/nomo_pvad.pt", f"{APP}/Models/NomoPVAD", device="cpu")
enroll = load(f"{APP}/Users/voice-samples/alex/enrollment/target-voice-5.wav")
clips, seen = [], set()
def add(person, p):
    m = load(p); h = hashlib.sha1(np.round(m[:SR*2]*32767).astype(np.int16).tobytes()).hexdigest()
    if h in seen or m.size < 8000: return
    seen.add(h); clips.append((person, p, m))
for f, person in FOLDERS.items():
    for p in sorted(glob.glob(f"{ROOT}/{f}/samples/*.wav")): add(person, p)
for d in sorted(glob.glob(f"{ROOT}/Разобранные/*/")):
    for p in sorted(glob.glob(d+"*.wav")): add(os.path.basename(d.rstrip("/")), p)
res = {}
for person, p, m in clips:
    s = NomoPVADSession(model); s.set_enrollment(enroll)
    probs = [float(s.process_chunk(m[i:i+2560])) for i in range(0, m.size - 2560 + 1, 2560)]
    res.setdefault(person, []).append(probs)

def roll(x, k=6):
    x=x[3:]
    return [float(np.mean(x[j:j+k])) for j in range(0, len(x)-k+1)]
own=np.array([v for l in res["Алексей"] for v in roll(l)])
oth=np.array([v for p,ls in res.items() if p!="Алексей" for l in ls for v in roll(l)])
print(f"1 s rolling mean: owner n={own.size} p1={np.percentile(own,1):.2f} p5={np.percentile(own,5):.2f} median={np.median(own):.2f} | others n={oth.size} median={np.median(oth):.2f} p95={np.percentile(oth,95):.2f} p99={np.percentile(oth,99):.2f} max={oth.max():.2f}")
for t in (0.3,0.4,0.5,0.6,0.7,0.8):
    print(f"threshold {t:.1f}: owner recall={np.mean(own>=t):.2f}  other false-accept={np.mean(oth>=t):.3f}")
for p,ls in res.items():
    v=np.array([x for l in ls for x in roll(l)])
    if v.size: print(f"{p:8s} 1 s mean: >=0.7 {np.mean(v>=0.7):.2f}  0.3-0.7 {np.mean((v>=0.3)&(v<0.7)):.2f}  <0.3 {np.mean(v<0.3):.2f}")
