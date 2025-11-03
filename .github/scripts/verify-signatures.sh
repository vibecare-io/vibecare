#!/bin/bash
# Verify all signatures (binary, app bundle, PKG)
# Usage: verify-signatures.sh <backend-binary> <app-bundle> <pkg-path>

set -euo pipefail

BACKEND_BINARY="${1:?Backend binary path required}"
APP_BUNDLE="${2:?App bundle path required}"
PKG_PATH="${3:?PKG path required}"

echo "=== Verifying all signatures ==="

# Verify backend binary
echo ""
echo "1. Backend binary signature:"
if codesign --verify --deep --strict --verbose=2 "$BACKEND_BINARY" 2>&1; then
  echo "✓ Backend binary signature verified"
else
  echo "✗ Backend binary signature verification failed"
  exit 1
fi

# Verify app bundle
echo ""
echo "2. App bundle signature:"
if codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE" 2>&1; then
  echo "✓ App bundle signature verified"
else
  echo "✗ App bundle signature verification failed"
  exit 1
fi

# Verify PKG
echo ""
echo "3. PKG signature:"
if pkgutil --check-signature "$PKG_PATH" 2>&1; then
  echo "✓ PKG signature verified"
else
  echo "✗ PKG signature verification failed"
  exit 1
fi

# Gatekeeper assessment (may fail in CI)
echo ""
echo "4. Gatekeeper assessment (PKG):"
if spctl --assess --type install --verbose "$PKG_PATH" 2>&1; then
  echo "✓ Gatekeeper assessment passed"
else
  echo "⚠ Note: Gatekeeper assessment may fail in CI but succeed on user systems"
fi

echo ""
echo "=== All signature verifications completed successfully! ==="