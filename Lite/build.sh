#!/bin/zsh
set -euo pipefail
cd "${0:A:h}"
APP="$PWD/build/DuoBar Lite.app"
mkdir -p "$APP/Contents/MacOS"
xcrun swiftc -O -swift-version 5 Sources/main.swift \
  -framework AppKit -framework CoreAudio -framework IOKit -framework Network \
  -o "$APP/Contents/MacOS/DuoBarLite"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built: $APP"
