#!/bin/zsh
# Build the iPhone sensor (phone/Vera.xcodeproj: the app and its Live Activity extension) and install it on the owner's iPhone over Wi-Fi.
# A free Apple ID (Personal Team) signs for 7 days only, so this runs on a schedule (launchd, see
# scripts/phone-deploy-schedule.sh, every 30 min): it installs a changed version as soon as the phone is on the Mac's
# network, and reinstalls when the last install is older than VERA_PHONE_EVERY_DAYS (3) so the signature never runs out.
# Usage: phone-deploy.sh [--force]      VERA_PHONE_UDID picks the device (default: the first paired physical iPhone).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUNDLE="$("$ROOT/scripts/phone-bundle.sh")"
DATA="$HOME/Library/Application Support/Vera03"
LOG="$DATA/phone-deploy.log"
STAMP="$DATA/phone-deploy.last"
BUILD="$HOME/.vera03/build/phone"
EVERY_DAYS="${VERA_PHONE_EVERY_DAYS:-3}"
mkdir -p "$DATA" "$BUILD"
log() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*" | tee -a "$LOG" >&2; }

# The phone's activity log (self-analysis) comes home on every run, whether or not there is anything to install.
"$ROOT/scripts/phone-sensors.sh" >>"$LOG" 2>&1 || true
# Vera's downloaded music goes to the phone the same way (Music/Vera, a mirror with library.json).
"$ROOT/scripts/phone-music-sync.sh" >>"$LOG" 2>&1 || true

# A request from Hermes (skill vera): it has its own HOME without Xcode's signing, so it leaves this file
# and kicks the launchd agent, which runs here with the owner's environment.
FORCE_FILE="$DATA/phone-deploy.force"
force="${1:-}"
if [[ -f "$FORCE_FILE" ]]; then force=--force; log "запрос на установку: $(head -c 200 "$FORCE_FILE")"; rm -f -- "$FORCE_FILE"; fi
# What is on the phone is described by a hash of the app's code (the phone package and the shared wire format):
# a changed hash means a new version to install as soon as the phone is near; otherwise only the signature's age.
code_hash=$(cd "$ROOT" && find phone/Vera.xcodeproj/project.pbxproj phone/VeraPhone.swiftpm/Sources phone/Shared phone/VeraWidgets phone/Vera \
  phone/VeraPhoneDeps/Package.swift phone/VeraPhoneDeps/CSherpaPhone app/Sources/PhoneWire app/Sources/SileroVoice app/Sources/VeraKit app/Sources/VeraMusic ears.lock.json -type f \( -name '*.swift' -o -name '*.c' -o -name '*.h' -o -name '*.json' -o -name '*.plist' -o -name '*.pbxproj' -o -name '*.png' \) \
  -not -path '*/Models/*' -print0 | sort -z | xargs -0 shasum | shasum | cut -c1-16)
if [[ "$force" != --force && -f "$STAMP" ]]; then
  age=$(( ($(date +%s) - $(stat -f %m "$STAMP")) / 86400 ))
  if (( age < EVERY_DAYS )) && [[ "$(cat "$STAMP")" == "$code_hash" ]]; then exit 0; fi
fi

udid="${VERA_PHONE_UDID:-}"
devices=$(xcrun devicectl list devices 2>/dev/null)
if [[ -z "$udid" ]]; then
  udid=$(print -r -- "$devices" | grep -E "physical" | grep -E "iPhone[0-9,]* *\)" | grep -oE "[0-9A-F]{8}-[0-9A-F]{16}" | head -1)
fi
[[ -n "$udid" ]] || { log "нет сопряжённого iPhone"; exit 0; }
if ! print -r -- "$devices" | grep "$udid" | grep -qE "(^| )available|connected"; then
  # Logged once per waiting version, not every half hour.
  [[ "$(cat "$DATA/phone-deploy.waiting" 2>/dev/null)" == "$code_hash" ]] || log "iPhone не в сети с Маком — поставлю $code_hash, когда вернётся"
  print -r -- "$code_hash" > "$DATA/phone-deploy.waiting"; exit 0
fi

# Xcode keeps reusing a profile until it expires, so a reinstall on day 6 would still die on day 7: a profile of
# this app with less than two days left is removed, and the build below fetches a fresh one (only this app's).
PROFILES="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
for p in "$PROFILES"/*.mobileprovision(N); do
  plist=$(security cms -D -i "$p" 2>/dev/null) || continue
  [[ "$(print -r -- "$plist" | plutil -extract Entitlements.application-identifier raw -o - - 2>/dev/null)" == *."$BUNDLE" ]] || continue
  until_s=$(date -j -u -f "%Y-%m-%dT%H:%M:%SZ" "$(print -r -- "$plist" | plutil -extract ExpirationDate raw -o - -)" +%s 2>/dev/null) || continue
  if (( until_s - $(date +%s) < 2 * 86400 )); then log "профиль подписи кончается — беру новый"; rm -f -- "$p"; fi
done

"$ROOT/scripts/phone-assets.sh" >>"$LOG" 2>&1 || { log "нет ушей для телефона — scripts/build-ears-ios.sh"; exit 1; }
log "сборка для $udid"
# Release: the phone runs the ears all day (sound windows 31 times a second, GigaAM); an unoptimized Debug build ate a
# core in the background and iOS killed it (cpu_resource_fatal). Debugging from Xcode keeps its own Debug.
(cd "$ROOT/phone" && xcodebuild -project Vera.xcodeproj -scheme Vera -configuration Release -destination "id=$udid" -derivedDataPath "$BUILD" \
   -allowProvisioningUpdates build >"$BUILD/build.log" 2>&1) || { log "сборка не удалась — $BUILD/build.log"; exit 1; }
APP="$BUILD/Build/Products/Release-iphoneos/Vera.app"
# Background modes, file sharing and Live Activities are in the project's Info.plist (phone/Vera/Info.plist).
expires=$(security cms -D -i "$APP/embedded.mobileprovision" 2>/dev/null | plutil -extract ExpirationDate raw -o - - 2>/dev/null)

for try in 1 2 3; do
  if out=$(xcrun devicectl device install app --device "$udid" "$APP" 2>&1); then
    print -r -- "$code_hash" > "$STAMP"
    log "поставлено на iPhone (попытка $try), версия $code_hash, подпись до ${expires:-?}"
    exit 0
  fi
  log "установка не вышла (попытка $try): $(print -r -- "$out" | grep -m1 -E 'ERROR|error' | cut -c1-160)"
  sleep 20
done
exit 1
