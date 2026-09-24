#!/bin/bash
# Build pace as a double-clickable, self-contained .app bundle.
#   ./make-app.sh              → build pace.app in the project root
#   ./make-app.sh --install    → also copy to /Applications and relaunch
#
# Mirrors netty's conventions: the launcher is named "pace" (so Activity Monitor
# and Login Items show "pace"), and it's marked LSUIElement so it lives only in
# the menu bar (no Dock icon).
set -euo pipefail
cd "$(dirname "$0")"

APP="pace.app"
BIN="pace"
ID="codes.charlie.pace"
VERSION="1.1.0"

echo "▸ Building release binary…"
swift build -c release 2>&1 | grep -vE "XCTest|PlatformPath|xcrun" || true
BINPATH="$(swift build -c release --show-bin-path)"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINPATH/$BIN" "$APP/Contents/MacOS/$BIN"

echo "▸ Generating icon…"
ICON_PNG="$(mktemp -t pace-icon).png"
"$BINPATH/$BIN" --make-icon "$ICON_PNG"
ICONSET="$(mktemp -d)/pace.iconset"
mkdir -p "$ICONSET"
for spec in "16:16x16" "32:16x16@2x" "32:32x32" "64:32x32@2x" \
            "128:128x128" "256:128x128@2x" "256:256x256" "512:256x256@2x" \
            "512:512x512" "1024:512x512@2x"; do
    px="${spec%%:*}"; name="${spec##*:}"
    sips -z "$px" "$px" "$ICON_PNG" --out "$ICONSET/icon_${name}.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/pace.icns"
rm -f "$ICON_PNG"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>            <string>pace</string>
    <key>CFBundleDisplayName</key>     <string>pace</string>
    <key>CFBundleIdentifier</key>      <string>$ID</string>
    <key>CFBundleExecutable</key>      <string>$BIN</string>
    <key>CFBundleIconFile</key>        <string>pace</string>
    <key>CFBundlePackageType</key>     <string>APPL</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleVersion</key>         <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>  <string>14.0</string>
    <key>LSUIElement</key>             <true/>
    <key>NSHighResolutionCapable</key> <true/>
    <key>NSPrincipalClass</key>        <string>NSApplication</string>
</dict>
</plist>
PLIST

# Ad-hoc sign so Gatekeeper lets it run after being moved (and so the login-item
# registration has a stable identity).
echo "▸ Ad-hoc signing…"
codesign --force --deep --sign - "$APP" 2>/dev/null || echo "  (codesign skipped)"

echo "✓ Built $APP"

if [[ "${1:-}" == "--install" || "${1:-}" == "install" ]]; then
    echo "▸ Installing to /Applications…"
    pkill -f "pace.app/Contents/MacOS/pace" 2>/dev/null || true
    sleep 1
    rm -rf "/Applications/$APP"
    cp -R "$APP" /Applications/
    open "/Applications/$APP"
    # Drop the build-dir copy so Spotlight/Launchpad don't show two apps.
    LSREG=/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister
    "$LSREG" -u "$PWD/$APP" 2>/dev/null || true
    rm -rf "$APP"
    echo "✓ Installed + launched /Applications/$APP (build copy cleaned)"
fi
