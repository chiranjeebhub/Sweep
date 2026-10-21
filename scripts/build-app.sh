#!/usr/bin/env bash
# Builds Sweep.app into ./build from the Swift package.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
# Set SWEEP_ARCHS="arm64 x86_64" to build a universal binary, and SWEEP_VERSION / SWEEP_BUILD
# to stamp the version into Info.plist (scripts/release.sh does both).
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/build/Sweep.app"

ARCH_FLAGS=()
for arch in ${SWEEP_ARCHS:-}; do ARCH_FLAGS+=(--arch "$arch"); done

cd "$ROOT"
swift build -c "$CONFIG" --product Sweep ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN="$(swift build -c "$CONFIG" --show-bin-path ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"})/Sweep"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Sweep"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# The version has to be set before signing: the signature covers Info.plist.
[ -z "${SWEEP_VERSION:-}" ] || /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $SWEEP_VERSION" "$APP/Contents/Info.plist"
[ -z "${SWEEP_BUILD:-}" ] || /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $SWEEP_BUILD" "$APP/Contents/Info.plist"
cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Ad-hoc signature so macOS will run it locally. Sign with a Developer ID to distribute.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
