#!/bin/sh
# Builds BudsDeck.app (menu bar only), runs its self-test, installs to ~/Applications.
#
# Signing: defaults to ad-hoc ("-"). macOS then re-asks for Bluetooth permission
# after every rebuild, because each ad-hoc build looks like a new app. To keep
# the grant, sign with your own identity: create an untracked `local.env` with
#   SIGN_ID="Apple Development: you@example.com (XXXXXXXXXX)"
set -e
cd "$(dirname "$0")"
[ -f local.env ] && . ./local.env
APP=build/BudsDeck.app
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS"
swiftc -O -swift-version 5 -target arm64-apple-macos26.0 BudsDeck.swift -o "$APP/Contents/MacOS/BudsDeck"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>io.github.notacp.budsdeck</string>
  <key>CFBundleName</key><string>BudsDeck</string>
  <key>CFBundleExecutable</key><string>BudsDeck</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1.0</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>NSBluetoothAlwaysUsageDescription</key><string>BudsDeck talks to your earbuds to show battery and switch noise control and EQ.</string>
</dict></plist>
PLIST
codesign --force --sign "${SIGN_ID:--}" "$APP"
"$APP/Contents/MacOS/BudsDeck" --selftest
mkdir -p ~/Applications && rm -rf ~/Applications/BudsDeck.app && cp -R "$APP" ~/Applications/
echo "installed ~/Applications/BudsDeck.app"
