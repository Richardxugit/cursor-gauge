#!/bin/bash
# Builds CursorGauge.app as a universal (Apple Silicon + Intel) bundle.
#
#   ./build.sh            build into ./build
#   ./build.sh --install  build, then replace /Applications/CursorGauge.app
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="CursorGauge"
BUNDLE_ID="com.pxu.cursorgauge"
VERSION="1.0.0"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Building universal binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64

BINARY=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

echo "==> Rendering app icon"
ICONSET="$BUILD_DIR/$APP_NAME.iconset"
rm -rf "$ICONSET"
# Run the freshly built binary to draw its own icon, keeping it in sync with the ring.
"$APP/Contents/MacOS/$APP_NAME" --emit-iconset "$ICONSET" >/dev/null
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/$APP_NAME.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>              <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>       <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>        <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>        <string>$BUNDLE_ID</string>
    <key>CFBundleIconFile</key>          <string>$APP_NAME</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key>           <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>    <string>14.0</string>
    <!-- Menu bar only: no Dock icon, no entry in the app switcher. -->
    <key>LSUIElement</key>               <true/>
    <key>NSHumanReadableCopyright</key>  <string>Local build</string>
</dict>
</plist>
PLIST

echo "==> Signing (ad-hoc)"
# Ad-hoc signature: enough for macOS to run it locally. Not notarized, so a copy that
# is *downloaded* elsewhere needs its quarantine flag cleared — see README.
codesign --force --sign - --timestamp=none "$APP" 2>/dev/null

echo "==> Verifying"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'
file "$APP/Contents/MacOS/$APP_NAME" | sed 's/^/    /'

if [[ "${1:-}" == "--install" ]]; then
    TARGET="/Applications/$APP_NAME.app"
    echo "==> Installing to $TARGET"
    if pgrep -x "$APP_NAME" >/dev/null; then
        echo "    quitting running instance"
        pkill -x "$APP_NAME" || true
        sleep 1
    fi
    rm -rf "$TARGET"
    cp -R "$APP" "$TARGET"
    echo "    installed"
fi

echo "==> Done: $APP"
