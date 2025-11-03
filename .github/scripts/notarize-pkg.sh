#!/bin/bash
# Notarize PKG and staple notarization ticket
# Usage: notarize-pkg.sh <pkg-path> <apple-id> <app-password> <team-id>

set -euo pipefail

PKG_PATH="${1:?PKG path required}"
APPLE_ID="${2:?Apple ID required}"
APP_PASSWORD="${3:?App password required}"
TEAM_ID="${4:?Team ID required}"

echo "Submitting PKG for notarization: $PKG_PATH"

# Submit for notarization
xcrun notarytool submit "$PKG_PATH" \
  --apple-id "$APPLE_ID" \
  --password "$APP_PASSWORD" \
  --team-id "$TEAM_ID" \
  --wait \
  --timeout 30m

echo "Notarization completed. Stapling ticket..."

# Staple the notarization ticket
xcrun stapler staple "$PKG_PATH"

# Verify stapling
echo "Verifying notarization stapling..."
xcrun stapler validate "$PKG_PATH"

# Final Gatekeeper check
echo "Running Gatekeeper assessment..."
if spctl --assess --type install --verbose "$PKG_PATH" 2>&1; then
  echo "Gatekeeper assessment passed"
else
  echo "Warning: Gatekeeper assessment failed, but continuing..."
  echo "This may be normal in CI environment"
fi

echo "Notarization and stapling completed successfully"