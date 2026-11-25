#!/bin/zsh
# The schedule for scripts/phone-deploy.sh: a launchd agent of the user (space.vera.v03.phone-deploy), every 30 minutes;
# the script installs only a new version or an ageing signature, and only when the iPhone is on the same network.
# Usage: phone-deploy-schedule.sh [install|remove|status]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LABEL="space.vera.v03.phone-deploy"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

case "${1:-status}" in
install)
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Application Support/Vera03"
  cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>/bin/zsh</string><string>$ROOT/scripts/phone-deploy.sh</string></array>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/bin:/bin:/usr/sbin:/sbin</string></dict>
  <key>StartInterval</key><integer>1800</integer>
  <key>StandardOutPath</key><string>$HOME/Library/Application Support/Vera03/phone-deploy.launchd.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Application Support/Vera03/phone-deploy.launchd.log</string>
</dict>
</plist>
EOF
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  launchctl bootstrap "$DOMAIN" "$PLIST"
  echo "расписание включено: $PLIST (каждые 30 минут)"
  ;;
remove)
  launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
  rm -f -- "$PLIST"
  echo "расписание снято"
  ;;
status)
  launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E "state|last exit|runs" || echo "расписания нет"
  tail -3 "$HOME/Library/Application Support/Vera03/phone-deploy.log" 2>/dev/null || true
  ;;
esac
