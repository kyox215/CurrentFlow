#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PREVIEW_ROOT="${1:-$(mktemp -d /private/tmp/currentflow-history-demo.XXXXXXXX)}"
mkdir -p "$PREVIEW_ROOT/module-cache"
APP="$PREVIEW_ROOT/History UI Preview.app"
mkdir -p "$APP/Contents/MacOS"
PREVIEW_SOURCES=()
for file in "$TASK_ROOT"/Sources/*.swift; do
  if [[ "$file" != "$TASK_ROOT/Sources/App.swift" ]]; then PREVIEW_SOURCES+=("$file"); fi
done
xcrun swiftc -swift-version 5 -O -parse-as-library -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$PREVIEW_ROOT/module-cache" \
  -framework Cocoa -framework SwiftUI -framework IOKit -framework ServiceManagement -lsqlite3 \
  "${PREVIEW_SOURCES[@]}" "$TASK_ROOT/Tests/HistoryPreview.swift" -o "$APP/Contents/MacOS/HistoryPreview"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>HistoryPreview</string>
<key>CFBundleIdentifier</key><string>local.currentflow.history-ui-preview</string>
<key>CFBundleName</key><string>History UI Preview</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
xattr -cr "$APP"
codesign --force --sign - "$APP"
if [[ ! -f "$PREVIEW_ROOT/demo/history.sqlite3" ]]; then
  python3 "$TASK_ROOT/Tests/make-history-demo.py" "$PREVIEW_ROOT/demo/history.sqlite3"
fi
printf 'Demo preview: %s\n' "$APP"
# Optional --dark / --small / --empty / --error can be passed to the executable.
