#!/bin/bash
# Generate release notes markdown
# Usage: generate-release-notes.sh <version> <output-file>

set -euo pipefail

VERSION="${1:?Version required}"
OUTPUT_FILE="${2:?Output file required}"

echo "Generating release notes for $VERSION..."

cat > "$OUTPUT_FILE" << EOF
# VibeCare $VERSION

## Installation

### Option 1: PKG Installer (Recommended)
1. Download \`VibeCare-${VERSION}.pkg\`
2. Double-click to install
3. The backend will start automatically
4. Launch VibeCare from Applications

### Option 2: Manual Installation
1. Download and extract \`vibecare-${VERSION}-macos.tar.gz\`
2. Move \`vibecare-server\` to \`/usr/local/bin/\`
3. Move \`VibeCare.app\` to \`/Applications/\`
4. Start the backend: \`vibecare-server\`
5. Launch the app from Applications

## What's Included
- VibeCare Backend Server (gRPC + Web Dashboard)
- VibeCare macOS Client App
- Automatic backend startup via LaunchAgent
- Database auto-migration

## System Requirements
- macOS 15.0 or later
- Apple Silicon (M1/M2/M3/M4) or Intel Mac

## Usage
- Backend web dashboard: http://localhost:8080/status
- gRPC endpoint: localhost:50051
- Logs: ~/Library/Logs/VibeCare/

## Verify Installation
\`\`\`bash
# Check backend is running
curl http://localhost:8080/status

# View backend logs
tail -f ~/Library/Logs/VibeCare/server.log

# Stop backend
launchctl unload ~/Library/LaunchAgents/io.vibecare.server.plist

# Start backend
launchctl load ~/Library/LaunchAgents/io.vibecare.server.plist
\`\`\`

## Checksums
Verify file integrity using the .sha256 files provided.

EOF

echo "Release notes generated: $OUTPUT_FILE"