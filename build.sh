#!/bin/bash
# Builds dist/PodFill.app (ad-hoc signed). Needs only the Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release --product PodFill
BIN="$(swift build -c release --show-bin-path)/PodFill"

APP="dist/PodFill.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/PodFill"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PodFill</string>
    <key>CFBundleDisplayName</key><string>PodFill</string>
    <key>CFBundleIdentifier</key><string>local.podfill</string>
    <key>CFBundleExecutable</key><string>PodFill</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

codesign --force --deep -s - "$APP"
codesign --verify --deep --strict "$APP" && echo "Built and signed: $APP"
