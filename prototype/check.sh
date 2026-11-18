#!/bin/zsh
# One command for "is everything still fine": build, all tests, and the harness scoreboard on the newest
# recording of a microphone session. The scoreboard (numbers only, no transcripts) goes to Evaluation/runs/.
set -euo pipefail
cd "$(dirname "$0")"
swift build
swift test 2>&1 | grep -E "Test run|✘|error:" || true
latest=$(ls -t "$HOME/Library/Application Support/VeraSensorPrototype/Recordings/"*-live.jsonl 2>/dev/null | head -1 || true)
if [[ -n "${latest:-}" ]]; then
  mkdir -p Evaluation/runs
  swift run Harness --recordings "$latest" --out Evaluation/runs/latest.md >/dev/null
  echo "harness scoreboard: Evaluation/runs/latest.md ($(basename "$latest"))"
else
  echo "no recordings yet: skipped the harness run"
fi
