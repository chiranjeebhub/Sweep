#!/usr/bin/env bash
# Builds Sweep.app into ./build from the Swift package.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Sweep.app"

cd "$ROOT"
swift build -c "$CONFIG" --product Sweep
BIN="$(swift build -c "$CONFIG" --show-bin-path)/Sweep"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sweep"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS will run it locally. Sign with a Developer ID to distribute.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
