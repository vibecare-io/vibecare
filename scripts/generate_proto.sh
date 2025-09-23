#!/bin/bash

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Generating protobuf code...${NC}"

# Get the project root directory
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROTO_DIR="$PROJECT_ROOT/proto"
BACKEND_DIR="$PROJECT_ROOT/backend"

# Create output directory if it doesn't exist
mkdir -p "$BACKEND_DIR/pkg/proto"

# Check if protoc is installed
if ! command -v protoc &> /dev/null; then
    echo -e "${RED}protoc is not installed. Please install Protocol Buffers compiler.${NC}"
    echo "On macOS: brew install protobuf"
    echo "On Linux: apt-get install protobuf-compiler"
    exit 1
fi

# Check if Go protoc plugins are installed
if ! command -v protoc-gen-go &> /dev/null; then
    echo -e "${YELLOW}Installing protoc-gen-go...${NC}"
    go install google.golang.org/protobuf/cmd/protoc-gen-go@latest
fi

if ! command -v protoc-gen-go-grpc &> /dev/null; then
    echo -e "${YELLOW}Installing protoc-gen-go-grpc...${NC}"
    go install google.golang.org/grpc/cmd/protoc-gen-go-grpc@latest
fi

# Generate Go code
echo -e "${GREEN}Generating Go code...${NC}"
protoc \
    --proto_path="$PROTO_DIR" \
    --go_out="$BACKEND_DIR/pkg/proto" \
    --go_opt=paths=source_relative \
    --go-grpc_out="$BACKEND_DIR/pkg/proto" \
    --go-grpc_opt=paths=source_relative \
    "$PROTO_DIR/vibecare.proto"

echo -e "${GREEN}✓ Go protobuf code generated successfully${NC}"

# Generate Swift code (if swift-protobuf is installed)
if command -v protoc-gen-swift &> /dev/null && command -v protoc-gen-grpc-swift &> /dev/null; then
    echo -e "${GREEN}Generating Swift code...${NC}"

    SWIFT_DIR="$PROJECT_ROOT/clients/macos-swift/VibeCare/Generated"
    mkdir -p "$SWIFT_DIR"

    protoc \
        --proto_path="$PROTO_DIR" \
        --swift_out="$SWIFT_DIR" \
        --grpc-swift_out="$SWIFT_DIR" \
        "$PROTO_DIR/vibecare.proto"

    echo -e "${GREEN}✓ Swift protobuf code generated successfully${NC}"
else
    echo -e "${YELLOW}Swift protobuf generators not found. Skipping Swift code generation.${NC}"
    echo "To install: brew install swift-protobuf grpc-swift"
fi

echo -e "${GREEN}✓ All protobuf code generation complete!${NC}"