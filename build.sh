#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
target="$(uname -m)-apple-macos14.0"

mkdir -p .build/PortkeyBar.app/Contents/MacOS
xcrun swiftc -swift-version 6 -warnings-as-errors \
    Sources/Usage.swift Sources/RankingHistory.swift Tests/UsageTests.swift -o .build/usage-tests
.build/usage-tests
xcrun swiftc -swift-version 6 -warnings-as-errors -O -target "$target" \
    Sources/Usage.swift Sources/RankingHistory.swift Sources/HistoryView.swift Tools/PreviewHistory.swift \
    -o .build/preview-history
.build/preview-history
xcrun swiftc -swift-version 6 -warnings-as-errors -O -target "$target" \
    Sources/Usage.swift Sources/RankingHistory.swift Sources/HistoryView.swift \
    Sources/Credentials.swift Sources/AppDelegate.swift Sources/main.swift \
    -o .build/PortkeyBar.app/Contents/MacOS/PortkeyBar
cp Info.plist .build/PortkeyBar.app/Contents/Info.plist
codesign --force --sign - --options runtime .build/PortkeyBar.app
codesign --verify --strict .build/PortkeyBar.app
printf 'Built %s/.build/PortkeyBar.app\n' "$PWD"
