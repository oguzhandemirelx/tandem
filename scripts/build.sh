#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/Tandem.app/Contents/MacOS build/Tandem.app/Contents/Resources
SDK=$(xcrun --sdk macosx --show-sdk-path)
xcrun clang -isysroot "$SDK" -mmacosx-version-min=14.0 -Wall -Wextra -c Sources/Native.c -o build/Native.o
xcrun swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx14.0" -sdk "$SDK" \
  -import-objc-header Sources/Native.h Sources/*.swift build/Native.o \
  -framework AppKit -framework CoreAudio -framework IOKit -framework CoreGraphics \
  -o build/Tandem.app/Contents/MacOS/Tandem
cp Resources/Info.plist build/Tandem.app/Contents/Info.plist
cp Resources/AppIcon.icns build/Tandem.app/Contents/Resources/AppIcon.icns
if [ -n "${TANDEM_SIGNING_IDENTITY:-}" ]; then
  codesign --force --sign "$TANDEM_SIGNING_IDENTITY" --options runtime --timestamp \
    --identifier com.oguzhandemirelx.Tandem build/Tandem.app
else
  # Stable requirement keeps local Accessibility access across development rebuilds.
  codesign --force --sign - --identifier com.oguzhandemirelx.Tandem \
    --requirements '=designated => identifier "com.oguzhandemirelx.Tandem"' build/Tandem.app
fi
printf 'Built %s/build/Tandem.app\n' "$PWD"
