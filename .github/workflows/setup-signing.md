# GitHub Actions Code Signing Setup

This guide explains how to set up Apple Developer ID certificates for signing VibeCare releases in GitHub Actions.

## Prerequisites

- Active Apple Developer Program membership ($99/year)
- Access to a Mac with the certificates installed in Keychain

## Required Certificates

You need two Developer ID certificates:

1. **Developer ID Application** - For signing the app bundle and backend binary
2. **Developer ID Installer** - For signing the PKG installer

## Exporting Certificates

### Step 1: Export from Keychain Access

1. Open Keychain Access on your Mac
2. Select "My Certificates" in the sidebar
3. Find your Developer ID certificates:
   - "Developer ID Application: Your Name (TEAMID)"
   - "Developer ID Installer: Your Name (TEAMID)"

4. For each certificate:
   - Right-click and select "Export..."
   - Choose .p12 format
   - Save with a memorable name (e.g., `DeveloperID_Application.p12`)
   - Set a strong password (you'll need this later)

### Step 2: Convert to Base64

```bash
# Convert certificates to base64 for GitHub Secrets
base64 -i DeveloperID_Application.p12 > app_cert.txt
base64 -i DeveloperID_Installer.p12 > installer_cert.txt

# Copy to clipboard (macOS)
cat app_cert.txt | pbcopy
# Paste this into APPLE_CERTIFICATE_APP_BASE64 secret

cat installer_cert.txt | pbcopy
# Paste this into APPLE_CERTIFICATE_INSTALLER_BASE64 secret

# Clean up
rm app_cert.txt installer_cert.txt
```

## GitHub Secrets Configuration

Add these secrets to your GitHub repository:

| Secret Name | Description | How to Get It |
|------------|-------------|---------------|
| `APPLE_CERTIFICATE_APP_BASE64` | Base64-encoded Developer ID Application certificate | Export from Keychain, encode with base64 |
| `APPLE_CERTIFICATE_INSTALLER_BASE64` | Base64-encoded Developer ID Installer certificate | Export from Keychain, encode with base64 |
| `APPLE_CERT_PASSWORD` | Password used when exporting certificates | Set when exporting from Keychain |
| `APPLE_TEAM_ID` | Your 10-character Apple Team ID | Apple Developer Portal → Membership → Team ID |
| `APPLE_DEVELOPER_ID` | Apple ID email for notarization | Your Apple Developer account email |
| `APPLE_APP_PASSWORD` | App-specific password for notarization | appleid.apple.com → Security → App-Specific Passwords |

### Creating an App-Specific Password

1. Go to https://appleid.apple.com
2. Sign in and navigate to "Security"
3. Under "App-Specific Passwords", click "Generate Password"
4. Name it "VibeCare CI Notarization" or similar
5. Copy the generated password (you won't see it again)
6. Add it as `APPLE_APP_PASSWORD` in GitHub Secrets

### Adding Secrets to GitHub

1. Go to your repository on GitHub
2. Navigate to Settings → Secrets and variables → Actions
3. Click "New repository secret" for each secret
4. Paste the values without any extra whitespace

## Verifying Your Setup

After adding all secrets, you can verify by:

1. Running the release workflow manually with `workflow_dispatch`
2. Checking the "Import Code Signing Certificates" step output
3. Verifying no "identity not found" errors during signing steps

## Certificate Renewal

Developer ID certificates are valid for several years, but when they expire:

1. Request new certificates from Apple Developer Portal
2. Export the new certificates from Keychain
3. Update the GitHub Secrets with new base64 values
4. The workflow will automatically use the new certificates

## Troubleshooting

### "No identity found" error
- Verify the certificate is a Developer ID certificate (not Mac App Store)
- Check the base64 encoding is complete (no truncation)
- Ensure the password matches what was used during export

### "Unable to build chain to self-signed root" error
- The intermediate certificates might be missing
- Re-export from Keychain with "Include all certificates in the certification path" checked

### Notarization failures
- Check the app-specific password is correct
- Verify your Apple Developer account is in good standing
- Ensure the Apple ID matches the account that owns the certificates

## Security Best Practices

- Never commit certificates or passwords to the repository
- Rotate app-specific passwords periodically
- Use GitHub's encrypted secrets (never GitHub variables)
- Limit access to these secrets to trusted maintainers only
- Consider using separate certificates for CI vs local development

## Local Testing

To test signing locally before pushing to CI:

```bash
# Set environment variables
export APPLE_TEAM_ID="YOUR_TEAM_ID"
export APPLE_IDENTITY="Developer ID Application: Your Name (TEAMID)"

# Test signing
codesign --force --sign "$APPLE_IDENTITY" \
  --options runtime --timestamp \
  --entitlements path/to/entitlements \
  path/to/binary

# Verify
codesign --verify --verbose path/to/binary
```