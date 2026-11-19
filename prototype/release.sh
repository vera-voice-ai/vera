#!/bin/zsh
# Release build: tests first, then an optimized signed bundle zipped to dist/Vera-<version>.zip.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"
swift test 2>&1 | grep -E "Test run|✘|error:" 
VERSION=$(sed -n 's/.*version = "\(.*\)"/\1/p' SignalBus/VeraRelease.swift)
APP=$(./bundle.sh release)
mkdir -p dist
ditto -c -k --keepParent "$APP" "dist/Vera-$VERSION.zip"
echo "dist/Vera-$VERSION.zip"
