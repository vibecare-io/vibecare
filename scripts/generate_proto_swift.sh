#!/bin/bash

# Generate Swift gRPC code from protobuf definitions
# This script generates Swift code for the VibeCare gRPC client

set -e

# Colors for output
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

echo -e "${GREEN}Generating Swift protobuf code...${NC}"

# Paths
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROTO_DIR="${SCRIPT_DIR}/../proto"
OUTPUT_DIR="${SCRIPT_DIR}/../clients/macos-swift/VibeCare/vibecare/Generated"

echo "Script dir: $SCRIPT_DIR"
echo "Proto dir: $PROTO_DIR"
echo "Output dir: $OUTPUT_DIR"

# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Check if protoc is installed
if ! command -v protoc &> /dev/null; then
    echo -e "${RED}protoc is not installed. Please install protocol buffers compiler.${NC}"
    echo "On macOS: brew install protobuf"
    exit 1
fi

# Check if Swift protoc plugins are installed
if ! command -v protoc-gen-swift &> /dev/null; then
    echo -e "${YELLOW}Installing Swift protobuf plugin...${NC}"
    brew install swift-protobuf
fi

if ! command -v protoc-gen-grpc-swift &> /dev/null; then
    echo -e "${YELLOW}Installing Swift gRPC plugin...${NC}"
    brew install grpc-swift
fi

# Generate Swift code
echo -e "${GREEN}Generating Swift code from vibecare.proto...${NC}"

# Generate protobuf messages
protoc \
    --proto_path="$PROTO_DIR" \
    --swift_opt=Visibility=Public \
    --swift_out="$OUTPUT_DIR" \
    "$PROTO_DIR/vibecare.proto"

# Generate gRPC service stubs
protoc \
    --proto_path="$PROTO_DIR" \
    --plugin=protoc-gen-grpc-swift=/opt/homebrew/bin/protoc-gen-grpc-swift-2 \
    --grpc-swift_opt=Visibility=Public \
    --grpc-swift_out="$OUTPUT_DIR" \
    "$PROTO_DIR/vibecare.proto"

# List generated files
echo -e "${GREEN}Generated files:${NC}"
ls -la "$OUTPUT_DIR"

echo -e "${GREEN}✓ Swift protobuf generation complete!${NC}"
echo -e "${YELLOW}Generated files are in: $OUTPUT_DIR${NC}"