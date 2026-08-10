#!/bin/bash
# Packages CursorGauge.app into a distributable disk image.
#
#   ./package.sh              build + drag-to-install .dmg in ./dist
#   ./package.sh --notarize   also submit to Apple (needs a Developer ID, see below)
#
# Signing is picked up automatically: if a "Developer ID Application" certificate is in
# the keychain it is used, otherwise the app is ad-hoc signed and the image ships with a
# note telling the recipient how to get past Gatekeeper. Both produce a working .dmg —
# the difference is entirely in how much friction the person opening it hits.
#
# To notarize you need a paid Apple Developer account and a stored credential:
#   xcrun notarytool store-credentials CursorGauge \
#       --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific-password>
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="CursorGauge"
VERSION=$(tr -d '[:space:]' < VERSION)
VOLUME_NAME="$APP_NAME"
NOTARY_PROFILE="${NOTARY_PROFILE:-$APP_NAME}"

BUILD_DIR="build"
DIST_DIR="dist"
STAGE="$BUILD_DIR/dmg"
APP="$BUILD_DIR/$APP_NAME.app"
DMG="$DIST_DIR/$APP_NAME-$VERSION.dmg"
SCRATCH="$BUILD_DIR/scratch.dmg"

NOTARIZE=false
[[ "${1:-}" == "--notarize" ]] && NOTARIZE=true

# ---------------------------------------------------------------- signing identity

# `codesign` wants the full certificate name; find-identity prints it in quotes.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null \
    | grep "Developer ID Application" \
    | head -1 | sed -n 's/.*"\(.*\)".*/\1/p' || true)

if [[ -z "$IDENTITY" ]]; then
    IDENTITY="-"
    echo "==> No Developer ID found — ad-hoc signing"
    if $NOTARIZE; then
        echo "    --notarize needs a Developer ID certificate; nothing to submit." >&2
        exit 1
    fi
else
    echo "==> Signing as: $IDENTITY"
fi

# ---------------------------------------------------------------- build

SIGN_IDENTITY="$IDENTITY" ./build.sh

# ---------------------------------------------------------------- stage

echo "==> Staging disk image contents"
rm -rf "$STAGE" "$SCRATCH"
mkdir -p "$STAGE" "$DIST_DIR"
cp -R "$APP" "$STAGE/"
# The symlink is what makes the window a drag-to-install target.
ln -s /Applications "$STAGE/Applications"

if [[ "$IDENTITY" == "-" ]]; then
    # Unnotarized builds are quarantined on arrival, and since macOS 15 the old
    # right-click-Open bypass is gone — so the recipient needs to be told, in the image
    # itself, what to do. A notarized build needs no such note and doesn't get one.
    cat > "$STAGE/Read me first.txt" <<NOTE
CursorGauge $VERSION
====================

1. Drag CursorGauge onto Applications.

2. This build is not signed by an Apple-registered developer, so macOS will refuse
   to open it the first time. Clear the download flag once, in Terminal:

       xattr -dr com.apple.quarantine /Applications/CursorGauge.app

   Then open it normally. (Equivalently: try to open it, then go to System Settings
   > Privacy & Security and click "Open Anyway".)

3. A hexagon appears in the menu bar showing your Cursor spend this billing cycle.
   There is nothing to configure — it reads the account already signed into Cursor
   on this Mac. No Cursor, or not signed in, and it will say so.

Requires macOS 14 or later. Intel and Apple Silicon both work.
NOTE
fi

# ---------------------------------------------------------------- window layout

# Size the writable image off the payload, with headroom for the .DS_Store the Finder
# layout writes back.
SIZE_MB=$(( $(du -sm "$STAGE" | cut -f1) + 32 ))

echo "==> Creating writable image (${SIZE_MB}MB)"
hdiutil detach "/Volumes/$VOLUME_NAME" >/dev/null 2>&1 || true
hdiutil create -srcfolder "$STAGE" -volname "$VOLUME_NAME" -fs HFS+ \
    -format UDRW -size "${SIZE_MB}m" "$SCRATCH" >/dev/null

MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen "$SCRATCH" \
    | grep -E '^/dev/' | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p' | head -1)
echo "    mounted at $MOUNT"

echo "==> Setting window layout"
# Best effort: the image is perfectly usable without a custom layout, and Finder
# automation can be refused or unavailable (headless, no permission). Never fail on it.
osascript <<APPLESCRIPT >/dev/null 2>&1 || echo "    skipped (Finder automation unavailable)"
tell application "Finder"
    tell disk "$VOLUME_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {400, 150, 1010, 690}
        set theViewOptions to the icon view options of container window
        set arrangement of theViewOptions to not arranged
        set icon size of theViewOptions to 128
        set position of item "$APP_NAME.app" of container window to {155, 180}
        set position of item "Applications" of container window to {455, 180}
        -- Below the drag target, and high enough to stay above the fold: anything that
        -- forces a scrollbar reads as a broken window rather than a considered one.
        try
            set position of item "Read me first.txt" of container window to {305, 355}
        end try
        update without registering applications
        close
    end tell
end tell
APPLESCRIPT

# Give the volume the app's own icon, so it is recognisable while mounted.
if [[ -f "$APP/Contents/Resources/$APP_NAME.icns" ]]; then
    cp "$APP/Contents/Resources/$APP_NAME.icns" "$MOUNT/.VolumeIcon.icns"
    SetFile -a C "$MOUNT" 2>/dev/null || true
fi

sync
# The Finder can hold the volume open for a moment after `close`; retry rather than
# failing the whole build on a transient busy.
for _ in 1 2 3 4 5; do
    hdiutil detach "$MOUNT" >/dev/null 2>&1 && break
    sleep 2
done

# ---------------------------------------------------------------- compress

echo "==> Compressing"
rm -f "$DMG"
hdiutil convert "$SCRATCH" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$SCRATCH"
rm -rf "$STAGE"

echo "==> Signing image"
if [[ "$IDENTITY" == "-" ]]; then
    codesign --force --sign - "$DMG" 2>/dev/null
else
    codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi

# ---------------------------------------------------------------- notarize

if $NOTARIZE; then
    echo "==> Submitting to Apple (this takes a few minutes)"
    xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
    echo "==> Stapling"
    xcrun stapler staple "$DMG"
    xcrun stapler validate "$DMG"
fi

echo "==> Verifying"
hdiutil verify "$DMG" >/dev/null && echo "    image checksum OK"
# An ad-hoc image is *expected* to fail this check, so report the result in those terms.
# A bare "rejected" looks like a broken build when it is simply an unnotarized one.
if spctl --assess --type open --context context:primary-signature "$DMG" 2>/dev/null; then
    echo "    Gatekeeper: accepted — opens with no warning"
else
    echo "    Gatekeeper: rejected — expected, this image is not notarized"
fi

echo
echo "==> Done: $DMG ($(du -h "$DMG" | cut -f1))"
if [[ "$IDENTITY" == "-" ]]; then
    echo "    Ad-hoc signed. Recipients must clear quarantine once — see 'Read me first.txt'."
fi
