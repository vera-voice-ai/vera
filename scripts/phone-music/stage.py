"""Stage Vera's downloaded music for the phone: the files Hermes downloaded (its workspace, soulseek/музыка) under
clear names «Artist - Title.ext», and library.json with artist / title / album / year from its catalog (каталог.json),
which is more exact than the files' own tags. Hard links: no copies on disk. Usage: stage.py <workspace> <stage-dir>"""
import json
import os
import re
import sys

ws, stage = sys.argv[1], sys.argv[2]
root = os.path.join(ws, "soulseek")
catalog = json.load(open(os.path.join(root, "каталог.json"), encoding="utf-8"))["tracks"]
local = os.path.join(root, "музыка")
os.makedirs(stage, exist_ok=True)
for f in os.listdir(stage):
    os.remove(os.path.join(stage, f))

library, seen = [], set()
for t in catalog:
    if t.get("status") != "скачано" or not t.get("file"):
        continue
    src = os.path.join(local, t["file"].replace("\\", "/").split("/")[-1])
    if not os.path.isfile(src):
        continue
    ext = os.path.splitext(src)[1].lower()
    name = re.sub(r'[/\\:]+', " ", f"{t['artist']} - {t['title']}").strip()[:180] + ext
    if name in seen:
        continue
    seen.add(name)
    os.link(src, os.path.join(stage, name))
    entry = {"file": name, "artist": t["artist"], "title": t["title"]}
    for k in ("album", "year", "duration"):
        if t.get(k):
            entry[k] = t[k]
    library.append(entry)

json.dump(library, open(os.path.join(stage, "library.json"), "w", encoding="utf-8"), ensure_ascii=False, indent=1)
print(len(library))
