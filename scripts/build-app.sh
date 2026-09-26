#!/usr/bin/env bash
# Builds app/build/Subtitler.app from the Swift package (no Xcode project needed).
#
#   scripts/build-app.sh                  # release build
#   scripts/build-app.sh debug            # debug build
#   scripts/build-app.sh release --dev    # also wire up python/ for the developer engines
#   scripts/build-app.sh release --open   # open the app when done
#
# Signing: ad-hoc by default. macOS ties the System Audio Recording grant to the
# signature, so an ad-hoc build asks again after every rebuild. Set SIGN_IDENTITY to a
# certificate in your keychain (a self-signed "Code Signing" certificate from Keychain
# Access works) to keep the grant across rebuilds:
#   SIGN_IDENTITY="Subtitler Dev" scripts/build-app.sh
set -euo pipefail

CONFIG="${1:-release}"
shift || true
DEV=0
OPEN=0
for arg in "$@"; do
    case "$arg" in
        --dev) DEV=1 ;;
        --open) OPEN=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_DIR="$ROOT/app"
APP="$APP_DIR/build/Subtitler.app"
# A stable identity keeps permissions across rebuilds: SIGN_IDENTITY, else the local
# "Subtitler Dev" certificate from scripts/make-dev-cert.sh, else ad-hoc.
if [[ -z "${SIGN_IDENTITY:-}" ]] && security find-certificate -c "Subtitler Dev" >/dev/null 2>&1; then
  SIGN_IDENTITY="Subtitler Dev"
fi
IDENTITY="${SIGN_IDENTITY:--}"

cd "$APP_DIR"
swift build -c "$CONFIG" --arch arm64
BIN_DIR="$(swift build -c "$CONFIG" --arch arm64 --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Subtitler" "$APP/Contents/MacOS/Subtitler"
# llama.cpp (translation runtime) is a dynamic framework, found via @executable_path/../Frameworks.
# Apple Silicon only, so drop the x86_64 slice.
cp -R "$BIN_DIR/llama.framework" "$APP/Contents/Frameworks/"
LLAMA_BIN="$APP/Contents/Frameworks/llama.framework/Versions/Current/llama"
if lipo -archs "$LLAMA_BIN" | grep -q x86_64; then
    lipo -thin arm64 "$LLAMA_BIN" -output "$LLAMA_BIN.arm64" && mv "$LLAMA_BIN.arm64" "$LLAMA_BIN"
fi
# SwiftPM resource bundles (e.g. swift-transformers' Hub) are looked up in Contents/Resources.
find "$BIN_DIR" -maxdepth 1 -name "*.bundle" -exec cp -R {} "$APP/Contents/Resources/" \;
cp "$APP_DIR/Resources/AppIcon.icns" "$APP/Contents/Resources/"
cp "$APP_DIR/Resources/Info.plist" "$APP/Contents/Info.plist"
if [[ $DEV == 1 ]]; then
    # Development only: lets the app find python/translate_server.py in this checkout.
    /usr/libexec/PlistBuddy -c "Add :SubtitlerRepoRoot string $ROOT" "$APP/Contents/Info.plist"
fi

# Sign inside-out: the framework first, then the app (no --deep).
codesign --force --sign "$IDENTITY" "$APP/Contents/Frameworks/llama.framework"
codesign --force --sign "$IDENTITY" "$APP"

echo "Built $APP"
if [[ $OPEN == 1 ]]; then
    open "$APP"
fi
