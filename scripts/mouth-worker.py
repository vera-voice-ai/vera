"""Vera's mouth: Silero TTS as a long-lived worker. One JSON line in, one JSON line out.

in:  {"id": 1, "text": "Привет.", "speaker": "baya", "sample_rate": 48000}
out: {"id": 1, "pcm": "<base64 float32 little-endian mono>", "sample_rate": 48000, "ms": 120}
     {"id": 1, "error": "..."}
The first line out is {"ready": true, ...} once the model is loaded. Only text comes in; nothing is logged but errors.
Started by Vera with `python -I worker.py <model.pt>`: isolated, no inherited environment, nothing found on the machine.
"""
import base64, json, sys, time

import torch


def main() -> None:
    model_path = sys.argv[1]
    torch.set_num_threads(4)
    importer = torch.package.PackageImporter(model_path)
    model = importer.load_pickle("tts_models", "model")
    model.to(torch.device("cpu"))
    print(json.dumps({"ready": True, "speakers": list(getattr(model, "speakers", []))}), flush=True)
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        req = {}
        try:
            req = json.loads(line)
            t0 = time.monotonic()
            audio = model.apply_tts(text=req["text"], speaker=req.get("speaker", "baya"),
                                    sample_rate=int(req.get("sample_rate", 48000)), put_accent=True, put_yo=True)
            pcm = audio.detach().to(torch.float32).contiguous().numpy().astype("<f4").tobytes()
            print(json.dumps({"id": req.get("id"), "pcm": base64.b64encode(pcm).decode("ascii"),
                              "sample_rate": int(req.get("sample_rate", 48000)),
                              "ms": int((time.monotonic() - t0) * 1000)}), flush=True)
        except Exception as e:  # one bad sentence must not stop the mouth
            print(json.dumps({"id": req.get("id"), "error": f"{type(e).__name__}: {e}"}), flush=True)


if __name__ == "__main__":
    main()
