#!/bin/zsh
# Music to Vera's iPhone app over Wi-Fi (or cable): copies a folder or files into the app's Documents/Music, skipping
# what is already there. Usage: scripts/phone-music.sh <folder-or-file>...
# The phone must be on the Mac's network and the app installed (scripts/phone-deploy.sh).
set -euo pipefail
(( $# )) || { print -u2 "usage: $0 <folder-or-file>..."; exit 2; }
BUNDLE="$("$(dirname "$0")/phone-bundle.sh")"
udid=$(xcrun devicectl list devices 2>/dev/null | awk '/physical/ && /iPhone/ && /(^| )available|connected/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F]{8}-[0-9A-F]{16}$/) print $i}' | head -1)
[[ -n "$udid" ]] || { print -u2 "iPhone не в сети с Маком"; exit 1; }
args=()
for src in "$@"; do args+=(--source "$src"); done
xcrun devicectl device copy to --device "$udid" "${args[@]}" \
  --domain-type appDataContainer --domain-identifier "$BUNDLE" --destination Documents/Music
print "залито в Документы/Music приложения Вера — на телефоне потяни список вниз, чтобы обновить"
