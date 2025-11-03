#!/bin/bash

# VibeCare Distribution Signing Script
# This script signs binaries, app bundles, and PKG installers for distribution
# It can be used both locally and in CI/CD pipelines

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_status() {
    echo -e "${GREEN}[✓]${NC} $1"
}

print_error() {
    echo -e "${RED}[✗]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[!]${NC} $1"
}

# Function to find signing identity
find_identity() {
    local identity_type="$1"
    security find-identity -v -p codesigning | grep "$identity_type" | head -1 | awk '{print $2}'
}

# Check if we have signing certificates available
check_certificates() {
    local app_identity=$(find_identity "Developer ID Application")
    local installer_identity=$(find_identity "Developer ID Installer")

    if [ -z "$app_identity" ]; then
        print_warning "No Developer ID Application certificate found"
        echo "Signing will be skipped. To enable signing:"
        echo "1. Install Developer ID certificates in Keychain"
        echo "2. Or set up GitHub Secrets for CI signing"
        return 1
    fi

    if [ -z "$installer_identity" ]; then
        print_warning "No Developer ID Installer certificate found"
        echo "PKG signing will be skipped"
    fi

    print_status "Found Developer ID Application: $app_identity"
    [ -n "$installer_identity" ] && print_status "Found Developer ID Installer: $installer_identity"
    return 0
}

# Sign a binary or executable
sign_binary() {
    local binary_path="$1"
    local entitlements="$2"

    if [ ! -f "$binary_path" ]; then
        print_error "Binary not found: $binary_path"
        return 1
    fi

    local identity=$(find_identity "Developer ID Application")
    if [ -z "$identity" ]; then
        print_warning "Skipping binary signing (no certificate)"
        return 0
    fi

    echo "Signing binary: $binary_path"

    local sign_args=(
        --force
        --sign "$identity"
        --options runtime
        --timestamp
        --verbose
    )

    # Add entitlements if provided
    if [ -n "$entitlements" ] && [ -f "$entitlements" ]; then
        sign_args+=(--entitlements "$entitlements")
    fi

    if /usr/bin/codesign "${sign_args[@]}" "$binary_path"; then
        print_status "Binary signed successfully"

        # Verify signature
        if codesign --verify --deep --strict --verbose=2 "$binary_path"; then
            print_status "Signature verified"
        else
            print_error "Signature verification failed"
            return 1
        fi
    else
        print_error "Failed to sign binary"
        return 1
    fi
}

# Sign an app bundle
sign_app_bundle() {
    local app_path="$1"
    local entitlements="$2"

    if [ ! -d "$app_path" ]; then
        print_error "App bundle not found: $app_path"
        return 1
    fi

    local identity=$(find_identity "Developer ID Application")
    if [ -z "$identity" ]; then
        print_warning "Skipping app bundle signing (no certificate)"
        return 0
    fi

    echo "Signing app bundle: $app_path"

    local sign_args=(
        --force
        --sign "$identity"
        --options runtime
        --timestamp
        --deep
        --verbose
    )

    # Add entitlements if provided
    if [ -n "$entitlements" ] && [ -f "$entitlements" ]; then
        sign_args+=(--entitlements "$entitlements")
        print_status "Using entitlements: $entitlements"
    fi

    if /usr/bin/codesign "${sign_args[@]}" "$app_path"; then
        print_status "App bundle signed successfully"

        # Verify signature
        if codesign --verify --deep --strict --verbose=2 "$app_path"; then
            print_status "Signature verified"

            # Check with spctl (may fail in CI)
            if spctl --assess --type execute --verbose "$app_path" 2>/dev/null; then
                print_status "Gatekeeper assessment passed"
            else
                print_warning "Gatekeeper assessment failed (may be normal in CI)"
            fi
        else
            print_error "Signature verification failed"
            return 1
        fi
    else
        print_error "Failed to sign app bundle"
        return 1
    fi
}

# Sign a PKG installer
sign_pkg() {
    local unsigned_pkg="$1"
    local signed_pkg="$2"

    if [ ! -f "$unsigned_pkg" ]; then
        print_error "PKG not found: $unsigned_pkg"
        return 1
    fi

    local identity=$(find_identity "Developer ID Installer")
    if [ -z "$identity" ]; then
        print_warning "Skipping PKG signing (no certificate)"
        # Just copy the unsigned PKG to the output location
        cp "$unsigned_pkg" "$signed_pkg"
        return 0
    fi

    echo "Signing PKG: $unsigned_pkg -> $signed_pkg"

    if productsign --sign "$identity" --timestamp "$unsigned_pkg" "$signed_pkg"; then
        print_status "PKG signed successfully"

        # Verify signature
        if pkgutil --check-signature "$signed_pkg"; then
            print_status "PKG signature verified"
        else
            print_error "PKG signature verification failed"
            return 1
        fi
    else
        print_error "Failed to sign PKG"
        return 1
    fi
}

# Notarize a PKG (requires Apple credentials)
notarize_pkg() {
    local pkg_path="$1"
    local apple_id="$2"
    local app_password="$3"
    local team_id="$4"

    if [ ! -f "$pkg_path" ]; then
        print_error "PKG not found: $pkg_path"
        return 1
    fi

    if [ -z "$apple_id" ] || [ -z "$app_password" ] || [ -z "$team_id" ]; then
        print_warning "Skipping notarization (credentials not provided)"
        echo "To enable notarization, provide:"
        echo "  - Apple ID (--apple-id)"
        echo "  - App-specific password (--app-password)"
        echo "  - Team ID (--team-id)"
        return 0
    fi

    echo "Submitting PKG for notarization..."

    if xcrun notarytool submit "$pkg_path" \
        --apple-id "$apple_id" \
        --password "$app_password" \
        --team-id "$team_id" \
        --wait \
        --timeout 30m; then

        print_status "Notarization successful"

        # Staple the notarization ticket
        if xcrun stapler staple "$pkg_path"; then
            print_status "Notarization ticket stapled"

            # Verify stapling
            if xcrun stapler validate "$pkg_path"; then
                print_status "Stapling verified"
            else
                print_warning "Stapling verification failed"
            fi
        else
            print_error "Failed to staple notarization ticket"
            return 1
        fi
    else
        print_error "Notarization failed"
        return 1
    fi
}

# Main function
main() {
    local mode=""
    local target=""
    local entitlements=""
    local apple_id=""
    local app_password=""
    local team_id=""
    local output=""

    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --binary)
                mode="binary"
                target="$2"
                shift 2
                ;;
            --app)
                mode="app"
                target="$2"
                shift 2
                ;;
            --pkg)
                mode="pkg"
                target="$2"
                shift 2
                ;;
            --output)
                output="$2"
                shift 2
                ;;
            --entitlements)
                entitlements="$2"
                shift 2
                ;;
            --apple-id)
                apple_id="$2"
                shift 2
                ;;
            --app-password)
                app_password="$2"
                shift 2
                ;;
            --team-id)
                team_id="$2"
                shift 2
                ;;
            --check)
                check_certificates
                exit $?
                ;;
            --help)
                cat << EOF
Usage: $0 [OPTIONS]

Sign VibeCare components for distribution.

Options:
  --binary PATH         Sign a binary executable
  --app PATH           Sign an app bundle
  --pkg PATH           Sign a PKG installer
  --output PATH        Output path for signed PKG (required for --pkg)
  --entitlements PATH  Path to entitlements file (for --binary or --app)
  --apple-id EMAIL     Apple ID for notarization
  --app-password PASS  App-specific password for notarization
  --team-id ID         Apple Team ID for notarization
  --check              Check if signing certificates are available
  --help               Show this help message

Examples:
  # Check available certificates
  $0 --check

  # Sign backend binary
  $0 --binary vibecare-server

  # Sign app bundle with entitlements
  $0 --app VibeCare.app --entitlements vibecare.entitlements

  # Sign and notarize PKG
  $0 --pkg unsigned.pkg --output signed.pkg \\
     --apple-id dev@example.com \\
     --app-password xxxx-xxxx-xxxx-xxxx \\
     --team-id XXXXXXXXXX
EOF
                exit 0
                ;;
            *)
                print_error "Unknown option: $1"
                echo "Use --help for usage information"
                exit 1
                ;;
        esac
    done

    # Validate mode
    if [ -z "$mode" ]; then
        print_error "No mode specified. Use --binary, --app, or --pkg"
        echo "Use --help for usage information"
        exit 1
    fi

    # Execute based on mode
    case $mode in
        binary)
            sign_binary "$target" "$entitlements"
            ;;
        app)
            sign_app_bundle "$target" "$entitlements"
            ;;
        pkg)
            if [ -z "$output" ]; then
                print_error "--output is required for PKG signing"
                exit 1
            fi
            sign_pkg "$target" "$output"
            # Optionally notarize if credentials provided
            if [ -n "$apple_id" ]; then
                notarize_pkg "$output" "$apple_id" "$app_password" "$team_id"
            fi
            ;;
    esac
}

# Run main function with all arguments
main "$@"