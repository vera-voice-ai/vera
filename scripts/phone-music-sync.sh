#!/bin/zsh
# Vera's downloaded music → the phone, kept in step: what Hermes downloaded (workspace/soulseek, see its catalog
# каталог.json) goes to the app's Documents/Music/Vera with library.json (artist, title, album). That folder on the
# phone is a mirror: tracks gone here go there too; what the owner adds himself (Documents/Music) is left alone.
# Copied without --remove-existing-content: with it devicectl wiped the app's whole data container (settings, home and
# work, the journals), not just Music/Vera. Tracks dropped from library.json are deleted by the app itself (Music.scan).
# Only near the phone (Wi-Fi or cable); run by the launchd agent of scripts/phone-deploy.sh every 30 minutes.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WS="$HOME/Library/Application Support/Vera03/hermes/workspace"
STAGE="$HOME/.vera03/build/phone-music/Vera"   # no spaces: devicectl does not take a source path with them
STATUS="$HOME/Library/Application Support/Vera03/phone-music.json"
BUNDLE="$("$(dirname "$0")/phone-bundle.sh")"
[[ -f "$WS/soulseek/каталог.json" ]] || exit 0
udid=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /iPhone/ && /(^| )available|connected/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)
[[ -n "$udid" ]] || exit 0
n=$(/usr/bin/python3 -I "$ROOT/scripts/phone-music/stage.py" "$WS" "$STAGE") || { print -r -- "музыка: не собрал список"; exit 0; }
stamp="$HOME/.vera03/build/phone-music/last"
# A transfer with the phone may hang when it falls asleep or leaves the Wi-Fi: give it a ceiling, so the launchd
# agent (and the installs after it) never waits on it. Prints the command's output; fails on timeout.
within() {
  local secs=$1; shift
  local out=$(mktemp)
  "$@" >"$out" 2>&1 &
  local pid=$! waited=0
  while kill -0 $pid 2>/dev/null; do
    (( waited >= secs )) && { kill $pid 2>/dev/null; sleep 1; kill -9 $pid 2>/dev/null; cat "$out"; print -r -- "ERROR: no answer from the phone in ${secs} s"; rm -f "$out"; return 124; }
    sleep 1; (( waited++ ))
  done
  wait $pid; local rc=$?
  cat "$out"; rm -f "$out"; return $rc
}
sig=$(cd "$STAGE" && ls -l | shasum | cut -c1-16)
[[ "$(cat "$stamp" 2>/dev/null)" == "$sig" ]] && exit 0
if out=$(within 900 xcrun devicectl device copy to --device "$udid" --source "$STAGE" --destination Documents/Music/Vera \
    --domain-type appDataContainer --domain-identifier "$BUNDLE" 2>&1); then
  print -r -- "$sig" > "$stamp"
  print -r -- "{\"tracks\": $n, \"synced\": $(date +%s)}" > "$STATUS"
  print -r -- "$(date '+%Y-%m-%d %H:%M:%S') музыка на телефоне: $n треков (Music/Vera)"
else
  print -r -- "музыка не перенесена: $(print -r -- "$out" | grep -m1 -iE 'error' | cut -c1-160)"
fi
