#!/bin/bash
# Create and sign PKG installer
# Usage: create-pkg-installer.sh <version> <installer-identity> <server-binary-path> <app-bundle-path>

set -euo pipefail

VERSION="${1:?Version required}"
INSTALLER_IDENTITY="${2:?Installer identity required}"
SERVER_BINARY="${3:?Server binary path required}"
APP_BUNDLE="${4:?App bundle path required}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

PKG_ROOT="build/pkg-root"
PKG_SCRIPTS="build/pkg-scripts"
PKG_NAME="VibeCare-${VERSION}.pkg"
COMPONENT_PKG="build/VibeCare-component.pkg"

echo "Creating PKG installer: $PKG_NAME"

# Create directory structure
mkdir -p "${PKG_ROOT}/usr/local/bin"
mkdir -p "${PKG_ROOT}/Applications"
mkdir -p "${PKG_ROOT}/tmp/vibecare-install"
mkdir -p "${PKG_SCRIPTS}"

# Copy files
echo "Copying files to package root..."
cp "$SERVER_BINARY" "${PKG_ROOT}/usr/local/bin/vibecare-server"
chmod +x "${PKG_ROOT}/usr/local/bin/vibecare-server"

cp -R "$APP_BUNDLE" "${PKG_ROOT}/Applications/"

# Copy LaunchAgent plist and scripts
cp "${PROJECT_ROOT}/scripts/io.vibecare.server.plist" "${PKG_ROOT}/tmp/vibecare-install/"
cp "${PROJECT_ROOT}/scripts/postinstall" "${PKG_SCRIPTS}/postinstall"
chmod +x "${PKG_SCRIPTS}/postinstall"

# Create unsigned component package
echo "Creating component package..."
pkgbuild \
  --root "${PKG_ROOT}" \
  --scripts "${PKG_SCRIPTS}" \
  --identifier "io.vibecare.app" \
  --version "$VERSION" \
  --install-location "/" \
  "$COMPONENT_PKG"

# Sign the package
echo "Signing PKG with identity: $INSTALLER_IDENTITY"
productsign --sign "$INSTALLER_IDENTITY" \
  --timestamp \
  "$COMPONENT_PKG" \
  "build/$PKG_NAME"

# Verify signature
echo "Verifying PKG signature..."
pkgutil --check-signature "build/$PKG_NAME"

# Clean up component package
rm "$COMPONENT_PKG"

# Generate checksum
shasum -a 256 "build/$PKG_NAME" > "build/${PKG_NAME}.sha256"

echo "PKG installer created successfully: build/$PKG_NAME"