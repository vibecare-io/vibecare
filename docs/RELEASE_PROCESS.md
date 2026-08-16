# VibeCare Release Process

This document outlines the complete release process for VibeCare, including code signing, notarization, and distribution.

## Overview

VibeCare releases are fully automated through GitHub Actions with proper code signing and notarization to ensure a smooth installation experience on macOS without security warnings.

## Release Types

### Production Release (Recommended)
- Triggered by pushing a version tag (e.g., `v0.1.4`)
- Automatically builds, signs, notarizes, and publishes to GitHub Releases
- Creates both PKG installer and tarball archive

### Manual Release
- Triggered via GitHub Actions workflow_dispatch
- Useful for testing or emergency releases
- Requires manual version input

## Prerequisites

Before creating a release, ensure:

1. ✅ All tests pass
2. ✅ Code is merged to main/release branch
3. ✅ Version bumped in relevant files
4. ✅ GitHub Secrets configured (see [SIGNING_SETUP.md](SIGNING_SETUP.md))
5. ✅ Changelog updated

## Release Workflow

### Step 1: Prepare the Release

```bash
# Ensure you're on the correct branch
git checkout main  # or release branch
git pull origin main

# Run tests locally
just test
just swift-test

# Build and test locally (backend, CLI, plugins, Swift client)
just build

# Optional: Test PKG creation locally
./scripts/build-release.sh
./scripts/create-pkg.sh
```

### Step 2: Create Version Tag

```bash
# Semantic versioning: vMAJOR.MINOR.PATCH
VERSION="v0.1.4"

# Create annotated tag
git tag -a $VERSION -m "Release $VERSION

- Feature: Add dark mode support
- Fix: Resolve notification timing issue
- Improvement: Better error handling"

# Push tag to trigger release
git push origin $VERSION
```

### Step 3: Monitor Release Build

```bash
# Using GitHub CLI
gh run watch

# Or via web
# Go to Actions tab on GitHub repository
```

### Step 4: Verify Release

Once the workflow completes:

1. Check [GitHub Releases](https://github.com/YOUR_ORG/vibecare/releases)
2. Verify artifacts are attached:
   - `VibeCare-v0.1.4.pkg` (signed and notarized)
   - `VibeCare-v0.1.4.pkg.sha256`
   - `vibecare-v0.1.4-macos.tar.gz`
   - `vibecare-v0.1.4-macos.tar.gz.sha256`
3. Test installation on a clean Mac

## What Happens During Release

The automated release workflow performs these steps:

### 1. Build Backend
- Builds Go backend for both arm64 and amd64
- Creates universal binary with `lipo`
- Signs binary with Developer ID Application certificate

### 2. Build Swift Client
- Builds Swift client in release mode
- Creates app bundle with Info.plist
- Signs app bundle with entitlements and hardened runtime

### 3. Create Release Package
- Imports signing certificates
- Creates PKG installer with signed components
- Signs PKG with Developer ID Installer certificate
- Submits PKG for notarization
- Staples notarization ticket
- Verifies all signatures

### 4. Publish Release
- Creates GitHub Release with release notes
- Uploads signed and notarized artifacts
- Generates SHA256 checksums

## Manual/Local Release

For testing or special cases, you can create releases locally:

### Local Build and Sign

```bash
# Set version
export VERSION="v0.1.4-test"

# Build everything
./scripts/build-release.sh

# Create and sign PKG (requires certificates in Keychain)
./scripts/create-pkg.sh

# Manual notarization (optional)
xcrun notarytool submit build/VibeCare-$VERSION.pkg \
  --apple-id "your-email@example.com" \
  --password "xxxx-xxxx-xxxx-xxxx" \
  --team-id "XXXXXXXXXX" \
  --wait

xcrun stapler staple build/VibeCare-$VERSION.pkg
```

### Manual GitHub Release

```bash
# Create release with GitHub CLI
gh release create $VERSION \
  build/VibeCare-$VERSION.pkg \
  build/VibeCare-$VERSION.pkg.sha256 \
  build/vibecare-$VERSION-macos.tar.gz \
  build/vibecare-$VERSION-macos.tar.gz.sha256 \
  --title "VibeCare $VERSION" \
  --notes "Release notes here..."
```

## Release Checklist

### Pre-Release
- [ ] All tests pass
- [ ] Code reviewed and merged
- [ ] Version updated in code
- [ ] Changelog updated
- [ ] Documentation updated

### Release
- [ ] Tag created and pushed
- [ ] GitHub Actions workflow succeeds
- [ ] Artifacts uploaded to release
- [ ] PKG is signed and notarized

### Post-Release
- [ ] Installation tested on clean Mac
- [ ] No security warnings appear
- [ ] App launches successfully
- [ ] Backend starts automatically
- [ ] Release announcement sent (if applicable)

## Versioning Strategy

We follow [Semantic Versioning](https://semver.org/):

- **MAJOR**: Incompatible API changes
- **MINOR**: New functionality (backwards-compatible)
- **PATCH**: Bug fixes (backwards-compatible)

Examples:
- `v1.0.0` - First stable release
- `v1.1.0` - New feature added
- `v1.1.1` - Bug fix
- `v2.0.0` - Breaking changes

## Rollback Procedure

If a release has critical issues:

1. **Delete the problematic release** (keep the tag for history):
```bash
gh release delete $VERSION --yes
```

2. **Fix the issue** in code

3. **Create new patch version**:
```bash
# If v0.1.4 was bad, create v0.1.5
git tag -a v0.1.5 -m "Hotfix: Resolve critical issue from v0.1.4"
git push origin v0.1.5
```

## Troubleshooting

### Release Workflow Fails

Check the workflow logs:
```bash
gh run view <run-id> --log
```

Common issues:
- **Certificate errors**: Check GitHub Secrets are correctly set
- **Notarization fails**: Review Apple requirements, check entitlements
- **Build errors**: Ensure all dependencies are available

### PKG Won't Install

Verify signatures:
```bash
pkgutil --check-signature VibeCare-v0.1.4.pkg
spctl --assess --type install --verbose VibeCare-v0.1.4.pkg
```

### Users Still See Security Warnings

Ensure:
1. PKG is properly signed (check with `pkgutil`)
2. Notarization completed (check with `xcrun stapler validate`)
3. User downloaded via HTTPS (not modified in transit)

## Release Notes Template

```markdown
# VibeCare vX.Y.Z

## 🎉 Highlights
- Brief summary of main changes

## ✨ New Features
- Feature 1: Description
- Feature 2: Description

## 🐛 Bug Fixes
- Fix: Issue description (#issue-number)
- Fix: Another issue

## 🔧 Improvements
- Performance: Optimization description
- UX: Interface improvement

## 📦 Installation

### PKG Installer (Recommended)
Download and run `VibeCare-vX.Y.Z.pkg`

### Manual Installation
Extract `vibecare-vX.Y.Z-macos.tar.gz` and follow README instructions

## 🔍 Checksums
Verify downloads with provided .sha256 files

## 📝 Full Changelog
See [CHANGELOG.md](../CHANGELOG.md)
```

## Security Considerations

### Protecting Release Credentials

1. **GitHub Secrets**: Never expose certificate passwords or Apple credentials
2. **Certificate Security**: Keep certificates in secure keychain
3. **Access Control**: Limit who can create releases
4. **Audit Trail**: Review release history regularly

### Verifying Release Integrity

Users should verify downloads:
```bash
# Check SHA256
shasum -a 256 -c VibeCare-v0.1.4.pkg.sha256

# Verify signature
pkgutil --check-signature VibeCare-v0.1.4.pkg
```

## Automation Improvements

Future enhancements to consider:

1. **Automatic version bumping** based on commit messages
2. **Changelog generation** from commit history
3. **Beta/preview releases** with separate workflow
4. **Cross-platform releases** (Windows, Linux)
5. **Update notification** in the app
6. **Homebrew formula** updates

## Support

For release-related issues:

1. Check [GitHub Actions logs](https://github.com/YOUR_ORG/vibecare/actions)
2. Review [SIGNING_SETUP.md](SIGNING_SETUP.md) for certificate issues
3. File an issue with the `release` label
4. Contact the release manager

## Related Documentation

- [SIGNING_SETUP.md](SIGNING_SETUP.md) - Certificate and signing configuration
- [GitHub Actions setup-signing.md](.github/workflows/setup-signing.md) - CI/CD signing setup
- [Apple Notarization Guide](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)