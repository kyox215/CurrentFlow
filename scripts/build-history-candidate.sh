#!/bin/bash
# Local review bundle, isolated from the installed application and its history/preferences.
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$(mktemp -d /private/tmp/currentflow-history-candidate.XXXXXXXX)}"
STAGING="$(mktemp -d /private/tmp/currentflow-history-build.XXXXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/CurrentFlow History.app"
mkdir -p "$OUTPUT/module-cache" "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -parse-as-library \
  -target "$(uname -m)-apple-macosx13.0" -module-cache-path "$OUTPUT/module-cache" \
  -framework Cocoa -framework SwiftUI -framework IOKit -framework ServiceManagement -lsqlite3 \
  "$TASK_ROOT"/Sources/*.swift -o "$APP/Contents/MacOS/CurrentFlow"
cp "$TASK_ROOT/Info.plist" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier local.currentflow.history-candidate' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName CurrentFlow History' "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleDisplayName CurrentFlow History' "$APP/Contents/Info.plist"
xcrun swiftc -module-cache-path "$OUTPUT/module-cache" -framework Cocoa \
  "$TASK_ROOT/scripts/make-icon.swift" -o "$STAGING/MakeAppIcon"
"$STAGING/MakeAppIcon" "$STAGING/AppIcon.iconset"
/usr/bin/iconutil -c icns "$STAGING/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"
cp "$TASK_ROOT/Resources/使用说明.txt" "$TASK_ROOT/LICENSE" "$TASK_ROOT/THIRD_PARTY_NOTICES.txt" "$APP/Contents/Resources/"
/usr/bin/xattr -cr "$APP"
/usr/bin/codesign --force --sign - "$APP"
/usr/bin/codesign --verify --strict "$APP"
/usr/bin/ditto --noextattr --norsrc "$APP" "$OUTPUT/CurrentFlow History.app"
# File Provider may reattach FinderInfo when updating an existing local bundle.
if /usr/bin/xattr -p com.apple.FinderInfo "$OUTPUT/CurrentFlow History.app" >/dev/null 2>&1; then
  /usr/bin/xattr -d com.apple.FinderInfo "$OUTPUT/CurrentFlow History.app"
fi
/usr/bin/codesign --verify --strict "$OUTPUT/CurrentFlow History.app"
printf 'Local candidate: %s\n' "$OUTPUT/CurrentFlow History.app"
