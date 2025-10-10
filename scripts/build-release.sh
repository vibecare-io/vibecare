#!/usr/bin/env bash
set -euo pipefail

# VibeCare Release Build Script
# Builds both backend server and macOS client for distribution

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="${PROJECT_ROOT}/build"
DIST_DIR="${BUILD_DIR}/dist"
VERSION="${VERSION:-$(git describe --tags --always --dirty)}"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
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

# Clean previous builds
clean_build() {
    log_info "Cleaning previous builds..."
    rm -rf "${BUILD_DIR}"
    mkdir -p "${DIST_DIR}"
}

# Build backend server
build_backend() {
    log_info "Building VibeCare backend server..."

    cd "${PROJECT_ROOT}/backend"

    # Build for macOS (universal binary if possible)
    local GOOS="darwin"
    local OUTPUT="${DIST_DIR}/vibecare-server"

    # Check if we can build universal binary
    if command -v lipo &> /dev/null; then
        log_info "Building universal binary (arm64 + amd64)..."

        # Build arm64
        GOOS=${GOOS} GOARCH=arm64 CGO_ENABLED=1 go build \
            -ldflags "-X main.version=${VERSION}" \
            -o "${OUTPUT}-arm64" \
            cmd/server/main.go

        # Build amd64
        GOOS=${GOOS} GOARCH=amd64 CGO_ENABLED=1 go build \
            -ldflags "-X main.version=${VERSION}" \
            -o "${OUTPUT}-amd64" \
            cmd/server/main.go

        # Combine into universal binary
        lipo -create -output "${OUTPUT}" \
            "${OUTPUT}-arm64" \
            "${OUTPUT}-amd64"

        # Cleanup
        rm -f "${OUTPUT}-arm64" "${OUTPUT}-amd64"
    else
        # Build for current architecture only
        local ARCH=$(uname -m)
        log_warn "Building for ${ARCH} only (lipo not available for universal binary)"

        CGO_ENABLED=1 go build \
            -ldflags "-X main.version=${VERSION}" \
            -o "${OUTPUT}" \
            cmd/server/main.go
    fi

    chmod +x "${OUTPUT}"
    log_info "Backend binary: ${OUTPUT}"
}

# Build macOS Swift client
build_macos_client() {
    log_info "Building VibeCare macOS client..."

    cd "${PROJECT_ROOT}/clients/macos-swift/VibeCare"

    # Build release configuration
    swift build -c release

    # Copy executable to dist
    local SWIFT_BUILD_DIR=".build/release"
    if [ -f "${SWIFT_BUILD_DIR}/VibeCare" ]; then
        cp "${SWIFT_BUILD_DIR}/VibeCare" "${DIST_DIR}/vibecare-client"
        chmod +x "${DIST_DIR}/vibecare-client"
        log_info "macOS client binary: ${DIST_DIR}/vibecare-client"
    else
        log_error "Swift build failed - binary not found"
        exit 1
    fi
}

# Create app bundle for macOS
create_app_bundle() {
    log_info "Creating VibeCare.app bundle..."

    local APP_BUNDLE="${DIST_DIR}/VibeCare.app"
    local CONTENTS="${APP_BUNDLE}/Contents"
    local MACOS="${CONTENTS}/MacOS"
    local RESOURCES="${CONTENTS}/Resources"

    mkdir -p "${MACOS}" "${RESOURCES}"

    # Copy executable
    cp "${DIST_DIR}/vibecare-client" "${MACOS}/VibeCare"

    # Create Info.plist
    cat > "${CONTENTS}/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>VibeCare</string>
    <key>CFBundleIdentifier</key>
    <string>io.vibecare.app</string>
    <key>CFBundleName</key>
    <string>VibeCare</string>
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
</dict>
</plist>
EOF

    # Replace version placeholder
    sed -i '' "s/\${VERSION}/${VERSION}/g" "${CONTENTS}/Info.plist"

    log_info "App bundle created: ${APP_BUNDLE}"
}

# Package everything
package_release() {
    log_info "Creating release archive..."

    cd "${BUILD_DIR}"

    local ARCHIVE_NAME="vibecare-${VERSION}-macos.tar.gz"

    tar -czf "${ARCHIVE_NAME}" \
        -C dist \
        vibecare-server \
        VibeCare.app

    log_info "Release archive: ${BUILD_DIR}/${ARCHIVE_NAME}"

    # Generate checksums
    shasum -a 256 "${ARCHIVE_NAME}" > "${ARCHIVE_NAME}.sha256"

    log_info "Checksum: ${BUILD_DIR}/${ARCHIVE_NAME}.sha256"
}

# Main execution
main() {
    log_info "VibeCare Release Build v${VERSION}"
    log_info "Project root: ${PROJECT_ROOT}"

    clean_build
    just proto
    build_backend
    build_macos_client
    create_app_bundle
    package_release

    log_info "Build complete! 🎉"
    log_info "Artifacts in: ${BUILD_DIR}"
}

main "$@"
