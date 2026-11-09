#!/bin/sh
# Builds dist/Crateyard.app: the SwiftUI app plus crateyardd, which keeps its own virtualization entitlement.
set -eu
cd "$(dirname "$0")/.."
(cd .. && ./build.sh)
swift build -c release
# Ask SwiftPM where the binary is: the output layout differs between toolchain versions.
BIN=$(swift build -c release --show-bin-path)/Crateyard
[ -f "$BIN" ] || { echo "Build output not found at $BIN. Run swift build -c release and check its errors." >&2; exit 1; }
APP=dist/Crateyard.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Crateyard"
cp ../bin/crateyardd "$APP/Contents/MacOS/crateyardd"
cp brand/Crateyard.icns "$APP/Contents/Resources/Crateyard.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Crateyard</string>
  <key>CFBundleDisplayName</key><string>Crateyard</string>
  <key>CFBundleIdentifier</key><string>app.crateyard.mac</string>
  <key>CFBundleExecutable</key><string>Crateyard</string>
  <key>CFBundleIconFile</key><string>Crateyard</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST
# crateyardd needs its virtualization entitlement again after the copy. Signing the app without --deep keeps it.
codesign --force --sign - --entitlements ../crateyardd.entitlements "$APP/Contents/MacOS/crateyardd"
codesign --force --sign - "$APP"
echo "built $APP"
