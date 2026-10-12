#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

mkdir -p .build/PortkeyBar.app/Contents/MacOS
xcrun swiftc -swift-version 6 -warnings-as-errors \
    Sources/Usage.swift Tests/UsageTests.swift -o .build/usage-tests
.build/usage-tests
xcrun swiftc -swift-version 6 -warnings-as-errors -O -target arm64-apple-macos14.0 \
    Sources/Usage.swift Sources/Credentials.swift Sources/AppDelegate.swift Sources/main.swift \
    -o .build/PortkeyBar.app/Contents/MacOS/PortkeyBar
cp Info.plist .build/PortkeyBar.app/Contents/Info.plist
codesign --force --sign - --options runtime .build/PortkeyBar.app
codesign --verify --strict .build/PortkeyBar.app
printf 'Built %s/.build/PortkeyBar.app\n' "$PWD"
