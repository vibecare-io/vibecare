#!/bin/bash
# Create macOS .app bundle structure with Info.plist
# Usage: create-app-bundle.sh <app-name> <binary-path> <version> <bundle-id>

set -euo pipefail

APP_NAME="${1:?App name required}"
BINARY_PATH="${2:?Binary path required}"
VERSION="${3:?Version required}"
BUNDLE_ID="${4:?Bundle ID required}"

APP_BUNDLE="${APP_NAME}.app"

echo "Creating app bundle: $APP_BUNDLE (version: $VERSION)"

# Create directory structure
mkdir -p "${APP_BUNDLE}/Contents/MacOS"
mkdir -p "${APP_BUNDLE}/Contents/Resources"

# Copy binary
echo "Copying binary to app bundle..."
cp "$BINARY_PATH" "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"
chmod +x "${APP_BUNDLE}/Contents/MacOS/${APP_NAME}"

# Create Info.plist
echo "Creating Info.plist..."
cat > "${APP_BUNDLE}/Contents/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>${APP_NAME}</string>
    <key>CFBundleIdentifier</key>
    <string>${BUNDLE_ID}</string>
    <key>CFBundleName</key>
    <string>${APP_NAME}</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSUIElement</key>
    <true/>
    <key>NSCameraUsageDescription</key>
    <string>VibeCheck uses the camera to detect body-focused repetitive behaviors. Video is processed on-device and never leaves your Mac.</string>
</dict>
</plist>
EOF

echo "App bundle created successfully: $APP_BUNDLE"
ls -lh "$APP_BUNDLE/Contents/MacOS/"