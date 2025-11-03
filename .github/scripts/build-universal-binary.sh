#!/bin/bash
# Build universal macOS binary (arm64 + amd64)
# Usage: build-universal-binary.sh <version> <output-name> <source-path>

set -euo pipefail

VERSION="${1:?Version required}"
OUTPUT_NAME="${2:?Output name required}"
SOURCE_PATH="${3:?Source path required}"

echo "Building universal binary: $OUTPUT_NAME (version: $VERSION)"

# Build for arm64
echo "Building arm64 binary..."
GOOS=darwin GOARCH=arm64 CGO_ENABLED=1 go build \
  -ldflags "-X main.version=$VERSION" \
  -o "${OUTPUT_NAME}-arm64" \
  "$SOURCE_PATH"

# Build for amd64
echo "Building amd64 binary..."
GOOS=darwin GOARCH=amd64 CGO_ENABLED=1 go build \
  -ldflags "-X main.version=$VERSION" \
  -o "${OUTPUT_NAME}-amd64" \
  "$SOURCE_PATH"

# Create universal binary
echo "Creating universal binary..."
lipo -create -output "$OUTPUT_NAME" \
  "${OUTPUT_NAME}-arm64" \
  "${OUTPUT_NAME}-amd64"

chmod +x "$OUTPUT_NAME"

# Clean up architecture-specific binaries
rm "${OUTPUT_NAME}-arm64" "${OUTPUT_NAME}-amd64"

# Verify
echo "Universal binary created successfully:"
file "$OUTPUT_NAME"
lipo -info "$OUTPUT_NAME"