#!/bin/bash
# Builds dist/ZipPick.app (Apple Silicon + Intel).
#   ./build.sh            build the app
#   ./build.sh install    build, copy to /Applications and register the Finder action
#   ./build.sh dmg        build and package dist/ZipPick.dmg for sharing
#
# Set SIGN_IDENTITY to a "Developer ID Application: …" certificate to produce a build
# that other Macs open without a warning (it then also needs notarizing). Without it
# the app is ad-hoc signed.
set -euo pipefail
cd "$(dirname "$0")"

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}"
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)/ZipPick"

APP="dist/ZipPick.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ZipPick"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

if [ -n "${SIGN_IDENTITY:-}" ]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
echo "Built $APP"

case "${1:-}" in
install)
    pkill -x ZipPick 2>/dev/null || true
    rm -rf /Applications/ZipPick.app
    cp -R "$APP" /Applications/ZipPick.app
    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/ZipPick.app
    /System/Library/CoreServices/pbs -update
    echo "Installed to /Applications/ZipPick.app"
    ;;
dmg)
    STAGE="$(mktemp -d)"
    trap 'rm -rf "$STAGE"' EXIT
    cp -R "$APP" "$STAGE/ZipPick.app"
    ln -s /Applications "$STAGE/Applications"
    rm -f dist/ZipPick.dmg
    hdiutil create -volname "ZipPick" -srcfolder "$STAGE" -ov -format UDZO dist/ZipPick.dmg >/dev/null
    if [ -n "${SIGN_IDENTITY:-}" ]; then
        codesign --force --timestamp --sign "$SIGN_IDENTITY" dist/ZipPick.dmg
    fi
    echo "Packaged dist/ZipPick.dmg"
    ;;
esac
