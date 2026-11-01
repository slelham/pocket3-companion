#!/bin/zsh
# Builds the pocket3-companion command and Pocket3 Companion.app.
# Installs the app into /Applications when that folder is writable,
# otherwise into ~/Applications. Set APP= to choose the destination.
set -euo pipefail
cd "${0:A:h}"

if [[ -z "${APP-}" ]]; then
  if [[ -w /Applications ]]; then
    APP="/Applications/Pocket3 Companion.app"
  else
    mkdir -p "$HOME/Applications"
    APP="$HOME/Applications/Pocket3 Companion.app"
  fi
fi
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"

rm -rf build "$APP"
mkdir -p build "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BIN_DIR"

clang -O2 -c ptz.c -o build/ptz.o
clang -O2 -fobjc-arc -c format.m -o build/format.o
clang -O2 cli.c build/ptz.o -framework IOKit -framework CoreFoundation -o "$BIN_DIR/pocket3-companion"
swiftc -O -swift-version 5 -parse-as-library -import-objc-header ptz.h \
  Pocket3Companion.swift build/ptz.o build/format.o \
  -framework IOKit -framework CoreFoundation -framework Carbon -framework AVFoundation -framework Foundation \
  -o "$APP/Contents/MacOS/Pocket3Companion"

ICONSET="build/AppIcon.iconset"
mkdir -p "$ICONSET"
sips -z 16 16 assets/icon.png --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 assets/icon.png --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 assets/icon.png --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 assets/icon.png --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 assets/icon.png --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 assets/icon.png --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 assets/icon.png --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 assets/icon.png --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 assets/icon.png --out "$ICONSET/icon_512x512.png" >/dev/null
cp assets/icon.png "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>Pocket3 Companion</string>
  <key>CFBundleDisplayName</key><string>Pocket3 Companion</string>
  <key>CFBundleIdentifier</key><string>local.slelham.pocket3-companion</string>
  <key>CFBundleExecutable</key><string>Pocket3Companion</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>1.0.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSCameraUsageDescription</key><string>Shows an optional live preview, and uses that picture when Autofocus can move the lens. Pan, tilt, and zoom work without it.</string>
</dict></plist>
EOF

codesign --force --sign - "$APP"
echo "built $APP"
echo "built $BIN_DIR/pocket3-companion"
