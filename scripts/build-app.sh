#!/usr/bin/env bash
# Builds app/build/Subtitler.app from the Swift package (no Xcode project needed).
#
#   scripts/build-app.sh            # release build
#   scripts/build-app.sh debug      # debug build
#   scripts/build-app.sh release --open
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/app"
APP="$APP_DIR/build/Subtitler.app"

cd "$APP_DIR"
swift build -c "$CONFIG" --arch arm64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Subtitler" "$APP/Contents/MacOS/Subtitler"
# llama.cpp (translation runtime) is a dynamic framework, found via @executable_path/../Frameworks.
cp -R "$BIN_DIR/llama.framework" "$APP/Contents/Frameworks/"
# SwiftPM resource bundles (e.g. swift-transformers' Hub) are looked up in Contents/Resources.
find "$BIN_DIR" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;
sed "s|__REPO_ROOT__|$ROOT|" "$APP_DIR/Resources/Info.plist" > "$APP/Contents/Info.plist"

# Ad-hoc signature. macOS ties the Screen Recording grant to the signature, so after a
# rebuild you may need to re-enable Subtitler in System Settings › Privacy & Security.
codesign --force --deep --sign - "$APP"

echo "Built $APP"
if [[ "${2:-}" == "--open" ]]; then
    open "$APP"
fi
