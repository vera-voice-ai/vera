#!/bin/zsh
# Prints the iPhone app's bundle id: $(VERA_BUNDLE_PREFIX).phone, the prefix from phone/Local.xcconfig (the owner's
# own values, not in git) or else from phone/Vera.xcconfig. Used by the phone scripts instead of a fixed id.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
prefix=""
for f in "$ROOT/phone/Local.xcconfig" "$ROOT/phone/Vera.xcconfig"; do
  [[ -f "$f" ]] || continue
  prefix=$(sed -n -E 's/^[[:space:]]*VERA_BUNDLE_PREFIX[[:space:]]*=[[:space:]]*([^[:space:]]+).*/\1/p' "$f" | tail -1)
  [[ -n "$prefix" ]] && break
done
print -r -- "${prefix:-space.vera.v03}.phone"
