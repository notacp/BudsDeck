#!/bin/sh
# Builds BudsDeck.app (menu bar only), runs its self-test, installs to ~/Applications.
#   ./build.sh         build + install (+ restart if running)
#   ./build.sh --dmg   build a universal, ad-hoc-signed dist/BudsDeck.dmg for a release
#
# Signing: defaults to ad-hoc ("-"). macOS then re-asks for Bluetooth permission
# after every rebuild, because each ad-hoc build looks like a new app. To keep
# the grant, sign with your own identity: create an untracked `local.env` with
#   SIGN_ID="Apple Development: you@example.com (XXXXXXXXXX)"
set -e
cd "$(dirname "$0")"
DMG=0; [ "$1" = "--dmg" ] && DMG=1
# Releases are always ad-hoc: a personal "Apple Development" identity is useless to others.
[ "$DMG" = 0 ] && [ -f local.env ] && . ./local.env
APP=build/BudsDeck.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
# Universal: Apple Silicon + Intel (macOS 26 still supports some Intel Macs).
for arch in arm64 x86_64; do
  swiftc -O -swift-version 5 -target $arch-apple-macos26.0 BudsDeck.swift -o build/BudsDeck-$arch
done
lipo -create build/BudsDeck-arm64 build/BudsDeck-x86_64 -output "$APP/Contents/MacOS/BudsDeck"
# App icon: generated from assets/icon-1024.png (the single source) with built-in macOS tools.
ICONSET=build/AppIcon.iconset; rm -rf "$ICONSET" && mkdir -p "$ICONSET" "$APP/Contents/Resources"
for s in 16 32 128 256 512; do
  sips -z $s $s assets/icon-1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) assets/icon-1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.notacp.budsdeck</string>
  <key>CFBundleName</key><string>BudsDeck</string>
  <key>CFBundleExecutable</key><string>BudsDeck</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.3.2</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>BudsDeck talks to your earbuds to show battery and switch noise control and EQ.</string>
</dict></plist>
PLIST
codesign --force --sign "${SIGN_ID:--}" "$APP"
"$APP/Contents/MacOS/BudsDeck" --selftest

if [ "$DMG" = 1 ]; then
  rm -rf build/dmg dist && mkdir -p build/dmg dist
  cp -R "$APP" build/dmg/ && ln -s /Applications build/dmg/Applications
  hdiutil create -quiet -volname BudsDeck -srcfolder build/dmg -ov -format UDZO dist/BudsDeck.dmg
  shasum -a 256 dist/BudsDeck.dmg
  exit 0
fi
# Quit a running copy first, otherwise `open` just re-activates the old version.
WAS_RUNNING=0; pkill -x BudsDeck && WAS_RUNNING=1 && sleep 1
mkdir -p ~/Applications && rm -rf ~/Applications/BudsDeck.app && cp -R "$APP" ~/Applications/
echo "installed ~/Applications/BudsDeck.app"
[ "$WAS_RUNNING" = 1 ] && open ~/Applications/BudsDeck.app && echo "restarted BudsDeck"
exit 0
