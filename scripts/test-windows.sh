#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -n "${CURRENTFLOW_WINDOW_TEST_BUILD:-}" ]]; then
  TEST_BUILD="$CURRENTFLOW_WINDOW_TEST_BUILD"
  mkdir -p "$TEST_BUILD"
else
  TEST_BUILD="$(mktemp -d /private/tmp/currentflow-window-tests.XXXXXXXX)"
  trap 'rm -rf "$TEST_BUILD"' EXIT
fi
TEST_SOURCES=()
for file in "$TASK_ROOT"/Sources/*.swift; do
  if [[ "$file" != "$TASK_ROOT/Sources/App.swift" ]]; then TEST_SOURCES+=("$file"); fi
done
TEST_APP="$TEST_BUILD/WindowInteractionTests.app"
mkdir -p "$TEST_APP/Contents/MacOS"
cat > "$TEST_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WindowInteractionTests</string>
<key>CFBundleIdentifier</key><string>local.currentflow.window-interaction-tests</string>
<key>CFBundleName</key><string>CurrentFlow Window Tests</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xcrun swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$TEST_BUILD/module-cache" \
  -framework Cocoa -framework SwiftUI -framework IOKit -framework ServiceManagement -lsqlite3 \
  "${TEST_SOURCES[@]}" "$TASK_ROOT/Tests/WindowInteractionTests.swift" -o "$TEST_APP/Contents/MacOS/WindowInteractionTests"
"$TEST_APP/Contents/MacOS/WindowInteractionTests" "$@"
