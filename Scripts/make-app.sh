#!/bin/bash
# Builds DPScope.app: a double-clickable, ad-hoc signed application bundle.
set -euo pipefail

cd "$(dirname "$0")/.."
BUNDLE="build/DPScope.app"
VERSION="2.0"

echo "==> Building release binary"
swift build -c release --product DPScope

echo "==> Assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$(swift build -c release --product DPScope --show-bin-path)/DPScope" "$BUNDLE/Contents/MacOS/DPScope"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>DPScope</string>
    <key>CFBundleDisplayName</key><string>DPScope</string>
    <key>CFBundleIdentifier</key><string>com.dpscope.mac</string>
    <key>CFBundleExecutable</key><string>DPScope</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Distributed under the Eclipse Public License.</string>
</dict>
</plist>
PLIST

echo "==> Drawing icon"
swift Scripts/MakeIcon.swift "$BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$BUNDLE"

echo "==> Done: $BUNDLE"
