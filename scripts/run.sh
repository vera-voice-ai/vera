#!/bin/zsh
# Development launch: build, bundle, open. Extra arguments go to Vera (e.g. --mute).
set -euo pipefail
APP=$("$(dirname "$0")/bundle.sh" debug)
open -n "$APP" --args "$@"
