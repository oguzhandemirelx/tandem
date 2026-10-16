#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
xcrun swiftc -swift-version 5 -import-objc-header Sources/Native.h Sources/Models.swift Sources/Audio.swift Sources/DDCCapabilities.swift Sources/DisplayControl.swift Sources/WindowLayout.swift Tests/main.swift build/Native.o \
 -framework AppKit -framework CoreAudio -framework CoreGraphics -framework IOKit -o build/RoutingTests
build/RoutingTests
