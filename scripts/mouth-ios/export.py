"""Silero v5 (ru) for Vera's phone: three ONNX networks and the text side's data, checked against the original.

    export.py <v5_ru.pt> <out> [<golden-text.txt> <golden.json>]

out/silero-encoder.onnx, silero-decoder.onnx, silero-homo.onnx   networks (silero_eager.py), opset 18
out/silero-text.json   symbols, speakers, accentor (MLP, exceptions, stop words), homograph dict (variants pre-sorted
                       as Python sorts them), BERT vocab and special ids
out/silero-ngrams.txt  accentor n-grams, one per line (line = row); out/silero-ngrams.bin  their int8 table [rows, 16]
out/reference.txt, reference.f32   one sentence and the original's audio for it (the Swift test speaks it too)
golden.json            text -> prepared -> after homographs -> accented -> ids, by the original (Swift tests)

Fails if the ONNX audio differs from the original's by more than 1e-3 on the check sentences.
"""
import json, os, sys, warnings

import numpy as np
import onnx
import onnxruntime as ort
import torch

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from silero_eager import Decoder, Encoder, Homo, durations  # noqa: E402

warnings.filterwarnings("ignore")
torch.set_grad_enabled(False)
model_path, out = sys.argv[1], sys.argv[2]
os.makedirs(out, exist_ok=True)
imp = torch.package.PackageImporter(model_path)
model = imp.load_pickle("tts_models", "model")
p = model.packages[0]
tts = p.models[0]
OPSET = 18

# ---- networks ----

def save(net, args, name, inputs, outputs, dyn):
    path = f"{out}/{name}"
    prog = torch.onnx.export(net, args, dynamo=True, opset_version=OPSET, input_names=inputs, output_names=outputs,
                             dynamic_shapes=dyn, verbose=False)
    prog.optimize()
    prog.save(path, external_data=False)
    mp = onnx.load(path)
    print(f"  {name}: {os.path.getsize(path) / 1e6:.0f} МБ, ir {mp.ir_version}, opset {mp.opset_import[0].version}")

T, F_ = torch.export.Dim("T", min=4, max=4000), torch.export.Dim("F", min=8, max=60000)
N, L = torch.export.Dim("N", min=1, max=64), torch.export.Dim("L", min=4, max=2048)
# The homograph BERT reads the original quantized word table, so it is taken before apply_tts dequantizes it.
homo_net = Homo(p.accentor.homosolver.model).eval()
save(Encoder(tts).eval(), (torch.randint(3, 46, (1, 50)), torch.tensor([1])), "silero-encoder.onnx",
     ["seq", "speaker"], ["log_dur", "cond"], ({1: T}, None))
save(Decoder(tts).eval(), (torch.randn(1, 301, 128),), "silero-decoder.onnx", ["frames"], ["audio"], ({1: F_},))
save(homo_net, (torch.randint(5, 1000, (3, 40)), torch.tensor([3, 5, 7]), torch.tensor([6, 9, 9])),
     "silero-homo.onnx", ["input_ids", "start", "end"], ["logit"], ({0: N, 1: L}, {0: N}, {0: N}))

# ---- text side ----

acc, homo = p.accentor.accentor, p.accentor.homosolver
am, tok = acc.model, homo.tokenizer
# The accentor table ships as integers, dequantized at load (AccentorNgram._loadmodel: scale * (q - zero_point)).
# Recover them and prove the Swift side's float32 formula gives back exactly the table the model uses.
loaded = am.embedding.weight.detach()
q = torch.round(loaded / am.scale + am.zero_point)
assert q.min() >= -128 and q.max() <= 127, "accentor table is not int8"
assert torch.equal(am.scale * (q - am.zero_point), loaded), "dequantization does not round-trip"
ngrams = sorted(am.embedding.ngram_dict.items(), key=lambda kv: kv[1])
assert [i for _, i in ngrams] == list(range(len(ngrams))) == list(range(q.shape[0]))
assert all("\n" not in g and g == g.strip() and g for g, _ in ngrams)
with open(f"{out}/silero-ngrams.txt", "w", encoding="utf-8") as f:
    f.write("\n".join(g for g, _ in ngrams) + "\n")
q.to(torch.int8).numpy().tofile(f"{out}/silero-ngrams.bin")


def mlp(seq):
    mods = list(seq._modules.values())
    layers = [m for m in mods if m.original_name == "Linear"]
    assert [m.original_name for m in mods] == ["Linear", "ReLU"] * (len(layers) - 1) + ["Linear"]
    return [{"w": l.weight.detach().flatten().tolist(), "b": l.bias.detach().tolist(),
             "out": l.weight.shape[0], "in": l.weight.shape[1]} for l in layers]


vocab = sorted(tok.vocab.items(), key=lambda kv: kv[1])
assert [i for _, i in vocab] == list(range(len(vocab)))
data = {
    "about": "Silero TTS v5_ru text side for Vera's phone (scripts/build-mouth-ios.sh)",
    "speakers": p.speaker_to_ids[0], "symbols": p.symbols, "symbol_to_id": p.symbol_to_id,
    "sos": p.sos_token, "eos": p.eos_token,
    "accentor": {"scale": float(am.scale), "zero_point": float(am.zero_point), "dim": int(q.shape[1]),
                 "stress": mlp(am.stress_clf), "yo": mlp(am.yo_clf),
                 "exceptions": {k: list(v) for k, v in acc.exceptions.items()}, "stop_words": acc.stop_words},
    "homo": {"dict": {k: sorted(v) for k, v in homo.homodict.items()}, "vocab": [t for t, _ in vocab],
             "cls": tok.cls_token_id, "sep": tok.sep_token_id, "unk": tok.unk_token_id, "pad": tok.pad_token_id,
             "start": tok.homo_start_id, "end": tok.homo_end_id, "never_split": sorted(tok.never_split),
             "max_chars": tok.wordpiece_tokenizer.max_input_chars_per_word},
}
with open(f"{out}/silero-text.json", "w", encoding="utf-8") as f:
    json.dump(data, f, ensure_ascii=False, separators=(",", ":"))
print(f"  текст: {len(ngrams)} n-грамм, {len(acc.exceptions)} исключений, {len(homo.homodict)} омографов, {len(vocab)} токенов")

# ---- check: ONNX against the original, sentence by sentence ----

E = ort.InferenceSession(f"{out}/silero-encoder.onnx")
D = ort.InferenceSession(f"{out}/silero-decoder.onnx")
H = ort.InferenceSession(f"{out}/silero-homo.onnx")
checks = ["Привет! Я Вера, твоя подруга. Сегодня в Паттайе тридцать градусов, и всё хорошо.",
          "Да.", "Ну что, поехали в магазин за хлебом?", "Мой замок на двери, а не замок короля."]
for i, text in enumerate(checks):
    ref = model.apply_tts(text=text, speaker="baya", sample_rate=48000, put_accent=True, put_yo=True).numpy()
    sents, _, br, rates, pitches, sp = p.prepare_tts_model_input(text, ssml=False, speaker_ids=[1])
    seq, *_ = p.merge_batch_model(sents, br, rates, pitches)
    log_dur, cond = E.run(None, {"seq": seq.numpy(), "speaker": np.array([1], dtype=np.int64)})
    d = durations(torch.from_numpy(log_dur)).numpy().astype(np.int64)
    (audio,) = D.run(None, {"frames": np.repeat(cond[0], d[0], axis=0)[None].astype(np.float32)})
    diff = float(np.abs(ref - audio[0]).max()) if ref.shape == audio[0].shape else float("inf")
    print(f"  проверка {i + 1}: {len(ref) / 48000:.1f} с, расхождение {diff:.6f}")
    assert diff < 1e-3, f"ONNX differs from the original on: {text}"
    if i == 2:
        open(f"{out}/reference.txt", "w", encoding="utf-8").write(text)
        ref.astype("<f4").tofile(f"{out}/reference.f32")
# the homograph BERT on a real batch (padding attended, as in the original)
sent = "мой замок на двери, а не замок короля. все пришли, но белки ели белки."
rows, st, en = [], [], []
for _, _, _, _, raw in homo._find_and_tag_homos(sent):
    if raw is None:
        continue
    t = torch.tensor(tok(raw)); rows.append(t)
    st.append(int(torch.where(t == tok.homo_start_id)[0][0])); en.append(int(torch.where(t == tok.homo_end_id)[0][0]))
batch = torch.nn.utils.rnn.pad_sequence(rows, batch_first=True, padding_value=tok.pad_token_id)
ref_logits = homo.model(batch, torch.tensor(st), torch.tensor(en)).flatten().numpy()
(logits,) = H.run(None, {"input_ids": batch.numpy(), "start": np.array(st), "end": np.array(en)})
assert np.abs(ref_logits - logits).max() < 1e-3, "homograph BERT differs from the original"
print(f"  омографы: {len(rows)} строк, расхождение {np.abs(ref_logits - logits).max():.6f}")

# ---- golden cases for the Swift tests ----

if len(sys.argv) > 4:
    cases = []
    for text in open(sys.argv[3], encoding="utf-8").read().splitlines():
        if not text.strip():
            continue
        sentence, _, _ = p.prepare_text_input(text)
        seq, *_ = p.merge_batch_model([sentence], [None], [1.0], [1.0])
        cases.append({"text": text, "prepared": sentence, "homo": homo(sentence), "accented": p.accentor(sentence),
                      "ids": seq[0].tolist()})
    with open(sys.argv[4], "w", encoding="utf-8") as f:
        json.dump(cases, f, ensure_ascii=False, indent=1); f.write("\n")
    print(f"  эталон: {len(cases)} фраз → {sys.argv[4]}")
