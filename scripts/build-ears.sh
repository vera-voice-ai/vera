#!/bin/zsh
# Vera's ears for the box: the sherpa-onnx C library, GigaAM v3, T-one and Silero VAD, pinned in ears.lock.json.
#   build-ears.sh          fetch (cached in ~/.vera03/downloads), check sha256, unpack into ~/.vera03/build/ears
#   build-ears.sh --pin    the same, and write the sha256 of new items into the lock (only when changing versions)
# Touches nothing outside ~/.vera03 and the repository.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${VERA_BUILD_ROOT:-$HOME/.vera03}"
PIN=0; [[ "${1:-}" == "--pin" ]] && PIN=1
mkdir -p "$WORK/downloads" "$WORK/build"
/usr/bin/python3 -I - "$REPO/ears.lock.json" "$WORK" "$PIN" <<'PY'
import hashlib, json, os, shutil, subprocess, sys, tarfile, urllib.request
lock_path, work, pin = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
lock = json.load(open(lock_path))
out = os.path.join(work, "build", "ears.tmp")
shutil.rmtree(out, ignore_errors=True)
changed = False
for item in lock["items"]:
    url = item["url"]; name = os.path.basename(url)
    cached = os.path.join(work, "downloads", name)
    if not os.path.exists(cached):
        print(f"→ {item['name']}: {name}", flush=True)
        subprocess.run(["/usr/bin/curl", "-fsSL", "--retry", "3", "-o", cached + ".part", url], check=True)
        os.replace(cached + ".part", cached)
    h = hashlib.sha256()
    with open(cached, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""): h.update(block)
    digest = h.hexdigest()
    if item["sha256"] != digest:
        if pin and not item["sha256"]:
            item["sha256"] = digest; changed = True
        else:
            sys.exit(f"ошибка: {name}: sha256 {digest}, в замке {item['sha256'] or 'пусто (нужен --pin)'}")
    dest = os.path.join(out, item["dest"])
    if name.endswith(".tar.bz2"):
        os.makedirs(dest, exist_ok=True)
        with tarfile.open(cached) as t:
            members = t.getmembers()
            for m in members:   # the system Python has no extraction filter: refuse odd entries ourselves
                if m.name.startswith("/") or ".." in m.name.split("/") or not (m.isfile() or m.isdir() or m.issym()):
                    sys.exit(f"ошибка: {name}: подозрительный элемент {m.name}")
                if m.issym() and (m.linkname.startswith("/") or ".." in m.linkname.split("/")):
                    sys.exit(f"ошибка: {name}: ссылка наружу {m.name}")
            t.extractall(dest, members=members)
        # Every archive has one top folder: lift its contents to dest.
        inner = [d for d in os.listdir(dest) if not d.startswith(".")]
        if len(inner) == 1 and os.path.isdir(os.path.join(dest, inner[0])):
            top = os.path.join(dest, inner[0])
            for e in os.listdir(top): shutil.move(os.path.join(top, e), dest)
            os.rmdir(top)
    else:
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        shutil.copy2(cached, dest)
final = os.path.join(work, "build", "ears")
shutil.rmtree(final, ignore_errors=True)
os.replace(out, final)
json.dump({"sherpa_onnx": lock["sherpa_onnx"], "items": {i["name"]: i["sha256"] for i in lock["items"]}},
          open(os.path.join(final, "ears.stamp.json"), "w"), indent=2)
if changed:
    with open(lock_path, "w") as f: json.dump(lock, f, indent=2, ensure_ascii=False); f.write("\n")
    print("замок обновлён: sha256 записаны")
print(final)
PY
