#!/bin/zsh
# The phone's activity log (self-analysis) (SensorLog: places, GPS, activity, steps, the phone's state) → Vera's data on the
# Mac: ~/Library/Application Support/Vera03/sensors/<day>/*.jsonl. Over Wi-Fi or cable, only when the phone is near;
# devicectl skips files that did not change. Run by the launchd agent of scripts/phone-deploy.sh every 30 minutes.
# Nothing here goes to Hermes by itself: it reads the log only when asked.
set -uo pipefail
BUNDLE="$("$(dirname "$0")/phone-bundle.sh")"
DEST="$HOME/Library/Application Support/Vera03/sensors"
udid=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /iPhone/ && /(^| )available|connected/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)
[[ -n "$udid" ]] || exit 0
mkdir -p "$DEST"
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
out=$(within 90 xcrun devicectl device copy from --device "$udid" --source Documents/Sensors --destination "$DEST" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE" 2>&1) || {
  # No log yet (the app was not opened since it was installed, or recording is off): nothing to say.
  print -r -- "$out" | grep -q "file node" && exit 0
  print -r -- "журнал активности с телефона не скопирован: $(print -r -- "$out" | grep -m1 -iE 'error' | cut -c1-160)"; exit 0; }
print -r -- "$(date '+%Y-%m-%d %H:%M:%S') журнал активности телефона → $DEST ($(find "$DEST" -name '*.jsonl' | wc -l | tr -d ' ') файлов)"
