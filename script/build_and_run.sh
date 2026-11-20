#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-run}"
APP_NAME="OpenChat"
APP_BUNDLE="$ROOT_DIR/DerivedData/Build/Products/Debug/Neon.app"

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify) ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2; exit 2 ;;
esac

cd "$ROOT_DIR"
xcodegen generate
mkdir -p "$ROOT_DIR/.build"
cp OpenChat/OpenChat.entitlements "$ROOT_DIR/.build/local.entitlements"
/usr/libexec/PlistBuddy -c 'Delete :com.apple.developer.aps-environment' "$ROOT_DIR/.build/local.entitlements"
set --
if [[ -n "${NEON_BACKEND_URL:-}" ]]; then
  set -- "NEON_BACKEND_URL=$NEON_BACKEND_URL"
fi
xcodebuild -project OpenChat.xcodeproj -scheme OpenChat \
  -destination 'platform=macOS' -derivedDataPath "$ROOT_DIR/DerivedData" \
  CODE_SIGN_ENTITLEMENTS="$ROOT_DIR/.build/local.entitlements" \
  SDK_STAT_CACHE_ENABLE=NO \
  "$@" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES build

case "$MODE" in
  --debug|debug) lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" ;;
  --logs|logs)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'process == "OpenChat"'
    ;;
  --telemetry|telemetry)
    /usr/bin/open -n "$APP_BUNDLE"
    /usr/bin/log stream --info --style compact --predicate 'subsystem == "com.example.neon"'
    ;;
  --verify|verify)
    /usr/bin/open -n "$APP_BUNDLE"
    sleep 2
    pgrep -x "$APP_NAME"
    ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
esac
