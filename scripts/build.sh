#!/bin/bash
set -euo pipefail
TASK_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$TASK_ROOT/build"
APP="$BUILD/电流脉动.app"
STAGING="$(mktemp -d /private/tmp/currentflow-build.XXXXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
STAGED_APP="$STAGING/电流脉动.app"
mkdir -p "$BUILD/module-cache" "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
xcrun swiftc -swift-version 5 -O -parse-as-library \
  -target "$(uname -m)-apple-macosx13.0" \
  -module-cache-path "$BUILD/module-cache" \
  -framework Cocoa -framework SwiftUI -framework IOKit -framework ServiceManagement -lsqlite3 \
  "$TASK_ROOT"/Sources/*.swift -o "$STAGED_APP/Contents/MacOS/CurrentFlow"
cp "$TASK_ROOT/Info.plist" "$STAGED_APP/Contents/Info.plist"
xcrun swiftc -module-cache-path "$BUILD/module-cache" -framework Cocoa \
  "$TASK_ROOT/scripts/make-icon.swift" -o "$BUILD/MakeAppIcon"
"$BUILD/MakeAppIcon" "$STAGING/AppIcon.iconset"
/usr/bin/iconutil -c icns "$STAGING/AppIcon.iconset" -o "$STAGED_APP/Contents/Resources/AppIcon.icns"
cp "$TASK_ROOT/Resources/使用说明.txt" "$STAGED_APP/Contents/Resources/使用说明.txt"
cp "$TASK_ROOT/LICENSE" "$STAGED_APP/Contents/Resources/LICENSE"
cp "$TASK_ROOT/THIRD_PARTY_NOTICES.txt" "$STAGED_APP/Contents/Resources/THIRD_PARTY_NOTICES.txt"
# Sign outside File Provider folders: they can race to attach FinderInfo.
/usr/bin/xattr -cr "$STAGED_APP"
/usr/bin/codesign --force --sign - "$STAGED_APP"
/usr/bin/codesign --verify --strict "$STAGED_APP"
mkdir -p "$TASK_ROOT/artifacts"
APP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$TASK_ROOT/Info.plist")"
/usr/bin/ditto -c -k --keepParent --noextattr --norsrc "$STAGED_APP" "$TASK_ROOT/artifacts/电流脉动-$APP_VERSION.zip"
cp "$TASK_ROOT/artifacts/电流脉动-$APP_VERSION.zip" "$TASK_ROOT/artifacts/电流脉动.zip"
mkdir -p "$STAGING/distribution"
/usr/bin/ditto --noextattr --norsrc "$STAGED_APP" "$STAGING/distribution/电流脉动.app"
ln -s /Applications "$STAGING/distribution/Applications"
cp "$TASK_ROOT/Resources/使用说明.txt" "$STAGING/distribution/安装说明.txt"
cp "$TASK_ROOT/LICENSE" "$STAGING/distribution/LICENSE"
cp "$TASK_ROOT/THIRD_PARTY_NOTICES.txt" "$STAGING/distribution/THIRD_PARTY_NOTICES.txt"
/usr/bin/hdiutil create -quiet -volname "电流脉动" -srcfolder "$STAGING/distribution" \
  -format UDZO -ov "$STAGING/电流脉动-$APP_VERSION.dmg"
cp "$STAGING/电流脉动-$APP_VERSION.dmg" "$TASK_ROOT/artifacts/电流脉动-$APP_VERSION.dmg"
/usr/bin/ditto --noextattr --norsrc "$STAGED_APP" "$APP"
# File Provider retains its directory marker when copying into an existing bundle.
if /usr/bin/xattr -p com.apple.FinderInfo "$APP" >/dev/null 2>&1; then
  /usr/bin/xattr -d com.apple.FinderInfo "$APP"
fi
/usr/bin/codesign --verify --strict "$APP"
printf '已构建：%s\n' "$APP"
