# VibeCare Code Signing & Notarization Setup Guide

This guide explains how to set up code signing and notarization for VibeCare releases to ensure users can install and run the application without security warnings on macOS.

## Table of Contents
- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Certificate Setup](#certificate-setup)
- [GitHub Actions Configuration](#github-actions-configuration)
- [Local Development](#local-development)
- [Testing](#testing)
- [Troubleshooting](#troubleshooting)

## Overview

Starting with macOS 10.15 (Catalina), Apple requires all distributed software to be:
1. **Signed** with a Developer ID certificate
2. **Notarized** by Apple
3. **Stapled** with the notarization ticket

Without these steps, users will see scary security warnings when trying to install or run VibeCare.

### What Gets Signed

- **Backend binary** (`vibecare-server`) - Signed with Developer ID Application certificate
- **Swift app bundle** (`VibeCare.app`) - Signed with Developer ID Application certificate + entitlements
- **PKG installer** (`VibeCare-*.pkg`) - Signed with Developer ID Installer certificate

## Prerequisites

### Required Accounts

1. **Apple Developer Program Membership** ($99/year)
   - Required for Developer ID certificates
   - Sign up at: https://developer.apple.com/programs/

2. **Apple ID with App-Specific Password**
   - For notarization submission
   - Create at: https://appleid.apple.com → Security → App-Specific Passwords

### Required Certificates

You need two Developer ID certificates:

| Certificate Type | Purpose | Used For |
|-----------------|---------|----------|
| Developer ID Application | Sign apps and binaries | `vibecare-server`, `VibeCare.app` |
| Developer ID Installer | Sign installers | `VibeCare-*.pkg` |

## Certificate Setup

### Step 1: Create Certificates

1. Log in to [Apple Developer Portal](https://developer.apple.com)
2. Navigate to Certificates, Identifiers & Profiles
3. Click the "+" button to create new certificates
4. Select:
   - "Developer ID Application" → Continue
   - "Developer ID Installer" → Continue
5. Follow the Certificate Signing Request (CSR) instructions
6. Download and install certificates in Keychain Access

### Step 2: Export Certificates

```bash
# Open Keychain Access
open /Applications/Utilities/Keychain\ Access.app

# Find your certificates under "My Certificates"
# Right-click each certificate and select "Export..."
# Save as .p12 format with a strong password
```

### Step 3: Prepare for GitHub Actions

```bash
# Convert to base64 for GitHub Secrets
base64 -i DeveloperID_Application.p12 | pbcopy
# Paste into APPLE_CERTIFICATE_APP_BASE64

base64 -i DeveloperID_Installer.p12 | pbcopy
# Paste into APPLE_CERTIFICATE_INSTALLER_BASE64

# Find your Team ID
security find-certificate -c "Developer ID" -p | openssl x509 -text | grep "Subject:" | grep -oE "OU=[A-Z0-9]{10}"
```

## GitHub Actions Configuration

### Required Secrets

Add these secrets to your GitHub repository (Settings → Secrets and variables → Actions):

| Secret Name | Description | How to Get |
|------------|-------------|------------|
| `APPLE_CERTIFICATE_APP_BASE64` | Base64-encoded Developer ID Application certificate | Export from Keychain, encode with `base64` |
| `APPLE_CERTIFICATE_INSTALLER_BASE64` | Base64-encoded Developer ID Installer certificate | Export from Keychain, encode with `base64` |
| `APPLE_CERT_PASSWORD` | Password for .p12 certificates | Set when exporting from Keychain |
| `APPLE_TEAM_ID` | Your 10-character Team ID | Apple Developer Portal → Membership |
| `APPLE_DEVELOPER_ID` | Apple ID email | Your developer account email |
| `APPLE_APP_PASSWORD` | App-specific password | appleid.apple.com → Security |

### Workflow Configuration

The release workflow (`.github/workflows/release.yml`) is already configured to:

1. Import certificates into a temporary keychain
2. Sign the backend binary with hardened runtime
3. Sign the app bundle with entitlements
4. Create and sign the PKG installer
5. Submit for notarization
6. Staple the notarization ticket
7. Verify all signatures

### Testing the Workflow

```bash
# Test with workflow_dispatch (manual trigger)
gh workflow run release.yml -f version=v0.1.4-test

# Monitor the workflow
gh run watch
```

## Local Development

### Quick Check

```bash
# Check if you have signing certificates
./scripts/sign-for-distribution.sh --check
```

### Building Signed Release Locally

```bash
# Build everything with signing (if certificates available)
./scripts/build-release.sh

# Create signed PKG
./scripts/create-pkg.sh

# Sign individual components
./scripts/sign-for-distribution.sh --binary vibecare-server
./scripts/sign-for-distribution.sh --app VibeCare.app --entitlements clients/macos-swift/VibeCare/vibecare/vibecare.entitlements
./scripts/sign-for-distribution.sh --pkg unsigned.pkg --output signed.pkg
```

### Manual Notarization

If you want to notarize locally:

```bash
# Set credentials
export APPLE_ID="your-email@example.com"
export APP_PASSWORD="xxxx-xxxx-xxxx-xxxx"
export TEAM_ID="XXXXXXXXXX"

# Submit for notarization
xcrun notarytool submit VibeCare-v0.1.4.pkg \
  --apple-id "$APPLE_ID" \
  --password "$APP_PASSWORD" \
  --team-id "$TEAM_ID" \
  --wait

# Staple the ticket
xcrun stapler staple VibeCare-v0.1.4.pkg

# Verify
xcrun stapler validate VibeCare-v0.1.4.pkg
spctl --assess --type install --verbose VibeCare-v0.1.4.pkg
```

## Testing

### Verification Commands

```bash
# Verify backend binary signature
codesign --verify --deep --strict --verbose=2 vibecare-server

# Verify app bundle signature
codesign --verify --deep --strict --verbose=2 VibeCare.app
spctl --assess --type execute --verbose VibeCare.app

# Verify PKG signature
pkgutil --check-signature VibeCare-v0.1.4.pkg
spctl --assess --type install --verbose VibeCare-v0.1.4.pkg

# Check notarization status
xcrun stapler validate VibeCare-v0.1.4.pkg
```

### Testing on Clean System

1. Copy the PKG to a Mac without developer tools
2. Double-click to install
3. Verify no security warnings appear
4. Check that the app launches without "unidentified developer" dialog
5. Verify LaunchAgent starts automatically

## Troubleshooting

### Common Issues

#### "No identity found" Error

**Problem**: Certificate not found during signing
**Solution**:
```bash
# List available certificates
security find-identity -v -p codesigning

# If empty, certificates not installed or not in correct keychain
# Re-import certificates or check keychain settings
```

#### "Unable to build chain to self-signed root"

**Problem**: Missing intermediate certificates
**Solution**: Re-export from Keychain with "Include all certificates in the certification path" option

#### Notarization Fails

**Problem**: Apple rejects the notarization
**Solution**:
```bash
# Get detailed log
xcrun notarytool log <submission-id> \
  --apple-id "$APPLE_ID" \
  --password "$APP_PASSWORD" \
  --team-id "$TEAM_ID"

# Common fixes:
# - Ensure hardened runtime is enabled
# - Check entitlements are correct
# - Verify all nested code is signed
```

#### "VibeCare.app is damaged"

**Problem**: Signature broken after modification
**Solution**: Never modify signed apps. Always sign as the last step.

#### Gatekeeper Still Shows Warning

**Problem**: PKG opens but shows warning
**Possible Causes**:
- Not notarized
- Notarization ticket not stapled
- Certificate expired or revoked
- Downloaded via browser that adds quarantine attribute incorrectly

### Certificate Expiration

Developer ID certificates typically expire after several years. To renew:

1. Create new certificates in Apple Developer Portal
2. Export from Keychain
3. Update GitHub Secrets
4. The workflow automatically uses the new certificates

### Debugging Locally

```bash
# Enable verbose codesign output
export CODESIGN_ALLOCATE_VERBOSE=1

# Check quarantine attributes
xattr -l VibeCare-v0.1.4.pkg

# Remove quarantine for testing (NOT for distribution)
xattr -d com.apple.quarantine VibeCare-v0.1.4.pkg

# View certificate details
security find-certificate -c "Developer ID" -p | openssl x509 -text
```

## Security Best Practices

1. **Never commit certificates or passwords to the repository**
2. **Use GitHub's encrypted secrets for sensitive data**
3. **Rotate app-specific passwords periodically**
4. **Limit access to signing secrets to trusted maintainers**
5. **Keep certificates in a secure keychain with timeout lock**
6. **Use separate certificates for development vs. distribution**
7. **Monitor certificate expiration dates**
8. **Test signed releases before distribution**

## Additional Resources

- [Apple's Notarization Documentation](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution)
- [Code Signing Guide](https://developer.apple.com/library/archive/documentation/Security/Conceptual/CodeSigningGuide/)
- [Hardened Runtime](https://developer.apple.com/documentation/security/hardened_runtime)
- [notarytool Documentation](https://developer.apple.com/documentation/security/notarizing_macos_software_before_distribution/customizing_the_notarization_workflow)
- [GitHub Encrypted Secrets](https://docs.github.com/en/actions/security-guides/encrypted-secrets)