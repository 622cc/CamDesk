#!/bin/bash
set -euo pipefail
PROJECT_ROOT="$(cd -- "$(dirname -- "$0")" && pwd)"
APP_PATH="$PROJECT_ROOT/build/CamDesk.app"
SDK_PATH="$(/usr/bin/xcrun --show-sdk-path)"
VERSION="$(/usr/bin/plutil -extract CFBundleShortVersionString raw "$PROJECT_ROOT/Resources/Info.plist")"
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

# Developer ID when supplied, otherwise a local ad-hoc signature.
SIGN_ID="${CODESIGN_IDENTITY:--}"
/usr/bin/codesign --force --deep --sign "$SIGN_ID" --options runtime --timestamp=none "$APP_PATH"
/usr/bin/codesign --verify --deep --strict "$APP_PATH"
printf 'Built: %s\n' "$APP_PATH"

# Disk image: the app plus an Applications shortcut for drag-to-install.
DIST="$PROJECT_ROOT/dist"
DMG="$DIST/CamDesk-$VERSION-arm64.dmg"
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/camdesk-dmg.XXXXXX")"
trap '/bin/rm -rf "$STAGE"' EXIT
mkdir -p "$DIST"
/bin/cp -R "$APP_PATH" "$STAGE/CamDesk.app"
/bin/ln -s /Applications "$STAGE/Applications"
/bin/rm -f "$DMG"
/usr/bin/hdiutil create -volname "CamDesk $VERSION" -srcfolder "$STAGE" \
  -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
if [ "$SIGN_ID" != "-" ]; then
  /usr/bin/codesign --force --sign "$SIGN_ID" --timestamp=none "$DMG"
fi
/usr/bin/hdiutil verify "$DMG" >/dev/null
/usr/bin/shasum -a 256 "$DMG" | /usr/bin/awk '{print $1"  "$2}' > "$DMG.sha256"
printf 'Disk image: %s\n' "$DMG"
/bin/cat "$DMG.sha256"
