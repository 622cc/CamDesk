#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
APP_PATH="$PROJECT_ROOT/build/CamDesk.app"
SDK_PATH="$(/usr/bin/xcrun --show-sdk-path)"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
/usr/bin/xcrun swiftc -swift-version 5 -parse-as-library -O \
  -target arm64-apple-macosx14.0 -sdk "$SDK_PATH" \
  -framework SwiftUI -framework AppKit -framework AVFoundation \
  -framework Network -framework Security -framework CryptoKit \
  "$PROJECT_ROOT"/Sources/*.swift -o "$APP_PATH/Contents/MacOS/CamDesk"
/usr/bin/plutil -lint "$PROJECT_ROOT/Resources/Info.plist"
/bin/cp "$PROJECT_ROOT/Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
if [ -f "$PROJECT_ROOT/Resources/AppIcon.icns" ]; then
  /bin/cp "$PROJECT_ROOT/Resources/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"
fi
/usr/bin/codesign --force --sign - "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
printf 'Built: %s\n' "$APP_PATH"
