#!/bin/bash
# Complete local release build pipeline
# Usage: build-local-release.sh [version]
#
# This script mirrors the GitHub Actions workflow and produces:
# - Signed backend binary
# - Signed app bundle
# - Signed PKG installer
# - Tarball archive
# - Checksums

set -euo pipefail

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Get version
VERSION="${1:-v0.1.4-local-$(date +%Y%m%d-%H%M%S)}"

log_info "Building VibeCare $VERSION locally"

# Get script directory and project root
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

cd "$PROJECT_ROOT"

# Check for signing certificates
log_info "Checking for signing certificates..."
APP_CERT=$(security find-identity -v -p codesigning | grep "Developer ID Application" | head -1 | awk '{print $2}' || true)
INSTALLER_CERT=$(security find-identity -v | grep "Developer ID Installer" | head -1 | awk '{print $2}' || true)

if [ -z "$APP_CERT" ]; then
    log_warn "No Developer ID Application certificate found"
    log_warn "Binaries and app will be unsigned (security warnings will appear)"
else
    log_info "Found Application certificate: $APP_CERT"
fi

if [ -z "$INSTALLER_CERT" ]; then
    log_warn "No Developer ID Installer certificate found"
    log_warn "PKG will be unsigned (security warnings will appear)"
else
    log_info "Found Installer certificate: $INSTALLER_CERT"
fi

# Clean previous builds
log_info "Cleaning previous builds..."
rm -rf build dist vibecare-server vibecare-client VibeCare.app

# Step 1: Build Backend
log_info "Building backend (universal binary)..."
cd backend
"${SCRIPT_DIR}/build-universal-binary.sh" "$VERSION" "../vibecare-server" "cmd/server/main.go"
cd ..

# Step 2: Sign backend binary
if [ -n "$APP_CERT" ]; then
    log_info "Signing backend binary..."
    codesign --force --sign "$APP_CERT" --options runtime --timestamp vibecare-server
    codesign --verify --deep --strict --verbose=2 vibecare-server
    log_info "Backend binary signed successfully"
else
    log_warn "Skipping backend binary signing (no certificate)"
fi

# Step 3: Build Swift Client
log_info "Building Swift client..."
cd clients/macos-swift/VibeCare
swift build -c release --product VibeCare --jobs $(sysctl -n hw.ncpu)
cp .build/release/VibeCare ../../../vibecare-client
chmod +x ../../../vibecare-client
cd ../../..

# Step 4: Create app bundle
log_info "Creating app bundle..."
"${SCRIPT_DIR}/create-app-bundle.sh" "VibeCare" "vibecare-client" "$VERSION" "io.vibecare.app"

# Step 5: Sign app bundle
if [ -n "$APP_CERT" ]; then
    log_info "Signing app bundle..."
    ENTITLEMENTS="clients/macos-swift/VibeCare/vibecare/vibecare.entitlements"
    codesign --force --sign "$APP_CERT" \
        --entitlements "$ENTITLEMENTS" \
        --options runtime \
        --timestamp \
        --deep \
        VibeCare.app
    codesign --verify --deep --strict --verbose=2 VibeCare.app
    log_info "App bundle signed successfully"
else
    log_warn "Skipping app bundle signing (no certificate)"
fi

# Step 6: Create dist directory
log_info "Creating distribution directory..."
mkdir -p dist
cp vibecare-server dist/
cp -R VibeCare.app dist/

# Step 7: Create tarball
log_info "Creating tarball..."
mkdir -p build
cd dist
tar -czf ../build/vibecare-${VERSION}-macos.tar.gz vibecare-server VibeCare.app
cd ..
shasum -a 256 build/vibecare-${VERSION}-macos.tar.gz > build/vibecare-${VERSION}-macos.tar.gz.sha256

# Step 8: Create PKG installer
log_info "Creating PKG installer..."
if [ -n "$INSTALLER_CERT" ]; then
    "${SCRIPT_DIR}/create-pkg-installer.sh" "$VERSION" "$INSTALLER_CERT" "dist/vibecare-server" "dist/VibeCare.app"
    log_info "PKG created and signed successfully"
else
    log_warn "Creating unsigned PKG (no installer certificate)"
    # Create PKG without signing
    PKG_ROOT="build/pkg-root"
    PKG_SCRIPTS="build/pkg-scripts"

    mkdir -p "${PKG_ROOT}/usr/local/bin"
    mkdir -p "${PKG_ROOT}/Applications"
    mkdir -p "${PKG_ROOT}/tmp/vibecare-install"
    mkdir -p "${PKG_SCRIPTS}"

    cp dist/vibecare-server "${PKG_ROOT}/usr/local/bin/"
    chmod +x "${PKG_ROOT}/usr/local/bin/vibecare-server"

    cp -R dist/VibeCare.app "${PKG_ROOT}/Applications/"

    cp scripts/io.vibecare.server.plist "${PKG_ROOT}/tmp/vibecare-install/"
    cp scripts/postinstall "${PKG_SCRIPTS}/postinstall"
    chmod +x "${PKG_SCRIPTS}/postinstall"

    pkgbuild \
        --root "${PKG_ROOT}" \
        --scripts "${PKG_SCRIPTS}" \
        --identifier "io.vibecare.app" \
        --version "$VERSION" \
        --install-location "/" \
        "build/VibeCare-${VERSION}.pkg"

    shasum -a 256 "build/VibeCare-${VERSION}.pkg" > "build/VibeCare-${VERSION}.pkg.sha256"
fi

# Step 9: Verify signatures (if signed)
if [ -n "$APP_CERT" ] && [ -n "$INSTALLER_CERT" ]; then
    log_info "Verifying all signatures..."
    "${SCRIPT_DIR}/verify-signatures.sh" "dist/vibecare-server" "dist/VibeCare.app" "build/VibeCare-${VERSION}.pkg"
fi

# Step 10: Generate release notes
log_info "Generating release notes..."
"${SCRIPT_DIR}/generate-release-notes.sh" "$VERSION" "build/release_notes.md"

# Summary
echo ""
log_info "=== Build Complete ==="
log_info "Version: $VERSION"
log_info ""
log_info "Artifacts created:"
ls -lh build/
echo ""
log_info "To install locally:"
log_info "  sudo installer -pkg build/VibeCare-${VERSION}.pkg -target /"
echo ""
if [ -z "$APP_CERT" ] || [ -z "$INSTALLER_CERT" ]; then
    log_warn "Some components are unsigned. Users will see security warnings."
    log_warn "To create signed releases, install Developer ID certificates in Keychain."
fi