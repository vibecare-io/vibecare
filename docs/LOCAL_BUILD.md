# Local Build Guide

This guide explains how to build, sign, and package VibeCare releases locally, mirroring the GitHub Actions CI workflow.

## Quick Start

```bash
# One command to build everything
./.github/scripts/build-local-release.sh v0.1.4-local

# Result: Signed PKG installer in build/
```

##Prerequisites

### Required

- **macOS 15.0+** (for running and testing)
- **Xcode Command Line Tools** (`xcode-select --install`)
- **Go 1.24+** (`brew install go`)
- **Swift 6.0+** (comes with Xcode)
- **Protobuf Compiler** (`brew install protobuf`)

### Optional (for signing)

- **Apple Developer ID Application Certificate** - For signing binaries and app bundles
- **Apple Developer ID Installer Certificate** - For signing PKG installers
- **Apple Developer Account** - For notarization

## Building Locally

### Option 1: Complete Build (Recommended)

Build everything with one command:

```bash
# With automatic version
./.github/scripts/build-local-release.sh

# With specific version
./.github/scripts/build-local-release.sh v0.1.4-local-test
```

**What it does:**
1. Builds universal backend binary (arm64 + amd64)
2. Builds Swift client
3. Creates macOS app bundle
4. Signs binary and app (if certificates available)
5. Creates PKG installer
6. Signs PKG (if certificates available)
7. Creates tarball archive
8. Generates checksums and release notes

**Output:**
```
build/
├── VibeCare-v0.1.4-local-test.pkg
├── VibeCare-v0.1.4-local-test.pkg.sha256
├── vibecare-v0.1.4-local-test-macos.tar.gz
├── vibecare-v0.1.4-local-test-macos.tar.gz.sha256
└── release_notes.md
```

### Option 2: Step-by-Step Build

Build components individually for testing:

#### 1. Build Backend Binary

```bash
cd backend
../.github/scripts/build-universal-binary.sh "v0.1.4-local" "../vibecare-server" "cmd/server/main.go"
cd ..

# Verify
file vibecare-server
lipo -info vibecare-server
```

#### 2. Build Swift Client

```bash
cd clients/macos-swift/VibeCare
swift build -c release --product VibeCare
cp .build/release/VibeCare ../../../vibecare-client
cd ../../..
```

#### 3. Create App Bundle

```bash
./.github/scripts/create-app-bundle.sh \
  "VibeCare" \
  "vibecare-client" \
  "v0.1.4-local" \
  "io.vibecare.app"

# Verify
ls -la VibeCare.app/Contents/MacOS/
plutil -p VibeCare.app/Contents/Info.plist
```

#### 4. Sign Components (if certificates available)

```bash
# Find your signing identities
security find-identity -v -p codesigning | grep "Developer ID"

# Set variables
APP_CERT="YOUR_APP_CERTIFICATE_HASH"
INSTALLER_CERT="YOUR_INSTALLER_CERTIFICATE_HASH"

# Sign backend binary
codesign --force --sign "$APP_CERT" --options runtime --timestamp vibecare-server

# Sign app bundle
codesign --force --sign "$APP_CERT" \
  --entitlements clients/macos-swift/VibeCare/vibecare/vibecare.entitlements \
  --options runtime --timestamp --deep VibeCare.app

# Verify
codesign --verify --deep --strict --verbose=2 vibecare-server
codesign --verify --deep --strict --verbose=2 VibeCare.app
```

#### 5. Create PKG Installer

```bash
# Create dist directory
mkdir -p dist
cp vibecare-server dist/
cp -R VibeCare.app dist/

# Create PKG
./.github/scripts/create-pkg-installer.sh \
  "v0.1.4-local" \
  "$INSTALLER_CERT" \
  "dist/vibecare-server" \
  "dist/VibeCare.app"

# Verify
pkgutil --check-signature build/VibeCare-v0.1.4-local.pkg
```

#### 6. Notarize (Optional)

```bash
# Set credentials
export APPLE_ID="your-email@example.com"
export APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"  # App-specific password
export TEAM_ID="XXXXXXXXXX"

# Notarize
./.github/scripts/notarize-pkg.sh \
  "build/VibeCare-v0.1.4-local.pkg" \
  "$APPLE_ID" \
  "$APP_PASSWORD" \
  "$TEAM_ID"

# Verify
xcrun stapler validate build/VibeCare-v0.1.4-local.pkg
```

## Signing Setup

### Getting Certificates

1. **Enroll in Apple Developer Program** ($99/year)
   - Go to https://developer.apple.com/programs/

2. **Create Certificates**
   - Log in to Apple Developer Portal
   - Navigate to Certificates, Identifiers & Profiles
   - Create both:
     - Developer ID Application certificate
     - Developer ID Installer certificate

3. **Install Certificates**
   - Download .cer files
   - Double-click to install in Keychain
   - Verify installation:
     ```bash
     security find-identity -v -p codesigning
     ```

### Without Certificates

You can still build without certificates, but:
- Binaries will be unsigned
- Users will see security warnings
- Gatekeeper will block installation by default
- Good for development/testing only

To install unsigned PKG on your own Mac:
```bash
# Right-click PKG → Open (override security)
# Or use command line:
sudo installer -pkg build/VibeCare-v0.1.4-local.pkg -target / -allowUntrusted
```

## Testing Individual Scripts

All workflow scripts can be tested independently:

### Test Version Extraction

```bash
# Simulate tag push
export GITHUB_REF="refs/tags/v0.1.4"
echo "VERSION=${GITHUB_REF#refs/tags/}"

# Simulate manual version
VERSION="v0.1.4-manual"
```

### Test Build Scripts

```bash
# Test universal binary build
cd backend
../.github/scripts/build-universal-binary.sh "v0.1.4-test" "../test-server" "cmd/server/main.go"
cd ..

# Test app bundle creation
./.github/scripts/create-app-bundle.sh "TestApp" "test-binary" "v0.1.4" "io.test.app"
```

### Test Signature Verification

```bash
# Create some test artifacts and verify
./.github/scripts/verify-signatures.sh \
  "dist/vibecare-server" \
  "dist/VibeCare.app" \
  "build/VibeCare-v0.1.4-local.pkg"
```

### Test Release Notes Generation

```bash
./.github/scripts/generate-release-notes.sh "v0.1.4-test" "test-notes.md"
cat test-notes.md
```

## Comparison: Local vs CI

| Feature | Local Build | CI Build |
|---------|------------|----------|
| **Build artifacts** | Identical | Identical |
| **Signing** | Optional (if certs installed) | Required (from secrets) |
| **Notarization** | Optional | Automatic |
| **Environment** | Your Mac | GitHub macOS runner |
| **Speed** | Faster (no setup overhead) | Slower (clean environment) |
| **Testing** | Easy (iterate quickly) | Requires push/tag |

## Troubleshooting

### "No Developer ID certificate found"

**Problem:** Scripts can't find signing certificates

**Solution:**
```bash
# Check Keychain
security find-identity -v -p codesigning | grep "Developer ID"

# If empty, install certificates from Apple Developer Portal
```

### "Permission denied" when running scripts

**Problem:** Scripts not executable

**Solution:**
```bash
chmod +x .github/scripts/*.sh
```

### "Protobuf generation failed"

**Problem:** Missing protobuf compiler or plugins

**Solution:**
```bash
brew install protobuf
go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
```

### "Build fails with SDK path errors"

**Problem:** CGO can't find macOS SDK

**Solution:**
```bash
# Set SDK path manually
export SDK_PATH=$(xcrun --show-sdk-path)
export CGO_CFLAGS="-isysroot $SDK_PATH"
export CGO_LDFLAGS="-isysroot $SDK_PATH"
export CGO_ENABLED=1
```

### "PKG won't install - security warning"

**Problem:** PKG is unsigned or not notarized

**Solution:**
```bash
# For your own Mac, bypass Gatekeeper:
sudo installer -pkg build/VibeCare-*.pkg -target / -allowUntrusted

# For distribution, sign and notarize the PKG
```

### "Notarization fails"

**Problem:** Invalid credentials or PKG issue

**Solution:**
```bash
# Check credentials
xcrun notarytool history --apple-id your-email@example.com --password xxxx --team-id XXXX

# Get detailed error log
xcrun notarytool log SUBMISSION_ID --apple-id your-email@example.com --password xxxx --team-id XXXX
```

## CI vs Local Differences

### Environment Variables

**CI uses:**
- `$RUNNER_TEMP` for temporary files
- `$GITHUB_WORKSPACE` for working directory
- `$GITHUB_REF` for version tags

**Local uses:**
- Current directory
- Command-line arguments for version
- Keychain for certificate access

### Secrets

**CI:**
- Certificates stored as base64-encoded GitHub Secrets
- Automatically imported into temporary keychain

**Local:**
- Certificates installed in your login keychain
- Accessed directly by `security` commands

## Best Practices

1. **Always test locally first** before pushing to CI
2. **Use semantic versions** (v1.0.0, not v1.0 or 1.0)
3. **Keep local builds in separate branch** (e.g., `local-test-builds`)
4. **Don't commit build artifacts** to git
5. **Test unsigned builds** to verify functionality without signing
6. **Test signed builds** before creating releases
7. **Notarize for distribution** to avoid user security warnings

## Automation with just

Add to `justfile` for convenience:

```just
# Build local release
build-local version="v0.1.4-local":
    ./.github/scripts/build-local-release.sh {{version}}

# Test all scripts individually
test-scripts:
    ./.github/scripts/build-universal-binary.sh "test" "test-server" "backend/cmd/server/main.go"
    ./.github/scripts/create-app-bundle.sh "Test" "test-server" "test" "io.test"
    ./.github/scripts/generate-release-notes.sh "test" "test-notes.md"

# Quick build without signing
build-quick:
    cd backend && go build -o ../vibecare-server cmd/server/main.go
    cd clients/macos-swift/VibeCare && swift build -c release
```

## Related Documentation

- [SIGNING_SETUP.md](SIGNING_SETUP.md) - Certificate setup guide
- [RELEASE_PROCESS.md](RELEASE_PROCESS.md) - Official release workflow
- [.github/REFACTORING_SUMMARY.md](../.github/REFACTORING_SUMMARY.md) - Workflow refactoring details
- [.claude/tasks/REFACTOR_GITHUB_ACTIONS.md](../.claude/tasks/REFACTOR_GITHUB_ACTIONS.md) - Task history