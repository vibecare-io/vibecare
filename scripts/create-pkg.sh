#!/usr/bin/env bash
set -euo pipefail

# VibeCare PKG Installer Creation Script
# Creates a macOS .pkg installer for VibeCare

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_ROOT}/build"
DIST_DIR="${BUILD_DIR}/dist"
PKG_ROOT="${BUILD_DIR}/pkg-root"
PKG_SCRIPTS="${BUILD_DIR}/pkg-scripts"
VERSION="${VERSION:-$(git describe --tags --always --dirty)}"
PKG_NAME="VibeCare-${VERSION}.pkg"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
check_prereqs() {
    if [ ! -d "${DIST_DIR}" ]; then
        log_error "Distribution directory not found. Run build-release.sh first."
        exit 1
    fi

    if ! command -v pkgbuild &> /dev/null; then
        log_error "pkgbuild not found. This script requires macOS."
        exit 1
    fi
}

# Prepare package structure
prepare_pkg_structure() {
    log_info "Preparing package structure..."

    # Clean previous builds
    rm -rf "${PKG_ROOT}" "${PKG_SCRIPTS}"
    mkdir -p "${PKG_ROOT}"
    mkdir -p "${PKG_SCRIPTS}"

    # Create directory structure
    mkdir -p "${PKG_ROOT}/usr/local/bin"
    mkdir -p "${PKG_ROOT}/Applications"
    mkdir -p "${PKG_ROOT}/tmp/vibecare-install"

    # Copy binaries
    cp "${DIST_DIR}/vibecare-server" "${PKG_ROOT}/usr/local/bin/"
    chmod +x "${PKG_ROOT}/usr/local/bin/vibecare-server"

    # Copy app bundle
    cp -R "${DIST_DIR}/VibeCare.app" "${PKG_ROOT}/Applications/"

    # Copy LaunchAgent plist to temp location for postinstall script
    cp "${SCRIPT_DIR}/io.vibecare.server.plist" "${PKG_ROOT}/tmp/vibecare-install/"

    # Copy postinstall script
    cp "${SCRIPT_DIR}/postinstall" "${PKG_SCRIPTS}/postinstall"
    chmod +x "${PKG_SCRIPTS}/postinstall"

    log_info "Package structure prepared"
}

# Build the package
build_pkg() {
    log_info "Building PKG installer..."

    cd "${BUILD_DIR}"

    # Build unsigned package
    pkgbuild \
        --root "${PKG_ROOT}" \
        --scripts "${PKG_SCRIPTS}" \
        --identifier "io.vibecare.app" \
        --version "${VERSION}" \
        --install-location "/" \
        "${PKG_NAME}"

    log_info "PKG created: ${BUILD_DIR}/${PKG_NAME}"

    # Generate checksum
    shasum -a 256 "${PKG_NAME}" > "${PKG_NAME}.sha256"

    log_info "Checksum: ${BUILD_DIR}/${PKG_NAME}.sha256"
}

# Create distribution XML for productbuild (optional, for signed PKG)
create_distribution_xml() {
    log_info "Creating distribution XML..."

    cat > "${BUILD_DIR}/distribution.xml" << EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="1">
    <title>VibeCare</title>
    <organization>io.vibecare</organization>
    <domains enable_localSystem="true"/>
    <options customize="never" require-scripts="true" rootVolumeOnly="true" />

    <welcome file="welcome.html" mime-type="text/html" />
    <license file="LICENSE" mime-type="text/plain" />

    <pkg-ref id="io.vibecare.app"/>

    <options customize="never" require-scripts="false"/>

    <choices-outline>
        <line choice="default">
            <line choice="io.vibecare.app"/>
        </line>
    </choices-outline>

    <choice id="default"/>
    <choice id="io.vibecare.app" visible="false">
        <pkg-ref id="io.vibecare.app"/>
    </choice>

    <pkg-ref id="io.vibecare.app" version="${VERSION}" onConclusion="none">VibeCare-${VERSION}.pkg</pkg-ref>

</installer-gui-script>
EOF

    log_info "Distribution XML created"
}

# Main execution
main() {
    log_info "Creating VibeCare PKG installer v${VERSION}"

    check_prereqs
    prepare_pkg_structure
    build_pkg

    log_info "PKG installer creation complete! 🎉"
    log_info "Installer: ${BUILD_DIR}/${PKG_NAME}"
    log_info ""
    log_info "To install: sudo installer -pkg ${PKG_NAME} -target /"
}

main "$@"
