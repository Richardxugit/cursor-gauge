#!/bin/bash
# Builds CursorGauge.app as a universal (Apple Silicon + Intel) bundle.
#
#   ./build.sh            build into ./build
#   ./build.sh --install  build, then replace /Applications/CursorGauge.app
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="CursorGauge"
BUNDLE_ID="com.pxu.cursorgauge"
# Single source of truth, so the bundle and the .dmg filename can never disagree.
VERSION=$(tr -d '[:space:]' < VERSION)
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "==> Building universal binary (arm64 + x86_64)"
swift build -c release --arch arm64 --arch x86_64

BINARY=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/$APP_NAME

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
# Keep Spotlight out of the staging directory, or the build copy shows up in
# Launchpad and search alongside the installed one as a confusing duplicate.
touch "$BUILD_DIR/.metadata_never_index"
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

# A real Developer ID (if one is ever bought) is passed in by package.sh; without it we
# fall back to an ad-hoc signature, which is enough for macOS to run it locally but not
# enough to survive being *downloaded* elsewhere — see README.
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
    echo "==> Signing (ad-hoc)"
    codesign --force --sign - --timestamp=none "$APP" 2>/dev/null
else
    echo "==> Signing ($SIGN_IDENTITY)"
    # Hardened runtime and a secure timestamp are both preconditions for notarization.
    codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$APP"
fi

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
    # Remove the staging copy once it's installed, so only one CursorGauge.app
    # exists on the machine.
    rm -rf "$APP"
    echo "    installed (staging copy removed)"
fi

echo "==> Done: $APP"
