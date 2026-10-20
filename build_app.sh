#!/bin/bash
# Builds SpaceUtilizer as a real macOS app.
#
#   ./build_app.sh            → dist/SpaceUtilizer.app + dist/SpaceUtilizer.dmg
#   ./build_app.sh --install  → same, then installs into /Applications (or ~/Applications)
#
# Needs the Swift toolchain (Xcode or Command Line Tools: `xcode-select --install`).
set -euo pipefail

APP_NAME="SpaceUtilizer"
BUNDLE_ID="com.fighter.SpaceUtilizer"
VERSION="1.2.0"
BUILD_NUMBER="$(date +%Y%m%d%H%M)"
MIN_MACOS="13.0"

ROOT="$(cd "$(dirname "$0")" && pwd)"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"
INSTALL=false
[[ "${1:-}" == "--install" ]] && INSTALL=true

cd "$ROOT"
command -v swift >/dev/null || { echo "❌ Swift not found. Install Xcode or run: xcode-select --install"; exit 1; }

# ── 1. Compile (universal binary if the full Xcode is available, otherwise this Mac's architecture)
echo "▶ Building $APP_NAME (release)…"
if swift build -c release --arch arm64 --arch x86_64 >/tmp/su_build.log 2>&1; then
    BIN="$ROOT/.build/apple/Products/Release/$APP_NAME"
    echo "  universal binary (Apple Silicon + Intel)"
else
    swift build -c release
    BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
    echo "  native binary ($(uname -m))"
fi
[[ -f "$BIN" ]] || { echo "❌ Build output not found at $BIN"; exit 1; }

# ── 2. Assemble the .app bundle
echo "▶ Creating $APP_NAME.app…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

# App icon (Resources/AppIcon.png → AppIcon.icns)
if [[ -f "$ROOT/Resources/AppIcon.png" ]]; then
    ICONSET="$(mktemp -d)/AppIcon.iconset"
    mkdir -p "$ICONSET"
    for s in 16 32 128 256 512; do
        sips -z $s $s         "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${s}x${s}.png"    >/dev/null
        sips -z $((s*2)) $((s*2)) "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
fi

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>                 <string>$APP_NAME</string>
    <key>CFBundleDisplayName</key>          <string>$APP_NAME</string>
    <key>CFBundleExecutable</key>           <string>$APP_NAME</string>
    <key>CFBundleIdentifier</key>           <string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key>          <string>APPL</string>
    <key>CFBundleShortVersionString</key>   <string>$VERSION</string>
    <key>CFBundleVersion</key>              <string>$BUILD_NUMBER</string>
    <key>CFBundleIconFile</key>             <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>       <string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key>    <string>public.app-category.utilities</string>
    <key>NSPrincipalClass</key>             <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>      <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>SpaceUtilizer asks Finder to move apps owned by the system (like App Store apps) to the Trash.</string>
</dict>
</plist>
PLIST

# ── 3. Sign (ad-hoc — fine for your own Mac)
echo "▶ Signing (ad-hoc)…"
xattr -cr "$APP"
codesign --force --deep --sign - "$APP"

# ── 4. DMG for installing on other Macs
echo "▶ Creating $APP_NAME.dmg…"
STAGE="$(mktemp -d)"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DIST/$APP_NAME.dmg"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -ov -format UDZO "$DIST/$APP_NAME.dmg" >/dev/null
rm -rf "$STAGE"

echo "✅ Built:"
echo "   $APP"
echo "   $DIST/$APP_NAME.dmg"

# ── 5. Optional install
if $INSTALL; then
    pkill -x "$APP_NAME" 2>/dev/null || true
    DEST="/Applications"
    [[ -w "$DEST" ]] || DEST="$HOME/Applications"
    mkdir -p "$DEST"
    rm -rf "$DEST/$APP_NAME.app"
    cp -R "$APP" "$DEST/"
    echo "✅ Installed to $DEST/$APP_NAME.app"
    open "$DEST/$APP_NAME.app"
fi
