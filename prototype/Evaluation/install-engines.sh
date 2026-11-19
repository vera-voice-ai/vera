#!/bin/zsh
# Installs Vera's own copies of the agent CLIs (Codex and Claude Code) into the engines folder.
# Vera uses these copies first and falls back to the system PATH only when they are missing.
set -euo pipefail

PREFIX="$HOME/Library/Application Support/VeraSensorPrototype/Engines/agents"

mkdir -p "$PREFIX"
npm install --prefix "$PREFIX" @openai/codex@0.170.0 @anthropic-ai/claude-code@2.1.328

echo "Installed in: $PREFIX"
npm ls --prefix "$PREFIX" --depth=0 @openai/codex @anthropic-ai/claude-code
