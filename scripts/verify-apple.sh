#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
  echo 'Apple verification requires a Mac with Xcode and XcodeGen.' >&2
  exit 1
fi
xcodebuild -version
xcodegen generate
xcodebuild -project OpenChat.xcodeproj -scheme OpenChat -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project OpenChat.xcodeproj -scheme OpenChat -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
