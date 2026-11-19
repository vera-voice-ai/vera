#!/bin/zsh
# Development launch: debug build, signed bundle, opened with the given arguments (e.g. --listen --agent).
set -euo pipefail
APP=$("$(dirname "$0")/bundle.sh" debug)
open -n "$APP" --args "$@"
