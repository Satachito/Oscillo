#!/bin/bash
# Builds PiLyzer.app: a double-clickable, ad-hoc signed application bundle.
set -euo pipefail

cd "$(dirname "$0")/.."
BUNDLE="build/PiLyzer.app"
VERSION="${VERSION:-3.1.1}"
BUILD_ARGS=(-c release --product PiLyzer)
if [[ "${UNIVERSAL:-0}" == 1 ]]; then BUILD_ARGS+=(--arch arm64 --arch x86_64); fi

echo "==> Building release binary"
swift build "${BUILD_ARGS[@]}"

echo "==> Assembling $BUNDLE"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$(swift build "${BUILD_ARGS[@]}" --show-bin-path)/PiLyzer" "$BUNDLE/Contents/MacOS/PiLyzer"

cat > "$BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>PiLyzer</string>
    <key>CFBundleDisplayName</key><string>PiLyzer</string>
    <key>CFBundleIdentifier</key><string>tokyo.828.pilyzer</string>
    <key>CFBundleExecutable</key><string>PiLyzer</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>MIT licensed.</string>
</dict>
</plist>
PLIST

echo "==> Drawing icon"
swift Scripts/MakeIcon.swift "$BUNDLE/Contents/Resources/AppIcon.icns"

echo "==> Signing (ad-hoc)"
codesign --force --sign - "$BUNDLE"

echo "==> Done: $BUNDLE"
